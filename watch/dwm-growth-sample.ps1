# 一次取樣 dwm 合成器的劣化指標，附加一列到 CSV 後結束。
# 設計成 one-shot：沒有常駐進程會死掉或洩漏，每次執行獨立，重開機也不影響。
#
# 關鍵衍生欄位 ms_per_pass = 每次合成 pass 花掉的 CPU 毫秒數。
# 2026-07-31 16:00 重啟 dwm 後的乾淨基準約 2 ms；劣化 13 天後量到約 9 ms。

$ErrorActionPreference = 'Continue'
$csv = 'C:\Users\LZong\Scripts\dwm-growth.csv'
$err = 'C:\Users\LZong\Scripts\dwm-growth-error.txt'

try {

Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Runtime.InteropServices;
public static class G {
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr h, uint flags);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  // GDI / USER 物件數 —— 直接的「保留中 UI 資源」計數，比 private bytes 乾淨得多
  // （private bytes 在健康的 dwm 上自己就會盪 4 倍，沒有鑑別力）。
  // 需要提權；排程工作是 RunLevel Highest 所以讀得到，未提權時回 [0,0]。
  public static uint[] Gui(int pid){
    IntPtr h = OpenProcess(0x1000, false, pid);              // QUERY_LIMITED_INFORMATION
    if(h == IntPtr.Zero) h = OpenProcess(0x0400, false, pid); // QUERY_INFORMATION
    if(h == IntPtr.Zero) return new uint[]{0,0};
    uint gdi = GetGuiResources(h, 0), usr = GetGuiResources(h, 1);
    CloseHandle(h);
    return new uint[]{ gdi, usr };
  }
  [DllImport("user32.dll")] static extern bool EnumWindows(E cb, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  delegate bool E(IntPtr h, IntPtr l);

  // 回傳 [pass/s, p50ms, p90ms]
  public static double[] Rate(int n){
    var iv=new double[n]; DwmFlush(); var sw=Stopwatch.StartNew(); double prev=0;
    for(int i=0;i<n;i++){ DwmFlush(); double now=sw.Elapsed.TotalMilliseconds; iv[i]=now-prev; prev=now; }
    sw.Stop(); Array.Sort(iv);
    return new double[]{ n/(prev/1000.0), iv[n/2], iv[(int)(n*0.9)] };
  }
  public static int[] Windows(){
    int top=0, vis=0;
    EnumWindows((h,l)=>{ top++; if(IsWindowVisible(h)) vis++; return true; }, IntPtr.Zero);
    return new int[]{ top, vis };
  }
}
'@

$d = Get-CimInstance Win32_Process -Filter "Name='dwm.exe'" | Select-Object -First 1
if(-not $d){ throw 'dwm.exe 不存在' }
$dwmPid = [int]$d.ProcessId

function CpuSec { $q = Get-CimInstance Win32_Process -Filter "ProcessId=$dwmPid" -EA SilentlyContinue
                  if($q){ ([double]$q.KernelModeTime + [double]$q.UserModeTime)/1e7 } else { $null } }

# 每條執行緒的 CPU 累計秒數。用 .NET 而不是
# Win32_PerfFormattedData_PerfProc_Thread —— 後者會透過 WMI 枚舉全系統的執行緒
# （-Filter 是事後才套用），實測一次要 15.2 核心秒；這個版本 0.6 秒且牆鐘 0.0 秒。
function ThreadCpu {
  $h = @{}
  try {
    foreach($t in [Diagnostics.Process]::GetProcessById($dwmPid).Threads){
      try { $h[[int]$t.Id] = $t.TotalProcessorTime.TotalSeconds } catch { }
    }
  } catch { }
  $h
}

# --- CPU 速率：先取 10 秒的安靜區間，再單獨量 pass rate ---
$c0 = CpuSec; $th0 = ThreadCpu; $t0 = Get-Date
Start-Sleep -Seconds 10
$r  = try { [G]::Rate(120) } catch { @(0,0,0) }     # ~1 秒的 DwmFlush 叢發
$c1 = CpuSec; $th1 = ThreadCpu; $t1 = Get-Date
$el = ($t1-$t0).TotalSeconds
$cpuPct = if($c0 -ne $null -and $c1 -ne $null -and $el -gt 0){ ($c1-$c0)/$el*100 } else { $null }

# --- 最熱的 thread（合成執行緒；dwm 重啟後 TID 會變，所以取最大值而不是寫死）---
$hotTid = ''; $hotPct = ''
if($th1.Count -gt 0 -and $el -gt 0){
  # 注意：別用 $d 當迴圈變數 —— 外層的 $d 是 dwm 的 CIM 物件，蓋掉會讓 $d.CreationDate 變 null
  $best = $null
  foreach($id in $th1.Keys){
    if($th0.ContainsKey($id)){
      $delta = $th1[$id] - $th0[$id]
      if($null -eq $best -or $delta -gt $best.delta){ $best = @{ id=$id; delta=$delta } }
    }
  }
  if($best){ $hotTid = $best.id; $hotPct = [math]::Round($best.delta/$el*100,1) }
}

# --- GPU：用萬用字元查詢，避開昂貴的 -ListSet 列舉 ---
$gpuMem = ''; $gpuPct = ''
try {
  $gpuMem = [math]::Round(((Get-Counter '\GPU Process Memory(*)\Local Usage' -EA Stop).CounterSamples |
              Where-Object { $_.InstanceName -match "pid_${dwmPid}_" } |
              Measure-Object CookedValue -Sum).Sum / 1MB, 0)
} catch { }
try {
  $gpuPct = [math]::Round(((Get-Counter '\GPU Engine(*)\Utilization Percentage' -EA Stop).CounterSamples |
              Where-Object { $_.InstanceName -match "pid_${dwmPid}_" } |
              Measure-Object CookedValue -Sum).Sum, 3)
} catch { }

# --- 場景複雜度的粗略代理指標 ---
$w = try { [G]::Windows() } catch { @(0,0) }

# --- CRD 是否正在擷取桌面 ---
$crd = [int][bool](Get-CimInstance Win32_Process -Filter "Name='remoting_desktop.exe'" -EA SilentlyContinue)

$osUp   = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalHours
$dwmUp  = ((Get-Date) - $d.CreationDate).TotalHours
$passPs = $r[0]

# 每次 pass 的 CPU 毫秒數 —— 這就是要追的那個數字
$msPass    = if($cpuPct -and $passPs -gt 0){ [math]::Round($cpuPct/100*1000/$passPs, 3) } else { '' }
$msPassHot = if($hotPct -ne '' -and $passPs -gt 0){ [math]::Round([double]$hotPct/100*1000/$passPs, 3) } else { '' }

$gui = try { [G]::Gui($dwmPid) } catch { @(0,0) }

# 新欄位一律加在最後 —— 舊資料列只有 20 欄，靠位置索引前 20 欄的讀法不會壞。
# top_windows / vis_windows 量的是全系統視窗數（= 使用者開了哪些 app），
# 與 dwm 內部狀態無關，已證實無鑑別力，保留只為不破壞既有欄位順序。
$head = 'time,dwm_pid,dwm_up_h,os_up_h,cpu_pct,hot_tid,hot_pct,pass_per_s,p50_ms,p90_ms,ms_per_pass,ms_per_pass_hot,private_mb,gpu_local_mb,gpu_pct,handles,threads,top_windows,vis_windows,crd_capturing,gdi_objects,user_objects'
if(-not (Test-Path $csv)){ $head | Out-File $csv -Encoding utf8 }

('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13},{14},{15},{16},{17},{18},{19},{20},{21}' -f `
  (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $dwmPid,
  [math]::Round($dwmUp,2), [math]::Round($osUp,2),
  $(if($cpuPct -ne $null){[math]::Round($cpuPct,1)}else{''}),
  $hotTid, $hotPct,
  [math]::Round($passPs,1), [math]::Round($r[1],2), [math]::Round($r[2],2),
  $msPass, $msPassHot,
  [math]::Round($d.PrivatePageCount/1MB,0), $gpuMem, $gpuPct,
  $d.HandleCount, $d.ThreadCount, $w[0], $w[1], $crd,
  $gui[0], $gui[1]
) | Out-File $csv -Encoding utf8 -Append

# ---------------------------------------------------------------------------
# 劣化陷阱。實際情況不會是「使用者看到曲線」，而是「發現變慢，順手重啟 dwm，證據又沒了」，
# 所以要在他察覺之前自己抓好。
#
# 【為什麼是兩個獨立訊號】
# 原本只看 ms_per_pass_hot。但 24 小時的資料顯示成本沒動、保留資源卻在漲 ——
# 如果這次劣化長在別的地方，單一訊號的陷阱永遠不會觸發，等於白架。
# 所以改成兩個各自獨立、各自有 flag 的觸發條件，一個誤觸不會吃掉另一個的機會。
#
# 訊號 1  ms_per_pass_hot > 4.0
#         乾淨散佈 0.10–2.77（54 筆），爛掉時 8.7。高於雜訊上緣 1.4 倍、低於劣化值一半。
# 訊號 2  handles > 2400
#         handles 是三個候選裡最單調的（相鄰下降僅 20%、全距 1.10x）。
#         爛掉時 2532，目前上限 1791。
#         ※ private_mb 刻意不當觸發訊號：健康狀態自己就盪 256–1092（4.27x、下降 33%），
#           而且已經超過「爛掉時」的 795 —— 沒有鑑別力，拿它觸發只會浪費採證機會。
#
# 兩者都要求連續兩次超標，擋掉瞬間尖峰。
# ---------------------------------------------------------------------------
$TH_COST    = 4.0
$TH_HANDLES = 2400

# 前一列（同一個 dwm PID）拿來做「連續兩次」判定
$prevRow = $null
$allRows = @(Get-Content $csv | Select-Object -Skip 1)
if($allRows.Count -ge 2){
  $p = $allRows[-2] -split ','
  if($p.Count -ge 16 -and $p[1] -eq "$dwmPid"){ $prevRow = $p }
}

function Fire($tag, $reason){
  $flag = "C:\Users\LZong\Scripts\dwm-captured-$dwmPid-$tag.flag"
  if(Test-Path $flag){ return }
  New-Item -ItemType File -Path $flag -Force | Out-Null
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$tag] $reason" |
    Out-File 'C:\Users\LZong\Scripts\dwm-growth-trigger.log' -Encoding utf8 -Append
  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass `
    -File 'C:\Users\LZong\Scripts\dwm-autocapture.ps1' -Reason "[$tag] $reason"
}

# 訊號 1：每次合成 pass 的 CPU 成本
if($msPassHot -ne '' -and [double]$msPassHot -gt $TH_COST -and $prevRow -and $prevRow[11]){
  if([double]$prevRow[11] -gt $TH_COST){
    Fire 'cost' "ms_per_pass_hot=$msPassHot 前次=$($prevRow[11])（門檻 $TH_COST，爛掉時 8.7）"
  }
}

# 訊號 2：保留中的核心物件
if([int]$d.HandleCount -gt $TH_HANDLES -and $prevRow -and $prevRow[15]){
  if([int]$prevRow[15] -gt $TH_HANDLES){
    Fire 'handles' "handles=$($d.HandleCount) 前次=$($prevRow[15])（門檻 $TH_HANDLES，爛掉時 2532）"
  }
}

} catch {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($_.Exception.GetType().Name): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" |
    Out-File $err -Encoding utf8 -Append
}
