# Continuous logger for foreground-UI responsiveness.
#
# WHY A LOGGER AND NOT A TRAP. The DWM watcher can fire automatically because
# an ad-hoc capture in 2026-07 first established what degradation looks like
# (composition rate 144 -> 45/s, p50 leaving its vsync-pinned 6.94 ms), and a
# threshold could then be placed between that known-degraded value and a known
# healthy distribution. For "typing feels slow" neither end exists yet: the
# symptom has never once been measured while happening, so there is nothing to
# calibrate against. A logger needs no threshold, so it cannot false-fire and
# cannot disarm itself -- and the DWM investigation's own history shows the
# logger has to come first anyway (545 rows of sampling are what overturned
# its "gradual degradation" framing).
#
# WHAT IT MEASURES. SendMessageTimeout(WM_NULL) to the foreground window,
# round-trip. WM_NULL performs no operation -- this is the documented way to
# ask whether a window's thread is pumping messages, and it is what underlies
# Windows' own "Not Responding" detection. A blocked or slow message pump is
# the most common mechanism behind "typing feels laggy", so this is the
# cheapest proxy that is plausibly on the causal path.
#
# It is a PROXY, not the thing itself. It does not measure keystroke-to-pixel
# latency, and a stall it does not see is not proof that nothing stalled. Read
# any conclusion from this data with that limit attached.
#
# COST, measured on this machine before committing to running it (per this
# investigation's rule that instruments must not perturb what they measure):
# at 500 ms probe interval the loop costs 0.31% of one core and ~82 MB working
# set. Probe latency while healthy: p50 0.305 ms, p90 0.923 ms, p99 7.369 ms,
# max 19.284 ms over 118 probes.
#
# NOTE THE TAIL. p50 is sub-millisecond but the healthy p99 is already 7 ms and
# the max 19 ms. Any future threshold must be calibrated against that tail, not
# against the median -- judging by the median while ignoring the tail is
# exactly how this investigation's first DWM threshold ended up sitting inside
# the healthy distribution.
#
# Output: one summary row per window to ui-response.csv. Individual probes are
# not logged; percentiles of the window are, which keeps the file small enough
# to run indefinitely (~2 rows/min, roughly 350 KB/day).

param(
    [string]$DataDir = $PSScriptRoot,
    [int]$IntervalMs = 500,       # probe spacing
    [int]$WindowSeconds = 30,     # one CSV row per window
    [int]$TimeoutMs = 1000,       # SendMessageTimeout budget; also caps how long one probe can block us
    [int]$RunMinutes = 0          # 0 = run until stopped
)

$ErrorActionPreference = 'Continue'
$csv = Join-Path $DataDir 'ui-response.csv'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UiResp {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg,
        UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemTimes(out long lpIdleTime, out long lpKernelTime, out long lpUserTime);
}
'@

$WM_NULL = 0
$SMTO_ABORTIFHUNG = 0x0002

$header = 'time,probes,hung,nofg,p50_ms,p90_ms,p99_ms,max_ms,fg_proc,fg_procs_seen,cpu_pct'
if (-not (Test-Path $csv)) { $header | Out-File $csv -Encoding utf8 }

# pid -> process name, so a probe does not pay for Get-Process every time
$nameCache = @{}
function Get-ProcName([uint32]$procId) {
    if ($nameCache.ContainsKey($procId)) { return $nameCache[$procId] }
    $n = try { (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { 'unknown' }
    # Bound the cache: pids are reused and a long-running logger would otherwise
    # accumulate one entry per process ever seen.
    if ($nameCache.Count -gt 512) { $nameCache.Clear() }
    $nameCache[$procId] = $n
    return $n
}

function Get-CpuBusy {
    $idle = 0L; $kern = 0L; $user = 0L
    [void][UiResp]::GetSystemTimes([ref]$idle, [ref]$kern, [ref]$user)
    # Kernel time includes idle time, so total is kernel + user.
    return @{ Idle = $idle; Total = $kern + $user }
}

function Get-Pct($sorted, [double]$p) {
    if ($sorted.Count -eq 0) { return 0 }
    $i = [math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * $p))
    return [math]::Round($sorted[$i], 3)
}

$probeSw = New-Object System.Diagnostics.Stopwatch
$overall = [System.Diagnostics.Stopwatch]::StartNew()

while ($true) {
    if ($RunMinutes -gt 0 -and $overall.Elapsed.TotalMinutes -ge $RunMinutes) { break }

    $winSw = [System.Diagnostics.Stopwatch]::StartNew()
    $samples = New-Object System.Collections.Generic.List[double]
    $procCounts = @{}
    $hung = 0
    $nofg = 0
    $cpu0 = Get-CpuBusy

    while ($winSw.Elapsed.TotalSeconds -lt $WindowSeconds) {
        try {
            $hwnd = [UiResp]::GetForegroundWindow()
            if ($hwnd -eq [IntPtr]::Zero) {
                # No foreground window: locked screen, secure desktop, or a
                # transition. Counted rather than silently skipped -- a window
                # made up mostly of these is not evidence of responsiveness.
                $nofg++
            }
            else {
                $procId = [uint32]0
                [void][UiResp]::GetWindowThreadProcessId($hwnd, [ref]$procId)
                $pname = Get-ProcName $procId
                if ($procCounts.ContainsKey($pname)) { $procCounts[$pname]++ } else { $procCounts[$pname] = 1 }

                $res = [UIntPtr]::Zero
                $probeSw.Restart()
                $r = [UiResp]::SendMessageTimeout($hwnd, $WM_NULL, [UIntPtr]::Zero,
                    [IntPtr]::Zero, $SMTO_ABORTIFHUNG, $TimeoutMs, [ref]$res)
                $probeSw.Stop()
                $samples.Add($probeSw.Elapsed.TotalMilliseconds)
                # Zero return with ABORTIFHUNG means the window was already
                # flagged as not responding -- recorded separately because it
                # returns fast and would otherwise look like a healthy probe.
                if ($r -eq [IntPtr]::Zero) { $hung++ }
            }
        }
        catch {
            # Never let one bad probe end a run that is meant to last for days.
            $nofg++
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
    $winSw.Stop()

    $cpu1 = Get-CpuBusy
    $dTotal = $cpu1.Total - $cpu0.Total
    $dIdle = $cpu1.Idle - $cpu0.Idle
    $cpuPct = if ($dTotal -gt 0) { [math]::Round(100.0 * ($dTotal - $dIdle) / $dTotal, 1) } else { 0 }

    $sorted = @($samples | Sort-Object)
    $top = ($procCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $fgProc = if ($top) { $top.Key } else { '-' }

    $row = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f @(
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $samples.Count, $hung, $nofg,
        (Get-Pct $sorted 0.50), (Get-Pct $sorted 0.90), (Get-Pct $sorted 0.99),
        $(if ($sorted.Count) { [math]::Round(($sorted[-1]), 3) } else { 0 }),
        $fgProc, $procCounts.Count, $cpuPct
    )
    # Appended per window rather than buffered: if this process dies, whatever
    # it already saw is still on disk.
    Add-Content -Path $csv -Value $row -Encoding utf8
}
