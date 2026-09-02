# One sample of the Vid.sys paged pool alongside the hypervisor's own page
# counters, appended to a CSV. Sampled at one minute, not thirty.
#
# WHY THIS EXISTS, AND WHY IT IS SEPARATE FROM pool-tags.ps1. Between 03:15 and
# 03:41 on 2026-08-31 the pool tag Vi54 fell 373.9 MB with no reboot and no
# intervention, in steps of 145 to 195 MB separated by flat plateaus. Over the
# same window the summed paged pool across every tag on the machine moved
# -357.0 MB, so Vi54 accounts for more than the whole of it; the next largest
# mover was Vi12 at -20.9 MB, eighteen times smaller. When paged pool moves on
# this machine, it is Vi54 moving.
#
# The 30-minute sampler cannot see this. Its interval is longer than the
# plateaus, so it samples the levels and misses every transition. The question
# now is not "what level is Vi54 at" but "what else moves at the instant Vi54
# steps", and that needs an interval shorter than the step spacing.
#
# THE PRE-REGISTERED TEST, stated here so it cannot be re-chosen later:
#
#   If gpa4k_guest steps at the same samples as vi54_mb and in the same
#   direction, Vi54 is a per-guest-page structure and its size is set by how
#   much guest physical memory the host is currently backing.
#   If gpa4k_guest sits flat across a Vi54 step, it is not, and the ratio
#   vi54_mb / gpa4k_guest is a coincidence of magnitude.
#
#   The two are not the same number today: Vid Physical Pages Allocated reads
#   3,174,400 and 4K GPA Pages reads 3,190,796, a 16,396 page difference. The
#   first is known to be a constant -- see below. The second has never been
#   sampled twice on this machine, so whether it moves at all is open.
#
# WHY NOT vmmemWSL. It was the obvious candidate and the 26-minute series ruled
# it out on step alignment, which is stronger than correlation: vmmemWSL's
# largest single step (-304 MB at 03:39) lands where Vi54 is flat, and Vi54's
# four largest steps all land where vmmemWSL is flat within 47 MB. It is still
# logged here, because ruling a quantity out of one mechanism is not ruling it
# out of the machine, and because it is the number the 2026-08-21 retraction
# identified as the VM's real host cost.
#
# THE COUNTER THAT IS A CONSTANT. \Hyper-V VM Vid Partition\Physical Pages
# Allocated reads 3,174,400 pages = 12,400 MB. It read exactly that ten days
# ago. On 2026-08-21 this investigation retracted an entire finding built on it
# (commit a219530) after a perturbation experiment showed it does not move when
# guest memory does: it is the hot-add ceiling, matching "Max. dynamic memory
# size: 12400 MB" in the guest's dmesg and "Initial Memory Assigned Per Node"
# in Hyper-V VM Worker Process NUMA Manager. It is logged anyway, as vid_pages,
# for the single purpose of staying visible as a constant. A column that never
# moves is the cheapest possible guard against quoting it as though it had.
#
# A COUNTER THAT IS GARBAGE, DELIBERATELY NOT LOGGED. \Hyper-V Dynamic Memory
# Balancer(system balancer)\Available Memory For Balancing reads 4,294,967,090,
# which is 2^32 - 206. That is an unsigned underflow, not a quantity.
#
# A COUNTER SET THAT IS EMPTY, WHICH IS NOT THE SAME AS ZERO. Hyper-V Dynamic
# Memory VM has twelve counters that would have answered this question directly
# -- Added Memory, Removed Memory, Memory Add Operations, Current Pressure --
# and no instances at all on this machine, failing with "the specified instance
# does not exist". WSL's utility VM is not managed by the Dynamic Memory
# Balancer, so that path is genuinely absent rather than unreadable, and no
# column here pretends otherwise.
#
# FAILED QUERIES ARE 'na', NEVER 0.
#
# COST, MEASURED RATHER THAN ASSERTED. This header first claimed "roughly 1 s
# wall clock". That was a guess and it was wrong by a factor of eight. Timed:
#
#   powershell.exe -NoProfile startup      1.08 s
#   Add-Type (C# compile, every run)       1.05 s
#   Get-Counter memory group               2.50 s   (first PDH call pays init)
#   Get-Counter rate group, 2 samples      2.08 s
#   Get-Counter Hyper-V group              1.04 s
#   Get-Process + grouping                 0.21 s
#   NtQuerySystemInformation + decode      0.07 s
#
# The actual measurement -- 4,245 pool tags read and summed -- is 0.07 s. All of
# the rest is the cost of asking. Two things were removed once that was visible:
# a redundant '\Hyper-V Hypervisor\*' wildcard call whose two values were already
# in the explicit list (1.04 s for nothing), and a Win32_OperatingSystem query
# for uptime that [Environment]::TickCount64 answers for free (0.41 s).
#
# End to end now 5.9-6.1 s over three timed runs, about 10% duty cycle at
# one-minute sampling, one thread of sixteen. The CSV grows about 400 KB/day.
#
# That is not free and it is written down so the next reader can weigh it. The
# reason to keep paying it: an earlier attempt to answer the same question with
# wpr -start Pool produced a 13,228 MB trace, dropped 192,160,703 events, and
# left the machine under test at 712 MB available. An instrument that damages
# the system more than the effect it measures is not an instrument -- but an
# instrument whose cost is unmeasured is not one either.
#
# Read-only. Nothing here changes settings, restarts services, edits the
# registry, or kills processes.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
    [string]$DataDir = $PSScriptRoot,
    [string]$CsvName = 'vi54-steps.csv',
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

function Fmt {
    param($Value, [int]$Round = 0)
    if ($null -eq $Value) { return 'na' }
    return ([math]::Round($Value, $Round)).ToString($inv)
}

# ------------------------------------------------------------- pool tag snap --
# SystemPoolTagInformation = 0x16, the same thing poolmon reads. This succeeds
# from a Medium integrity shell on this machine; per-tag pool attribution does
# not require elevation and the assumption that it did cost a 13 GB trace.
#
# SYSTEM_POOLTAG on x64 is 40 bytes, not 32: Tag[4] at 0, PagedAllocs at 4,
# PagedFrees at 8, four bytes of padding at 12, PagedUsed at 16, NonPagedAllocs
# at 24, NonPagedFrees at 28, NonPagedUsed at 32. The array starts at buffer+8,
# after the ULONG Count and its own padding.
if (-not ('PoolTagQuery' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PoolTagQuery {
  [DllImport("ntdll.dll")]
  static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
  public static IntPtr Query(out int count, out int status) {
    int need = 0, len = 1 << 20; count = 0; status = -1;
    for (int i = 0; i < 8; i++) {
      IntPtr b = Marshal.AllocHGlobal(len);
      status = NtQuerySystemInformation(0x16, b, len, out need);
      if (status == 0) { count = Marshal.ReadInt32(b); return b; }
      Marshal.FreeHGlobal(b);
      if (status == unchecked((int)0xC0000004)) { len = (need > len) ? need + 65536 : len * 2; continue; }
      return IntPtr.Zero;
    }
    return IntPtr.Zero;
  }
}
'@
}

$vi54Paged = $null
$viPaged = $null
$viNp = $null
$sumPaged = $null
$sumNp = $null

$count = 0
$status = -1
$buf = [PoolTagQuery]::Query([ref]$count, [ref]$status)
if ($buf -ne [IntPtr]::Zero) {
    try {
        $sp = [double]0; $sn = [double]0; $vp = [double]0; $vn = [double]0; $v54 = [double]0
        $base = [int64]$buf + 8
        for ($i = 0; $i -lt $count; $i++) {
            $p = [IntPtr]($base + ($i * 40))
            $tag = -join (0..3 | ForEach-Object {
                $b = [Runtime.InteropServices.Marshal]::ReadByte($p, $_)
                if ($b -ge 32 -and $b -le 126) { [char]$b } else { '' }
            })
            $pu = [double][Runtime.InteropServices.Marshal]::ReadInt64($p, 16)
            $nu = [double][Runtime.InteropServices.Marshal]::ReadInt64($p, 32)
            $sp += $pu; $sn += $nu
            if ($tag.StartsWith('Vi')) { $vp += $pu; $vn += $nu }
            if ($tag -eq 'Vi54') { $v54 = $pu }
        }
        $vi54Paged = $v54 / 1MB
        $viPaged = $vp / 1MB
        $viNp = $vn / 1MB
        $sumPaged = $sp / 1MB
        $sumNp = $sn / 1MB
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
}

# ---------------------------------------------------------------- host memory --
$mem = @{}
try {
    $paths = @(
        '\Memory\Pool Paged Bytes'
        '\Memory\Pool Nonpaged Bytes'
        '\Memory\Available MBytes'
        '\Memory\Committed Bytes'
        '\Memory\Commit Limit'
        '\Memory\Modified Page List Bytes'
    )
    foreach ($s in (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples) {
        $mem[$s.Path.Split('\')[-1]] = $s.CookedValue
    }
} catch { $mem = @{} }
function MemC { param([string]$n) if ($mem.ContainsKey($n)) { $mem[$n] } else { $null } }

# ------------------------------------------------------------- fault activity --
# ADDED 2026-08-31 10:0x, because Available MBytes was caught not tracking the
# symptom. Between 09:18 and 09:29 available memory fell 7,923 MB monotonically
# while the machine was reported as feeling better. Whatever the slowdown is, in
# that range it is not the available-memory level -- but the 02:12 live episode
# recorded 46,921 hard page reads/sec alongside avail bottoming at 504 MB, so
# the fault rate is the candidate that avail failed to be.
#
# SEPARATE CALL WITH TWO SAMPLES. Rate and inverse-time counters need two raw
# samples to cook. The memory group above is instantaneous and one sample is
# correct for it; these are not, and mixing them into that call would have
# produced plausible-looking numbers computed from a single reading. Costs one
# extra second per sample, once a minute.
#
# BOTH pgin_s AND pgread_s, deliberately. Pages Input/sec counts pages, Page
# Reads/sec counts the disk operations that carried them, so pgin_s >= pgread_s
# must hold in every row and the ratio is pages per read. That invariant is the
# check on a mistake this log has already made -- quoting a numerator and a
# denominator sampled in different windows -- and it is only checkable when both
# come from the same instant.
#
# disk_read_ms AND disk_idle_pct BESIDE THEM for the same reason. The 02:12
# entry recorded 46,921 page reads/sec against a disk 98.2% idle at 0.39 ms per
# read, which cannot all be true of one interval. Sampling the four together is
# what makes that contradiction decidable instead of arguable.
$rate = @{}
try {
    $ratePaths = @(
        '\Memory\Pages Input/sec'
        '\Memory\Page Reads/sec'
        '\Memory\Page Faults/sec'
        '\Memory\Transition Faults/sec'
        '\PhysicalDisk(_Total)\Avg. Disk sec/Read'
        '\PhysicalDisk(_Total)\% Idle Time'
        '\System\Processor Queue Length'
    )
    $s2 = Get-Counter -Counter $ratePaths -MaxSamples 2 -SampleInterval 1 -ErrorAction Stop
    foreach ($s in $s2[-1].CounterSamples) { $rate[$s.Path.Split('\')[-1]] = $s.CookedValue }
} catch { $rate = @{} }
function RateC { param([string]$n) if ($rate.ContainsKey($n)) { $rate[$n] } else { $null } }

# ------------------------------------------------------------------ hypervisor --
# The guest partition instance is named by GUID and suffixed :hvpt. It is
# selected by exclusion rather than by GUID: a WSL restart mints a new GUID, and
# hardcoding tonight's would silently produce 'na' forever afterwards.
$hv = @{}
try {
    $hvPaths = @(
        '\Hyper-V Hypervisor Partition(*)\4K GPA Pages'
        '\Hyper-V Hypervisor Partition(*)\Deposited Pages'
        '\Hyper-V Hypervisor Partition(*)\Virtual Processors'
        '\Hyper-V Hypervisor Root Partition(root)\4K GPA Pages'
        '\Hyper-V Hypervisor Root Partition(root)\2M GPA Pages'
        '\Hyper-V Hypervisor Root Partition(root)\1G GPA Pages'
        '\Hyper-V Hypervisor Root Partition(root)\Deposited Pages'
        '\Hyper-V Hypervisor\Total Pages'
        '\Hyper-V Hypervisor\Partitions'
        '\Hyper-V VM Vid Partition(*)\Physical Pages Allocated'
    )
    foreach ($s in (Get-Counter -Counter $hvPaths -ErrorAction Stop).CounterSamples) {
        $leaf = $s.Path.Split('\')[-1]
        $iname = $s.InstanceName
        if ($iname -eq '_total') { continue }
        if ($s.Path -like '*Root Partition*') { $hv["root:$leaf"] = $s.CookedValue }
        elseif ($s.Path -like '*Hypervisor Partition*') { $hv["guest:$leaf"] = $s.CookedValue }
        elseif ($s.Path -like '*Vid Partition*') { $hv["vid:$leaf"] = $s.CookedValue }
        else { $hv["hv:$leaf"] = $s.CookedValue }
    }

} catch { $hv = @{} }
function HvC { param([string]$n) if ($hv.ContainsKey($n)) { $hv[$n] } else { $null } }

# ----------------------------------------------------------------------- misc --
try {
    $vm = Get-Process vmmem, vmmemWSL -ErrorAction SilentlyContinue |
        Measure-Object -Property PrivateMemorySize64 -Sum
    if ($vm.Count -gt 0) { $vmmemMb = $vm.Sum / 1MB } else { $vmmemMb = $null }
} catch { $vmmemMb = $null }

# A COUNT IS NOT AN INVENTORY. On 2026-08-31 this sampler caught the 87 seconds
# before the machine froze and recorded procs going 501 -> 524 with commit up
# 1,375 MB in 40 seconds -- and could not say what the 23 new processes were,
# because it stored only the count. The single most useful fact about that
# window is the one column that was missing. topmem fixes it: the largest
# processes by name and MB, from the Get-Process call that was already being
# made for the count.
#
# PRIVATE BYTES ARE NOT RAM. Until 2026-09-02 this column ranked on
# PrivateMemorySize64 alone and was read as though it answered "who is using the
# memory". It does not. Private bytes are commit. A serena python measured
# 1,780 MB private against a 90 MB working set -- 5% resident -- and LINE, which
# an earlier entry catalogued at 1,108 MB, occupies 206 MB. Machine-wide the two
# quantities differed by 20,723 MB on 31,997 MB of RAM.
#
# Both are kept because both questions are real: commit is the quantity that ran
# out on 08-31, occupancy is what makes the machine swap. Each entry is
# name:private/workingset, and the set is the union of the top 8 by private and
# the top 8 by working set, so a process that is large in one and small in the
# other cannot fall out of the row unseen.
#
# Names, not PIDs, and repeated names are collapsed with a count. Twenty
# chrome.exe processes are one fact about chrome, not twenty rows of noise, and
# a PID is useless in a series where every row is a different instant.
$procs = $null
$topmem = $null
$privMb = $null
$wsMb = $null
try {
    $all = Get-Process -ErrorAction Stop
    $procs = $all.Count
    $grouped = $all | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{
            n  = $_.Name
            c  = $_.Count
            pv = ($_.Group | Measure-Object -Property PrivateMemorySize64 -Sum).Sum / 1MB
            ws = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB
        }
    }
    $privMb = ($grouped | Measure-Object -Property pv -Sum).Sum
    $wsMb = ($grouped | Measure-Object -Property ws -Sum).Sum
    $byPv = $grouped | Sort-Object pv -Descending | Select-Object -First 8
    $byWs = $grouped | Sort-Object ws -Descending | Select-Object -First 8
    $names = @($byPv.n) + @($byWs.n) | Select-Object -Unique
    $topmem = (
        $grouped | Where-Object { $names -contains $_.n } |
            Sort-Object pv -Descending | ForEach-Object {
                if ($_.c -gt 1) { '{0}x{1}:{2:F0}/{3:F0}' -f $_.n, $_.c, $_.pv, $_.ws }
                else { '{0}:{1:F0}/{2:F0}' -f $_.n, $_.pv, $_.ws }
            }
    ) -join ' '
} catch { $procs = $null; $topmem = $null; $privMb = $null; $wsMb = $null }
# Process names cannot normally contain a comma, and topmem is the last field on
# the line, so one would add a phantom column rather than misalign the others.
# Stripped anyway: a CSV that parses is worth more than the character.
if ($topmem) { $topmem = $topmem -replace ',', '' }

# TickCount64 rather than Win32_OperatingSystem.LastBootUpTime: same number,
# 0.41 s cheaper, and it does not need WMI to be answering. WMI was not
# answering during the 08:27 window today.
try { $upH = [Environment]::TickCount64 / 3600000 } catch { $upH = $null }

# ------------------------------------------------------------------------ row --
$row = [ordered]@{
    time          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv)
    os_up_h       = (Fmt $upH 2)
    vi54_mb       = (Fmt $vi54Paged 1)
    vi_paged_mb   = (Fmt $viPaged 1)
    vi_np_mb      = (Fmt $viNp 1)
    sum_paged_mb  = (Fmt $sumPaged 1)
    sum_np_mb     = (Fmt $sumNp 1)
    pdh_paged_mb  = (Fmt $(if ($null -ne (MemC 'pool paged bytes')) { (MemC 'pool paged bytes') / 1MB }) 1)
    pdh_np_mb     = (Fmt $(if ($null -ne (MemC 'pool nonpaged bytes')) { (MemC 'pool nonpaged bytes') / 1MB }) 1)
    gpa4k_guest   = (Fmt (HvC 'guest:4k gpa pages'))
    dep_guest     = (Fmt (HvC 'guest:deposited pages'))
    vp_guest      = (Fmt (HvC 'guest:virtual processors'))
    gpa4k_root    = (Fmt (HvC 'root:4k gpa pages'))
    gpa2m_root    = (Fmt (HvC 'root:2m gpa pages'))
    gpa1g_root    = (Fmt (HvC 'root:1g gpa pages'))
    dep_root      = (Fmt (HvC 'root:deposited pages'))
    hv_total_pgs  = (Fmt (HvC 'hv:total pages'))
    hv_partitions = (Fmt (HvC 'hv:partitions'))
    vid_pages     = (Fmt (HvC 'vid:physical pages allocated'))
    vmmem_mb      = (Fmt $vmmemMb)
    avail_mb      = (Fmt (MemC 'available mbytes'))
    commit_mb     = (Fmt $(if ($null -ne (MemC 'committed bytes')) { (MemC 'committed bytes') / 1MB }))
    commit_lim_mb = (Fmt $(if ($null -ne (MemC 'commit limit')) { (MemC 'commit limit') / 1MB }))
    modified_mb   = (Fmt $(if ($null -ne (MemC 'modified page list bytes')) { (MemC 'modified page list bytes') / 1MB }))
    pgin_s        = (Fmt (RateC 'pages input/sec') 1)
    pgread_s      = (Fmt (RateC 'page reads/sec') 1)
    pgfault_s     = (Fmt (RateC 'page faults/sec') 1)
    trans_s       = (Fmt (RateC 'transition faults/sec') 1)
    disk_read_ms  = (Fmt $(if ($null -ne (RateC 'avg. disk sec/read')) { (RateC 'avg. disk sec/read') * 1000 }) 3)
    disk_idle_pct = (Fmt (RateC '% idle time') 1)
    cpu_queue     = (Fmt (RateC 'processor queue length'))
    procs         = (Fmt $procs)
    proc_priv_mb  = (Fmt $privMb)
    proc_ws_mb    = (Fmt $wsMb)
    poolstatus    = ('0x{0:x8}' -f $status)
    tags          = (Fmt $count)
    topmem        = $(if ($topmem) { $topmem } else { 'na' })
}

$csv = Join-Path $DataDir $CsvName
$header = ($row.Keys -join ',')
$line = (($row.Values | ForEach-Object { $_ }) -join ',')

if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value $header -Encoding ASCII
} else {
    # A header that no longer matches means the column set changed. Appending
    # under the old header would silently misalign every later row.
    $existing = (Get-Content -LiteralPath $csv -TotalCount 1)
    if ($existing -ne $header) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $inv)
        Move-Item -LiteralPath $csv -Destination "$csv.$stamp.bak"
        Set-Content -LiteralPath $csv -Value $header -Encoding ASCII
    }
}
Add-Content -LiteralPath $csv -Value $line -Encoding ASCII

if ($Show) {
    foreach ($k in $row.Keys) { '{0,-14} {1}' -f $k, $row[$k] }
    ''
    "appended to $csv"
}
