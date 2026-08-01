# Any sound costs ~9-17 core-seconds of CPU

**Status: MEASURED and reproducible on demand.** 2026-08-02.

Unlike the DWM investigation in this repo, this one does not need to wait for a
recurrence. It reproduces every time, with a clean silent control.

## Finding

On this machine, playing *any* audio wakes
`iGoSwServer.exe --apo --server=session_monitor` — Intelligo Technology's
"Audio SW Server/API library", version 100.1.4.2738, shipped as an audio
processing object (APO) in the driver store under
`igoaudioservice.inf_amd64_14e12b67b31695ac`.

It then burns roughly 85% of one core for about 20 seconds, regardless of how
short the sound was.

```
control (no sound at all)              0.0 core-seconds
Console::Beep, 90 ms                  16.9 core-seconds
SystemSounds.Asterisk (real WASAPI)    9.0 core-seconds
```

A 90 ms sound producing 16.9 core-seconds of CPU is a ratio of about 187:1.

### Decay profile after a single 90 ms beep

```
T+ 0s.. 3s    90.1%    cumulative  2.7 core-seconds
T+ 3s.. 6s    90.1%                5.4
T+ 6s.. 9s    75.5%                7.7
T+ 9s..12s    84.9%               10.2
T+12s..15s    80.2%               12.6
T+15s..18s    85.4%               15.2
T+18s..21s    53.6%               16.8
T+21s..24s     0.0%               16.8   <- stops abruptly
```

It does not taper. It runs flat out for ~18 seconds and then stops dead, which
looks more like a fixed-duration processing window than a workload that
finishes.

## Why this matters for "the machine feels slow sometimes"

Notification sounds are constant on a normal desktop — chat messages, calls,
mail, a video starting, an error ding. Each one buys ~20 seconds of a core.
Sounds arriving more often than every 20 seconds would keep it permanently
busy.

This is a plausible contributor to intermittent slowness, and it is worth
saying plainly what has and has not been shown:

- **[MEASURED]** Audio triggers ~9-17 core-seconds of CPU in this process.
- **[NOT SHOWN]** That this is what the user is actually experiencing as
  "slow". One core out of 16 is not obviously enough to be felt. Establishing
  the link needs slow episodes correlated against audio events, which is what
  the hotkey capture in this repo is for.

Note the lifetime average is only 0.4% of one core (1.57 hours of CPU over
354.8 hours of uptime). A snapshot of long-run averages would never surface
this. It is entirely a burst phenomenon.

## How it was found — the instrument caused it

Worth recording, because it nearly became a false finding.

`capture-slow-moment.ps1` originally beeped twice on startup to confirm the
hotkey had fired. In the first two captures, `iGoSwServer` appeared as the
**top CPU consumer** at 93.8% and 89.3% — above every real application.

That looked like a major discovery. It was an artifact: the capture script's
own confirmation beep woke the APO, inside the measurement window the script
had just opened.

Two things caught it before it was written up as a finding:

1. The lifetime average (0.4% of one core) flatly contradicted "burns 90%
   constantly". A process that really ran at 90% could not average 0.4%.
2. A sustained 20-second re-measurement showed 0.0%.

The A/B that settled it — silent control, beep, silent control — is three lines
and should have been the first move, not the last.

The startup beep has been removed. The completion beep is kept, because it
fires after all data is collected, and `-Silent` suppresses it.

## Reproducing

```powershell
$pid5916 = (Get-Process iGoSwServer | Sort-Object -Property Id | Select-Object -Last 1).Id
function Burst($label, $act) {
  $s = [Diagnostics.Process]::GetProcessById($pid5916).TotalProcessorTime.TotalSeconds
  & $act
  Start-Sleep -Seconds 24
  "{0,-34} {1,6:N1} core-seconds" -f $label,
    ([Diagnostics.Process]::GetProcessById($pid5916).TotalProcessorTime.TotalSeconds - $s)
}
Burst 'silent control' { }
Burst 'Console::Beep 90ms' { [Console]::Beep(1000,90) }
Burst 'SystemSounds.Asterisk' { [System.Media.SystemSounds]::Asterisk.Play() }
```

Let it settle back to 0% between runs, or the tail of one contaminates the
next — the same mistake, one level down.

## Open questions

1. Does it scale with sound length, or is ~20 seconds fixed regardless? The
   90 ms beep and the longer system sound gave 16.9 and 9.0 core-seconds, which
   is not a clean relationship and needs more points.
2. Two `iGoSwServer` instances run (pids 8884 and 5916 in this boot). Only the
   one launched with `--apo --server=session_monitor` burns CPU. Why two?
3. Is this specific to this Intelligo version, this ASUS model, or the APO
   framework generally? One machine, one version. Untested elsewhere.
4. Does disabling the ASUS AI noise-cancelling feature stop it? Not tested —
   that changes a user-facing setting and is the user's call, not a diagnostic
   step.
5. Already reported upstream? **Not searched yet.** Same prerequisite as the
   DWM finding: check before treating it as novel.
