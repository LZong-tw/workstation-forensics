# Regression tests for every .ps1 in this repo.
#
# These guard the failure modes that actually bit during development, all of
# which produce scripts that look fine in an editor and explode at runtime:
#
#   1. Non-ASCII bytes. PowerShell 5.1 reads BOM-less UTF-8 as ANSI, so a
#      non-ASCII character inside a comment becomes a mangled quote and the
#      parser reports "string is missing the terminator" dozens of lines later.
#   2. Parse errors in either host. 5.1 and 7 do not agree; a script that
#      parses in one can fail in the other.
#   3. Hardcoded user paths. This repo is public; C:\Users\<someone> in a
#      default parameter means it only runs on one machine.
#
# Usage:  pwsh -File test\Test-Scripts.ps1     (or powershell -File ...)
# Exit code 0 = all passed.

$ErrorActionPreference = 'Stop'

$root    = Split-Path $PSScriptRoot -Parent
$scripts = Get-ChildItem $root -Recurse -Filter *.ps1 |
           Where-Object { $_.FullName -notmatch '\\\.git\\' }

$ps51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$ps7  = (Get-Command pwsh -ErrorAction SilentlyContinue).Source

$failures = New-Object System.Collections.Generic.List[string]
function Fail($file, $why) { $failures.Add("$file : $why") }

Write-Host "Testing $($scripts.Count) scripts under $root"
Write-Host ""

foreach ($s in $scripts) {
  $rel = $s.FullName.Substring($root.Length + 1)
  $problems = @()

  # -- 1. pure ASCII -----------------------------------------------------
  $bytes = [IO.File]::ReadAllBytes($s.FullName)
  $bad   = @($bytes | Where-Object { $_ -gt 127 })
  if ($bad.Count) { $problems += "$($bad.Count) non-ASCII bytes" }

  # -- 2. parses in both hosts -------------------------------------------
  $err = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$err)
  if ($err) { $problems += "parse error (this host) line $($err[0].Extent.StartLineNumber): $($err[0].Message)" }

  foreach ($host51 in @($ps51, $ps7)) {
    if (-not $host51 -or -not (Test-Path $host51)) { continue }
    if ($host51 -eq $PSHOME) { continue }
    $r = & $host51 -NoProfile -Command "try { [void][ScriptBlock]::Create([IO.File]::ReadAllText('$($s.FullName)')); 'OK' } catch { 'FAIL: ' + `$_.Exception.Message }"
    if ($r -notmatch '^OK') { $problems += "$(Split-Path $host51 -Leaf): $r" }
  }

  # -- 3. no hardcoded user paths ----------------------------------------
  # Matches C:\Users\<name>\ where <name> is a real account, not a placeholder.
  $text = [IO.File]::ReadAllText($s.FullName)
  $hits = [regex]::Matches($text, '(?i)C:\\Users\\(?!<|%|\$)[A-Za-z0-9._-]+')
  if ($hits.Count) {
    $names = ($hits | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
    $problems += "$($hits.Count) hardcoded user path(s): $names"
  }

  if ($problems.Count) {
    Write-Host "  FAIL  $rel" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "          $p" -ForegroundColor Red; Fail $rel $p }
  } else {
    Write-Host "  ok    $rel" -ForegroundColor Green
  }
}

Write-Host ""

# Behavioural tests live in their own file; run them here so one command covers
# the repo.
$behavioural = Join-Path $PSScriptRoot 'Test-DwmTrap.ps1'
if (Test-Path $behavioural) {
  & (Get-Process -Id $PID).Path -NoProfile -File $behavioural
  if ($LASTEXITCODE -ne 0) { Fail 'test\Test-DwmTrap.ps1' 'behavioural tests failed' }
  Write-Host ""
}

if ($failures.Count) {
  Write-Host "$($failures.Count) failure(s)." -ForegroundColor Red
  exit 1
}
Write-Host "All passed." -ForegroundColor Green
exit 0
