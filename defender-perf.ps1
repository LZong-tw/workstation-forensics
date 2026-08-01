# Find out where Windows Defender real-time protection is spending CPU.
# MUST be run from an elevated (Administrator) window.
#
# Records for a fixed window, then reports which files, extensions, processes
# and individual scans cost the most time.
#
# Recording only. Changes no Defender setting and disables no protection.
#
# Usage:  powershell -ExecutionPolicy Bypass -File defender-perf.ps1
#
# Reading the output: scan TotalDuration is elapsed time per scan, scans
# overlap each other, and memory/AMSI scans are not attributed to any file. The
# per-file numbers therefore do NOT sum to the process's CPU time and must not
# be presented as if they do.

param(
  [int]$Seconds   = 120,
  [string]$OutDir = (Join-Path $PSScriptRoot 'defender-perf')
)

$ErrorActionPreference = 'Continue'
$etl = Join-Path $OutDir 'defender.etl'
$out = Join-Path $OutDir 'report.txt'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { Write-Host 'X  Run this from an Administrator window.' -ForegroundColor Red; exit 1 }

$log = New-Object System.Collections.Generic.List[string]
function L($m) { $log.Add([string]$m); Write-Host $m; ($log -join "`r`n") | Out-File $out -Encoding utf8 }

L '=== Current state ==='
$p    = Get-CimInstance Win32_Process -Filter "Name='MsMpEng.exe'"
$cpu0 = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7
$age  = ((Get-Date) - $p.CreationDate)
L ("  MsMpEng up {0:N2} days   CPU {1:N2} h   lifetime average {2:N1}% of one core" -f `
    $age.TotalDays, ($cpu0/3600), ($cpu0/$age.TotalSeconds*100))

# Exclusions are invisible without elevation, which is why they are printed
# here rather than left for the reader to look up.
$pref = Get-MpPreference
L ''
L '=== Current exclusions ==='
L "  Paths     : $(if ($pref.ExclusionPath)      { $pref.ExclusionPath      -join ' | ' } else { '(none)' })"
L "  Processes : $(if ($pref.ExclusionProcess)   { $pref.ExclusionProcess   -join ' | ' } else { '(none)' })"
L "  Extensions: $(if ($pref.ExclusionExtension) { $pref.ExclusionExtension -join ' | ' } else { '(none)' })"

L ''
L "=== Recording for $Seconds s ==="
L '  Use the machine normally so the recording captures a representative load.'
if (Test-Path $etl) { Remove-Item -LiteralPath $etl -Force }
try {
  New-MpPerformanceRecording -RecordTo $etl -Seconds $Seconds -ErrorAction Stop
  L ("  done, ETL = {0:N1} MB" -f ((Get-Item $etl).Length/1MB))
} catch {
  L "  X  recording failed: $($_.Exception.Message)"
  exit 1
}

$cpu1 = (Get-CimInstance Win32_Process -Filter "Name='MsMpEng.exe'" |
         ForEach-Object { ([double]$_.KernelModeTime + [double]$_.UserModeTime)/1e7 })
L ("  MsMpEng used {0:N1} core-seconds during the window = {1:N1}% of one core" -f `
    ($cpu1-$cpu0), (($cpu1-$cpu0)/$Seconds*100))

L ''
# Splatting must go through a variable. Writing @($v.Args) wraps the hashtable
# in an array, which arrives as a positional argument and fails every section
# with "cannot find a positional parameter that accepts argument
# System.Object[]" -- silently blanking the entire report.
$views = @(
  @{ Title='Costliest files';            Args=@{ TopFiles      = 25 }; Field='Path'        }
  @{ Title='Costliest extensions';       Args=@{ TopExtensions = 25 }; Field='Extension'   }
  @{ Title='Processes triggering scans'; Args=@{ TopProcesses  = 25 }; Field='ProcessPath' }
  @{ Title='Costliest single scans';     Args=@{ TopScans      = 25 }; Field='Path'        }
)
foreach ($v in $views) {
  L "=== $($v.Title) ==="
  try {
    $splat = $v.Args
    $r = Get-MpPerformanceReport -Path $etl @splat -ErrorAction Stop
    # The result is a nested object (.TopFiles / .TopExtensions / ...), so the
    # matching property has to be dug out before enumerating.
    $rows = $r.($v.Args.Keys | Select-Object -First 1)
    if (-not $rows) { $rows = $r }
    foreach ($row in $rows) {
      $n = $row.($v.Field); if (-not $n) { $n = '(unknown)' }
      L ("  {0,9:N0} ms  x{1,-5} {2}" -f $row.TotalDuration.TotalMilliseconds, $row.Count, $n)
    }
  } catch { L "  failed: $($_.Exception.Message)" }
  L ''
}

L "Report saved to: $out"
L "ETL kept at: $etl  (re-analyse with Get-MpPerformanceReport -Path <etl>)"
