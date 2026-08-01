# Capture machine state at the moment it feels slow.
#
# Triggered by a global hotkey via a scheduled task at RunLevel Highest, so it
# never raises a UAC prompt.
#
# Speed is a design constraint: a slow episode can be brief, and a capture that
# takes a minute records the recovery instead of the problem. Two things keep
# it near 10 seconds:
#
#   1. Every performance counter is fetched in ONE Get-Counter call. Four
#      separate calls measured 8.32 s; the same counters combined measured
#      4.26 s, because each call pays its own PDH initialisation.
#   2. There is no dedicated sleep for the CPU delta. The first process
#      snapshot is taken up front, the counter work happens, and the second
#      snapshot closes the window -- so the delta is measured across work that
#      had to happen anyway. Elapsed time is read from a stopwatch rather than
#      assumed, because it varies.
#
# Read-only. Records state; changes nothing, kills nothing.
#
# Source is deliberately pure ASCII: PowerShell 5.1 reads BOM-less UTF-8 as
# ANSI, which turns non-ASCII comments into parser errors.

param(
  # Defaults to a folder beside the script, so it works wherever it is installed.
  [string]$OutRoot = (Join-Path $PSScriptRoot 'slow-capture'),
  [string]$Reason  = 'hotkey',
  [switch]$Silent          # suppress the completion beep entirely
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir   = Join-Path $OutRoot $stamp
New-Item -ItemType Directory -Path $dir -Force | Out-Null

# There is deliberately NO beep here, only at the end.
#
# The first version beeped twice on startup to confirm the hotkey fired. That
# beep contaminated the very measurement it was announcing: on this machine any
# audio session wakes Intelligo's audio APO (iGoSwServer.exe --apo
# --server=session_monitor), which then burns ~85% of a core for about 20
# seconds. Measured: 90 ms Console::Beep -> 16.9 core-seconds; a real WASAPI
# sound -> 9.0 core-seconds; silent control -> 0.0. See
# docs/audio-apo-cpu-burst.md.
#
# So the instrument was manufacturing a 90%-CPU process inside its own capture
# window, and it showed up as the top CPU consumer in the first two captures.
# The completion beep is kept because it fires after all data is collected --
# use -Silent to suppress it too.

$out = New-Object System.Collections.Generic.List[string]
function W($m){ $out.Add([string]$m) }

$swTotal = [Diagnostics.Stopwatch]::StartNew()

function Snap {
  $h = @{}
  foreach ($p in [Diagnostics.Process]::GetProcesses()) {
    try { $h[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch { }
  }
  $h
}

# --- open the CPU measurement window before doing anything expensive --------
$swDelta = [Diagnostics.Stopwatch]::StartNew()
$s0 = Snap

W "Slow-moment capture  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   reason: $Reason"
W "================================================================"

$os = Get-CimInstance Win32_OperatingSystem
W ""
W "-- Uptime --"
W ("  OS up {0:N2} h" -f ((Get-Date) - $os.LastBootUpTime).TotalHours)
# dwm.exe runs as DWM-1, so [Diagnostics.Process] returns AccessDenied for its
# StartTime. CIM returns CreationDate without needing those rights.
$dwm = Get-CimInstance Win32_Process -Filter "Name='dwm.exe'" | Select-Object -First 1
if ($dwm) { W ("  DWM up {0:N2} h  (pid {1})" -f ((Get-Date) - $dwm.CreationDate).TotalHours, $dwm.ProcessId) }

# --- one counter call for everything ---------------------------------------
$fixed = @(
  '\Processor Information(_Total)\% Processor Performance'
  '\Processor Information(_Total)\Processor Frequency'
  '\Processor Information(_Total)\% Processor Utility'
  '\Processor Information(_Total)\% Idle Time'
  '\Memory\Available MBytes'
  '\Memory\Committed Bytes'
  '\Memory\Commit Limit'
  '\Memory\Pages/sec'
  '\Memory\Page Faults/sec'
  '\Memory\Pages Input/sec'
  '\PhysicalDisk(_Total)\Current Disk Queue Length'
  '\PhysicalDisk(_Total)\% Idle Time'
  '\Paging File(_Total)\% Usage'
)
$wild = @(
  '\Processor Information(*)\Processor Frequency'
  '\GPU Engine(*)\Utilization Percentage'
  '\Process(*)\IO Data Bytes/sec'
)
# SilentlyContinue, not Stop: with a wildcard set this wide, one unavailable
# path under -Stop aborts the whole batch and every section below it goes
# blank. Partial results are worth more than an all-or-nothing read.
$cs = @()
try { $cs = (Get-Counter ($fixed + $wild) -ErrorAction SilentlyContinue).CounterSamples } catch { }

W ""
W "-- Counters --"
if ($cs.Count) {
  # Anything that is not a wildcard-expanded sample is one of the fixed paths.
  $fx = $cs | Where-Object {
    $_.Path -notmatch 'gpu engine' -and
    $_.Path -notmatch 'io data bytes' -and
    # -ne, not -notmatch: the group-total instance is named "0,_total" and a
    # substring match lets it through as a duplicate of the real total.
    -not ($_.Path -match 'processor information' -and $_.InstanceName -ne '_total')
  }
  foreach ($s in $fx) { W ("  {0,-46} {1,16:N2}" -f ($s.Path -replace '^\\\\[^\\]+\\',''), $s.CookedValue) }
  # % Processor Performance is what settles the throttling question: under 100
  # means the CPU is running below its rated clock.
  $perf = ($cs | Where-Object { $_.Path -match 'processor performance' } | Select-Object -First 1).CookedValue
  if ($null -ne $perf) {
    W ""
    if ($perf -lt 95) { W ("  >> THROTTLED: running at {0:N0}% of rated clock" -f $perf) }
    else              { W ("  >> not throttled ({0:N0}% of rated clock)" -f $perf) }
  }
} else { W "  counter read failed" }

# A single throttled core disappears into the _Total average.
W ""
W "-- Per-core frequency (MHz) --"
$pc = $cs | Where-Object { $_.Path -match 'processor information' -and $_.Path -match 'processor frequency' -and $_.InstanceName -notmatch '_total' }
if ($pc) { W ("  " + (($pc | ForEach-Object { [int]$_.CookedValue }) -join ' ')) } else { W "  unavailable" }

W ""
W "-- GPU engines over 1% --"
$g = $cs | Where-Object { $_.Path -match 'gpu engine' -and $_.CookedValue -gt 1 } |
     Sort-Object CookedValue -Descending | Select-Object -First 10
if ($g) { foreach ($e in $g) { W ("  {0,7:N1}%  {1}" -f $e.CookedValue, $e.InstanceName) } }
else    { W "  none above 1%" }

W ""
W "-- Busiest process I/O --"
$io = $cs | Where-Object { $_.Path -match 'io data bytes' -and $_.CookedValue -gt 100KB -and $_.InstanceName -notmatch '^(_total|idle)$' } |
      Sort-Object CookedValue -Descending | Select-Object -First 8
if ($io) { foreach ($e in $io) { W ("  {0,10:N0} KB/s  {1}" -f ($e.CookedValue/1KB), $e.InstanceName) } }
else     { W "  nothing above 100 KB/s" }

# --- dwm composition rate ---------------------------------------------------
# DwmFlush blocks until the next composition pass. Looping it measures the pass
# rate without creating composition work.
W ""
W "-- DWM composition --"
try {
  if (-not ('SM.Dwm' -as [type])) {
    Add-Type -Namespace SM -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmFlush();
'@ -ErrorAction Stop
  }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $t = @(); $last = 0.0
  while ($sw.Elapsed.TotalSeconds -lt 1.5) {
    [void][SM.Dwm]::DwmFlush()
    $n = $sw.Elapsed.TotalMilliseconds; $t += ($n - $last); $last = $n
  }
  $sw.Stop()
  if ($t.Count -gt 4) {
    $sorted = $t | Sort-Object
    W ("  passes/sec {0:N1}   p50 {1:N2} ms   p90 {2:N2} ms" -f `
        ($t.Count / ($last/1000)), $sorted[[int]($sorted.Count*0.5)], $sorted[[int]($sorted.Count*0.9)])
    W "  (healthy on this machine: ~144/s, p50 ~6.94 ms)"
  }
} catch { W "  DwmFlush unavailable: $($_.Exception.Message)" }

W ""
W "-- System/Application errors in the last 10 minutes --"
try {
  $ev = Get-WinEvent -FilterHashtable @{
          LogName=@('System','Application'); Level=@(1,2)
          StartTime=(Get-Date).AddMinutes(-10) } -MaxEvents 15 -ErrorAction Stop
  foreach ($e in $ev) {
    W ("  {0:HH:mm:ss} {1,-30} {2}" -f $e.TimeCreated, $e.ProviderName, (($e.Message -split "`n")[0]).Trim())
  }
} catch { W "  none" }

# --- close the CPU window ---------------------------------------------------
$s1 = Snap
$swDelta.Stop()
$el = $swDelta.Elapsed.TotalSeconds

$rows = New-Object System.Collections.Generic.List[object]
foreach ($id in $s1.Keys) {
  if (-not $s0.ContainsKey($id)) { continue }
  $d = $s1[$id] - $s0[$id]
  try { $p = [Diagnostics.Process]::GetProcessById($id) } catch { continue }
  $rows.Add([pscustomobject]@{
    Name    = $p.ProcessName
    ProcId  = $id
    CpuPct  = [math]::Round($d / $el * 100, 1)
    PrivMB  = [math]::Round($p.PrivateMemorySize64/1MB, 0)
    WsMB    = [math]::Round($p.WorkingSet64/1MB, 0)
    Handles = $p.HandleCount
    Threads = $p.Threads.Count
  })
}

W ""
W ("-- Processes (CPU measured over {0:N1} s) --" -f $el)
W ("  {0,-26} {1,-8} {2,8} {3,9} {4,9} {5,8} {6,6}" -f 'Name','Pid','CPU%','PrivMB','WsMB','Handles','Thr')
foreach ($r in ($rows | Sort-Object CpuPct -Descending | Select-Object -First 20)) {
  W ("  {0,-26} {1,-8} {2,8:N1} {3,9:N0} {4,9:N0} {5,8} {6,6}" -f `
      $r.Name,$r.ProcId,$r.CpuPct,$r.PrivMB,$r.WsMB,$r.Handles,$r.Threads)
}
W ""
W ("  Total across all processes: {0:N1}% of {1} logical cores" -f `
    (($rows | Measure-Object CpuPct -Sum).Sum), [Environment]::ProcessorCount)
W ""
W "  By private memory:"
foreach ($r in ($rows | Sort-Object PrivMB -Descending | Select-Object -First 10)) {
  W ("  {0,-26} {1,-8} priv {2,7:N0} MB   ws {3,7:N0} MB" -f $r.Name,$r.ProcId,$r.PrivMB,$r.WsMB)
}
$rows | Sort-Object CpuPct -Descending |
  Export-Csv (Join-Path $dir 'processes.csv') -NoTypeInformation -Encoding UTF8

$swTotal.Stop()
W ""
W ("-- Capture cost: {0:N1} s --" -f $swTotal.Elapsed.TotalSeconds)

($out -join "`r`n") | Out-File (Join-Path $dir 'summary.txt') -Encoding utf8
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Reason  ->  $dir" |
  Out-File "$env:USERPROFILE\Desktop\slow-captures.txt" -Encoding utf8 -Append

if (-not $Silent) { try { [Console]::Beep(600,350) } catch { } }
Write-Host "captured to $dir  ($([math]::Round($swTotal.Elapsed.TotalSeconds,1)) s)"
