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
# COST. Two Get-Counter calls plus one NtQuerySystemInformation snapshot,
# roughly 1 s wall clock, no disk writes beyond one CSV line of about 200 bytes.
# At one-minute sampling the CSV grows about 290 KB/day. This matters here: an
# earlier attempt to answer the same question with wpr -start Pool produced a
# 13,228 MB trace, dropped 192,160,703 events, and left the machine under test
# at 712 MB available -- an instrument that damages the system more than the
# effect it measures is not an instrument.
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
        '\Memory\Modified Page List Bytes'
    )
    foreach ($s in (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples) {
        $mem[$s.Path.Split('\')[-1]] = $s.CookedValue
    }
} catch { $mem = @{} }
function MemC { param([string]$n) if ($mem.ContainsKey($n)) { $mem[$n] } else { $null } }

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
    foreach ($s in (Get-Counter -Counter '\Hyper-V Hypervisor\*' -ErrorAction Stop).CounterSamples) {
        $hv['hv:' + $s.Path.Split('\')[-1]] = $s.CookedValue
    }
} catch { $hv = @{} }
function HvC { param([string]$n) if ($hv.ContainsKey($n)) { $hv[$n] } else { $null } }

# ----------------------------------------------------------------------- misc --
try {
    $vm = Get-Process vmmem, vmmemWSL -ErrorAction SilentlyContinue |
        Measure-Object -Property PrivateMemorySize64 -Sum
    if ($vm.Count -gt 0) { $vmmemMb = $vm.Sum / 1MB } else { $vmmemMb = $null }
} catch { $vmmemMb = $null }

try { $procs = (Get-Process -ErrorAction Stop).Count } catch { $procs = $null }

try {
    $upH = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).TotalHours
} catch { $upH = $null }

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
    modified_mb   = (Fmt $(if ($null -ne (MemC 'modified page list bytes')) { (MemC 'modified page list bytes') / 1MB }))
    procs         = (Fmt $procs)
    poolstatus    = ('0x{0:x8}' -f $status)
    tags          = (Fmt $count)
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
