# dwm 劣化時的自動採證。由 dwm-growth-sample.ps1 在超過門檻時呼叫，也可手動執行。
# 需要 admin（完整 dump 與 wpr 都要）。排程工作若設為 RunLevel Highest 就不會跳 UAC。
#
# 產出全部放在 C:\Users\LZong\Scripts\dwm-capture\<時間戳>\
#   dwm-full.dmp   完整記憶體 dump —— 讓 Microsoft 能真的去數那棵 visual tree
#   dwm.etl        30 秒取樣式剖析 —— 用 wpa.exe 開（GUI，不需 profile）
#   stacks.txt     cdb 符號化堆疊
#   summary.txt    當下的量測值
#
# 重點：採完證之後才可以重啟 dwm。桌面上會留一個提示檔。

param([string]$Reason = '手動觸發')

$ErrorActionPreference = 'Continue'
$root = 'C:\Users\LZong\Scripts\dwm-capture'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $root $stamp
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$log = New-Object System.Collections.Generic.List[string]
function L($m){ $log.Add([string]$m); ($log -join "`r`n") | Out-File "$dir\summary.txt" -Encoding utf8 }

$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

L "採證時間 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
L "觸發原因 : $Reason"
L "已提權   : $elevated"

$d = Get-CimInstance Win32_Process -Filter "Name='dwm.exe'" | Select-Object -First 1
$dwmPid = [int]$d.ProcessId
L "dwm PID  : $dwmPid   已存活 $([math]::Round(((Get-Date)-$d.CreationDate).TotalHours,2)) 小時"
L "Private  : $([math]::Round($d.PrivatePageCount/1MB,0)) MB   Handles: $($d.HandleCount)   Threads: $($d.ThreadCount)"
L ""

if(-not $elevated){
  L "❌ 未提權 —— 無法抓完整 dump 也無法跑 wpr。"
  L "   請在系統管理員視窗執行： powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

# ---------- 1. 完整記憶體 dump ----------
if($elevated){
  L "=== 完整記憶體 dump ==="
  try {
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class DC {
  [DllImport("dbghelp.dll", SetLastError=true)]
  public static extern bool MiniDumpWriteDump(IntPtr hProc, int pid, IntPtr hFile,
      int type, IntPtr ex, IntPtr user, IntPtr cb);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@
    $dmp = "$dir\dwm-full.dmp"
    $hp = [DC]::OpenProcess(0x0400 -bor 0x0010, $false, $dwmPid)   # QUERY_INFORMATION | VM_READ
    if($hp -ne [IntPtr]::Zero){
      $fs = [System.IO.File]::Create($dmp)
      # WithFullMemory(0x2) | WithHandleData(0x4) | WithProcessThreadData(0x100) | WithThreadInfo(0x1000)
      $ok = [DC]::MiniDumpWriteDump($hp, $dwmPid, $fs.SafeFileHandle.DangerousGetHandle(),
              (0x2 -bor 0x4 -bor 0x100 -bor 0x1000), [IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
      $fs.Close(); [void][DC]::CloseHandle($hp)
      L "  結果 = $ok   大小 = $([math]::Round((Get-Item $dmp).Length/1MB,1)) MB"
    } else { L "  OpenProcess 失敗 err=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  } catch { L "  例外: $($_.Exception.Message)" }
  L ""
}

# ---------- 2. cdb 符號化堆疊（不需 admin、不碰進程）----------
L "=== cdb 符號化堆疊 ==="
try {
  $cdb = "$((Get-AppxPackage Microsoft.WinDbg).InstallLocation)\amd64\cdb.exe"
  if(Test-Path $cdb){
    $env:_NT_SYMBOL_PATH = 'srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
    $target = if(Test-Path "$dir\dwm-full.dmp"){ "$dir\dwm-full.dmp" } else { $null }
    if($target){
      & $cdb -z $target -c ".symfix;.reload;~*k 30;q" 2>&1 | Out-File "$dir\stacks.txt" -Encoding utf8
      L "  已寫入 stacks.txt（來源: $(Split-Path $target -Leaf)）"
      # 把合成執行緒那段挑出來放進 summary
      $sel = Select-String -Path "$dir\stacks.txt" -Pattern 'dwmcore!' -Context 0,6 |
             Select-Object -First 3
      foreach($s in $sel){ L "    $($s.Line.Trim())" }
    } else { L "  無 dump 可分析（未提權）" }
  } else { L "  ❌ 找不到 cdb.exe" }
} catch { L "  例外: $($_.Exception.Message)" }
L ""

# ---------- 3. wpr 取樣式剖析 ----------
if($elevated){
  L "=== wpr 收集 30 秒 ==="
  try {
    & wpr.exe -cancel 2>&1 | Out-Null
    $r = & wpr.exe -start CPU -start DesktopComposition -start GPU -filemode 2>&1 | Out-String
    if($LASTEXITCODE -ne 0){
      & wpr.exe -cancel 2>&1 | Out-Null
      $r = & wpr.exe -start CPU -filemode 2>&1 | Out-String
      L "  改用 CPU only: exit=$LASTEXITCODE"
    }
    if($LASTEXITCODE -eq 0){
      Start-Sleep 30
      & wpr.exe -stop "$dir\dwm.etl" 2>&1 | Out-Null
      if(Test-Path "$dir\dwm.etl"){ L "  ETL = $([math]::Round((Get-Item "$dir\dwm.etl").Length/1MB,1)) MB  ← 用 wpa.exe 開" }
      else { L "  ❌ ETL 沒產生" }
    } else { L "  ❌ 無法啟動收集: $($r.Trim())" }
  } catch { L "  例外: $($_.Exception.Message)" }
  L ""
}

# ---------- 4. 讓使用者「一定會看到」----------
$gotDump = Test-Path "$dir\dwm-full.dmp"
$gotEtl  = Test-Path "$dir\dwm.etl"
$title   = if($gotDump){ '採證完成' } else { '採證失敗-需手動' }
$note = "$env:USERPROFILE\Desktop\!! DWM 已劣化-$title !!.txt"
$head  = if($gotDump){ 'DWM 合成器又劣化了，證據已經自動抓好，你可以放心重啟 dwm。' }
         else { "DWM 合成器又劣化了，但【證據沒抓到】—— 重啟 dwm 之前請先手動採證：`r`n`r`n  在系統管理員視窗執行:`r`n  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`"" }
@"
$head

  觸發時間 : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  觸發原因 : $Reason
  證據位置 : $dir
  完整 dump: $(if($gotDump){'✅ 有'}else{'❌ 無'})     ETL: $(if($gotEtl){'✅ 有'}else{'❌ 無'})

重啟指令（需系統管理員）:
  taskkill /f /im dwm.exe

要看堆疊:
  $dir\stacks.txt

要看取樣式剖析（證明時間集中在 CleanTrees）:
  wpa.exe "$dir\dwm.etl"

成長曲線:
  C:\Users\LZong\Scripts\dwm-growth.csv

看完就可以刪掉這個檔案。
"@ | Out-File $note -Encoding utf8
L "桌面提示檔: $note"
L ""
L "完成 $(Get-Date -Format 'HH:mm:ss')"
