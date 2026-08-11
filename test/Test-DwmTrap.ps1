# Behavioural regression tests for the DWM trap in watch/dwm-growth-sample.ps1.
#
# Test-Scripts.ps1 covers structure (ASCII, parses, no hardcoded paths). This
# file covers the one runtime failure the sampler's own comments warn about but
# nothing enforced:
#
#   The trap reads the previous CSV row by POSITION -- $prevRow[8], [9], [11],
#   [15]. Inserting a column anywhere but the end silently repoints every one of
#   them at different data. Nothing throws. The trap simply compares the wrong
#   numbers forever, and the failure is invisible until a degradation cycle is
#   missed -- weeks later, with no evidence that anything went wrong.
#
# Also checked: the CSV writer's format string must have exactly as many
# placeholders as the header has columns, so adding a header column without a
# matching value cannot shift every field right of it.
#
# Usage:  pwsh -File test\Test-DwmTrap.ps1     (or powershell -File ...)
# Exit code 0 = all passed.

$ErrorActionPreference = 'Stop'

$root   = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'watch\dwm-growth-sample.ps1'

# The contract: which CSV column each positional read is supposed to be reading.
# Keep this in sync with the trap deliberately -- a change here should be a
# conscious decision, which is the entire point of pinning it in a test.
$contract = @{
  8  = 'p50_ms'
  9  = 'p90_ms'
  11 = 'ms_per_pass_hot'
  15 = 'handles'
}

$failures = New-Object System.Collections.Generic.List[string]
function Fail($why) { $failures.Add($why); Write-Host "  FAIL  $why" -ForegroundColor Red }
function Pass($what) { Write-Host "  ok    $what" -ForegroundColor Green }

Write-Host "Testing the DWM trap in $script"
Write-Host ""

if (-not (Test-Path $script)) {
  Fail "sampler not found at $script"
  Write-Host ""
  Write-Host "1 failure(s)." -ForegroundColor Red
  exit 1
}
$text = [IO.File]::ReadAllText($script)

# -- 1. the header line ------------------------------------------------------
$m = [regex]::Match($text, "(?m)^\s*\`$head\s*=\s*'([^']+)'")
if (-not $m.Success) {
  Fail 'could not find the $head assignment'
  $cols = @()
} else {
  $cols = $m.Groups[1].Value -split ','
  Pass "header parsed, $($cols.Count) columns"
}

# -- 2. every positional read lands on the column the contract names ---------
foreach ($i in ($contract.Keys | Sort-Object)) {
  if ($i -ge $cols.Count) {
    Fail "column index $i is past the end of the header ($($cols.Count) columns)"
    continue
  }
  if ($cols[$i] -ne $contract[$i]) {
    Fail "`$prevRow[$i] should read '$($contract[$i])' but the header has '$($cols[$i])' there"
  } else {
    Pass "`$prevRow[$i] -> $($cols[$i])"
  }
}

# -- 3. no positional read outside the contract ------------------------------
# Catches a new signal added without pinning its column here.
$used = [regex]::Matches($text, '\$prevRow\[(\d+)\]') |
        ForEach-Object { [int]$_.Groups[1].Value } |
        Sort-Object -Unique
$unpinned = @($used | Where-Object { -not $contract.ContainsKey($_) })
if ($unpinned.Count) {
  Fail "positional read(s) not pinned by this test: $($unpinned -join ', ')"
} else {
  Pass "all positional reads pinned ($($used -join ', '))"
}

# -- 4. writer placeholders match the header width ---------------------------
$w = [regex]::Match($text, "\('(\{0\}(?:,\{\d+\})+)'\s*-f")
if (-not $w.Success) {
  Fail 'could not find the CSV writer format string'
} else {
  $n = ([regex]::Matches($w.Groups[1].Value, '\{\d+\}')).Count
  if ($n -ne $cols.Count) {
    Fail "writer has $n placeholders but the header has $($cols.Count) columns"
  } else {
    Pass "writer placeholders match header width ($n)"
  }
}

# -- 5. each threshold is actually used by a signal ---------------------------
# A threshold defined but never compared is a trap that silently never fires.
foreach ($t in ([regex]::Matches($text, '\$(Threshold\w+)\s*=') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
  $uses = ([regex]::Matches($text, [regex]::Escape('$' + $t))).Count
  if ($uses -lt 3) {
    Fail "`$$t is defined but referenced only $uses time(s) -- no signal compares against it"
  } else {
    Pass "`$$t is wired to a signal"
  }
}

Write-Host ""
if ($failures.Count) {
  Write-Host "$($failures.Count) failure(s)." -ForegroundColor Red
  exit 1
}
Write-Host "All passed." -ForegroundColor Green
exit 0
