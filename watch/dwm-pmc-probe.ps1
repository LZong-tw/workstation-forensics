# One-shot feasibility probe for hardware PMC on this machine. Needs admin.
#
# Two questions, neither answerable without elevation:
#   1. Can dwm-pmc.wprp coexist with the provider set dwm-autocapture.ps1
#      already uses? (wpr allows multiple -start calls, but the system
#      collector is merged, and a conflicting configuration fails to start.)
#   2. Can this machine actually program those counters? Listing 18 sources
#      via TraceProfileSourceListInfo does not mean they are usable -- under
#      Virtualization Based Security the hypervisor commonly withholds the
#      PMU, and a hybrid P/E-core layout makes programming more likely to
#      fail regardless. dwm-pmc.wprp's Strict="true" makes that kind of
#      failure abort wpr -start immediately rather than recording an empty
#      set.
#
# dwm-autocapture.ps1 is only worth changing once this has actually passed --
# changing it beforehand risks the one reliable "caught it mid-degradation"
# capture path on an unverified assumption.
#
# The captured ETL is checked with dwm-pmc-verify.ps1 (which does not need
# elevation) as the last step here.

param(
    [string]$DataDir = $PSScriptRoot
)

$ErrorActionPreference = 'Continue'
$out = Join-Path $DataDir 'dwm-capture\pmc-probe'
$wprp = Join-Path $PSScriptRoot 'dwm-pmc.wprp'
$etl = Join-Path $out 'probe.etl'
$rep = Join-Path $out 'probe-result.txt'

New-Item -ItemType Directory -Path $out -Force | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function L($m) {
    $lines.Add([string]$m); Write-Host $m
    ($lines -join "`r`n") | Out-File $rep -Encoding utf8
}

L "PMC feasibility probe  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

$elevated = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "Elevated: $elevated"
if (-not $elevated) {
    L "Needs Administrator. Run from an elevated window:"
    L "   powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 1
}

# Never blind -cancel: a scheduled sampler can fire dwm-autocapture.ps1 at any
# moment, and that capture is not reproducible on demand. Back off if anyone
# else is recording.
$st = & wpr.exe -status 2>&1 | Out-String
if ($st -notmatch 'not recording') {
    L "A WPR session is already recording (possibly autocapture). Leaving it alone; probe aborted."
    L $st.Trim()
    exit 1
}
L "WPR idle - ok"
L ""

# The "name" half of `file!name` is the <Profile>'s Name attribute, not its
# Id. Passing the Id (e.g. DwmPmcBasic.Verbose.File) fails with 0xc5600611,
# "The <Profile> element could not be found in the profile file" -- a
# profile-lookup failure that has nothing to do with whether PMC itself is
# supported. Do not conflate the two: the distinction is testable without
# elevation, because a correct Name advances to a permission error
# (0xc5600...4f) instead.
$FULL = "$wprp!DwmPmcFull"
$BASIC = "$wprp!DwmPmcBasic"

# Preference order: keep the provider set consistent with any prior traces
# taken with the plain CPU/DesktopComposition/GPU combination first (provider
# choice alone is worth a measurable multiplier -- switching it makes traces
# incomparable), then prefer the extra LLCMisses counter if it starts.
$base = @('-start', 'CPU', '-start', 'DesktopComposition', '-start', 'GPU')
$cands = @(
    @{ n = 'Full + CPU/DesktopComposition/GPU'; a = $base + @('-start', $FULL, '-filemode') }
    @{ n = 'Basic + CPU/DesktopComposition/GPU'; a = $base + @('-start', $BASIC, '-filemode') }
    @{ n = 'Full + CPU/GPU'; a = @('-start', 'CPU', '-start', 'GPU', '-start', $FULL, '-filemode') }
    @{ n = 'Basic + CPU/GPU'; a = @('-start', 'CPU', '-start', 'GPU', '-start', $BASIC, '-filemode') }
    @{ n = 'Full + CPU'; a = @('-start', 'CPU', '-start', $FULL, '-filemode') }
    @{ n = 'Basic + CPU'; a = @('-start', 'CPU', '-start', $BASIC, '-filemode') }
    @{ n = 'Basic only'; a = @('-start', $BASIC, '-filemode') }
)

L "=== 1. which combination starts ==="
$win = $null
foreach ($c in $cands) {
    $r = & wpr.exe @($c.a) 2>&1 | Out-String
    $ok = ($LASTEXITCODE -eq 0)
    & wpr.exe -cancel 2>&1 | Out-Null
    if ($ok) {
        L ("  ok  {0}" -f $c.n)
        if (-not $win) { $win = $c }
    }
    else {
        # Print the full message, not just the last line. wpr puts the
        # description first and the "Error code" last -- printing only the
        # last line leaves a bare hex number, which is how a mistyped
        # profile name once got misread as "this machine cannot get PMC".
        $msg = ($r.Trim() -split "`r?`n" | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }) -join ' | '
        L ("  fail  {0}  ->  {1}" -f $c.n, $msg)
    }
}
L ""
if (-not $win) {
    # All combinations failing has two very different causes -- do not
    # attribute it to "hardware unsupported" by default.
    L "No combination started."
    L "   -> If everything above is 0xc5600611 (Profile not found): a profile"
    L "      name is wrong. `file!name` needs the <Profile>'s Name, not its Id."
    L "      This has nothing to do with PMC support."
    L "   -> If it is 'Failed to enable ... policy': a permission problem --"
    L "      confirm this really is elevated."
    L "   -> Only if the error clearly names a counter: that is when PMC is"
    L "      genuinely unavailable on this machine, and dwm-autocapture.ps1"
    L "      should not be changed to depend on it."
    exit 1
}
L "-> using: $($win.n)"
L "   args: wpr.exe $($win.a -join ' ')"
L ""

# ---------- 2. record a short sample ----------
L "=== 2. recording 20 s ==="
Remove-Item $etl -ErrorAction SilentlyContinue
$r = & wpr.exe @($win.a) 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    L "  failed to start (it just succeeded above): $($r.Trim())"
    & wpr.exe -cancel 2>&1 | Out-Null
    exit 1
}
Start-Sleep 20
& wpr.exe -stop $etl 2>&1 | Out-Null
if (-not (Test-Path $etl)) { L "  no ETL was produced"; exit 1 }
L ("  ETL = {0:N1} MB   {1}" -f ((Get-Item $etl).Length / 1MB), $etl)
L ""

# ---------- 3. verify now, not next session ----------
# verify does not need elevation, but running it here saves a round trip --
# and if PMC was not actually received, that is known immediately instead of
# assuming the toolchain works.
L "=== 3. verifying PMC actually landed in the ETL ==="
$verify = Join-Path $PSScriptRoot 'dwm-pmc-verify.ps1'
if (Test-Path $verify) {
    $vout = & $verify -EtlPath $etl 2>&1 | Out-String
    foreach ($ln in ($vout -split "`r?`n")) { if ($ln.Trim()) { L "  $ln" } }
    if ($vout -match 'no PMC data|no deltas at all') {
        L ""
        L "Counters programmed successfully, but the ETL has no PMC data."
        L "   Most likely VBS/Hyper-V is virtualizing away the PMU -- this path"
        L "   is a dead end; do not change dwm-autocapture.ps1 to depend on it."
    }
    elseif ($vout -match 'HasInstructionCount=True') {
        L ""
        L "PMC received. This combination can be wired into dwm-autocapture.ps1."
    }
}
else {
    L "  $verify not found; run it by hand"
}
L ""
L "Done $(Get-Date -Format 'HH:mm:ss')"
