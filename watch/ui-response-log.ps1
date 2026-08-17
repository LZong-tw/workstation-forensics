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
#
# MEMORY COLUMNS, added 2026-08-17. The CPU column existed from the start and
# for one day it discriminated well: stalling windows read cpu median 50.2
# against 21.5 for non-stalling ones. A day later that gap had collapsed to
# 51.6 against 46.7 while stalls continued, so CPU stopped explaining them and
# there was no second variable to reach for. Memory was the obvious candidate
# -- 90.1% used, 240 hard faults/sec reaching disk -- but nothing in this file
# could tie a specific stall window to a specific fault burst, which is exactly
# the evidence needed to avoid attributing by plausibility again.
#
# Three columns close that gap:
#   pgread_s  system-wide hard page reads/sec over the window (PDH). Hard
#             faults only -- Page Faults/sec is dominated by cheap soft faults
#             and would read in the tens of thousands while nothing was wrong.
#   availmb   physical memory available at window end (GetPerformanceInfo).
#   fgfault   page faults charged to the FOREGROUND process during the window.
#             This is the discriminating one: a system-wide rate says the
#             machine was faulting, but this says the process that failed to
#             pump messages was the one faulting. Empty when the foreground
#             process changed mid-window, and 'na' when its handle could not be
#             opened -- a failed query is not zero.
#
# Both rate columns bracket the window exactly as cpu_pct does, so all three
# describe the same interval and are directly comparable.
#
# Their cost, re-measured at the production 30 s window: 0.31% of one core and
# 93 MB -- indistinguishable from the 0.31% measured before they were added.
# At a 10 s window the same code costs 1.15%, because the two PDH collections
# are per-window and not per-probe; that difference is the reason the cost has
# to be quoted with the window size attached.

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

    [StructLayout(LayoutKind.Sequential)]
    public struct PerfInfo {
        public uint cb;
        public IntPtr CommitTotal, CommitLimit, CommitPeak;
        public IntPtr PhysicalTotal, PhysicalAvailable, SystemCache;
        public IntPtr KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        public uint HandleCount, ProcessCount, ThreadCount;
    }
    [DllImport("psapi.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetPerformanceInfo(out PerfInfo pPerformanceInformation, uint cb);

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcMemCounters {
        public uint cb;
        public uint PageFaultCount;
        public IntPtr PeakWorkingSetSize, WorkingSetSize;
        public IntPtr QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage;
        public IntPtr QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage;
        public IntPtr PagefileUsage, PeakPagefileUsage;
    }
    [DllImport("psapi.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetProcessMemoryInfo(IntPtr hProcess, out ProcMemCounters counters, uint cb);

    // PROCESS_QUERY_LIMITED_INFORMATION: enough for memory counters, and
    // obtainable without elevation for most processes.
    public const uint QUERY_LIMITED = 0x1000;
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint procId);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseHandle(IntPtr h);

    // PDH. The English-named entry point is required, not cosmetic: this
    // machine runs a zh-TW locale, where the localized counter registry would
    // reject the literal path "\Memory\Page Reads/sec".
    // Two marshalling details, both of which produced silent wrong behaviour
    // rather than an obvious failure:
    //
    // 1. szDataSource is IntPtr, not string, so IntPtr.Zero arrives as a real
    //    NULL ("query live data"). PowerShell marshals $null to an EMPTY STRING
    //    for a string parameter, which PDH reads as a log-file name and rejects
    //    with PDH_INVALID_ARGUMENT.
    // 2. CharSet.Unicode is REQUIRED on the W entry points that take a string.
    //    DllImport defaults to Ansi, so the counter path reached PdhAddEnglishCounterW
    //    as ANSI bytes reinterpreted as UTF-16 -- returning
    //    PDH_CSTATUS_BAD_COUNTERNAME, which reads exactly like "this machine's
    //    locale has no English counter names" and sent this down a long detour
    //    through index lookups and WMI raw classes.
    [DllImport("pdh.dll")] public static extern uint PdhOpenQueryW(IntPtr src, IntPtr userData, out IntPtr query);
    [DllImport("pdh.dll", CharSet=CharSet.Unicode)] public static extern uint PdhAddEnglishCounterW(IntPtr query, string path, IntPtr userData, out IntPtr counter);
    [DllImport("pdh.dll")] public static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] public static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint fmt, out uint type, out PdhValue value);
    [StructLayout(LayoutKind.Explicit)]
    public struct PdhValue {
        [FieldOffset(0)] public uint CStatus;
        [FieldOffset(8)] public double doubleValue;
    }
    public const uint PDH_FMT_DOUBLE = 0x00000200;
}
'@

$WM_NULL = 0
$SMTO_ABORTIFHUNG = 0x0002

$header = 'time,probes,hung,nofg,p50_ms,p90_ms,p99_ms,max_ms,fg_proc,fg_procs_seen,cpu_pct,pgread_s,availmb,fgfault'
if (-not (Test-Path $csv)) {
    $header | Out-File $csv -Encoding utf8
}
else {
    # Migrate an existing file in place rather than rotating it: the day-over-day
    # comparisons this data exists for need the history to stay in one series.
    # Import-Csv fills the new trailing columns with null for the older rows,
    # which is the correct representation -- those windows were never measured.
    $existing = Get-Content $csv -TotalCount 1
    if ($existing -and $existing -ne $header) {
        $all = Get-Content $csv
        $all[0] = $header
        Set-Content -Path $csv -Value $all -Encoding utf8
    }
}

# One PDH query for the process lifetime. Opening it per window would cost more
# than the measurement itself.
$pdhQuery = [IntPtr]::Zero
$pdhPageReads = [IntPtr]::Zero
$pdhOk = $false
if ([UiResp]::PdhOpenQueryW([IntPtr]::Zero, [IntPtr]::Zero, [ref]$pdhQuery) -eq 0) {
    if ([UiResp]::PdhAddEnglishCounterW($pdhQuery, '\Memory\Page Reads/sec', [IntPtr]::Zero, [ref]$pdhPageReads) -eq 0) {
        $pdhOk = $true
    }
}

function Get-PageReadsPerSec {
    # Rate counters need two collections; the value returned by the second
    # describes the interval between them, so callers bracket the window.
    if (-not $pdhOk) { return $null }
    $type = [uint32]0
    $val = New-Object 'UiResp+PdhValue'
    if ([UiResp]::PdhGetFormattedCounterValue($pdhPageReads, [UiResp]::PDH_FMT_DOUBLE, [ref]$type, [ref]$val) -ne 0) { return $null }
    return [math]::Round($val.doubleValue, 1)
}

function Get-AvailableMB {
    $pi = New-Object 'UiResp+PerfInfo'
    $pi.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($pi)
    if (-not [UiResp]::GetPerformanceInfo([ref]$pi, $pi.cb)) { return $null }
    return [math]::Round(([double]$pi.PhysicalAvailable.ToInt64() * $pi.PageSize.ToInt64()) / 1MB, 0)
}

function Get-ProcFaults([uint32]$procId) {
    # Returns $null when the process cannot be queried. A failed query is not
    # zero faults, and recording it as zero would silently invent healthy data.
    if ($procId -eq 0) { return $null }
    $h = [UiResp]::OpenProcess([UiResp]::QUERY_LIMITED, $false, $procId)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
        $c = New-Object 'UiResp+ProcMemCounters'
        $c.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($c)
        if (-not [UiResp]::GetProcessMemoryInfo($h, [ref]$c, $c.cb)) { return $null }
        return [int64]$c.PageFaultCount
    }
    finally { [void][UiResp]::CloseHandle($h) }
}

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
    if ($pdhOk) { [void][UiResp]::PdhCollectQueryData($pdhQuery) }
    # Baseline the foreground process's faults. If the foreground changes during
    # the window the delta is not attributable, so the pid is checked again at
    # the end and the column left empty on a mismatch.
    $fgPid0 = [uint32]0
    $hwnd0 = [UiResp]::GetForegroundWindow()
    if ($hwnd0 -ne [IntPtr]::Zero) { [void][UiResp]::GetWindowThreadProcessId($hwnd0, [ref]$fgPid0) }
    $fgFault0 = Get-ProcFaults $fgPid0

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

    if ($pdhOk) { [void][UiResp]::PdhCollectQueryData($pdhQuery) }
    $pgRead = Get-PageReadsPerSec
    $availMb = Get-AvailableMB

    $fgPid1 = [uint32]0
    $hwnd1 = [UiResp]::GetForegroundWindow()
    if ($hwnd1 -ne [IntPtr]::Zero) { [void][UiResp]::GetWindowThreadProcessId($hwnd1, [ref]$fgPid1) }
    $fgFault = ''
    if ($fgPid1 -ne 0 -and $fgPid1 -eq $fgPid0) {
        $fgFault1 = Get-ProcFaults $fgPid1
        if ($null -eq $fgFault0 -or $null -eq $fgFault1) {
            # Distinguished from an empty cell: the window was measured, the
            # process just could not be queried.
            $fgFault = 'na'
        }
        else {
            $d = $fgFault1 - $fgFault0
            # PageFaultCount is a 32-bit counter and does wrap on long-lived
            # processes; a negative delta is a wrap, not a negative fault rate.
            $fgFault = if ($d -ge 0) { $d } else { '' }
        }
    }

    $sorted = @($samples | Sort-Object)
    $top = ($procCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
    $fgProc = if ($top) { $top.Key } else { '-' }

    $row = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13}' -f @(
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $samples.Count, $hung, $nofg,
        (Get-Pct $sorted 0.50), (Get-Pct $sorted 0.90), (Get-Pct $sorted 0.99),
        $(if ($sorted.Count) { [math]::Round(($sorted[-1]), 3) } else { 0 }),
        $fgProc, $procCounts.Count, $cpuPct,
        $(if ($null -ne $pgRead) { $pgRead } else { 'na' }),
        $(if ($null -ne $availMb) { $availMb } else { 'na' }),
        $fgFault
    )
    # Appended per window rather than buffered: if this process dies, whatever
    # it already saw is still on disk.
    Add-Content -Path $csv -Value $row -Encoding utf8
}
