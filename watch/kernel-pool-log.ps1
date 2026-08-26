# One sample of the kernel's own memory footprint, appended to a CSV.
#
# WHY THIS EXISTS. On 2026-08-26 this machine rebooted after 519.04 hours and
# Paged Pool plus Nonpaged Pool fell 2,834.7 MB between them -- 99.2% of the
# total kernel reduction, confirmed independently by PDH at 2,526 MB. That is
# the first substantial finding in this investigation that two instruments
# agree on. It is also confounded: KB5120708 and KB5121003 installed at 09:00
# the same morning, so the kernel binaries changed between the two readings and
# the drop cannot be attributed to uptime rather than to the update.
#
# Only time separates the two explanations, and only one sample per boot exists
# of each. Hence a logger rather than another ad-hoc capture.
#
# THE PRE-REGISTERED TEST, stated here so it cannot be re-chosen later:
#
#   Baseline at 0.71 h uptime on build 26200.9168:
#       Pool Nonpaged Bytes         1,247 MB
#       Pool Paged Resident Bytes     819 MB
#   Old kernel at 519.04 h:
#       Pool Nonpaged Bytes         2,126 MB
#       Pool Paged Resident Bytes   2,466 MB
#
#   If the pair climbs back toward 2,126 / 2,466 as uptime accumulates, uptime
#   is the mechanism and it is a pool leak worth naming.
#   If the pair sits flat near 1,247 / 819 across comparable uptime, the drop
#   belonged to the update and 519 hours was never the cause.
#
#   "Comparable uptime" means comparable, not "a while": the old figures are
#   from 519 h. A flat reading at 50 h decides nothing, and this script logs
#   os_up_h on every row so that constraint stays visible in the data.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not attribute pool usage to a
# driver or a pool tag. Per-tag attribution needs poolmon.exe (WDK) or a kernel
# debugger, both of which require elevation, and this investigation's rule is
# that the instrument does not acquire privileges it does not need. Totals are
# enough to decide the question above; if the answer is "uptime", per-tag work
# comes after, deliberately, as a separate elevated step.
#
# THE UPDATE COLUMN. os_build is recorded on every row, not once. The whole
# reason this test exists is that a kernel update landed unnoticed between two
# readings. A future update would do the same, and the confound has to be
# visible in the series itself rather than reconstructed from the Setup log
# afterwards.
#
# FAILED QUERIES ARE 'na', NEVER 0. Several counters in this investigation have
# returned null unelevated and been misread as zero. Every value here is either
# a number or the literal string na.
#
# TWO COLUMNS WERE DROPPED BEFORE THIS SHIPPED. Pool Nonpaged Allocs and Pool
# Paged Allocs would have discriminated a leak of many small allocations from a
# few large ones, which is the obvious next question if the pools do climb. Both
# read exactly 0 on this machine through three channels -- PDH cooked, PDH raw,
# and Win32_PerfRawData_PerfOS_Memory -- so they are not maintained by this
# kernel. A column that is constant carries no information, and this log has
# already been burned once by treating such a column (p50_ms, pinned at the
# 144 Hz frame interval in all 1,118 rows) as evidence.
#
# THE STANDBY BREAKDOWN replaced them, and earns its place differently: the four
# columns stby_core + stby_norm + stby_res + freezero must sum to avail_mb, which
# makes every row self-checking, and they are the exact quantity RamMap's Use
# Counts tab reports as Standby + Zeroed + Free. The one discriminating check
# this investigation has for RamMap's page-state decode needs those two numbers
# from the same instant; until now every attempt at it has been an unpaired
# comparison against a figure drifting hundreds of MB between seconds.
#
# COST. One Get-Counter call over 20 paths plus two CIM queries. Measured at
# roughly 0.6 s wall clock and under 40 MB peak working set, once per interval.
# At 30-minute sampling the CSV grows about 8 KB/day.
#
# Read-only. Nothing here changes settings, restarts services, edits the
# registry, or kills processes.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
    [string]$DataDir = $PSScriptRoot,
    [string]$CsvName = 'kernel-pool.csv',
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

function Fmt {
    param($Value, [int]$Round = 0)
    if ($null -eq $Value) { return 'na' }
    return ([math]::Round($Value, $Round)).ToString($inv)
}

# ---------------------------------------------------------------- counters --
# Paths are grouped so that one unavailable counter does not blank the row.
# Get-Counter throws for the whole call if any single path is invalid, which is
# why a failure here degrades every field to 'na' rather than silently to 0.
$paths = @(
    '\Memory\Pool Nonpaged Bytes'
    '\Memory\Pool Paged Bytes'
    '\Memory\Pool Paged Resident Bytes'
    '\Memory\Standby Cache Core Bytes'
    '\Memory\Standby Cache Normal Priority Bytes'
    '\Memory\Standby Cache Reserve Bytes'
    '\Memory\Free & Zero Page List Bytes'
    '\Memory\Available MBytes'
    '\Memory\Committed Bytes'
    '\Memory\Commit Limit'
    '\Memory\Modified Page List Bytes'
    '\Memory\System Cache Resident Bytes'
    '\Memory\System Driver Resident Bytes'
    '\Memory\System Code Resident Bytes'
    '\Memory\Pages Input/sec'
    '\Memory\Pages Output/sec'
    '\Process V2(_Total)\Working Set'
    '\Process V2(_Total)\Working Set - Private'
    '\Process V2(_Total)\Handle Count'
    '\Process V2(_Total)\Thread Count'
)

$c = @{}
try {
    foreach ($s in (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples) {
        $c[$s.Path.Split('\')[-1]] = $s.CookedValue
    }
} catch {
    $c = @{}
}

function Ctr { param([string]$Name) if ($c.ContainsKey($Name)) { $c[$Name] } else { $null } }
function CtrMB {
    param([string]$Name)
    $v = Ctr $Name
    if ($null -eq $v) { $null } else { $v / 1MB }
}

# ------------------------------------------------------------------- system --
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $boot = $os.LastBootUpTime
    $upH = ((Get-Date) - $boot).TotalHours
    $build = $os.BuildNumber
} catch {
    $boot = $null; $upH = $null; $build = $null
}

# UBR is the revision below the build number. 26200.9168 and 26200.8xxx are
# different kernels; recording only 26200 would hide exactly the confound this
# script exists to expose.
try {
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).UBR
} catch {
    $ubr = $null
}
if ($null -ne $build -and $null -ne $ubr) { $osBuild = "$build.$ubr" } else { $osBuild = 'na' }

try { $procs = (Get-Process -ErrorAction Stop).Count } catch { $procs = $null }

# Pagefiles are logged because a paging file that silently fails to appear at
# boot changes Commit Limit by tens of GB, and this machine has done exactly
# that: the D: entry is configured but D: is BitLocker-encrypted, so the file is
# never created during boot. The column makes that visible per row instead of
# requiring a separate query to notice.
try {
    $pf = (Get-CimInstance Win32_PageFileUsage -ErrorAction Stop |
        ForEach-Object { '{0}={1}' -f $_.Name.Substring(0, 1), $_.AllocatedBaseSize }) -join '+'
    if (-not $pf) { $pf = 'none' }
} catch {
    $pf = 'na'
}

# ---------------------------------------------------------------------- row --
$row = [ordered]@{
    time              = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv)
    os_up_h           = (Fmt $upH 2)
    boot              = $(if ($boot) { $boot.ToString('yyyy-MM-dd HH:mm:ss', $inv) } else { 'na' })
    os_build          = $osBuild
    np_mb             = (Fmt (CtrMB 'pool nonpaged bytes'))
    pp_bytes_mb       = (Fmt (CtrMB 'pool paged bytes'))
    pp_resident_mb    = (Fmt (CtrMB 'pool paged resident bytes'))
    stby_core_mb      = (Fmt (CtrMB 'standby cache core bytes'))
    stby_norm_mb      = (Fmt (CtrMB 'standby cache normal priority bytes'))
    stby_res_mb       = (Fmt (CtrMB 'standby cache reserve bytes'))
    freezero_mb       = (Fmt (CtrMB 'free & zero page list bytes'))
    avail_mb          = (Fmt (Ctr 'available mbytes'))
    commit_mb         = (Fmt (CtrMB 'committed bytes'))
    commit_limit_mb   = (Fmt (CtrMB 'commit limit'))
    modified_mb       = (Fmt (CtrMB 'modified page list bytes'))
    cache_resident_mb = (Fmt (CtrMB 'system cache resident bytes'))
    drv_resident_mb   = (Fmt (CtrMB 'system driver resident bytes'))
    code_resident_mb  = (Fmt (CtrMB 'system code resident bytes'))
    ws_total_mb       = (Fmt (CtrMB 'working set'))
    ws_priv_mb        = (Fmt (CtrMB 'working set - private'))
    handles           = (Fmt (Ctr 'handle count'))
    threads           = (Fmt (Ctr 'thread count'))
    procs             = (Fmt $procs)
    pgin_s            = (Fmt (Ctr 'pages input/sec') 1)
    pgout_s           = (Fmt (Ctr 'pages output/sec') 1)
    pagefiles         = $pf
}

$csv = Join-Path $DataDir $CsvName
$header = ($row.Keys -join ',')
$line = (($row.Values | ForEach-Object { $_ }) -join ',')

if (-not (Test-Path -LiteralPath $csv)) {
    Set-Content -LiteralPath $csv -Value $header -Encoding ASCII
} else {
    # A header that no longer matches means the column set changed. Appending
    # under the old header would silently misalign every later row, so this
    # rotates the file instead of corrupting the series.
    $existing = (Get-Content -LiteralPath $csv -TotalCount 1)
    if ($existing -ne $header) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $inv)
        Move-Item -LiteralPath $csv -Destination "$csv.$stamp.bak"
        Set-Content -LiteralPath $csv -Value $header -Encoding ASCII
    }
}
Add-Content -LiteralPath $csv -Value $line -Encoding ASCII

if ($Show) {
    foreach ($k in $row.Keys) { '{0,-18} {1}' -f $k, $row[$k] }
    ''
    "appended to $csv"
}
