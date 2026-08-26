# Workstation Forensics

Evidence tooling for Windows freezes, bugchecks, broken Start search, Wi-Fi
driver resets, DWM/Shell hangs, and WARP/Wintun/Hyper-V network churn.

Two halves, aimed at two different failure shapes:

| | `collect-freeze-evidence.ps1` | `watch/` (in progress) |
|---|---|---|
| Failure shape | Sudden — freeze, bugcheck, reboot | Gradual — machine slowly rots over days |
| When it runs | By hand, after recovery | Continuously, fires on its own |
| Catches | Whatever the OS logged before it died | The bad state *while it is still live* |

The collector answers "what happened?" after the fact. The watcher exists
because some failures leave nothing to collect: by the time you notice, your
instinct is to restart the offending process, and that destroys the only copy
of the evidence.

---

## Part 1 — Post-hoc collector

Run after the machine recovers from a freeze or unexpected reboot:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
C:\dev\workstation-forensics\collect-freeze-evidence.ps1
```

Evidence lands in a timestamped folder under `evidence\` (git-ignored). Start
with `summary.txt`, then `events\related-errors.txt`, `drivers\key-drivers.txt`,
and `power\sleepstudy.html`.

### What it collects

- Boot time, OS, BIOS, crash dump registry settings.
- Key driver versions for Intel Wi-Fi, GPU, Bluetooth, ME, Ethernet, WARP, Wintun.
- WLAN driver/interface state.
- Start/Search/Shell service and process state.
- Related System/Application errors and warnings since boot.
- AppModel, StateRepository, Search, Shell, WLAN, WER, Kernel-Power, bugcheck signals.
- Windows Search and Start Menu shortcut/cache clues.
- SleepStudy and power capability output.
- Dump and WER report inventory.

Minidumps and relevant WER `Report.wer` files are copied by default; a full
`MEMORY.DMP` is not, because it can be huge. Use `-CopyLargeDumps` for that.

### Options

```powershell
# Last 48 hours instead of only this boot.
.\collect-freeze-evidence.ps1 -SinceHours 48

# Copy full/kernel MEMORY.DMP too, if present.
.\collect-freeze-evidence.ps1 -CopyLargeDumps

# Write evidence somewhere else.
.\collect-freeze-evidence.ps1 -OutputRoot D:\Diagnostics\freeze-evidence
```

### Known gap

The collector records `dwm` in `search-shell\processes.txt` but with
`StartTime`, `CPU`, and `Path` **blank**. It runs unelevated, `dwm.exe` lives
under the `DWM-1` account, and those properties come back AccessDenied and get
written as empty strings. There is no handle or working-set column either.

Consequence: a 2026-07-24 collection taken six days into a boot cycle that ended
in confirmed DWM degradation contains **no usable DWM data at all**. Fixing this
means reading DWM through `Win32_Process` (CIM), which returns `HandleCount`,
`ThreadCount`, `CreationDate`, and kernel/user times without needing the same
rights. Not yet done.

---

## Part 1b — Defender scan cost

```powershell
# Elevated. Records 120 s, then reports what real-time protection spent it on.
.\defender-perf.ps1 -Seconds 120
```

Wraps `New-MpPerformanceRecording` / `Get-MpPerformanceReport` and prints the
top files, extensions, processes, and individual scans by time. Records only —
it changes no Defender setting and disables no protection.

Worth knowing when reading its output: scan `TotalDuration` is elapsed time per
scan, scans overlap, and memory/AMSI scans are not attributed to any file. The
per-file numbers therefore do **not** sum to the process's CPU time, and should
not be presented as if they do.

---

## Part 2 — Continuous watcher (investigation open)

```
watch/
  dwm-growth-sample.ps1        one-shot sampler, 22 columns to CSV
  dwm-autocapture.ps1          full dump + symbolized stacks + 30 s ETL (+ PMC, see below)
  dwm-setup-elevated-task.ps1  registers the scheduled task at RunLevel Highest
  dwm-pmc.wprp                 WPR profile: hardware PMC on CSwitch, alongside CPU/DesktopComposition/GPU
  dwm-pmc-probe.ps1            one-shot feasibility check that a given machine can program the counters
  dwm-pmc-baseline.ps1         dedicated healthy-state PMC capture, brackets the recording with CSV checks
  dwm-pmc-verify.ps1           reads an ETL, reports instructions/cycles/IPC per dwm.exe thread
  dwm-pmc-occlusion.ps1        apportions PMC by concurrent sampled-profile stacks -> occlusion-specific IPC
task-*.vbs (generated)         dedicated wscript launchers (no console flash)
```

### PMC: telling pruning failure apart from iterator slowdown

Two mechanisms produce the same symptom (a slower per-frame occlusion walk)
but predict different hardware counter behaviour:

| | instructions | cycles | IPC |
|---|---|---|---|
| pruning failure (more nodes visited) | rises with cycles | rises | flat |
| iterator slowdown (same nodes, memory-latency bound) | flat | spikes | collapses |

`dwm-pmc.wprp` hangs `InstructionRetired`/`TotalCycles`/`LLCMisses` on
context-switch events (the only place TraceProcessor's scriptable API exposes
PMC data), and `dwm-pmc-verify.ps1` reports IPC per thread from that. Because
the same trace also collects sampled-profile stacks, `dwm-pmc-occlusion.ps1`
goes one step further and apportions each PMC interval's instructions/cycles
between "occlusion walk" and "everything else" by which call-path samples
land inside it, producing an occlusion-specific IPC rather than a
whole-thread average.

**Setup:** these two scripts load the TraceProcessor SDK
(`Microsoft.Windows.EventTracing*.dll`) via `-TraceProcessorLibDir` (defaults
to a `lib/` folder next to the script, gitignored). Get the DLLs from the
`Microsoft.Windows.EventTracing.Processing.All` NuGet package's
`lib/netstandard2.0/` folder.

Findings so far are in
[`docs/dwm-investigation.md`](docs/dwm-investigation.md) under "PMC:
instructions-per-cycle as a discriminator" — leaning toward pruning failure,
not yet closed on a single sample.

Setup is one elevated run of `dwm-setup-elevated-task.ps1`. Because the task
runs at `RunLevel Highest`, it never raises a UAC prompt afterwards — capture
works with the screen off or over a remote session. The task action is
`wscript → task-dwm-growth-sample.vbs → powershell` (not powershell directly):
Interactive + Highest + `powershell.exe -WindowStyle Hidden` still flashes a
console; `WScript.Shell.Run` style 0 does not. The VBS hardcodes paths because
Task Scheduler mangles multi-argument `wscript` command lines.

See [`docs/dwm-investigation.md`](docs/dwm-investigation.md).

Status as of 2026-08-13: **open.** The trap has since fired repeatedly. The
mechanism is localized to a specific per-frame walk (hardware-overlay
candidate evaluation, ~187x growth vs. 13–35x for the rest of the composition
pipeline); what remains open is which of two causes drives that growth, and a
PMC-based discriminator built to answer that currently leans one way on a
single real trigger. Read the document's confidence markers before relying on
anything in it — several early claims here, including "gradual degradation
over days", turned out to be wrong and are marked as retracted rather than
removed.

The thresholds were recalibrated on 2026-08-08 against 396 healthy samples,
because the original was set from 71 and had drifted *inside* the healthy
distribution as more data arrived — it had already been crossed eight times by a
compositor that was merely busy, and escaped firing only because no two of those
crossings were adjacent. Two things there generalise past this bug. A threshold
picked from an early, narrow sample is a claim with an expiry date, so re-derive
it as the sample grows. And a trap that disarms itself on a false positive is
one bad calibration away from being decorative — which is why the trap is now
skipped entirely when unelevated, where it could have consumed a signal and
still captured nothing.

### The running instrument is a separate copy

On the machine the investigation is running on, these scripts are driven by a
scheduled task from a different directory. **The scheduled task is never
repointed** while the investigation is open: that would risk a gap in sampling,
and the point of the trap is to be there when degradation happens.

Editing the script the task already points at is a different matter and is
fine — the path is resolved on each run, so a corrected script takes effect at
the next sample with no gap. That is how the 2026-08-08 threshold recalibration
was applied, and the copies here are the same change ported over.

The copies here are the generalized ones: paths default off `$PSScriptRoot` and
thresholds are parameters, so they work wherever they are installed. They are
verified rather than assumed. `watch/dwm-growth-sample.ps1` was run against a
scratch `-DataDir`, producing a well-formed 22-column row without touching the
live data set, and both trap branches were then exercised there: unelevated
skips without writing a flag, and a forced-elevated copy writes the flag,
appends to the trigger log, and invokes autocapture (a harmless stand-in, so no
dump was taken).

One caveat, stated rather than glossed: those runs were **unelevated**, so
`hot_pct`, `ms_per_pass_hot` and the GDI/USER columns came back empty. Those
paths need elevation by design (dwm runs as `DWM-1`, and `GetGuiResources` needs
a privileged handle). The logic is carried over line-for-line from the copy that
does run elevated and does populate them, but the elevated *collection* path has
not been re-run against this version. The elevated *trap* path has, by
overriding the elevation probe.

---

## Part 3 — Slow-moment hotkey

For slowness that is intermittent and has no single suspect: press a key while
it is happening and the machine's state at that instant is recorded.

```powershell
# Elevated, once.
.\setup-slow-hotkey.ps1                       # default CTRL+ALT+S
.\setup-slow-hotkey.ps1 -Hotkey 'CTRL+ALT+Q'
```

One beep means the capture is done (~15-20 s); `-Silent` suppresses it. Output
lands in `slow-capture\<timestamp>\summary.txt`, indexed on the Desktop in
`slow-captures.txt`.

There is deliberately no beep at the *start*. The first version had one, and it
contaminated its own measurement — see
[`docs/audio-apo-cpu-burst.md`](docs/audio-apo-cpu-burst.md), which is also the
one finding in this repo that is fully measured rather than inferred: on this
machine any sound at all costs ~9-17 core-seconds of CPU.

Records CPU delta / private / working set / handles / threads per process,
per-core frequency, memory and paging counters, GPU engine use, per-process
I/O, DWM composition rate, and recent error events.

### Logged occurrences

[`docs/slow-moment-log.md`](docs/slow-moment-log.md) is a running log of
subjective slowness reports, most without a hotkey capture to back them
(pressing the hotkey *during* the episode is what makes a report checkable —
an after-the-fact check can rule out known causes but not see a transient
stall). Kept so a pattern across occurrences can emerge instead of each
report being checked once and forgotten.

### Why a hotkey here, when the DWM watcher had to be fully automatic

The DWM trap could not use a human trigger, because the human's reaction —
restarting `dwm.exe` — destroys the evidence before anyone can look at it.

Nothing is destroyed by noticing the machine is slow. So the human is a valid
trigger here, and pressing a key beats guessing a threshold for a symptom as
multi-causal as "slow".

### Speed is the design constraint

A slow episode can be brief, and a capture that takes a minute records the
recovery rather than the problem. The first version took 30.5 s. Two changes
brought it to ~14.7 s:

- **One `Get-Counter` call instead of four.** Measured: four separate calls
  8.32 s, the same counters combined 4.26 s. Each call pays its own PDH
  initialisation. (`\GPU Engine(*)` alone accounts for ~3 s of what remains.)
- **No dedicated sleep for the CPU delta.** The first process snapshot opens
  the window, the counter work happens, the second snapshot closes it — so the
  delta is measured across work that had to happen anyway. Elapsed time is read
  from a stopwatch rather than assumed, because it varies.

### Known limitation

Explorer is what registers `.lnk` hotkeys, so if Explorer itself is hung the
key may not fire — and that is one of the cases you most want to capture. The
fallback does not depend on it:

```powershell
schtasks /run /tn "Slow Moment Capture"
```

### Not included: a ring buffer

A hotkey can only record from the moment it is pressed. Capturing what led up
to it needs a continuously running ETW session flushed on demand — WPR records
to memory by default (`-filemode` is what selects file mode), so the mechanism
exists.

It is deliberately not wired up. WPR needs `SeSystemProfilePrivilege`, so the
session would have to run permanently and elevated, and its cost on this
machine has not been measured — an attempt to A/B it failed because WPR would
not start unelevated, and background CPU here swings 15–82% at 5-second
granularity, which is far too noisy to resolve the difference over a short run.
Buffer capacity is set inside the profile `.wprp`, not from the command line;
for a light CPU profile the order of magnitude is roughly a minute per 256 MB,
but that is an estimate, not a measurement.

Measure it first, then decide whether the standing cost is worth the history.

---

## Part 4 — UI responsiveness logger

```
watch/
  ui-response-log.ps1         continuous logger, one summary row per 30 s window
  ui-response-setup-task.ps1  registers it to start at logon (no elevation needed)
```

For "typing feels laggy" — the class of complaint the DWM trap does *not*
cover, because it measures composition-pass timing, not input responsiveness.

Probes the foreground window with `SendMessageTimeout(WM_NULL)` every 500 ms
and writes percentiles of each 30-second window to `ui-response.csv`. `WM_NULL`
performs no operation; this is the documented way to ask whether a window's
thread is pumping messages, and is what underlies Windows' own "Not
Responding" detection. A blocked or slow message pump is the most common
mechanism behind laggy typing, so it is the cheapest proxy plausibly on the
causal path — but it is a proxy, not keystroke-to-pixel latency, and a stall
it does not see is not evidence that nothing stalled.

```powershell
.\watch\ui-response-setup-task.ps1     # once, unelevated
Start-ScheduledTask -TaskName "UI Response Logger"
```

### Why a logger and not a trap

The obvious question is why this cannot fire automatically the way the DWM
trap does. It is not that the trap is harder to write — it is that a
threshold needs two things this symptom does not yet have.

The DWM trap could be calibrated because an ad-hoc capture first established
what degradation looks like (composition rate 144 → 45/s, `p50` leaving its
vsync-pinned 6.94 ms), and the sampler then supplied a healthy distribution
tight enough that a threshold fits between them — `p50` never exceeded 7.18
across 396 healthy samples. Typing lag has neither end: it has never once
been measured while happening, so there is nothing to place a threshold
against, and "slow" is multi-causal in a way a single vsync-pinned constant
is not.

The cost of guessing is also asymmetric. `Fire()` writes a per-pid flag and
returns early for the rest of that process's life, so one false fire disarms
the signal for the cycle it was meant to catch — this repo has already shipped
one threshold that sat inside the healthy distribution and escaped firing
only because no two crossings were adjacent.

A logger has neither problem: no threshold, so it cannot false-fire and
cannot disarm itself. And the DWM investigation's own history says this is
the right order anyway — 545 logged rows are what overturned its "gradual
degradation" framing, well before any of it was understood.

### Cost, measured before committing to run it

Per this repo's rule that instruments must not perturb what they measure, the
probe loop was measured before being made permanent: **0.31% of one core and
~82 MB working set** at a 500 ms probe interval. Probe latency while healthy,
over 118 probes: p50 0.305 ms, p90 0.923 ms, p99 7.369 ms, max 19.284 ms.

**Note that tail.** The median is sub-millisecond but the healthy p99 is
already 7 ms and the max 19 ms. Any threshold built on this later has to be
calibrated against the tail, not the median — judging by the median while
ignoring the tail is exactly how this repo's first DWM threshold ended up
inside the healthy distribution.

Findings are logged in
[`docs/slow-moment-log.md`](docs/slow-moment-log.md).

---

## Part 5 — Kernel pool sampler

```
watch/
  kernel-pool-log.ps1         one sample per firing, appended to kernel-pool.csv
  kernel-pool-setup-task.ps1  registers it every 30 min + at logon (no elevation)
```

Answers one question and no others: **do the kernel pools grow with uptime?**

On 2026-08-26 this machine rebooted after 519.04 hours. Paged Pool and Nonpaged
Pool fell 2,834.7 MB between them -- 99.2% of the total kernel reduction, and
PDH independently reported 2,526 MB across the same two counters. It is the
first substantial result in this investigation that two instruments agree on.

It is also confounded. KB5120708 and KB5121003 installed at 09:00 the same
morning, so the kernel binaries changed between the two readings, and one
sample per boot cannot separate 519 hours of uptime from a cumulative update.

**The test is pre-registered, in the script header, before the data exists:**

```
baseline, 0.71 h on build 26200.9168     old kernel, 519.04 h
  Pool Nonpaged Bytes     1,247 MB         2,126 MB
  Pool Paged Resident       819 MB         2,466 MB
```

Climbs back toward 2,126 / 2,466 as uptime accumulates -> uptime is the
mechanism, and per-tag attribution (poolmon, elevated) becomes worth doing.
Sits flat near 1,247 / 819 at *comparable* uptime -> the drop belonged to the
update and uptime was never the cause. The old figures are from 519 hours; a
flat reading at 50 hours decides nothing, which is why `os_up_h` is on every
row.

`os_build` is on every row too, for the same reason the test exists at all: a
kernel update landed unnoticed between two readings once already, and the
confound has to be visible in the series rather than reconstructed from the
Setup log afterwards.

Two columns were dropped before this shipped. `Pool Nonpaged Allocs` and `Pool
Paged Allocs` would have separated a leak of many small allocations from a few
large ones, but both read exactly 0 through three channels -- PDH cooked, PDH
raw, and `Win32_PerfRawData_PerfOS_Memory` -- so this kernel does not maintain
them. A constant column carries no information, and this repo has been burned
once already by reading meaning into one (`p50_ms`, pinned at the 144 Hz frame
interval in all 1,118 rows of `dwm-growth.csv`).

The standby breakdown replaced them and earns its place differently:
`stby_core + stby_norm + stby_res + freezero` must equal `avail_mb`, so every
row self-checks, and those four are exactly what RamMap's Use Counts tab reports
as Standby + Zeroed + Free. The one discriminating check this investigation has
for RamMap's page-state decode needs both numbers from the same instant; every
attempt at it so far has been unpaired against a figure drifting hundreds of MB
between consecutive seconds.

Failed queries are written as `na`, never `0`.

Findings are logged in
[`docs/slow-moment-log.md`](docs/slow-moment-log.md).

---

## Notes

Everything here is read-only with respect to system state. Nothing changes dump
settings, restarts services, rebuilds the search index, or edits registry keys.
The watcher writes dumps and traces of a target process; it never terminates or
modifies one.

That rule decides what does *not* live here. A working
`add-claude-exclusion.ps1` (adds a path to the Defender exclusion list) was
written alongside `defender-perf.ps1` during the same investigation and is
deliberately **not** in this repo: it mutates a security setting, so shipping it
next to tools that promise read-only behaviour would make the promise
meaningless. Remediation scripts belong somewhere else.

`evidence/` and watcher output are git-ignored — they contain hostnames, BIOS
identifiers, installed-software inventories, crash reports, and full process
memory. Keep it that way.
