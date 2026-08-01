# 只需執行一次，且必須在【系統管理員】視窗執行。
#
# 目的：把 DWM Growth Sampler 排程工作改成 RunLevel Highest。
# 排程工作以 Highest 執行時【不會跳 UAC】—— 所以這一次提權，換到往後永遠靜默採證。
# 沒有這一步，劣化觸發時抓不到完整 dump，也跑不了 wpr。

$ErrorActionPreference = 'Stop'

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $elevated){
  Write-Host '❌ 這支要在系統管理員視窗執行。' -ForegroundColor Red
  exit 1
}

$name = 'DWM Growth Sampler'
$ps   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arg  = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Users\LZong\Scripts\dwm-growth-sample.ps1"'

Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $ps -Argument $arg
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 30)
$t2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
# Highest = 採證時不跳 UAC；Interactive = 拿得到 DWM（DwmFlush 需要在互動 session 內）
$pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $name -Action $action -Trigger $t1,$t2 -Settings $set -Principal $pri | Out-Null

$t = Get-ScheduledTask -TaskName $name
Write-Host "✅ 完成。RunLevel = $($t.Principal.RunLevel)   狀態 = $($t.State)" -ForegroundColor Green
Write-Host "   下次執行: $((Get-ScheduledTaskInfo -TaskName $name).NextRunTime)"
Write-Host ''
Write-Host '驗證（會真的抓一次完整 dump + 30 秒 ETL，約 3–4 GB，可省略）:'
Write-Host "   powershell -ExecutionPolicy Bypass -File C:\Users\LZong\Scripts\dwm-autocapture.ps1 -Reason 驗證"
