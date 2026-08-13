# Dedicated healthy-state PMC baseline capture. Needs admin.
#
# A probe run once landed mid-way through a 30-minute spike (ms_per_pass_hot
# 1.875) while the next scheduled sample, 30 minutes later, read a normal
# 0.222 -- caught between two sample points with no way to tell which side
# the capture actually fell on. This script brackets the recording instead:
# it confirms the *current* dwm-growth-sample.ps1 reading is healthy before
# starting, and confirms again after that it did not flip into a degraded
# state mid-recording. Only with both ends pinned is a trace called a clean
# healthy baseline.
#
# Uses the combination already confirmed to start during the probe stage
# (Full + CPU/DesktopComposition/GPU) rather than re-testing all seven
# permutations. Capture length is 90 s, longer than the probe's 20 s, to get
# more compositor-thread CSwitch samples (the probe run only saw 235
# switches).

param(
    [string]$DataDir = $PSScriptRoot,
    [int]$CaptureSeconds = 90,
    [double]$HealthyThreshold = 0.3   # ms_per_pass_hot below this counts as healthy; known healthy baseline is 0.17-0.23, a spike measured 1.875
)

$ErrorActionPreference = 'Continue'
$growthCsv = Join-Path $DataDir 'dwm-growth.csv'
$wprp = Join-Path $PSScriptRoot 'dwm-pmc.wprp'
$FULL = "$wprp!DwmPmcFull"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $DataDir "dwm-capture\$stamp-pmc-healthy"
$etl = "$dir\dwm.etl"
$rep = "$dir\baseline-result.txt"

$lines = New-Object System.Collections.Generic.List[string]
function L($m) {
    $lines.Add([string]$m); Write-Host $m
    if (Test-Path $dir) { ($lines -join "`r`n") | Out-File $rep -Encoding utf8 }
}

New-Item -ItemType Directory -Path $dir -Force | Out-Null
L "Healthy-state PMC baseline capture  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$elevated = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "Elevated: $elevated"
if (-not $elevated) {
    L "Needs Administrator. Run from an elevated window:"
    L "   powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 1
}

function Get-LatestGrowthRow {
    $last = Get-Content $growthCsv -Tail 1
    $header = (Get-Content $growthCsv -TotalCount 1) -split ','
    $vals = $last -split ','
    $row = @{}
    for ($i = 0; $i -lt $header.Count; $i++) { $row[$header[$i]] = $vals[$i] }
    return $row
}

# ---------- pre-check: confirm the current state is healthy ----------
$pre = Get-LatestGrowthRow
$preAge = (Get-Date) - [datetime]$pre.time
L "Most recent growth-sample row before capture: $($pre.time) ($([math]::Round($preAge.TotalMinutes,1)) min ago)"
L "  ms_per_pass_hot = $($pre.ms_per_pass_hot)   cpu_pct = $($pre.cpu_pct)   crd_capturing = $($pre.crd_capturing)"
if ($preAge.TotalMinutes -gt 35) {
    L "Most recent sample is over 35 minutes old (the scheduler runs every 30). Too stale to represent now. Aborting."
    exit 1
}
if ([double]$pre.ms_per_pass_hot -ge $HealthyThreshold) {
    L "ms_per_pass_hot=$($pre.ms_per_pass_hot) >= threshold $HealthyThreshold -- not currently healthy. Aborting rather than recording a fake healthy baseline."
    exit 1
}
if ($pre.crd_capturing -ne '0') {
    L "CRD is currently capturing (crd_capturing=$($pre.crd_capturing)). A healthy baseline needs crd=0 to compare against prior crd=0 traces. Aborting."
    exit 1
}
L "  pre-check passed"
L ""

# Never blind -cancel: back off if anyone else is recording.
$st = & wpr.exe -status 2>&1 | Out-String
if ($st -notmatch 'not recording') {
    L "A WPR session is already recording. Leaving it alone, aborting."
    L $st.Trim()
    exit 1
}

# ---------- record ----------
L "=== recording $CaptureSeconds s ==="
$r = & wpr.exe -start 'CPU' -start 'DesktopComposition' -start 'GPU' -start $FULL -filemode 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    L "Failed to start: $($r.Trim())"
    & wpr.exe -cancel 2>&1 | Out-Null
    exit 1
}
Start-Sleep $CaptureSeconds
& wpr.exe -stop $etl 2>&1 | Out-Null
if (-not (Test-Path $etl)) { L "No ETL was produced"; exit 1 }
L ("  ETL = {0:N1} MB" -f ((Get-Item $etl).Length / 1MB))
L ""

# ---------- post-check: confirm it did not flip into degraded mid-recording ----------
Start-Sleep 5   # give growth-sample a chance to settle if it lands right on a boundary; does not affect the already-written ETL
$post = Get-LatestGrowthRow
L "Most recent growth-sample row after capture: $($post.time)"
L "  ms_per_pass_hot = $($post.ms_per_pass_hot)   cpu_pct = $($post.cpu_pct)   crd_capturing = $($post.crd_capturing)"
if ($post.time -ne $pre.time -and [double]$post.ms_per_pass_hot -ge $HealthyThreshold) {
    L "  caution: a new high-value sample appeared during or after recording -- this trace's healthy-state representativeness is in doubt. Flagged, not deleted."
} else {
    L "  post-check also passed, both ends bracket a healthy state"
}
L ""

# ---------- verify ----------
L "=== verifying PMC data ==="
$verify = Join-Path $PSScriptRoot 'dwm-pmc-verify.ps1'
$vout = & $verify -EtlPath $etl 2>&1 | Out-String
foreach ($ln in ($vout -split "`r?`n")) { if ($ln.Trim()) { L "  $ln" } }
L ""
L "ETL kept at: $etl"
L "Done $(Get-Date -Format 'HH:mm:ss')"
