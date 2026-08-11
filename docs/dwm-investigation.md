# DWM gradual degradation — investigation log

**Status: OPEN.** Started 2026-07-31. Last updated 2026-08-08.

The trap has not fired. A second boot cycle is 6.6 days in with no sign of
degradation — the median composition interval is still locked on vsync. The
trap's thresholds were recalibrated on 2026-08-08 against 396 samples after the
original `ms_per_pass_hot` threshold turned out to sit inside the healthy
distribution; see [Recalibrating the trap](#recalibrating-the-trap-2026-08-08-measured).

Confidence markers are used throughout and mean what they say:

- **[MEASURED]** — observed directly, numbers reproduced below.
- **[INFERRED]** — follows from measurements but not independently confirmed.
- **[ASSUMPTION]** — currently unverified. Do not build on these.
- **[RETRACTED]** — previously claimed here, since disproved. Kept on purpose.

---

## Symptom

On this machine (ASUS ExpertBook B5405CCA, Windows 11 build 26200, Intel Arc
140T, 16 logical cores, 31.25 GB RAM), `dwm.exe` gets progressively worse over
a period of days. The desktop grows sluggish — window drags, animations, and
compositor-driven UI stutter — while no single application is obviously at
fault.

Restarting `dwm.exe` restores full performance instantly. That is also why the
problem has no public paper trail: the fix is trivial, so nobody keeps the
broken state around long enough to look at it.

## The healthy / degraded signature [MEASURED]

Captured 2026-07-31. The degraded column is the state immediately before
restarting `dwm.exe`; the healthy column is the same machine minutes later, and
is corroborated by 71 subsequent samples (see below).

| | degraded | healthy |
|---|---|---|
| dwm CPU | 128–138% | 25–32% |
| dwm GPU | frequently exactly 0.000% | 1.1–5.6%, stable |
| composition passes/sec | 45–109, erratic | **144.0–144.1, locked** |
| p50 pass interval | 7.4–9.1 ms | **6.94 ms** |
| CPU per pass | ~9 ms | ~2 ms |
| handles | 2532 | 1623 at restart |

6.944 ms is exactly 1/144 Hz, the panel refresh rate. Healthy DWM sits on the
clock; degraded DWM cannot keep up and the interval becomes noise.

The GPU reading is the interesting one. A compositor that is slow *because it
is doing more drawing* would show GPU going **up**. It went to zero. Whatever
degraded DWM is spending its time on is not rendering.

## Root cause candidate [INFERRED]

Stacks from the degraded process point at:

```
dwmcore!CComposition::CleanTrees
  <- CComposition::PreRender
  <- CComposition::ProcessComposition
  <- MainCompositionThreadLoop
  <- CConnection::RunCompositionThread
```

The healthy control taken during a rehearsal capture shows the same thread
blocked in `CMonitorClock::WaitForNextTick` instead — waiting on the frame
clock, not walking a tree.

`CleanTrees` walks the composition tree once per frame before any GPU work.
A tree that accumulates entries would make this cost grow over time while GPU
work stays flat, which matches the signature above.

**Why this is [INFERRED] and not [MEASURED]:** it rests on *one* degraded
observation and *one* healthy control. A single stack sample proves where the
thread was at that instant, not where it spends its time. Confirming this needs
a second degraded capture with sampled stacks, which is what the watcher exists
to produce, and which **has not happened yet**.

## What the watcher does

Two scripts, driven by a scheduled task every 30 minutes:

**`dwm-growth-sample.ps1`** — one-shot sampler. Records 22 columns to CSV:
composition pass rate and percentiles, per-thread CPU, handles, threads,
private bytes, GPU local memory, GPU percent, window counts.

Pass rate is measured by calling `DwmFlush()` in a loop and timing the returns.
`DwmFlush()` blocks until the next composition pass; it does **not** create
composition work. Measuring the pass rate therefore costs essentially nothing
beyond the wait itself.

**`dwm-autocapture.ps1`** — fires when the sampler decides DWM has degraded.
Writes a full-memory dump, symbolized stacks via `cdb -z`, a 30-second WPR ETL,
and a note on the desktop. Runs in ~180 s.

### The design constraint that shaped this

The obvious approach — sample continuously, look at the graph — does not work,
because the user does not watch a graph. They notice the machine is slow, they
restart `dwm.exe`, and the evidence is gone. That has already happened once.

So the trap has to fire **by itself**, before the human reacts. It runs from a
scheduled task at `RunLevel Highest`, which does not raise a UAC prompt — one
elevation buys permanent silent capture, including while the screen is off or
the session is remote. The action is launched through a dedicated
`task-dwm-growth-sample.vbs` (`WScript.Shell.Run` style 0) so the half-hourly
sample does not flash a PowerShell console; `-WindowStyle Hidden` alone is not
enough for Interactive tasks, and multi-arg `wscript` lines get mangled by the
scheduler.

### Trigger signals

Four independent signals, each requiring **two consecutive** samples over
threshold so a transient spike cannot fire it:

| signal | threshold | degraded reference | healthy max | n |
|---|---|---|---|---|
| `p90_ms` | 14 | 16 of 51 samples above | **13.74** | 401 |
| `p50_ms` | 7.25 | 7.4–9.1 | 7.18 | 396 |
| `ms_per_pass_hot` | 6.0 | 8.7 | 4.712 | 396 |
| `handles` | 2400 | 2532 | 1955 | 396 |

Recalibrated 2026-08-08 against 396 samples; the original figures were set from
71. See [Recalibrating the trap](#recalibrating-the-trap-2026-08-08-measured)
below for why the first `ms_per_pass_hot` threshold was inside the healthy
distribution.

`p90_ms` was added 2026-08-11 and now carries the trap, demoting `p50_ms` to a
backstop. **`p50_ms` is a lagging indicator**: on the 2026-08-10 cycle,
composition throughput had already fallen from its vsync-pinned 144/s to 136/s
by 09:10, but `p50_ms` did not cross 7.25 until 06:10 the next morning — 21
hours later. Both captures it produced were taken a day after onset.

While healthy, `p90` equals `p50` equals 6.94: every frame lands on exactly one
vsync interval, so `p90` rising at all means frames are being dropped. Over 401
healthy samples it reached at most 13.74; a threshold of 14 is hit by none of
them, so it sits outside the healthy distribution rather than being rescued by
the two-consecutive rule. Backtested first fire is 14.5 hours earlier than the
signal that actually fired.

`pass_per_s` was **rejected** as a trigger despite looking like the cleanest
signal of all — it is pinned to exactly 144.0 while healthy. Its tail is not
clean: healthy samples reach down to 118.5, with p1 at 134.1, so "below 138,
twice consecutively" would have false-fired on 2026-08-04. Judging a threshold
by the median while ignoring the tail is precisely how `ms_per_pass_hot` came to
be 4.0. A combined `pass < 138 AND p90 > 12` was also tested and rejected: 3 of
401 healthy samples match it, and those 3 are exactly the healthy `p90` maxima,
so the `pass` term filters out nothing.

`private_mb` was **deliberately excluded** as a signal. It looks like a memory
leak and behaves like noise: over 71 healthy samples it ranges 256–1092 MB
(4.27x), falls between adjacent samples 32.9% of the time, and has already
exceeded the 795 MB recorded in the degraded state — while nothing is wrong.
`handles` was chosen instead for monotonicity: range 1.13x, falls 22.9% of the
time.

## Current data [MEASURED]

71 samples, 2026-07-31 16:42 → 2026-08-01 23:59, DWM uptime 0.69 h → 31.97 h.

```
                 min       max       avg       range
cpu_pct          2.80     44.90     21.33     16.04x
pass_per_s     138.30    144.40    143.84      1.04x
p50_ms           6.65      7.00      6.92      1.05x
ms_per_pass_hot  0.10      2.77      1.13     26.67x
handles          1623      1840      1725      1.13x
private_mb        256      1092       538      4.27x
threads            20        21     20.62      1.05x
```

Handle count against DWM uptime:

```
  0.69 h -> 1623
  9.43 h -> 1700
 20.93 h -> 1758
 31.97 h -> 1840
```

`pass_per_s` holding 143.84 average with 1.04x total range across 31 hours is
the strongest evidence that the healthy state is genuinely stable, and that the
degraded 45–109 reading was not measurement error.

### A problem with the handle threshold [ASSUMPTION]

Handles grew +217 in 31.3 h, about **+6.9/hour**. Extrapolated linearly, 2400
would be reached ~81 hours from the last sample — roughly 2026-08-05, well
before the 13-day mark.

But the degraded reference was 2532 at 13 d 9 h uptime. Linear growth from 1623
would predict roughly 3800 by then. It did not get there.

So growth is **sublinear** — it slows down. Which raises a risk this document
should state plainly rather than discover later: **if the curve saturates below
2400, the handle signal never fires.** The 2400 threshold was set from a single
degraded endpoint without knowing the shape of the curve leading to it.

Mitigation is that `ms_per_pass_hot` is an independent signal measuring the
actual symptom rather than a proxy. If handles saturate, that one should still
catch it. This is the reason there are two signals and not one.

**Update 2026-08-08 [MEASURED].** Both halves of that turned out to be wrong,
in opposite directions, and the mitigation was wrong too.

Over a full 158 h cycle handles ran 1447 → 1955, about **+3.0/hour** — not the
+6.9/hour measured over the first 31 h, but not saturating either. Projected,
the baseline crosses 2400 near day 13.8, against degradation observed on day
13.4. The signal does not fail to fire; it fires *level with or later than* the
event it is supposed to pre-empt. And because the rule needs two consecutive
samples, what has to cross is the baseline, not a peak — handles swing about
±300 within a single day.

The mitigation sentence was the real error: `ms_per_pass_hot` is **not** an
independent measurement of the symptom. See below.

## Recalibrating the trap (2026-08-08) [MEASURED]

### `ms_per_pass_hot` was measuring workload, not degradation

```
ms_per_pass_hot = hot_pct / 100 * 1000 / pass_per_s
```

While the composition rate is pinned to vsync at ~144, that is just
`hot_pct / 1.44`. It is a rescaling of "how busy is the compositor thread",
carrying no information the CPU column does not already have. The apparent
tenfold growth in `ms_per_pass` across the cycle was `cpu_pct` moving 4.26 →
43.49 between 12-hour buckets — and it moved back to 10.67 in the next bucket.
That is what the user was doing, not what dwm was becoming.

### The threshold sat inside the healthy distribution

`ms_per_pass_hot > 4.0` was calibrated when the healthy spread was 0.10–2.77
over 54 samples. At 320 samples the healthy maximum is **4.712**, and eight
samples had already crossed 4.0 — every one of them at `pass_per_s` of 137–144,
which is a healthy composition rate.

Nothing false-fired only because no two of those eight were adjacent. That is
luck, not debounce, and the stake is higher than one wasted capture: `Fire()`
writes `dwm-captured-<pid>-<tag>.flag` and returns early for the rest of that
pid's life, so **one false fire on day 7 disarms the signal for a cycle that
degrades on day 13**.

Raised to 6.0, which sits between the healthy maximum 4.712 and the degraded
8.7, and which — while the rate is pinned — also means the hot thread is above
86%, independently abnormal.

### `p50_ms` is the signal that survives the objection

| | healthy (n=396) | degraded |
|---|---|---|
| `p50_ms` | median 6.93, p95 7.00, p99 7.12, **max 7.18**, none above 7.20 | 7.4–9.1 |

Those 396 samples span dwm CPU from 4% to 67%. The median pass interval stays
locked on 1/144 Hz = 6.944 ms regardless, because it is a robust statistic: it
moves only when the whole distribution stretches, which is exactly what
degradation does and what a busy compositor does not. Threshold 7.25 sits in
the gap. It uses column 8, already present, so no schema change was needed —
which matters, because the debounce reads `$prevRow[11]` and `$prevRow[15]` by
position and any inserted column would silently repoint them.

**Provenance, since it decides whether that gap is real:** the degraded 7.4–9.1
never entered the CSV; it came from the ad-hoc 07-31 session. But the healthy
control from that same session read 6.94, against 6.93 across the sampler's 396
rows — the two were measuring the same thing the same way.

### An unelevated run could burn a signal and capture nothing

Independent of any threshold. Run unelevated, the sampler still reaches the
trap, and `Fire()` still writes the flag — but `dwm-autocapture.ps1` can take
neither a full dump nor a trace without elevation. The result is the signal
consumed and no evidence, which is strictly worse than not firing.

The trap is now skipped entirely when not elevated, and deliberately writes no
flag, leaving the chance to the next scheduled (elevated) run. It is recorded
in `dwm-growth-error.txt` rather than `dwm-growth-trigger.log`, because the
trigger log's existence is the artifact that says the trap really fired.

Relatedly, `$prevRow` now walks back to the most recent *complete* row for the
same pid instead of taking `[-2]` unconditionally. An unelevated sample writes a
differently shaped row — `hot_pct` 0, `ms_per_pass_hot` empty — and one of those
in between made the check read an empty value and skip a cycle in silence.

### Verification

Replaying all 398 stored rows through the new thresholds produces **zero** false
fires on all three signals, and feeding the degraded reference values (7.4 /
8.7 / 2532) fires all three. Both trap branches were then exercised end to end
in an isolated `-DataDir`: unelevated skips without writing a flag, forced-
elevated writes the flag, appends to the trigger log, and invokes autocapture.

One caveat on the data set: the row stamped `2026-08-08 16:40:45` is an
instrument artifact, not an observation — an unelevated verification run, and
the only row of the 399 with `hot_pct` 0 and `ms_per_pass_hot` empty. It was
left in place rather than quietly edited out, and analysis should exclude it.
That row is also what exposed the `$prevRow` problem above.

## Timeline correlation [INFERRED]

The machine booted 2026-07-18 06:08. DWM uptime at the point of degradation was
recorded as 13 d 9 h, and it was restarted 2026-07-31 16:00. That places DWM
start at roughly 07-18 07:00, about 50 minutes after boot.

That is **consistent with** DWM having been alive since first interactive
logon, and not with a mid-cycle restart. It is not proof — the 13 d 9 h figure
was read at the time and cannot be re-verified now that the process is gone.

## Retracted claims

Kept deliberately. Every one of these was stated with more confidence than the
evidence supported, and the pattern is the point.

**[RETRACTED] "Memory grew ~3x, from 290 MB healthy to 795 MB degraded."**
Healthy `private_mb` swings 256–1092 MB and has already exceeded 795 MB with
nothing wrong. The memory evidence for `CleanTrees` does not exist.

**[RETRACTED] "`ms_per_pass_hot > 4.0` sits 1.4x above the noise ceiling."**
True of the 54 samples it was calibrated on; false by 320. The healthy maximum
is 4.712, so the threshold was *inside* the healthy distribution and eight
samples had already crossed it at a perfectly healthy composition rate. The
deeper error was treating it as an independent measurement of the symptom at
all: while the rate is vsync-pinned it is `hot_pct / 1.44` and nothing more.
Raised to 6.0, and `p50_ms` added as the signal that is actually robust to
workload. See [Recalibrating the trap](#recalibrating-the-trap-2026-08-08-measured).

**[RETRACTED] "If handles saturate below 2400 the signal never fires."** Stated
as the risk to watch; the real behaviour is worse-but-different. Handles grew
+3.0/hour over a full cycle rather than saturating, which puts the crossing at
about day 13.8 — level with or later than the degradation it was meant to
anticipate. Not a signal that fails to fire, a signal that fires too late.

**[RETRACTED] "DWM CPU grew about 2x."** The two numbers compared — 69.7% and
138% — had different baselines (a 13-day mixed-workload average vs. a pure-idle
reading). The direction holds; the multiple does not.

**[RETRACTED] "WinDbg / WPA are not installed, so the degraded trace cannot be
read."** All three tools were present. Three separate errors produced this: a
glob that missed an `amd64\` path level, checking only `wpaexporter.exe` (CLI,
needs a profile) and never `wpa.exe` (GUI, does not), and a
`Get-ChildItem "$env:ProgramFiles\WindowsApps" -EA SilentlyContinue` whose
permission failure was swallowed into a false negative.

Acting on that false conclusion, a 2781 MB ETW trace **captured in the degraded
state** was permanently deleted, and DWM was then restarted, clearing the state.
That trace is why this investigation now needs to wait for a recurrence.
`Remove-Item` does not use the Recycle Bin, with or without `-Force`.

**[RETRACTED] "`top_windows` / `vis_windows` measure DWM's tree size."** They
count windows system-wide, i.e. which applications happen to be open. Healthy
average is 437.5 — *above* the degraded 419. No discriminating power.
`gdi_objects` / `user_objects` are likewise useless here: constant at 5 and 6,
because DWM uses DirectComposition/D3D rather than GDI.

## Prior art — thin, and generic

Searching for DWM high CPU returns a large volume of near-identical
troubleshooting articles. They converge on the same list: update the GPU
driver, disable overlays (Game Bar, Discord, RGB tools), reduce visual effects,
run `sfc` / `DISM`, restart. The framing throughout is that DWM is a victim of
something external rather than degrading on its own.

None of it addresses the shape of the problem described here:

- nothing about degradation that accumulates over **days of uptime**;
- no composition pass-rate or frame-interval measurements;
- no stacks, and no mention of `CleanTrees` or any other specific function.

"Restarting dwm.exe fixes it" is folk knowledge and easy to find. *Why* it comes
back, and what is growing in the meantime, is not documented anywhere found.

This is a weak basis for claiming novelty, and it is stated that way on
purpose: an absence of search results is not evidence that Microsoft is
unaware, only that no public write-up was located. This section should be
revisited before any bug report is filed.

## Open questions

1. Does a second degraded capture reproduce `CleanTrees`? — waiting on the trap.
2. Does the handle curve saturate below 2400? — see above.
3. Is this specific to this hardware, this Intel driver, or general to Windows
   11 build 26200? Untested. One machine, one GPU vendor.
4. Has this already been reported upstream? **Not yet searched.** This must
   happen before any bug report, and before treating any of this as novel.
