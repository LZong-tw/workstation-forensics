# Successor to load-attrib-log.ps1. That sampler logged busy_cores and
# accounted_cores, and the gap between them turned out to grow with load:
# 90% coverage below 30% machine load, 40% at 73.5%. The attribution is worst
# exactly where it matters, so the top-process ranking during an episode cannot
# be read at face value.
#
# Two candidates were tested at moderate load. Process churn is NOT it: crediting
# processes born inside the interval moved coverage by under 0.02 cores with only
# 0-1 births per interval. The process subsystem's own _Total instance came to
# 14.8-15.5 of 16 cores, so roughly one core is unaccounted by the subsystem
# itself, of which DPC+ISR is 0.40. None of that explains a 7-core gap.
#
# So this version stops guessing and records the discriminators, to be read from
# a HIGH-LOAD sample rather than reconstructed afterwards:
#   proc_total  the process subsystem's own _Total, Idle included -- should be 16
#   idle_proc   Idle as the process subsystem sees it -- cross-checks the CPU counter
#   dpc, isr    kernel time charged to no process
#   n_new/n_gone  process churn inside the interval, and new processes ARE credited
#   n_proc      how many processes were enumerated at all
#   enum_ms     how long the enumeration took; a slow enumeration under load would
#               skew every per-process rate and is the remaining untested candidate
#
# Read-only: counter reads only. Nothing here signals, suspends or reconfigures
# any process.

param(
    [int]$IntervalSec = 15,
    [int]$TopN = 6,
    [string]$Out = 'C:\Users\LZong\Scripts\load-attrib2.csv'
)

$ErrorActionPreference = 'Continue'

$header = 'time,machine_pct,busy_cores,acct_cores,proc_total,idle_proc,dpc,isr,n_new,n_gone,n_proc,enum_ms,' +
          'top1,top1_pct,top2,top2_pct,top3,top3_pct,top4,top4_pct,top5,top5_pct,top6,top6_pct'
if (-not (Test-Path $Out)) { Set-Content -Path $Out -Value $header -Encoding utf8 }
Add-Content $Out ("# start {0}  interval {1}s" -f (Get-Date -f s), $IntervalSec)

function SnapP {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $h = @{}; $tot = $null
    foreach ($p in Get-CimInstance Win32_PerfRawData_PerfProc_Process -ErrorAction SilentlyContinue) {
        if ($p.Name -eq '_Total') { $tot = $p; continue }
        $h[[string]$p.IDProcess] = @{ n = $p.Name; c = [double]$p.PercentProcessorTime; t = [double]$p.Timestamp_Sys100NS }
    }
    $sw.Stop()
    return @{ procs = $h; total = $tot; ms = $sw.ElapsedMilliseconds }
}

$a = SnapP
$aT = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"

while ($true) {
    Start-Sleep -Seconds $IntervalSec
    $b = SnapP
    $bT = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"
    if (-not $bT -or -not $aT) { $aT = $bT; $a = $b; continue }

    $dtM = [double]$bT.Timestamp_Sys100NS - [double]$aT.Timestamp_Sys100NS
    if ($dtM -le 0) { $a = $b; $aT = $bT; continue }

    $machine = 100 - 100 * ([double]$bT.PercentIdleTime - [double]$aT.PercentIdleTime) / $dtM
    $dpc = 16 * ([double]$bT.PercentDPCTime - [double]$aT.PercentDPCTime) / $dtM
    $isr = 16 * ([double]$bT.PercentInterruptTime - [double]$aT.PercentInterruptTime) / $dtM

    $rows = New-Object System.Collections.ArrayList
    $nNew = 0; $nGone = 0; $idleP = 0.0
    foreach ($k in $b.procs.Keys) {
        $y = $b.procs[$k]
        if ($a.procs.ContainsKey($k)) {
            $x = $a.procs[$k]; $dt = $y.t - $x.t
            if ($dt -le 0) { continue }
            $v = 100 * ($y.c - $x.c) / $dt
        } else {
            # Born inside the interval: its counter is cumulative since start, so
            # charge it against the interval and cap at one machine's worth.
            $nNew++
            $v = 100 * $y.c / $dtM
            if ($v -gt 1600) { $v = 1600 }
        }
        if ($y.n -eq 'Idle') { $idleP += $v / 100; continue }
        [void]$rows.Add([PSCustomObject]@{ n = "$($y.n)($k)"; pct = $v })
    }
    foreach ($k in $a.procs.Keys) { if (-not $b.procs.ContainsKey($k)) { $nGone++ } }

    $dtT = [double]$b.total.Timestamp_Sys100NS - [double]$a.total.Timestamp_Sys100NS
    $ptot = if ($dtT -gt 0) { ([double]$b.total.PercentProcessorTime - [double]$a.total.PercentProcessorTime) / $dtT } else { -1 }

    $top = @($rows | Sort-Object pct -Descending | Select-Object -First $TopN)
    $acct = ($rows | Measure-Object pct -Sum).Sum / 100

    $cells = @()
    for ($i = 0; $i -lt $TopN; $i++) {
        if ($i -lt $top.Count) { $cells += $top[$i].n; $cells += ('{0:F1}' -f $top[$i].pct) }
        else { $cells += ''; $cells += '' }
    }
    Add-Content $Out (('{0},{1:F1},{2:F2},{3:F2},{4:F2},{5:F2},{6:F2},{7:F2},{8},{9},{10},{11},' -f `
        (Get-Date -f 'yyyy-MM-dd HH:mm:ss'), $machine, ($machine * 16 / 100), $acct, $ptot, $idleP, $dpc, $isr, `
        $nNew, $nGone, $b.procs.Count, $b.ms) + ($cells -join ','))

    $a = $b; $aT = $bT
}
