# DWM gradual degradation — investigation log

**Status: OPEN.** Started 2026-07-31. Last updated 2026-08-02.

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
the session is remote.

### Trigger signals

Two independent signals, each requiring **two consecutive** samples over
threshold so a transient spike cannot fire it:

| signal | threshold | degraded reference | healthy max (n=71) |
|---|---|---|---|
| `ms_per_pass_hot` | 4.0 | 8.7 | 2.77 |
| `handles` | 2400 | 2532 | 1840 |

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

## Open questions

1. Does a second degraded capture reproduce `CleanTrees`? — waiting on the trap.
2. Does the handle curve saturate below 2400? — see above.
3. Is this specific to this hardware, this Intel driver, or general to Windows
   11 build 26200? Untested. One machine, one GPU vendor.
4. Has this already been reported upstream? **Not yet searched.** This must
   happen before any bug report, and before treating any of this as novel.
