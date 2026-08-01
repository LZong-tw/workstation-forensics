# Run once, and it MUST be from an elevated (Administrator) window.
#
# Registers the DWM Growth Sampler scheduled task at RunLevel Highest.
#
# A task registered at Highest runs elevated WITHOUT raising a UAC prompt, so
# this single elevation buys silent capture forever -- including with the screen
# off or over a remote session. Without it, the trap fires but cannot take a
# full dump and cannot run wpr, which is the whole point.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI.

param(
  [string]$TaskName        = 'DWM Growth Sampler',
  [int]$IntervalMinutes    = 30,
  # Defaults to the sampler beside this script.
  [string]$Script          = (Join-Path $PSScriptRoot 'dwm-growth-sample.ps1')
)

$ErrorActionPreference = 'Stop'

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) {
  Write-Host 'X  Run this from an Administrator window.' -ForegroundColor Red
  exit 1
}
if (-not (Test-Path $Script)) {
  Write-Host "X  Not found: $Script" -ForegroundColor Red
  exit 1
}

$ps  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $ps -Argument $arg
# No -RepetitionDuration: omitting it means indefinite. Passing
# [TimeSpan]::MaxValue fails with "P99999999DT23H59M59S is out of range".
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$t2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
# Highest   = no UAC prompt when the trap fires.
# Interactive = the sampler can see DWM at all; DwmFlush must run inside the
#               interactive session.
$pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $t1,$t2 `
  -Settings $set -Principal $pri | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "Registered.  RunLevel = $($t.Principal.RunLevel)   State = $($t.State)" -ForegroundColor Green
Write-Host "   next run: $((Get-ScheduledTaskInfo -TaskName $TaskName).NextRunTime)"
Write-Host ''
Write-Host 'Optional drill (really does take a full dump plus a 30 s ETL, several GB):'
Write-Host "   powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'dwm-autocapture.ps1')`" -Reason drill"
Write-Host ''
Write-Host 'To undo:'
Write-Host "   Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false"
