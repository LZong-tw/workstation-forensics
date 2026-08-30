# Standing kernel pool bytes per pool tag. One row per tag, appended to a CSV.
#
# WHY THIS EXISTS. kernel-pool.csv established over 225 rows, one boot and one
# build, that resident kernel pool is 4,319 MB against 2,066 MB at 0.71 h --
# 2,253 MB of physical RAM the kernel holds that it did not hold at boot. Pool
# tags name the allocating subsystem, which is the step that turns a measured
# quantity into a mechanism.
#
# WHAT IT USES, AND WHY NOT THE OBVIOUS THINGS.
#
#   NtQuerySystemInformation(SystemPoolTagInformation = 0x16) returns the
#   standing allocation count and byte total for every tag. It is what poolmon
#   reads. It costs one call, allocates no trace, touches no disk, and -- checked
#   on this machine -- SUCCEEDS UNELEVATED, returning STATUS_SUCCESS and 4,356
#   tags from a Medium-integrity shell.
#
#   poolmon.exe was the first choice and is not installed; the WDK is absent here
#   (Windows Kits 10 exists but has no Debuggers folder and System32 has no
#   pooltag.txt).
#
#   The version of this script that shipped on 2026-08-31 used `wpr -start Pool`
#   instead. That was wrong twice over and is recorded rather than quietly
#   replaced. It answered the wrong question -- the Pool profile records alloc and
#   free EVENTS, which is churn, when what was needed is what is standing right
#   now. And it was ruinous to run: 60 seconds of it produced a 13.2 GB ETL,
#   dropped 192,160,703 events, and left the machine at 712 MB available and
#   26,769 hard page reads/sec on a box that was already thrashing. An instrument
#   that degrades the system under test by more than the effect it is measuring is
#   not an instrument. It also demanded elevation that, as this version proves,
#   was never needed.
#
# ONE SNAPSHOT CANNOT SHOW GROWTH. That is the whole point of the CSV. A tag
# holding a lot is not a tag that is leaking -- the biggest holder may have been
# the biggest holder since boot. The answer is the tag whose STANDING total rises
# across samples separated by hours, which is why this appends rather than prints
# and why every row carries os_up_h.
#
# ALLOCS IS NOT SIZE. The allocation counter is cumulative since boot and says
# nothing about bytes held: on this machine `SeAt` shows 617,123,657 allocations
# holding 89.7 MB while `ismc` shows 3 allocations holding 321.1 MB. Sorting by
# allocs finds churn, not memory. Both columns are recorded; only bytes answer
# the question.
#
# THE SUM DOES NOT MATCH PDH, AND THAT IS EXPECTED. Summed tags read 3,590 MB
# paged against PDH's 4,259 MB, and 2,014 against 2,295 nonpaged -- tagged bytes
# are 84% and 88% of the totals. Untagged and large-page allocations are not in
# this table. Both sums are written to the CSV on every row so the shortfall stays
# visible instead of being discovered later and mistaken for a decode error.
#
# Read-only. One ntdll query and PDH counters. Nothing is started, stopped,
# loaded, or modified.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
    [string]$DataDir = $PSScriptRoot,
    [string]$CsvName = 'pool-tags.csv',
    # 200, chosen by measuring the distribution rather than guessing: on this
    # machine 3,170 tags hold 5,296 MB between them, and the top 200 cover 98.31%
    # of it (5,207 MB). Top 40 would already give 88.16% but would truncate the
    # mid-tail where a newly growing tag would first appear, which is exactly
    # what this file is watching for. Writing all 3,170 costs 286 KB per sample,
    # or 13.7 MB/day at 30-minute spacing; 200 costs about 900 KB/day.
    # Pass -Top 0 to keep every tag that holds anything.
    [int]$Top = 200,
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

# SYSTEM_POOLTAG on x64 is 40 bytes: Tag[4], PagedAllocs, PagedFrees, 4 bytes of
# padding to align the SIZE_T, PagedUsed, NonPagedAllocs, NonPagedFrees,
# NonPagedUsed. The padding is easy to miss and shifts every field after it, so
# the offsets are written as constants below rather than computed.
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

$count = 0
$status = 0
$buf = [PoolTagQuery]::Query([ref]$count, [ref]$status)
if ($buf -eq [IntPtr]::Zero -or $count -le 0) {
    Write-Host ('X  NtQuerySystemInformation(SystemPoolTagInformation) failed, status 0x{0:X8}' -f $status) -ForegroundColor Red
    exit 1
}

$rows = New-Object System.Collections.Generic.List[object]
try {
    for ($i = 0; $i -lt $count; $i++) {
        $o = [IntPtr]([int64]$buf + 8 + $i * 40)
        $tb = New-Object byte[] 4
        [Runtime.InteropServices.Marshal]::Copy($o, $tb, 0, 4)
        # Tags are four bytes and are not guaranteed printable. Non-printable
        # bytes become '.' so a row can never break the CSV, and the raw ulong is
        # kept alongside so an odd tag is still identifiable.
        $tag = ($tb | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } }) -join ''
        $rows.Add([pscustomobject]@{
            Tag          = $tag
            TagHex       = ('{0:X2}{1:X2}{2:X2}{3:X2}' -f $tb[3], $tb[2], $tb[1], $tb[0])
            PagedAllocs  = [Runtime.InteropServices.Marshal]::ReadInt32($o, 4)
            PagedFrees   = [Runtime.InteropServices.Marshal]::ReadInt32($o, 8)
            PagedUsed    = [Runtime.InteropServices.Marshal]::ReadInt64($o, 16)
            NpAllocs     = [Runtime.InteropServices.Marshal]::ReadInt32($o, 24)
            NpFrees      = [Runtime.InteropServices.Marshal]::ReadInt32($o, 28)
            NpUsed       = [Runtime.InteropServices.Marshal]::ReadInt64($o, 32)
        })
    }
} finally {
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
}

$sumPaged = ($rows | Measure-Object PagedUsed -Sum).Sum
$sumNp = ($rows | Measure-Object NpUsed -Sum).Sum

$os = Get-CimInstance Win32_OperatingSystem
$upH = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 2)
try { $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = 'na' }
$build = "$($os.BuildNumber).$ubr"

$pdh = @{}
try {
    foreach ($s in (Get-Counter -Counter @(
        '\Memory\Pool Nonpaged Bytes'
        '\Memory\Pool Paged Bytes'
        '\Memory\Pool Paged Resident Bytes'
        '\Memory\Available MBytes'
    ) -ErrorAction Stop).CounterSamples) { $pdh[$s.Path.Split('\')[-1]] = $s.CookedValue }
} catch { }
function P { param([string]$n, [switch]$Raw)
    if (-not $pdh.ContainsKey($n)) { return 'na' }
    if ($Raw) { [math]::Round($pdh[$n]) } else { [math]::Round($pdh[$n] / 1MB) } }

$time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv)
$hdr = 'time,os_up_h,os_build,tag,tag_hex,paged_kb,np_kb,paged_allocs,np_allocs,sum_paged_mb,sum_np_mb,pdh_paged_mb,pdh_np_mb,pdh_paged_resident_mb,avail_mb'

# Only tags holding something are written. A 4,356-row snapshot every 30 minutes
# would be 6 MB/day of mostly zeros; the ones holding nothing carry no
# information about where 2,253 MB went. Tags that later start holding memory
# appear as soon as they do.
$keep = $rows | Where-Object { $_.PagedUsed -gt 0 -or $_.NpUsed -gt 0 }
if ($Top -gt 0) {
    $keep = $keep | Sort-Object { $_.PagedUsed + $_.NpUsed } -Descending | Select-Object -First $Top
}

$csv = Join-Path $DataDir $CsvName
if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value $hdr -Encoding ASCII
} elseif ((Get-Content -LiteralPath $csv -TotalCount 1) -ne $hdr) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $inv)
    Move-Item -LiteralPath $csv -Destination "$csv.$stamp.bak"
    Set-Content -LiteralPath $csv -Value $hdr -Encoding ASCII
}

$lines = $keep | ForEach-Object {
    '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14}' -f `
        $time, $upH, $build, $_.Tag, $_.TagHex,
        [math]::Round($_.PagedUsed / 1KB), [math]::Round($_.NpUsed / 1KB),
        $_.PagedAllocs, $_.NpAllocs,
        [math]::Round($sumPaged / 1MB), [math]::Round($sumNp / 1MB),
        (P 'pool paged bytes'), (P 'pool nonpaged bytes'),
        (P 'pool paged resident bytes'), (P 'available mbytes' -Raw)
}
Add-Content -LiteralPath $csv -Value $lines -Encoding ASCII

if ($Show) {
    '{0}   up {1} h   build {2}' -f $time, $upH, $build
    '  tags total {0}, holding {1}' -f $count, $keep.Count
    '  summed  paged {0,6:N0} MB   nonpaged {1,6:N0} MB' -f ($sumPaged / 1MB), ($sumNp / 1MB)
    '  PDH     paged {0,6} MB   nonpaged {1,6} MB   ({2:N0}% / {3:N0}% tagged)' -f `
        (P 'pool paged bytes'), (P 'pool nonpaged bytes'),
        (100 * $sumPaged / [math]::Max([double]1, [double]$pdh['pool paged bytes'])),
        (100 * $sumNp / [math]::Max([double]1, [double]$pdh['pool nonpaged bytes']))
    ''
    '  top 15 by bytes held:'
    $keep | Sort-Object { $_.PagedUsed + $_.NpUsed } -Descending | Select-Object -First 15 | ForEach-Object {
        '    {0,-6} paged {1,9:N1} MB   nonpaged {2,8:N1} MB' -f $_.Tag, ($_.PagedUsed / 1MB), ($_.NpUsed / 1MB)
    }
    ''
    "  appended {0} rows to $csv" -f $keep.Count
}
