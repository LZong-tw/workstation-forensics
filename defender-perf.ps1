# 找出 Windows Defender 即時保護的 CPU 花在哪裡。必須在【系統管理員】視窗執行。
#
# 錄 120 秒，然後產出「哪些檔案 / 副檔名 / 進程 / 掃描路徑」最耗時的排行。
# 只是錄製，不改任何設定、不關保護。
#
# 用法:  powershell -ExecutionPolicy Bypass -File C:\Users\LZong\Scripts\defender-perf.ps1

param([int]$Seconds = 120)

$ErrorActionPreference = 'Continue'
$dir  = 'C:\Users\LZong\Scripts\defender-perf'
$etl  = "$dir\defender.etl"
$out  = "$dir\report.txt"
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $elevated){ Write-Host '❌ 要在系統管理員視窗執行。' -ForegroundColor Red; exit 1 }

$log = New-Object System.Collections.Generic.List[string]
function L($m){ $log.Add([string]$m); Write-Host $m; ($log -join "`r`n") | Out-File $out -Encoding utf8 }

L "=== 目前狀態 ==="
$p = Get-CimInstance Win32_Process -Filter "Name='MsMpEng.exe'"
$cpu0 = ([double]$p.KernelModeTime + [double]$p.UserModeTime)/1e7
L "  MsMpEng 已跑 $([math]::Round(((Get-Date)-$p.CreationDate).TotalDays,2)) 天   CPU 累計 $([math]::Round($cpu0/3600,2)) 小時   整段平均 $([math]::Round($cpu0/((Get-Date)-$p.CreationDate).TotalSeconds*100,1))%"

$pref = Get-MpPreference
L ""
L "=== 目前排除設定（未提權看不到，所以在這裡印）==="
L "  排除路徑  : $(if($pref.ExclusionPath){($pref.ExclusionPath) -join ' | '}else{'（無）'})"
L "  排除程序  : $(if($pref.ExclusionProcess){($pref.ExclusionProcess) -join ' | '}else{'（無）'})"
L "  排除副檔名: $(if($pref.ExclusionExtension){($pref.ExclusionExtension) -join ' | '}else{'（無）'})"

L ""
L "=== 錄製 $Seconds 秒 ==="
L "  現在請照常使用電腦，讓它錄到平常的負載。"
if(Test-Path $etl){ Remove-Item -LiteralPath $etl -Force }
try {
  New-MpPerformanceRecording -RecordTo $etl -Seconds $Seconds -ErrorAction Stop
  L "  完成，ETL = $([math]::Round((Get-Item $etl).Length/1MB,1)) MB"
} catch {
  L "  ❌ 錄製失敗: $($_.Exception.Message)"
  exit 1
}

$cpu1 = (Get-CimInstance Win32_Process -Filter "Name='MsMpEng.exe'" |
         ForEach-Object { ([double]$_.KernelModeTime + [double]$_.UserModeTime)/1e7 })
L "  錄製期間 MsMpEng 用掉 $([math]::Round($cpu1-$cpu0,1)) 核心秒 = $([math]::Round(($cpu1-$cpu0)/$Seconds*100,1))% of one core"

L ""
# 注意：splat 一定要用「變數」@splat，不能寫 @($v.a) —— 後者會把 hashtable 包成陣列，
# 變成位置引數傳進去，四段全部炸「找不到接受引數 System.Object[] 的位置參數」。
$views = @(
  @{ t='最耗時的檔案';     a=@{ TopFiles      = 25 }; f='Path' }
  @{ t='最耗時的副檔名';   a=@{ TopExtensions = 25 }; f='Extension' }
  @{ t='觸發掃描的進程';   a=@{ TopProcesses  = 25 }; f='ProcessPath' }
  @{ t='最耗時的單次掃描'; a=@{ TopScans      = 25 }; f='Path' }
)
foreach($v in $views){
  L "=== $($v.t) ==="
  try {
    $splat = $v.a
    $r = Get-MpPerformanceReport -Path $etl @splat -ErrorAction Stop
    # 回傳是巢狀物件（.TopFiles / .TopExtensions / …），要先挖出那層
    $rows = $r."$($v.a.Keys | Select-Object -First 1)"
    if(-not $rows){ $rows = $r }
    foreach($row in $rows){
      $n = $row.($v.f); if(-not $n){ $n = '(未知)' }
      L ("  {0,8:N0} ms  x{1,-5} {2}" -f $row.TotalDuration.TotalMilliseconds, $row.Count, $n)
    }
  } catch { L "  取得失敗: $($_.Exception.Message)" }
  L ""
}

L "報告已存: $out"
L "ETL 保留在: $etl（要重新分析可用 Get-MpPerformanceReport -Path 該檔）"
