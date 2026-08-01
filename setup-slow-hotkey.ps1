# One-time setup. MUST be run from an elevated (Administrator) window.
#
# Wires a global hotkey to capture-slow-moment.ps1.
#
# Why a scheduled task rather than running the script directly from the
# shortcut: the capture reads performance counters and process data that need
# elevation to be complete. A task registered at RunLevel Highest runs elevated
# WITHOUT raising a UAC prompt, so one elevation here buys silent capture
# forever -- including while the screen is off or over a remote session. The
# shortcut just asks the task to run.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
  [string]$Hotkey   = 'CTRL+ALT+S',
  [string]$TaskName = 'Slow Moment Capture',
  # Defaults to the capture script beside this one.
  [string]$Script   = (Join-Path $PSScriptRoot 'capture-slow-moment.ps1')
)

$ErrorActionPreference = 'Stop'

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { Write-Host 'X  Run this from an Administrator window.' -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Script)) { Write-Host "X  Not found: $Script" -ForegroundColor Red; exit 1 }

# --- the task ---------------------------------------------------------------
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$ps  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Reason hotkey"

$action = New-ScheduledTaskAction -Execute $ps -Argument $arg
# Interactive, not S4U: the capture calls DwmFlush, which needs to be inside
# the interactive session to see the compositor at all.
$pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

# No trigger: this task only ever runs on demand, from the hotkey.
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $pri -Settings $set | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "Task registered.  RunLevel = $($t.Principal.RunLevel)   State = $($t.State)" -ForegroundColor Green

# --- the shortcut -----------------------------------------------------------
# A .lnk hotkey is only registered by Explorer if the shortcut lives on the
# Desktop or in the Start Menu. Start Menu keeps the Desktop clean.
$dir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnk = Join-Path $dir 'Capture Slow Moment.lnk'

$sh = New-Object -ComObject WScript.Shell
$s  = $sh.CreateShortcut($lnk)
$s.TargetPath       = 'C:\Windows\System32\schtasks.exe'
$s.Arguments        = "/run /tn `"$TaskName`""
$s.WorkingDirectory = 'C:\Windows\System32'
$s.WindowStyle      = 7          # minimised, so no console window flashes
$s.IconLocation     = 'C:\Windows\System32\imageres.dll,101'
$s.Description      = 'Capture machine state at the moment it feels slow'
$s.Hotkey           = $Hotkey
$s.Save()

$v = $sh.CreateShortcut($lnk)
Write-Host ""
Write-Host "Shortcut: $lnk"
Write-Host "Hotkey  : $($v.Hotkey)" -ForegroundColor Green
Write-Host ""
Write-Host "Press $Hotkey anywhere. Two short beeps = fired, one long beep = done (~15 s)."
Write-Host "Captures land in $(Join-Path (Split-Path $Script -Parent) 'slow-capture')\<timestamp>\summary.txt"
Write-Host "and are indexed on the Desktop in slow-captures.txt."
Write-Host ""
Write-Host "Caveat: Explorer registers .lnk hotkeys, so if Explorer itself is hung the"
Write-Host "key may not fire. Fallback that does not depend on it:"
Write-Host "   schtasks /run /tn `"$TaskName`""
Write-Host ""
Write-Host "To undo:"
Write-Host "   Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false"
Write-Host "   Remove-Item -LiteralPath `"$lnk`""
