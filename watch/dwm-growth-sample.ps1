# Take one sample of dwm's degradation indicators, append a row to CSV, exit.
#
# Deliberately one-shot: there is no resident process to die or leak, each run
# is independent, and a reboot changes nothing.
#
# The derived column that matters is ms_per_pass -- CPU milliseconds spent per
# composition pass. On the reference machine a freshly restarted dwm sits near
# 2 ms; after 13 days of uptime it measured about 9 ms.
#
# Source is pure ASCII on purpose: PowerShell 5.1 reads BOM-less UTF-8 as ANSI,
# which turns non-ASCII comments into cascading parser errors.

param(
  # Everything this script reads or writes lives here. Defaults beside the
  # script so it works wherever it is installed.
  [string]$DataDir = $PSScriptRoot,

  # Signal 1: CPU milliseconds per composition pass on the hottest thread.
  # Degraded reading was 8.7.
  #
  # [RETRACTED] 4.0, the original value. It was calibrated on 54 samples whose
  # clean spread was 0.10-2.77, and described as sitting 1.4x above the noise
  # ceiling. At 320 samples the healthy maximum is 4.712: the threshold was
  # inside the healthy distribution, and 8 samples had already crossed it --
  # every one of them at a composition rate of 137-144/s, which is healthy.
  # Nothing false-fired only because no two of those 8 were adjacent.
  #
  # The cost of a false fire is not a wasted capture. Fire() writes a flag and
  # returns early for that pid and tag forever, so one false fire on day 7
  # disarms the signal for a cycle that degrades on day 13.
  #
  # 6.0 sits between the healthy maximum 4.712 and the degraded 8.7. While the
  # composition rate is pinned to vsync it also means "hot thread above 86%",
  # which is independently abnormal.
  [double]$ThresholdCost = 6.0,

  # Signal 2: handle count. Of the three candidates this was the most
  # monotonic -- it fell between adjacent samples only 20% of the time, total
  # range 1.10x. Degraded reading was 2532.
  #
  # Known to be weak: the two-consecutive rule requires the baseline to cross,
  # not a peak, and the baseline grows about +3.0/hour, reaching 2400 around day
  # 13.8 against degradation observed on day 13.4. It arrives with the failure
  # or after it. Kept because it costs nothing, not because it is relied on.
  [int]$ThresholdHandles = 2400,

  # Signal 3, and the one that carries the trap.
  #
  # Signals 1 and 2 are contaminated by workload. ms_per_pass_hot is
  # hot_pct/100*1000/pass_per_s, so while the rate is pinned at 144 it is just
  # hot_pct divided by 1.44 -- it rises whenever dwm is busy, degraded or not.
  #
  # p50_ms is not. Across 396 healthy samples spanning dwm CPU from 4% to 67%
  # the median pass interval stays locked on 1/144 Hz = 6.944 ms: median 6.93,
  # p95 7.00, p99 7.12, max 7.18, and nothing above 7.20. Degraded was 7.4-9.1,
  # with the median itself pushed off vsync. 7.25 sits in the gap.
  #
  # Provenance, since it decides whether that gap is real: the degraded 7.4-9.1
  # never entered the CSV -- it came from an ad-hoc measurement. But the healthy
  # control from that same session read 6.94, against 6.93 across the sampler's
  # 396 rows, so the two were measuring the same thing the same way.
  [double]$ThresholdP50 = 7.25
)

$ErrorActionPreference = 'Continue'
$csv = Join-Path $DataDir 'dwm-growth.csv'
$err = Join-Path $DataDir 'dwm-growth-error.txt'

try {

Add-Type -TypeDefinition @'
using System;using System.Diagnostics;using System.Runtime.InteropServices;
public static class G {
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  [DllImport("user32.dll")] static extern uint GetGuiResources(IntPtr h, uint flags);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  // GDI / USER object counts -- a direct count of retained UI resources, much
  // cleaner than private bytes (which swing 4x on a healthy dwm all by
  // themselves and have no discriminating power).
  // Needs elevation; the scheduled task runs at RunLevel Highest so it reads
  // fine there, and returns [0,0] unelevated.
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

  // Returns [passes/sec, p50 ms, p90 ms].
  // DwmFlush blocks until the next composition pass and does NOT create
  // composition work, so timing its returns measures the pass rate for free.
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
if(-not $d){ throw 'dwm.exe not found' }
$dwmPid = [int]$d.ProcessId

function CpuSec { $q = Get-CimInstance Win32_Process -Filter "ProcessId=$dwmPid" -EA SilentlyContinue
                  if($q){ ([double]$q.KernelModeTime + [double]$q.UserModeTime)/1e7 } else { $null } }

# Per-thread cumulative CPU seconds, via .NET rather than
# Win32_PerfFormattedData_PerfProc_Thread. That WMI class enumerates every
# thread on the system and applies -Filter afterwards; it measured 15.2 core
# seconds per call. This version costs 0.6 core seconds and 0.0 s wall clock.
function ThreadCpu {
  $h = @{}
  try {
    foreach($t in [Diagnostics.Process]::GetProcessById($dwmPid).Threads){
      try { $h[[int]$t.Id] = $t.TotalProcessorTime.TotalSeconds } catch { }
    }
  } catch { }
  $h
}

# --- CPU rate: a quiet 10 s interval first, then measure pass rate separately -
$c0 = CpuSec; $th0 = ThreadCpu; $t0 = Get-Date
Start-Sleep -Seconds 10
$r  = try { [G]::Rate(120) } catch { @(0,0,0) }     # ~1 s burst of DwmFlush
$c1 = CpuSec; $th1 = ThreadCpu; $t1 = Get-Date
$el = ($t1-$t0).TotalSeconds
$cpuPct = if($c0 -ne $null -and $c1 -ne $null -and $el -gt 0){ ($c1-$c0)/$el*100 } else { $null }

# --- hottest thread (the compositor thread; its TID changes when dwm restarts,
#     so pick the maximum rather than hardcoding one) -------------------------
$hotTid = ''; $hotPct = ''
if($th1.Count -gt 0 -and $el -gt 0){
  # Do not use $d as the loop variable -- the outer $d is dwm's CIM object, and
  # shadowing it makes $d.CreationDate null further down.
  $best = $null
  foreach($id in $th1.Keys){
    if($th0.ContainsKey($id)){
      $delta = $th1[$id] - $th0[$id]
      if($null -eq $best -or $delta -gt $best.delta){ $best = @{ id=$id; delta=$delta } }
    }
  }
  if($best){ $hotTid = $best.id; $hotPct = [math]::Round($best.delta/$el*100,1) }
}

# --- GPU: wildcard query, avoiding the expensive -ListSet enumeration --------
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

# --- crude proxy for scene complexity ---------------------------------------
$w = try { [G]::Windows() } catch { @(0,0) }

# --- is a remote-desktop tool capturing the screen right now -----------------
$crd = [int][bool](Get-CimInstance Win32_Process -Filter "Name='remoting_desktop.exe'" -EA SilentlyContinue)

$osUp   = ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalHours
$dwmUp  = ((Get-Date) - $d.CreationDate).TotalHours
$passPs = $r[0]

# CPU milliseconds per composition pass -- the number this whole script exists
# to track.
$msPass    = if($cpuPct -and $passPs -gt 0){ [math]::Round($cpuPct/100*1000/$passPs, 3) } else { '' }
$msPassHot = if($hotPct -ne '' -and $passPs -gt 0){ [math]::Round([double]$hotPct/100*1000/$passPs, 3) } else { '' }

# Rounded exactly as it is written to CSV. The trap compares this sample against
# the previous row, which is already rounded; without this the two sides of the
# comparison would be on different scales.
$p50ms = [math]::Round($r[1], 2)

$gui = try { [G]::Gui($dwmPid) } catch { @(0,0) }

# New columns always go on the end, so existing rows (which have only 20) stay
# readable by positional index.
#
# top_windows / vis_windows count windows system-wide -- effectively "which
# apps are open" -- and have nothing to do with dwm's internal state. They were
# measured to have no discriminating power (healthy average 437.5 sits ABOVE
# the degraded 419) and are kept only so column order does not shift.
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
# The degradation trap.
#
# What actually happens is not "the user watches a graph". It is "the machine
# feels slow, they restart dwm, and the evidence is gone". So the capture has
# to fire before they react.
#
# Why several independent signals:
#
# The first version watched ms_per_pass_hot alone. Twenty-four hours of data
# then showed cost flat while retained resources climbed -- so if the next
# degradation grows somewhere else, a single-signal trap never fires and the
# whole instrument is wasted. Each signal has its own flag file, so one firing
# does not consume another's chance.
#
# private_mb is deliberately NOT a signal. It looks like a memory leak and
# behaves like noise: 256-1092 MB on a healthy process (4.27x, falling between
# adjacent samples 33% of the time) and it has already exceeded the 795 MB seen
# while degraded. Triggering on it would only waste capture opportunities.
#
# Every signal requires two consecutive samples over threshold, so a transient
# spike cannot fire them. See the param block for each threshold's calibration.
# ---------------------------------------------------------------------------

# Whether to arm the trap at all.
#
# An unelevated run still writes its row -- data is data -- but must never fire.
# dwm runs as DWM-1, so unelevated the hot thread reads 0, GetGuiResources gets
# no privileged handle, and dwm-autocapture.ps1 can take neither a full dump nor
# a trace. Since Fire() writes a flag that suppresses that signal for the rest
# of the pid's life, an unelevated fire costs the signal and returns no
# evidence, which is strictly worse than not firing.
$elevated = (New-Object Security.Principal.WindowsPrincipal(
              [Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# The previous row, for the same dwm PID, provides the "two consecutive" test.
#
# Walk back rather than taking [-2] unconditionally: an unelevated run writes a
# differently shaped row (hot_pct 0, ms_per_pass_hot empty), and one of those
# sitting in between makes the check read an empty value and skip a cycle in
# silence. Bounded at 5 so a long gap cannot pass off stale data as "previous".
$prevRow = $null
$allRows = @(Get-Content $csv | Select-Object -Skip 1)
for($k = 2; $k -le [math]::Min(6, $allRows.Count); $k++){
  $p = $allRows[-$k] -split ','
  if($p.Count -ge 16 -and $p[1] -eq "$dwmPid" -and $p[8] -and $p[11] -and $p[15]){
    $prevRow = $p; break
  }
}

function Fire($tag, $reason){
  # Unelevated: do not fire, and deliberately do not write the flag either --
  # leave the chance to the next elevated run. Recorded in the error file rather
  # than the trigger log, because the trigger log's existence is the artifact
  # that says the trap really fired and must not be polluted by skips.
  if(-not $elevated){
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [skipped-unelevated] $tag : $reason" |
      Out-File $err -Encoding utf8 -Append
    return
  }
  $flag = Join-Path $DataDir "dwm-captured-$dwmPid-$tag.flag"
  if(Test-Path $flag){ return }
  New-Item -ItemType File -Path $flag -Force | Out-Null
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$tag] $reason" |
    Out-File (Join-Path $DataDir 'dwm-growth-trigger.log') -Encoding utf8 -Append
  & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'dwm-autocapture.ps1') -Reason "[$tag] $reason"
}

# Signal 1: CPU cost per composition pass
if($msPassHot -ne '' -and [double]$msPassHot -gt $ThresholdCost -and $prevRow -and $prevRow[11]){
  if([double]$prevRow[11] -gt $ThresholdCost){
    Fire 'cost' "ms_per_pass_hot=$msPassHot prev=$($prevRow[11]) (threshold $ThresholdCost, degraded reference 8.7)"
  }
}

# Signal 2: retained kernel objects
if([int]$d.HandleCount -gt $ThresholdHandles -and $prevRow -and $prevRow[15]){
  if([int]$prevRow[15] -gt $ThresholdHandles){
    Fire 'handles' "handles=$($d.HandleCount) prev=$($prevRow[15]) (threshold $ThresholdHandles, degraded reference 2532)"
  }
}

# Signal 3: median composition interval leaving vsync
# $prevRow[8] is p50_ms. Positional, not by name -- inserting a column anywhere
# but the end silently makes this read something else, which is why $head says
# new columns go on the end.
if($p50ms -ne '' -and [double]$p50ms -gt $ThresholdP50 -and $prevRow -and $prevRow[8]){
  if([double]$prevRow[8] -gt $ThresholdP50){
    Fire 'p50' "p50_ms=$p50ms prev=$($prevRow[8]) (threshold $ThresholdP50, degraded reference 7.4-9.1)"
  }
}

} catch {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($_.Exception.GetType().Name): $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" |
    Out-File $err -Encoding utf8 -Append
}
