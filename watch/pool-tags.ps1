# Names which kernel pool tags hold the memory the pool sampler measured growing.
#
# WHY THIS EXISTS. kernel-pool.csv answered its question over 225 rows on one
# boot and one build: nonpaged pool passed its 519-hour figure at 113 hours
# (2,263 MB against 2,126 MB) and paged pool bytes rose monotonically across all
# ten uptime bins. Resident kernel pool is 4,319 MB against 2,066 MB at 0.71 h --
# 2,253 MB of physical RAM held by the kernel that was not held at boot.
#
# That is a measured quantity with a correct label. It is not a mechanism. This
# script takes the one step that turns it into one: pool tags name the allocating
# subsystem, and pooltag.txt plus the loaded driver list map a tag to a component.
#
# WHY NOT poolmon. poolmon.exe ships in the WDK, which is not installed here
# (Windows Kits 10 is present but has no Debuggers folder, and pooltag.txt is
# absent from System32). wpr.exe is in System32 with a built-in `Pool` profile
# and wpaexporter.exe is present, so the same data is reachable without
# installing a toolkit onto the machine under investigation -- which matters,
# because installing a driver-loading toolkit onto the box whose kernel memory is
# being measured would perturb the thing being measured.
#
# WHY IT NEEDS ELEVATION. Pool tag enumeration is a kernel-only query. There is
# no unelevated route: not WMI, not PDH, not RamMap. WPR refuses to start kernel
# providers without it. This is a single scoped escalation to read, and the
# script writes nothing outside its own output directory.
#
# READ-ONLY. Starts a trace, stops it, exports CSV, reads two text files. It does
# not change settings, load drivers, restart services, or touch any process.
#
# WHAT THE NUMBERS MEAN, AND THE TRAP IN THEM. The Pool profile records alloc and
# free events during the capture window plus a rundown of what is already
# outstanding. Two different questions come out of it and they must not be mixed:
#
#   standing  -- what is held right now. Answers "who has the 2,253 MB".
#   churn     -- what was allocated and freed during the window. A tag can
#                dominate churn while holding almost nothing.
#
# A leak shows as standing growth across two captures taken hours apart, NOT as
# high churn in one. This script therefore stamps every export with uptime and
# tells you to take a second capture rather than concluding from the first. One
# capture of a growing quantity establishes nothing about growth -- that error is
# in this investigation's log twice already.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

# No [CmdletBinding()]. Under PowerShell 5.1 invoked with -File, adding it makes
# $PSScriptRoot empty *inside param() defaults* -- the script dies at binding
# time with "Cannot bind argument to parameter 'Path' because it is an empty
# string", before any code runs, so even the elevation check below never fires.
# Verified both ways on this machine. The other scripts here use a plain param()
# block for the same reason.
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'pool-capture'),
    [int]$Seconds = 60,
    [switch]$KeepEtl
)

$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

# ------------------------------------------------------------- preflight ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'X  Not elevated. Pool tag enumeration is a kernel-only query and' -ForegroundColor Red
    Write-Host '   there is no unelevated route to it. Run this from an elevated shell.' -ForegroundColor Red
    exit 1
}

$wpr = Join-Path $env:SystemRoot 'System32\wpr.exe'
if (-not (Test-Path $wpr)) { Write-Host "X  wpr.exe not found at $wpr" -ForegroundColor Red; exit 1 }

$exporter = (Get-Command wpaexporter.exe -ErrorAction SilentlyContinue)
if (-not $exporter) {
    Write-Host 'X  wpaexporter.exe not found. Install Windows Performance Analyzer' -ForegroundColor Red
    Write-Host '   (Microsoft Store, or the ADK Windows Performance Toolkit feature).' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $inv)
$dir = Join-Path $OutDir $stamp
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$etl = Join-Path $dir 'pool.etl'

# ------------------------------------------------------------- context ------
# Stamped before the capture, not after: the whole point of the exercise is that
# these values move with uptime, so a reader comparing two captures needs to know
# what the pools read at each one without going back to kernel-pool.csv.
$os = Get-CimInstance Win32_OperatingSystem
$upH = ((Get-Date) - $os.LastBootUpTime).TotalHours
try { $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR } catch { $ubr = 'na' }

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

$ctx = [ordered]@{
    captured_at    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv)
    boot           = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss', $inv)
    os_up_h        = [math]::Round($upH, 2)
    os_build       = "$($os.BuildNumber).$ubr"
    np_mb          = (P 'pool nonpaged bytes')
    pp_bytes_mb    = (P 'pool paged bytes')
    pp_resident_mb = (P 'pool paged resident bytes')
    avail_mb       = (P 'available mbytes' -Raw)
    capture_s      = $Seconds
}
$ctx.GetEnumerator() | ForEach-Object { '{0,-16} {1}' -f $_.Key, $_.Value }
($ctx.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join "`r`n" |
    Set-Content -LiteralPath (Join-Path $dir 'context.txt') -Encoding ASCII
''

# ------------------------------------------------------------- capture ------
# -start is cancelled in a finally block. A WPR session left running after a
# crash keeps kernel providers enabled indefinitely, which is exactly the kind of
# instrument residue this investigation has a rule against.
Write-Host "Starting Pool trace for $Seconds s ..."
& $wpr -start Pool -filemode
if ($LASTEXITCODE -ne 0) { Write-Host "X  wpr -start failed ($LASTEXITCODE)" -ForegroundColor Red; exit 1 }

try {
    Start-Sleep -Seconds $Seconds
    Write-Host "Stopping and writing $etl ..."
    & $wpr -stop $etl
    if ($LASTEXITCODE -ne 0) { throw "wpr -stop failed ($LASTEXITCODE)" }
} catch {
    & $wpr -cancel 2>&1 | Out-Null
    Write-Host "X  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

'{0:N1} MB trace' -f ((Get-Item $etl).Length / 1MB)
''

# ------------------------------------------------------------- export -------
# -listtables first, because the Pool table's exact name varies between WPA
# versions and guessing it produces an empty CSV that looks like "no pool
# activity" rather than like a failed export.
Write-Host 'Listing tables ...'
$tables = & $exporter.Source -i $etl -listtables 2>&1
$tables | Set-Content -LiteralPath (Join-Path $dir 'tables.txt') -Encoding ASCII
$poolTables = $tables | Where-Object { $_ -match 'Pool' }
if ($poolTables) { $poolTables | ForEach-Object { '  ' + $_.Trim() } }
else { Write-Host '  no table name matched /Pool/ -- see tables.txt' -ForegroundColor Yellow }
''

Write-Host 'Exporting ...'
Push-Location $dir
try { & $exporter.Source -i $etl 2>&1 | Select-Object -Last 5 | ForEach-Object { '  ' + $_ } }
finally { Pop-Location }
''

$csvs = Get-ChildItem $dir -Filter '*.csv' -ErrorAction SilentlyContinue
if ($csvs) { $csvs | ForEach-Object { '  {0,-52} {1,9:N0} KB' -f $_.Name, ($_.Length / 1KB) } }
else { Write-Host '  no CSV produced' -ForegroundColor Yellow }

if (-not $KeepEtl) {
    # The ETL is the bulky part and the CSVs carry the answer. Kept only on
    # request, because this repo's evidence directories already hold multi-GB
    # traces that must not be deleted, and adding more by default is rude.
    Remove-Item -LiteralPath $etl -Force -ErrorAction SilentlyContinue
    '  etl removed (pass -KeepEtl to keep it)'
}

''
Write-Host "Output: $dir"
Write-Host ''
Write-Host 'This is ONE capture. It cannot show growth.' -ForegroundColor Yellow
Write-Host 'Take a second one several hours from now and compare standing bytes'
Write-Host 'per tag; the tag whose STANDING total rose is the answer, not the tag'
Write-Host 'with the most allocations in either window.'
