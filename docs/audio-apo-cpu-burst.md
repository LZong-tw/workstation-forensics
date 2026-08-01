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

## Root cause [MEASURED]

The burning thread is not doing audio work. It is enumerating the process list
in a loop.

Stack from a full-memory dump taken 2.5 s into a burst, symbolized with
`cdb -z` (the process runs as the logged-in user, so no elevation and no live
attach were needed):

```
1  Id: 171c.3748          <- tid 14152, the thread measured at 89.5%
  kernel32!Process32NextW+0x80
  iGoSwServer+0x7d9f6
  iGoSwServer+0x80c19
  iGoSwServer+0x7dcc8
  iGoSwServer+0x6cbd2
  ucrtbase!thread_start<...>
  kernel32!BaseThreadInitThunk+0x17
  ntdll!RtlUserThreadStart+0x2c
```

`Process32NextW` is Toolhelp32 process enumeration. The `--server=session_monitor`
thread appears to poll the full process list to work out which application
started playing audio, rather than subscribing to an audio session
notification.

The arithmetic closes:

```
processes running                     502
one Toolhelp32 snapshot            15.42 ms   (measured, 196 iterations)
burst cost                          16.9 core-seconds
  -> enumerations per burst        ~1,096
  -> over the ~18 s burst             ~61 per second
  -> 61 x 15.42 ms                    94% of one core
measured                             85-90% of one core
```

This also explains the two things that did not fit:

- **89% kernel / 11% user time.** Process enumeration is a kernel operation.
  Real DSP would be user-mode SIMD math.
- **Turning ASUS AI noise cancelling off changes nothing.** Both "AI 降噪麥克風"
  and "AI ClearVoice - 喇叭" were already disabled on this machine throughout
  every measurement above. The polling is unconditional; it is not the feature
  doing work.

### The cost scales with how many processes you run

15.42 ms per snapshot is a function of having 502 processes. The relationship is
linear, so a machine with ~100 processes would pay roughly a fifth of this —
about 18% of a core instead of 94%.

That makes the severity here partly self-inflicted: the same defect is mild on a
lightly loaded machine and severe on this one. It also gives a cheap mitigation
that does not involve touching audio settings at all — fewer background
processes.

## Prior art — what was already known, and what is new here

`iGoSwServer.exe` is already a known-problematic process. It appears in
crash-and-freeze reports, and general "what is this process" pages describe it
as Intelligo's audio enhancement service shipped preinstalled by OEMs.

Most on-point is a Dell Alienware m16 R1 thread reporting *"intermittent
stuttering during any task"* — the same symptom shape as this machine. In it,
one user notes `iGoSwServer.exe` appearing in reliability logs. But it is
**mentioned, not established**: the thread contains no CPU measurements, no
stacks, and no mechanism, the discussion moves on to fTPM, Dell SupportAssist
and a failing chipset fan, and it remains marked unsolved.

The advice that circulates is to uninstall Intelligo Audio Enhancement or
disable the Intelligo Audio Service in Device Manager. That is a workaround
aimed at a process, not an explanation.

**What is new here** is the mechanism and its cost model:

- the trigger is *any* audio session, not a specific application;
- the burning thread is in `Process32NextW`, polling the whole process list
  ~60 times a second for ~18 seconds;
- the cost is therefore linear in the number of running processes, which is why
  the same defect is mild on some machines and severe on others;
- and it happens with both ASUS AI audio features switched **off**, so it is not
  the enhancement doing work.

Not found anywhere: a report tying the CPU burn to process enumeration, or to
audio events as the trigger.

## Open questions

1. Does it scale with sound length, or is ~20 seconds fixed regardless? The
   90 ms beep and the longer system sound gave 16.9 and 9.0 core-seconds, which
   is not a clean relationship and needs more points.
2. Two `iGoSwServer` instances run (pids 8884 and 5916 in this boot). Only the
   one launched with `--apo --server=session_monitor` burns CPU. Why two?
3. Is this specific to this Intelligo version, this ASUS model, or the APO
   framework generally? One machine, one version. Untested elsewhere.
4. ~~Does disabling the ASUS AI noise-cancelling feature stop it?~~
   **Answered: no.** Both AI features were already off for every measurement
   here. This was originally suggested as a mitigation; that suggestion was
   wrong, and the fact that it does not help is what pointed at an
   unconditional polling loop rather than feature work.
5. Already reported upstream? **Not searched yet.** Same prerequisite as the
   DWM finding: check before treating it as novel.
6. Why poll at all? Windows provides audio session notifications
   (`IAudioSessionNotification`). Whether the polling is a fallback path or the
   only implementation is not known from a single stack.
