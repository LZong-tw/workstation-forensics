# Slow-moment log

**Status: OPEN.** Started 2026-08-16.

[`docs/dwm-investigation.md`](dwm-investigation.md) covers one specific,
mechanism-identified cause of desktop sluggishness. Not every "the machine
feels slow" report is that cause, and most will not be traceable to a DWM
trap firing at all — that is exactly the gap the slow-moment hotkey (README
Part 3) exists to close.

This file is a running log of subjective slowness reports, kept so a pattern
across occurrences — time of day, what was running, whether it was
system-wide or something specific like typing — can emerge across entries
instead of each report being checked once and forgotten. Most entries here
will have no hard data, because the hotkey has to be pressed *during* the
episode to capture anything; an after-the-fact check can rule out known
causes but cannot see a transient stall. That is stated plainly per entry
rather than glossed over.

Confidence markers as in `dwm-investigation.md`:
[MEASURED] / [INFERRED] / [ASSUMPTION] / [RETRACTED].

## Entries

### 2026-08-16 [ASSUMPTION]

Reported: general slowness, narrowed on follow-up to specifically typing
responsiveness.

Checked at the time (after the fact, not during):

- `dwm-growth-sample.ps1`'s two most recent rows (00:10, 00:40): `p50_ms`
  6.98 / 6.97 (threshold 7.25), `p90_ms` 7.92 / 7.55 (threshold 14),
  `ms_per_pass_hot` 1.11 / 0.99 (threshold 6.0), `handles` 1959 / 1967
  (threshold 2400) — all inside the healthy band. No trap fire since
  2026-08-13.
- A 2-second top-CPU snapshot: highest process was `claude` at 6.3%, `dwm`
  itself at 1.4%. Nothing visibly saturating a core.

No slow-moment hotkey capture exists for this window — `slow-capture\`'s most
recent entry is 2026-08-02, so the hotkey was not pressed at the time. This
entry records that the known DWM mechanism was checked and did not match,
not that a cause was found. Typing-specific latency is not something the DWM
trap measures in the first place; it measures composition-pass timing, not
input-to-screen latency.

**Open follow-up:** next time this happens, press the slow-moment hotkey
*while it is happening*. An after-the-fact CPU snapshot cannot see a
transient stall, only a sustained one — this entry is exactly the kind of gap
that leaves.

**Follow-up, same day: a logger now covers this gap.** Relying on the hotkey
means relying on the user noticing, reacting, and remembering — which did not
happen here. `watch/ui-response-log.ps1` (README Part 4) now runs
continuously and records foreground-UI message-pump responsiveness, so the
next report of this kind has data behind it whether or not anything was
pressed at the time.

### First observations from the logger [MEASURED]

The logger's first four windows, taken during a 2-minute validation run on
2026-08-16, immediately showed a spread far wider than the 60-second cost
measurement had:

| window | p50 | p90 | max | foreground | cpu% |
|---|---|---|---|---|---|
| 01:36:04 | 0.266 | 6.894 | **106.617** | LINE | 44.7 |
| 01:36:35 | 0.269 | 0.763 | **613.330** | LINE | 37.9 |
| 01:37:05 | 0.240 | 0.595 | 0.819 | WindowsTerminal | 43.0 |
| 01:37:35 | 0.207 | 1.124 | 4.096 | WindowsTerminal | 43.6 |

Two consecutive windows with LINE in the foreground each contain a single
probe that took 107 ms and 613 ms respectively, against a median of 0.27 ms.
A 613 ms message-pump stall is well above the threshold of human perception
for typing feedback. Switching foreground to WindowsTerminal, the maximum
drops back to sub-millisecond and single-digit-millisecond.

**What this does and does not establish. [ASSUMPTION]** It establishes that
the instrument resolves stalls of this size, which the 60-second cost run
(max 19 ms) had not shown. It does **not** establish that these stalls are
the cause of the reported slowness, or that they are abnormal: n=4 windows is
no baseline, and it is not known whether the user was typing into LINE at the
time. A stall of this size in a chat client's message pump is also entirely
consistent with ordinary work — rendering an incoming message, decoding an
image — rather than with a fault.

The point of recording it is that this is now a checkable claim rather than a
feeling: if LINE-foreground windows keep producing hundred-millisecond
maxima while other applications do not, that is a pattern; if they do not
recur, this entry stands as a single unexplained sample and should be treated
that way.

### 2026-08-16, second report the same day [MEASURED]

The first report backed by twelve hours of logger data (1461 windows). This
entry is what the logger was built for, and it changed the answer: the
previous entry could only rule things out, this one identifies a cause.

**Stalls are not uniform across the day.** Bucketing every window by
half-hour:

| period | windows with max > 50 ms | worst max |
|---|---|---|
| 02:00-09:30 | **0 of ~900** | 3.1 ms |
| 10:00 onward | frequent | — |
| 13:00-13:30 | **20 of 60** (8 > 200 ms, 3 > 1000 ms) | **2469 ms** |

11:30-12:30 was clean with the *same* foreground application
(WindowsTerminal) that was in the foreground during the bad 13:00 bucket, so
the stalls are not a property of one application.

**Stalls track CPU contention. [MEASURED]** Windows containing a stall
> 50 ms had `cpu_pct` median 50.2 / p90 87.4; windows without had median
21.5 / p90 38.4. This is a system-wide contention signature, not an
application fault.

**Root cause: a superseded Serena HTTP singleton was never reaped.
[MEASURED]** `~/.serena/http-singleton/` runs one HTTP Serena per project on
a fixed port (`ports.json`: `C:\dev\sugar-dating` -> 9127). Three separate
generations of that singleton were found alive simultaneously, aged 209 h,
76.7 h and 48.2 h. Each roots in a `node.exe` whose own parent PID no longer
exists — the immediate parents are alive, so a one-level "is my parent alive"
check does not detect this; the ancestry has to be walked to the top:

```
tsserver <- node <- cmd.exe <- python <- python <- serena.exe <- uv <- uvx <- node <- DEAD(28432)
```

The 209 h generation **no longer holds the 9127 listener** — the newest
generation took it over — but it never exited, and it retains four
established sockets. Its `tsserver.js` for `sugar-dating` (pid 50388,
345 MB) has consumed **108.6 CPU-hours over 172 hours of life = 63.1% of one
core, sustained, for seven days.**

Standing cost of all three orphaned cohorts together: **27 processes,
572 MB resident, 113.5 CPU-hours burned.**

**What this does NOT establish, stated explicitly. [MEASURED negative]** The
orphan is *not sufficient* on its own. Because its 63.1% is a lifetime
average over the full 172 hours, it was burning exactly as much during the
02:00-09:30 window that had **zero** stalls. It is chronic headroom loss, not
a trigger: it removes most of a core permanently, so stalls appear once the
user's own activity is added on top. Killing it should reduce stall frequency
but is not predicted to eliminate stalls.

**Disclosure: the investigation is part of the load.** `claude.exe` pid 56620
— this session — has averaged 67.6% of a core over 183 hours (123.7
CPU-hours), making it the single largest consumer on the machine, slightly
ahead of the orphan. Any measurement of "what is loading this machine" taken
during this investigation includes the investigation. `Rize.exe` is a distant
third at 14.4%.

Prior art: the same project (`sugar-dating`) already has a recorded orphaned
`next` dev-server leak with the same shape — parent dies, child is never
reaped. This is a recurring failure mode of that toolchain, not a one-off.

**Open follow-up:** the singleton launcher supersedes an existing instance
without terminating it. Until that is fixed, orphan generations will keep
accumulating. Re-check the logger buckets after the orphans are cleared to
test the "reduced but not eliminated" prediction above.

#### Correction, after reading the launcher source [RETRACTED in part]

The two claims above about *mechanism* were written before
`~/.serena/http-singleton/serena-http-singleton.mjs` had been read, and both
are wrong. The measurements are unaffected; the diagnosis is not.

**[RETRACTED] "Each roots in a `node.exe` whose own parent PID no longer
exists" was presented as the anomaly.** It is not an anomaly. `spawnDaemon()`
starts the daemon with `detached: true` followed by `child.unref()`, so the
spawning `ensure` process exits immediately by design and *every* healthy
daemon has a dead root — including the two kept. A dead root is the designed
steady state here and is not evidence of anything. The full ancestry walk was
still the right tool, but for a different reason: it identifies which daemon
owns the listener, not which one is orphaned.

**[RETRACTED] "Root cause: a superseded singleton was never reaped."** That
is the symptom. The cause is in `watchdog()`: its health check is `probe()`,
which issues an HTTP request to `endpoint(config)` — a `host:port` URL. It
tests **the port**, not **its own child**. Once a newer generation binds the
port, the superseded daemon's probe is answered by the newcomer, `failures`
resets to 0 on every cycle, and the daemon supervises a child that serves
nothing for as long as the machine stays up. Nothing ever reaps it because
nothing ever concludes anything is wrong.

**Supporting evidence for the corrected mechanism. [MEASURED]** The
generation-1 daemon root was 209 h old while its `serena.exe` was 172 h old.
The watchdog therefore *did* work once: it detected a genuine failure at the
172 h mark and restarted its child. It only became blind afterwards, once a
competing generation existed to answer its probes. Consistent with this, that
daemon had accumulated just 0.02 CPU-hours across 209 hours — the cost of
~50,000 successful probes, and a rate only the healthy branch of the loop can
produce.

**Fix applied** (in `~/.serena/http-singleton/`, not in this repo — per
`CLAUDE.md` this repo does not carry remediation):

- `reap` command, and it is the *primary* defence rather than the watchdog
  change. A daemon already running executes the code it was spawned with, so
  patching the file cannot teach an existing stray to retire; `reap` runs in a
  fresh short-lived process on every `ensure`, so it always has current code
  and needs no cooperation from the stray. It kills any daemon supervising the
  port that is not an ancestor of the process currently holding the listener,
  and refuses to act at all when no listener exists.
- `watchdog()` now records which pid holds the listener and retires itself
  when another generation takes over — secondary hardening only.
- Kills now verify termination instead of trusting the exit status. This was
  not theoretical: during this session's manual cleanup, `Stop-Process`
  reported "killed 13 of 13" while three of those processes were still alive
  on immediate recheck. A supervisor that kills and returns can leave a
  half-dead tree with no supervisor — a new orphan class created by the fix.
- Process ancestry uses one process-table snapshot walked in memory, not a
  per-pid query per hop, and the expensive scan is kept off the `ensure` fast
  path (detached, rate-limited).

Verified in both directions with `reap --dry-run`: the live daemon (79044,
ancestor of listener 49652) is kept, and a decoy process matching the daemon
command-line pattern but not owning the listener is flagged.

#### The first verification was invalid [RETRACTED]

**[RETRACTED] "a decoy process matching the daemon command-line pattern ...
is flagged" was not the test it appeared to be.** The decoy was
`node decoy.js serena-http-singleton.mjs daemon --port 9127`. That does not
resemble a daemon; it resembles *any command that merely mentions the
launcher*. The first `reap` selected daemons by substring — file name present,
the word `daemon` present, `--port 9127` present — so the decoy proved only
that reap kills things matching a pattern that also matches innocent
processes. It confirmed the bug rather than the fix.

This surfaced because a later dry-run listed a pid as not owning the listener
yet did not select it for killing. The pid was a transient `pwsh.exe` running
a diagnostic command whose own arguments contained the script path. It was
spared only because it happened to be an ancestor of the reap process and hit
an unrelated guard — luck, not design. A diagnostic shell run from anywhere
else would have been killed.

Selection now matches by argv **position**, not substring: the process must be
`node`, its argv[1] must be this script, argv[2] must be `daemon`, and a
`--port` argument must equal the port. Retested with two decoys at once — one
reproducing a real daemon's file name and argv shape, one merely mentioning
the script. The first is killed, the second is not selected at all, and the
live daemon and listener are untouched.

The general lesson is about instrument validation, which this repo already
insists on for measurement and should equally for remediation: a decoy that
does not resemble the target validates the wrong thing, and a passing test
against it is worse than no test, because it converts an unverified change
into an apparently verified one.

#### Second defect, found by restarting onto the patched code [MEASURED]

Restarting the 9127 singleton exposed a pre-existing startup race, unrelated
to the changes above and untouched by them. `WATCHDOG_FAILURES` is 3 at
`WATCHDOG_INTERVAL_MS` 15000, so the watchdog gives serena 45 s to answer,
but a cold `uvx --from serena-agent@latest` start exceeds that. The observed
sequence:

```
07:41:00 spawned daemon pid=18452
07:41:15 watchdog failure 1/3: ECONNREFUSED
07:41:30 watchdog failure 2/3: ECONNREFUSED
07:41:45 watchdog failure 3/3: ECONNREFUSED
07:41:45 watchdog restarting serena pid=86568      <- killed while still starting
07:41:51 starting uvx ...                          <- second attempt
07:42:39 healthy, mcp:200
```

The watchdog kills serena before it has finished starting, and the endpoint
only comes up on a later attempt that wins the race. `ensure`'s own 60 s
timeout expires first, so `restart` exits non-zero even though the daemon
recovers ~110 s in. On this occasion it self-recovered and the endpoint is
healthy; a real MCP session start on a cold cache would have seen `ensure`
throw.

**Fixed, grace period set to 100 s** (user's call on the value). The watchdog
now records when the child started and does not count failures until either
the endpoint has answered once or the grace has elapsed; the grace covers
startup only, so a failure after the endpoint has ever been healthy still
counts immediately. Three coupled values had to move with it, or the fix
would have been defeated elsewhere:

- `DEFAULT_TIMEOUT_MS` 60 s -> 150 s. `ensure` would otherwise still give up
  before the grace it just granted had expired.
- The `acquireLock` stale threshold, previously a hardcoded 120 s, is now
  `DEFAULT_TIMEOUT_MS + 60 s`. At 120 s it would have sat *below* the new
  ensure timeout, so a second ensure would declare a live lock stale while the
  first was legitimately waiting for a cold start.
- The concurrent-ensure wait was capped at `min(timeout, 30 s)`; 30 s is
  shorter than a cold start, so a waiter gave up on a daemon that was still
  coming up. Now uses the full timeout.

Verified by restarting: the log shows `still starting (15s of 100s grace)`
where it previously showed `watchdog failure 1/3`, serena is no longer killed
mid-startup, and `restart` exits 0 (32.3 s) instead of 1 (66.2 s). Warm
`ensure` re-measured over five runs at 132-528 ms — the path every MCP session
start takes is unaffected.

**A second instance of the same trap. [MEASURED]** After adding the fix, the
state file still reported `starting: true` alongside `healthy: true`
seventeen seconds later. The fix was not wrong — `writeState` merges over the
previous file, so the flag needed explicit clearing, but the *reason it was
still showing* was that the running daemon had been spawned before that line
existed and was executing the older code. This is the same property that made
`reap` the primary defence, and it nearly produced a second "verified" claim
about code that had never run. Confirmed only after a further restart:
`starting: false`, daemon on final code.

#### Closing state [MEASURED]

Both singletons (`sugar-dating` on 9127, `sugar-wt-auditroot` on 18291) were
restarted onto the patched launcher — 32.3 s and 18.3 s, both exit 0. Final
counts against what was found at the start of this entry:

| | before | after |
|---|---|---|
| `serena.exe` instances | 3 (two superseded) | 2, one per live port |
| singleton daemons | 3 | 2, both ancestors of their listener |
| `tsserver` instances | 6 | 2 |
| worst `tsserver` | 108.9 CPU-h, 954 MB | 0.00 CPU-h, 76 MB |
| `reap --dry-run` | — | `wouldKill: []` on both ports |

A final incidental confirmation of the over-matching bug: a process listing
taken during this sweep showed a `pwsh.exe` whose own command line contained
`serena-http-singleton.mjs ... daemon ... --port 9127`, because it was the
diagnostic command being run. Under the substring matcher that shell would
have been selected for killing. Under the argv-position matcher only the two
genuine daemons appear.

#### Prediction tested [MEASURED, attribution not clean]

The kill time was fixed from an independent source — the mtime of the kill
script, 14:27:23 — rather than chosen by looking at the curve. Raw
before/after would be dominated by the daily pattern, since the "before" side
contains the stall-free overnight period, so active hours are compared with
active hours:

| window | n | max > 50 ms | > 200 ms | > 1 s | cpu median |
|---|---|---|---|---|---|
| before, 10:00–14:27 | 528 | 44 (**8.3%**) | 16 (3.0%) | 5 | 36.2 |
| after, 14:27–18:36 | 495 | 13 (**2.6%**) | 9 (1.8%) | **6** | 23.2 |

Both halves of the prediction hold: frequency fell to about a third, and
stalls did **not** disappear — the count above one second actually rose by
one.

**The attribution is not clean, and in both directions.** The cpu median fell
13 points but the orphan can only account for about 4 (0.63 of a core over 16
logical cores is 3.9 points); the remainder is the daily decline, which
*overstates* the improvement. Against that, all six post-kill stalls above one
second fall in the 15:00 hour — exactly when the restarts, reaps and
whole-process-table enumerations documented above were being run — which
*understates* it. The following hours read 1.7%, 0.8%, 0.0%.

A clean test needs tomorrow's 10:00–14:00 against today's 10:00–14:27, with
no investigation running. Recorded as directionally consistent, not
established.

#### Supersede path tested [MEASURED]

The watchdog's self-retirement was the one change that had never executed —
it requires a real takeover to happen. It is now driven directly by
`~/.serena/http-singleton/test/test-supersede.mjs`, which builds the takeover
instead of waiting for one: a stand-in MCP endpoint (enough to satisfy
`probe()`) is started as a *descendant* of the supervised child, then killed
and replaced by a second one *outside* that tree.

Nine checks pass, including that the watchdog stays quiet while the listener
is its own, retires with `superseded` once it is not, kills its own child, and
leaves the newcomer alone.

**The test was then checked for discrimination**, which is the step whose
absence invalidated the earlier reap verification. Run against a copy of the
launcher with owner detection removed, it reports 6/9 and *times out* on the
supersede check — no reaction in sixty seconds, which is precisely the
original symptom. A test that cannot fail against the unfixed code proves
nothing, and this one does fail.

### 2026-08-17 01:09 [MEASURED]

Reported: slow again. First report where the logger was already running and
could be consulted immediately.

**The logger does not corroborate the symptom.** Last 60 minutes: 1 window of
119 with a maximum over 50 ms, worst 106.9 ms, nothing over 200 ms. For
comparison, yesterday's bad stretch was 8.3% of windows over 50 ms with a
2468 ms worst. Whatever is being perceived is not showing up as foreground
message-pump unresponsiveness.

**The machine is nevertheless loaded.** Measured over three consecutive
20-second windows rather than one short sample, because a single 3-second
delta cannot separate a spike from a sustained burn:

| pid | process | W1 | W2 | W3 | mean | lifetime avg |
|---|---|---|---|---|---|---|
| 56620 | `claude` (this session) | 120.4 | 131.6 | 130.2 | **127.4%** | 69.1% |
| 29932 | `claude` (a second session) | 89.0 | 127.0 | 62.0 | **92.7%** | **2.7%** |
| 12164 | `dllhost` / Plan9FileSystem | 48.1 | 47.2 | 44.1 | **46.5%** | 5.5% |
| 56740 | `Rize` | 46.5 | 38.0 | 33.5 | 39.3% | 14.9% |

Two of these are elevated far above their own long-run baseline: the second
Claude session (92.7% against a 2.7% lifetime average over 194 h) and the
`dllhost` hosting `Plan9FileSystem` (`vp9fs.dll`) — the WSL file-sharing
server — at 46.5% against 5.5%, on an 8 MB working set. Whether the second
Claude session is doing real work is not determinable from outside the
process and is an open question for the user.

**Other pressure, checked because the logger cannot see any of it:**

- Memory: 3.5 GB free of 31.2 GB, **88.8% used**; `Pages/sec` 246. This is the
  tightest resource on the machine. Commit 53.9 GB against a 129.5 GB limit,
  page file only 6.4% used.
- Disk: not implicated — 86.9% idle, 1.0 ms average read, 0.1 ms average
  write, queue length 0.
- CPU throttling: ruled out. `% Processor Performance` reads **119.6** while
  `% Processor Utility` is 43.3, i.e. turbo is engaged under real load. (An
  idle reading here would have had no discriminating power; this one was taken
  with the machine already busy.)

**The Serena fix held. [MEASURED]** Eight hours after the restarts: two
`serena.exe`, two singleton daemons, two `tsserver` instances at 41 MB and
**0.00 CPU-hours** each. No new generation accumulated, which is the first
production evidence for the reap/supersede work above.

**Still pending:** the clean 10:00–14:27 day-over-day comparison. This report
came in at 01:09, so that window does not exist yet for 08-17.

#### Traced: a nightly `updatedb` walks the Windows drives over 9P [MEASURED]

The second Claude session was confirmed by the user to be theirs and working,
so its 92.7% is accounted for. The `Plan9FileSystem` burn was traced instead.

`Plan9FileSystem` (`vp9fs.dll`) is the Windows-side server for WSL file
sharing. In WSL2 it carries traffic in **both** directions — not only Windows
reaching `\\wsl$`, but also Linux reaching `/mnt/c`, which is why the load
appears on the Windows side while the Linux side looks idle.

Inside the Kali distro, `updatedb.plocate` had been running for 58 minutes in
state **`D`** — uninterruptible I/O wait. `/etc/updatedb.conf` prunes neither
`/mnt` (not in `PRUNEPATHS`) nor the relevant filesystems (`PRUNEFS` lists
neither `9p` nor `drvfs`), while `/mnt/c` and `/mnt/d` are both mounted
`type 9p ... aname=drvfs`. So the nightly index walk traverses the Windows
drives one 9P round trip at a time.

Direct confirmation rather than inference: the process's `wchan` read
**`p9_client_rpc`** — the kernel was blocked inside a 9P RPC call at the
moment of sampling — and its open descriptors included `/mnt/f` among more
than a hundred directory handles.

**It is not a one-off. It is a systemd timer, and it runs for hours:**

| date | started | finished | wall clock | CPU consumed |
|---|---|---|---|---|
| 08-14 | — | 04:45:49 | **4 h 12 m** | 10 m 27 s |
| 08-15 | 00:36:44 | 04:08:05 | **3 h 31 m** | 10 m 21 s |
| 08-16 | 00:24:44 | 03:05:32 | **2 h 41 m** | 10 m 03 s |
| 08-17 | 00:30:44 | still running at 01:29 | — | — |

Ten minutes of CPU spread over three to four hours of wall clock. That ratio —
roughly 95% of the time blocked — *is* the 9P round-trip cost, and the
Windows-side share of it is the `dllhost` at 46.5% of a core. Peak memory per
run is reported at 0.8–1.0 GB, on a machine currently at 88.8% memory used.

**What this does NOT explain, stated because it constrains the finding.
[MEASURED]** On 08-16 this same job ran from 00:24 to 03:05, and that window
falls inside the period recorded further up this file as having **zero**
windows over 50 ms. Tonight's logger is likewise clean. So `updatedb` is a
large, genuinely recurring consumer that does **not** produce foreground
message-pump stalls. It is a plausible cause of "the machine feels slow" —
saturating the file-sharing server degrades anything crossing the WSL
boundary, in either direction — but it is not the cause of the stall episodes
documented earlier, and should not be credited with them.

**Fix applied** (user's decision): `/mnt` added to `PRUNEPATHS`, `9p` and
`drvfs` added to `PRUNEFS` in `/etc/updatedb.conf`, backed up first to
`/etc/updatedb.conf.bak-20260817-014110`. The edit was made by a script that
refuses to write if any pre-existing value or unrelated key changed, and is
idempotent on a second run. Indexing the Windows drives from inside Linux has
little value — the same files are already indexed by Windows Search — and it
was the entire cost here.

**The config change does not affect the run already in progress**, which read
`updatedb.conf` at 00:30 and would have continued for another one to three
hours. This is the third instance in two days of the same trap: a running
process carries the configuration or code it started with. It was stopped
with `systemctl stop`.

**Causal confirmation. [MEASURED]** Stopping it converts the attribution from
correlation into a controlled test, and the result is unambiguous:

| `dllhost` / Plan9FileSystem | window 1 | window 2 | window 3 |
|---|---|---|---|
| with `updatedb` running | 36.2% | 38.1% | — |
| after `systemctl stop` | **0.0%** | **0.0%** | **0.0%** |

Not a reduction — a collapse to zero across three consecutive 15-second
windows. `updatedb` accounted for the entire Plan9FileSystem load, not merely
part of it.

The aborted run's own accounting agrees with the mechanism: **5 min 17 s of
CPU over 1 h 27 m of wall clock**, the same ~95%-blocked ratio seen in the
three completed runs.

**What it did not fix:** memory is unchanged at 89.6% used (3.2 GB free); the
job's peak was only 356 MB this run, so it was never the memory driver. The
timer remains enabled, so tomorrow's 00:30 run is the test of whether the
pruning works — it should finish in seconds rather than hours.

### 2026-08-17 19:31 [MEASURED]

Reported: slow again. Unlike the 01:09 report, **the logger corroborates it**:
the last 60 minutes had 18 of 118 windows over 50 ms (15.3%), six over 200 ms
and two over one second. That is worse than the 08-16 stretch that prompted
this whole investigation.

#### [RETRACTED] The orphan kill did not produce a durable improvement

The day-over-day comparison set up on 08-16 — same hours, no investigation
running in the window — now exists, and it does not support the earlier
reading:

| window | n | max > 50 ms | > 200 ms | > 1 s | cpu median |
|---|---|---|---|---|---|
| 08-16 10:00–14:27 (before the kill) | 528 | 44 (8.3%) | 16 | 5 | 36.2 |
| 08-17 10:00–14:27 (after) | 529 | 40 (**7.6%**) | 16 | 4 | **36.3** |

Stall rate 8.3% -> 7.6% and cpu median 36.2 -> 36.3. That is no improvement.
The 08-16 post-kill afternoon read 2.6%, and this file recorded it as
"directionally consistent" with the prediction while warning the attribution
was unclean. **The warning was right and the reading was wrong**: today's
equivalent afternoon hours run 21.2%, 13.6%, 9.3%, 15.1%, 11.8%. The 2.6% was
the daily decline, not the reclaimed core.

Reclaiming 0.63 of a core was still correct on its own terms — it was real
waste, and the Serena fix has held (see below) — but it is **not** the cause
of the stalls, and this file previously implied otherwise.

#### The CPU correlation has collapsed [MEASURED]

The finding that stalls track CPU contention was the basis for everything that
followed. Recomputed on today's data it no longer holds:

| | windows with a > 50 ms stall | windows without |
|---|---|---|
| 08-16 | cpu median **50.2**, p90 87.4 | cpu median **21.5**, p90 38.4 |
| 08-17 | cpu median **51.6**, p90 73.6 | cpu median **46.7**, p90 60.4 |

The gap has gone from 28.7 points to 4.9. CPU no longer discriminates between
stalling and non-stalling windows, so whatever is causing today's stalls is
not CPU contention.

Aggregate CPU agrees that saturation is not the problem: summed process time
is 485.8% of one core across 16 logical cores — **30.4% of the machine**. The
load is also diffuse rather than concentrated: the top three processes account
for 224.5% and the remaining 86 processes for 261.5%, with eight processes
above 20% of a core. There is no single culprit to remove this time.

#### Memory is the leading candidate, not yet established [INFERRED]

| | 08-17 01:09 | 08-17 19:31 |
|---|---|---|
| physical used | 88.8% | **90.1%** (3.1 GB free) |
| committed | 53.9 GB | **64.8 GB** |
| `Pages/sec` | 246 | **842** |

`Page Reads/sec` — hard faults that actually reach disk, as distinct from the
51,716 `Page Faults/sec` that are mostly cheap soft faults — reads **240.7**,
with `Pages Input/sec` at 1899. So the machine is genuinely faulting from disk
while a foreground application is trying to respond.

This is consistent with the symptom in a way CPU no longer is: a foreground
window whose working set has been trimmed must fault pages back in before it
can pump messages, which produces exactly the isolated hundred-millisecond
maxima against a sub-millisecond median that the logger records.

**It is not established.** Disk service times remain fast (91.6% idle, 0.8 ms
reads, queue length 0), so the hard-fault load is being absorbed comfortably;
and no measurement here ties a specific stall window to a specific fault
burst. The logger records `cpu_pct` but not fault rate, which is precisely the
gap — testing this properly needs the logger extended to sample
`Page Reads/sec` per window, so stalls can be correlated against faults the
way they were against CPU.

#### Both prior fixes held [MEASURED]

- **Serena:** two `serena.exe`, no accumulated generations, 26 h and 8 h old.
  The live `tsserver` descends from `node.exe(46928)` — the daemon restarted
  yesterday — via a root PID that no longer exists, which is the *designed*
  detached-spawn shape documented above, not an orphan.
- **updatedb:** `dllhost`/Plan9FileSystem measured **0.0% of a core**, down
  from 36-38% before the config change. `updatedb` is not running. The real
  test of the pruning is the next timer firing, 2026-08-18 00:25.

#### Logger extended to measure memory [MEASURED]

The gap identified above is now closed. `ui-response-log.ps1` records three
more columns per window, all bracketing the window exactly as `cpu_pct` does
so they describe the same interval:

- `pgread_s` — system-wide **hard** page reads/sec. Hard faults only:
  `Page Faults/sec` is dominated by cheap soft faults and reads in the tens of
  thousands while nothing is wrong.
- `availmb` — physical memory available at window end.
- `fgfault` — page faults charged to the **foreground process** over the
  window. This is the discriminating column: a system-wide rate says the
  machine was faulting, but this says the process that failed to pump messages
  was the one faulting. Left empty when the foreground changed mid-window
  (verified working — rows with `fg_procs_seen=2` are blank), and `na` when the
  handle could not be opened, since a failed query is not zero.

**Cost, re-measured before deploying it**, per the rule that instruments must
not perturb: **0.31% of one core and 93 MB at the production 30 s window** —
indistinguishable from the 0.31% measured before the columns existed. At a 10 s
window the same code costs 1.15%, because the PDH collections are per-window
rather than per-probe; the cost is only meaningful with the window size
attached.

The existing series was migrated in place rather than rotated, so the
day-over-day comparisons keep a single continuous history: 5201 rows, the
oldest from 08-16 01:43, with the new columns null for windows that predate
them.

**Two marshalling bugs, recorded because the first one impersonated a
different diagnosis.** `PdhAddEnglishCounterW` returned
`PDH_CSTATUS_BAD_COUNTERNAME` for `\Memory\Page Reads/sec`, which reads
precisely as "this zh-TW machine has no English counter names" — a plausible,
locale-specific, entirely wrong conclusion. Acting on it led through counter
index lookups (index 78 turned out to be `Announcements Domain/sec`, not
`Page Reads/sec` — caught only because the resolved names were printed rather
than trusted) and a `Win32_PerfRawData_PerfOS_Memory` alternative that measured
correctly but cost **542 ms per query, 1.8% of a core**, seven times the
logger's entire budget. `Get-Counter` was worse at 1020 ms.

The actual causes were both in the P/Invoke declarations:

1. `DllImport` defaults to `CharSet.Ansi`, so the counter path reached the `W`
   entry point as ANSI bytes read as UTF-16 — garbage, hence "bad counter
   name". `CharSet=CharSet.Unicode` fixes it.
2. PowerShell marshals `$null` to an **empty string** for a `string` parameter,
   which PDH reads as a log-file name and rejects with `PDH_INVALID_ARGUMENT`.
   Declaring those parameters `IntPtr` and passing `IntPtr.Zero` sends a real
   NULL.

With both fixed the English counter path works on this machine, and the
locale hypothesis was never true. The lesson is the one this file keeps
relearning in other forms: an error message that names a plausible cause is
still not evidence for it.

### 2026-08-18 00:37 — scheduled verification [MEASURED]

#### The updatedb pruning worked

The first run under the new `/etc/updatedb.conf`, read from the journal rather
than reported from memory:

```
8月 18 00:25:44 Starting plocate-updatedb.service...
8月 18 00:26:21 Finished plocate-updatedb.service.
8月 18 00:26:21 Consumed 11.970s CPU time over 36.305s wall clock time,
                785.5M memory peak.
```

| run | wall clock | CPU | CPU/wall |
|---|---|---|---|
| 08-14 | 4 h 12 m 04.788 s | 10 m 27.102 s | 4.1% |
| 08-15 | 3 h 31 m 20.251 s | 10 m 20.892 s | 4.9% |
| 08-16 | 2 h 40 m 47.930 s | 10 m 02.840 s | 6.2% |
| **08-18** | **36.305 s** | **11.970 s** | **33.0%** |

Against the 08-16 run that is 9647.93 s of wall clock reduced to 36.305 s.
The more telling number is the ratio of CPU to wall clock: it was 4-6%, i.e.
the job spent almost all of its life blocked, and is now 33%. The blocking was
the 9P traversal, and removing `/mnt` removed it.

The `Consumed` line also no longer reports a swap peak; the three prior runs
reported 119.8 M to 192.9 M. Memory peak itself is unchanged at 785.5 M
against 784.3 / 839.4 / 1015.4 M, so the pruning cut time and paging, not
footprint.

`updatedb` is not running, and the Plan9FileSystem `dllhost` measured
**0.0% of a core across three 15-second windows** — genuinely zero, not a
missing reading (see below). Its lifetime average is 4.89% over 131 hours,
which is the accumulated cost of the earlier runs.

**A fabricated zero, caught. [RETRACTED]** The first attempt at that dllhost
measurement assumed a single matching process, got an array, and computed the
deltas from a null — printing `0.0%` three times. Those readings were
meaningless, and they happened to agree with the expected answer, which is the
dangerous case: had the errors not been visible in the same output they would
have been reported as confirmation. Rewritten to handle multiple matches and
to report an unopenable process as unknown rather than as zero. This is the
same "null is not zero" failure this repo already documents, reproduced while
verifying a fix.

#### Memory hypothesis: direction consistent, not established [INFERRED]

377 windows now carry the memory columns, covering 3.2 hours; 342 have an
attributable `fgfault`. Split as CPU was:

| split at max_ms > 50 | stalling (n=15) | not stalling (n=362) |
|---|---|---|
| `availmb` median | **3560** | **4173** |
| `pgread_s` median | 162.3 | 116.8 |
| `fgfault` median | 321 | 270 |
| `cpu_pct` median | 40.7 | 31.8 |

At the stricter `> 200 ms` split (n=6) the separation widens: `pgread_s`
median 350.9 against 116.8, and `fgfault` median 8458 against 270 — but that
`fgfault` figure rests on **four** attributable windows and should not be
quoted as a ratio.

Every memory column points the same way — stalling windows have less memory
available and more faulting — which is the first evidence for the hypothesis.
**It does not explain all the stalls**, and the worst-window table is where
that shows:

| max_ms | `pgread_s` | `fgfault` | reading |
|---|---|---|---|
| 660.8 | 350.9 | 25044 | heavy foreground faulting |
| 512.4 | 145.8 | 8458 | faulting, also cpu 87.4 |
| 488.7 | **3968.2** | **321** | system faulting hard, foreground barely at all |
| 310.0 | 80.9 | **153** | no meaningful faulting; cpu 87.2 |
| 143.3 | **7.4** | (n/a) | essentially no paging in the window at all |

So there are stalls with large foreground fault counts, stalls where the
system faults but the stalling process does not, and stalls with no paging
worth the name. Memory looks like *one* contributor, not the mechanism.

**A sampling bias that works against this analysis, stated because it is not
obvious:** five of the ten worst windows have an empty `fgfault` because the
foreground changed mid-window. Switching applications plausibly causes both a
stall and a foreground change, so the windows most likely to be stalling are
disproportionately the ones where the discriminating column cannot be
computed. The 342/377 attributable rate is good overall but is probably much
worse among stalls specifically. Narrowing the window, or tracking faults per
foreground process rather than per window, would address it.

n=15 stalling windows over 3.2 hours is a first look, not a result.

### 2026-08-18 01:15 — following up the same session's numbers

#### Why the updatedb table skips 08-17

There is no completed 08-17 run to report. That night's job was **stopped
mid-flight on purpose**, as the causal test that took the Plan9FileSystem
`dllhost` from 36.2% / 38.1% to 0.0%. The gap in the table is the experiment,
not a missing measurement.

#### PRUNEPATHS confirmed at the database, not just the clock

A 36-second run is consistent with pruning but does not prove it — the job
could have been fast for some other reason. Checked directly:

```
locate -c /mnt   ->  9
locate -c /      ->  804943
locate -c /home  ->  270892
```

and those 9 are `/mnt` itself plus eight substring matches like
`/usr/include/mntent.h`. `/mnt/c` is not in the database at all, while the
database is otherwise fully populated. The pruning is real.

**The unprivileged run of this check returned 0 and it was not a zero.** The
first attempt printed `count: 0` for `/mnt` — with
`/var/lib/plocate/plocate.db: 拒絕不符權限的操作` on the line above it. Without
`sudo`, `locate` cannot read the database and every count is 0, including the
sanity checks that were supposed to prove the database was populated. A
permission failure that renders as the expected answer. This is the third time
this investigation has read an unqueryable thing as zero.

#### The `availmb` separation survives a drift check [MEASURED]

`availmb` is a level, not a rate, so a session-long drift would manufacture the
separation with no causal content: if the stalls happened to sit in the
memory-poorer part of the block, that is all the 3560-vs-4173 gap would mean.

Available memory does drift across this block — **upward**, +307 MB/h
(r = 0.273) — and the stalls are heavily **early**: 13 of 15 fall in the first
76 minutes of 200. So the raw comparison was confounded, and confounded in the
direction that flatters it.

Controlling for it by comparing each stalling window only against non-stalling
windows within ±15 minutes:

```
n=15  median delta -628 MB   below zero: 12 of 15
```

The association survives, and is slightly larger than the uncontrolled gap of
613 MB. Stalling windows really do sit in memory-poorer moments than their own
immediate neighbours.

#### But the mechanism is directly contradicted [MEASURED]

Looking at individual windows rather than medians overturns the reading above
them. Three groups, all from the same evening and mostly the same foreground
process:

**Stalls with no faulting.** The largest cluster — 21:41:22 through 21:42:54,
four stalls of 149, 105, 310 and 145 ms — runs at `cpu_pct` 87.2–87.4 with
`fgfault` of 227, 231, 153, 175. High CPU, essentially no paging.

**Heavy faulting with no stalls.** 22:16:33 through 22:20:05, six consecutive
windows:

| time | `pgread_s` | `fgfault` | max_ms |
|---|---|---|---|
| 22:16:33 | 3626.9 | 373 | **1.8** |
| 22:18:04 | 1576.4 | 364 | **1.4** |
| 22:18:34 | 3227.3 | 328 | **1.5** |
| 22:19:04 | 2668.9 | 343 | **2.3** |
| 22:19:35 | 2039.4 | 402 | **4.3** |
| 22:20:05 | 979.7 | 405 | **3.0** |

This is the heaviest sustained system paging in the entire dataset, and the UI
is at its most responsive.

**The highest foreground fault counts are not stalls either.** 22:23:36 has
`fgfault` 41837 — the largest in the table — and max_ms 29.9. 22:06:27 has
`fgfault` 16013 and `availmb` 1891, the lowest memory reading in the block, and
max_ms 9.8.

So faulting occurs without stalls, at the highest magnitudes recorded, and
stalls occur without faulting. **[RETRACTED]** — the "every memory column
points the same way, which is the first evidence for the hypothesis" reading in
the entry above does not survive this. The medians were carried by a handful of
windows that had both, and the sample is not what it looked like: the stall
rate falls 16.7% → 6.8% → 5.1% → 1.7% → 0% → 3.4% → 0% → 0% across the
half-hours, so these are **not 377 independent windows but one degrading period
followed by a quiet evening**, and the split was largely comparing the first
hour against the rest of it.

What is left is one unexplained association — stalling moments are ~600 MB
memory-poorer than their immediate neighbours, and that does survive the drift
control — while the causal story it was meant to support is contradicted by the
same data. That is a smaller and more awkward result than the entry above
claimed, and it is the correct one. This is the second hypothesis in this file
to look supported at the median and collapse at the individual windows, after
CPU. The median is where this investigation keeps going wrong; the per-window
table is where it keeps getting corrected.

### 2026-08-18 10:50 — "slow again": not corroborated, and a controlled negative

#### The instrument disagrees with the report

| | 08-16 | 08-17 | 08-18 |
|---|---|---|---|
| whole-day `cpu_pct` median | 21.8 | 32.9 | **21.1** |
| whole-day stall rate | 2.8% | 7.2% | **0.6%** |
| worst `max_ms`, 08:00–10:30 | 1010 | 579 | **264** |

Today is the best of the three days logged, by a wide margin on stall rate and
worst-case latency. `p50_ms` sits at 0.25–0.35 ms. The one thing drifting up is
the morning `cpu_pct` median across days — 17.4 → 22.2 → 24.5 in the 08:00–10:30
window — background load rising without producing stalls.

#### The largest process, and why it is not the answer

Three Claude Code sessions are running. Lifetime CPU:

| pid | project | age | CPU | average |
|---|---|---|---|---|
| 56620 | sugar-dating | 227.4 h | **165.30 h** | **72.7% of a core** |
| 29932 | this investigation | 227.4 h | 6.09 h | 2.7% |
| 73180 | finlab-executor | 189.4 h | 2.59 h | 1.4% |

Session identity was established by elimination rather than assumed from
timestamps: 29932 is this session (its slug and session id are the ones in my
own scratchpad path), 73180 was idle at 0.3–0.9% matching a transcript last
written 21.9 minutes earlier, leaving 56620.

56620 has one thread in state `Running` at 74.8%, 2.08 **billion** page faults
against 27 M for this session, and 15.8 GB read in 61.3 M operations — 277 bytes
per operation, against 8704 B/op here. Its descendants account for 0.01 CPU-h,
so the cost is in the Claude process itself.

That session has run **37 workflows and 424 subagents**, 381 of them on 08-17
alone, and subagents execute inside the parent process, so much of the CPU is
attributable work. **But that does not cover most of it.** Splitting the
process's life at the 08-16 measurement recorded earlier in this file:

| period | length | CPU burned | rate | subagents |
|---|---|---|---|---|
| 08-09 03:00 → 08-16 18:00 | 183 h | 123.7 h | 67.6% of a core | ~5 |
| 08-16 18:00 → 08-18 10:30 | 44.4 h | 41.6 h | 94% of a core | ~419 |

The subagent era added roughly 26 points. The **68% of a core sustained across
seven days with essentially no subagent activity** is the part that is not
explained, and it is the open question. That session did hold a 901.6 MB
transcript active until 08-14, so heavy main-loop use is a live alternative to
a defect; this entry does not settle it.

**The idle test failed to discriminate and is reported as such.** Thirty 20-second
windows were sampled looking for "high CPU with no activity"; the session wrote
its transcript in 28 of 30 windows and held 83–114% throughout. Two windows had
zero transcript growth at ~110% CPU, which is not evidence of anything during an
active workflow. The test did not answer the question it was built for.

#### Workflows do not move the machine: a controlled negative [MEASURED]

Hour by hour, hours with subagent activity look far worse than hours without:

```
agents running   n= 32  cpu median 32.0  stall median 4.2%
no agents        n= 25  cpu median 20.9  stall median 0.0%
```

**That split is time-of-day confounding, not an effect.** Agent-bearing hours
are mostly daytime hours. Comparing the same clock hour across days separates
them:

| clock hour | 08-16 | 08-17 | 08-18 |
|---|---|---|---|
| 04:00 | cpu 21.0 (0 agents) | cpu **19.7 (59 agents)** | cpu 20.9 (0 agents) |
| 05:00 | cpu 19.6 (0 agents) | cpu **16.4 (52 agents)** | cpu 20.4 (0 agents) |

The two heaviest agent hours in the dataset ran 59 and 52 subagents and produced
the *lowest* CPU readings of their clock slots. Meanwhile 08-17 14:00 ran 18
agents at cpu 56.3, and 08-16 10:00 ran **zero** agents at cpu 36.2 with a
13.6% stall rate.

The arithmetic explains why: `cpu_pct` is machine-wide across 16 logical cores,
so a process pegging one full core moves it by ~6 points. The observed swings
are 16 → 56, i.e. 2.5 to 9 cores. No single Claude session can account for
that, and the biggest one demonstrably does not.

This is the third hypothesis this file has had to reject, and the second
rejected specifically because an aggregate split was confounded by something
that tracked with the grouping — memory by session drift, this one by time of
day. Both were caught by printing the individual rows.

#### Also checked and cleared

Rize reports 3.20 TB `VirtualSize`, which looks alarming and is not a leak:
chrome is 3.53 TB and Slack 3.43 TB on the same machine. Chromium reserves
TB-scale address space by design. Rize's real cost is a renderer holding 1.3 GB
at 16.3% of a core sustained — genuine, but small.

#### Honest note on the current hour

08-18 10:00 shows cpu 39.8 and a 9.1% stall rate, the worst hour today. That
hour is when this investigation was running back-to-back 20–60 second sampling
scripts while the other session ran a workflow. The measurement is part of what
it measured.

#### Correcting the 2026-08-16 entry: pid 56620 is not this session [RETRACTED]

The 08-16 entry above carries a disclosure headed *"the investigation is part of
the load"*, attributing `claude.exe` pid 56620 — then 67.6% of a core over 183
hours — to **this** session. That attribution is wrong, and it inverted the
entry's point.

Established twice, at different times, from different shell PIDs, by walking up
from the tool process's own `$PID`:

```
51196(pwsh) <- 29932(claude.exe.old...) <- 27728(pwsh) <- 17692(WindowsTerminal)
44764(pwsh) <- 29932(claude.exe.old...) <- 27728(pwsh) <- 17692(WindowsTerminal)
```

Claude Code spawns its shell tool processes as its own children, so the claude
process that this investigation runs inside is **29932**, not 56620. Independent
cross-check: the harness names this session's transcript as
`C--Users-LZong\0f8fa802-…jsonl`, and that file's mtime tracks each tool call to
the second.

The correction reverses the meaning. This investigation has used **6.09
CPU-hours** across its 227-hour life — 2.7% of a core, third of the three
sessions. The single largest consumer on this machine was never the
investigation; it is and was the other session. The original disclosure was
written in the right spirit, and was simply about the wrong process.

The `.exe.old.<timestamp>` in the image name is a Claude Code self-update that
renamed the running binary underneath the process, which is also why a
`Get-Process claude` name match does not reliably find all three.

### 2026-08-18 17:00 — the 68% baseline: the premise was wrong [RETRACTED]

The entry above closed with "the seven-day 68% baseline predates the agents and
stays open". A nine-agent workflow was run against exactly that question. It did
not find the mechanism. It found that **the question was malformed**, and the
error was mine.

#### There was never a pre-subagent era

The briefing I wrote asserted "~5 subagents" inside the baseline window
(2026-08-08 19:00Z → 2026-08-16 10:00Z). The actual count:

```
pre-window   subagent files touched= 1970  records= 161924  MB= 599.8
baseline     subagent files touched=  856  records=  67926  MB= 234.6
recent       subagent files touched=  389  records=  25862  MB=  90.7
```

**856, not 5** — wrong by more than two orders of magnitude, spread across every
day of the window (353 files starting 08-10, 311 on 08-11, 84 on 08-13). And
1,970 subagent transcripts carry timestamps *before* the window opens, so **no
era anywhere in the data is pre-subagent.** There is no control period to which
a residual could be attributed.

The error's origin: I counted `agent-*.jsonl` by mtime inside **one** session
directory — `da3db8e2`, the session running *today* — and applied the result to
a window that belongs to a **different** session, `ecf97575`, the 901.6 MB
transcript that was live through 08-14. Right filter, wrong directory. The
counter was validated in passing: run against the recent era it returns 389
against the ~419 I had stated independently, so it reproduces my numbers where
they were checkable and contradicts them where they were not.

With the premise gone, the two "eras" differ in degree, not kind:

| | subagent files/h | subagent records/h | CPU |
|---|---|---|---|
| baseline (183 h) | 4.68 | 371 | 67.6% of a core |
| recent (44.4 h) | 8.76 | 582 | 94% of a core |

1.87x the subagent rate for 1.39x the CPU. The 84x regime change I asserted does
not exist.

#### Per unit of work it is not expensive — it is cheaper than this session

Apportioning CPU over the same window and dividing by logged records:

| session | records | CPU | CPU-s/record | CPU-s/MB |
|---|---|---|---|---|
| 56620 sugar-dating (incl. its own subagents) | 178,310 | 123.7 h | **2.50** | **883** |
| 29932 this investigation | 4,927 | 5.1–5.5 h | 3.75 | 1066 |
| 73180 finlab | 483 | 2.1–2.6 h | 15.4–19.5 | 4693 |

Ratio 56620/29932: **0.67x per record, 0.83x per MB.** Under an adversarial
normalization that credits the control every hook record and strips sugar's
estimated hook share, it is 0.98x. Every normalization tried lands at or below
1.0. The raw 24x CPU gap comes with a ~21x work gap.

This also corrects the workflow's own first draft, which used main-transcript
records only and got 1.1x–1.6x; that denominator omitted 38% of the session's
in-window records because it never descended into its own `subagents/` subtree.
A duplication gate was run on the correction — 67,926 records, 67,926 distinct
UUIDs, zero repeats, zero files skipped of 3,398 walked.

#### The idle burn was never observed at all

Every CPU measurement of 56620 in this entire investigation — `idle-correlate.txt`
(28 of 30 windows had transcript growth), the T2 600-sample run, T3's 13
intervals, the live sampler — was taken while the session was working. The one
test built to break that confound died four minutes in because it was launched
as a shell background job that did not outlive its session.

So the phrase "burns a core while idle", which this file has been carrying since
08-16, describes something **nobody has ever measured here.**

Two further honest notes from the workflow:

- It nearly reported five 60-second windows of zero bytes written as proof of
  idle burn. They were an artifact of summing ~9,000 files with
  `Get-ChildItem -Recurse`; a 20-second single-pinned-path probe showed steady
  growth with zero directory-entry skew. Caught before it became the fourth
  collapsed hypothesis in this file.
- "148 of 183 hours had records = 80.9% active" survives only as literally
  defined. At finer resolution the window is 62.4% within 5 minutes of a record
  and 49.0% within 1 minute, and the implied active-only rate spans 83% to 138%
  of a core depending on the threshold. Choosing the threshold whose answer looks
  right is threshold-shopping and was refused.

#### Mechanism: UNDETERMINED, and correctly so

What is established: the burn is **user-mode compute** — 93% user over the
process lifetime, 102.4 of 108.4 points user in a live 60 s sample. Not kernel,
not syscall, not paging, not I/O. The "61 million tiny reads" figure was a
base-rate illusion: 86 ops/s and 19.4 KB/s live cannot drive a core, and the
count is simply 227 hours of accumulation.

Rejected during this pass: page faults as the driver — process CPU was 103.3% of
a core at 479 faults/s and 101.3% at 6,468 faults/s, invariant across a 91x fault
swing. Also rejected, again: transcript size, which had already failed its own
natural experiment when the live transcript shrank 5.6x on 08-14 with no change
in burn.

The one step that could name the code region is an elevated ETW/WPR sample.
It failed twice from the current token:

```
Failed to enable the policy to profile system performance.
Profile Id: CPU.Verbose.File  Error code: 0xc5585011
Elevated: False, BUILTIN\Administrators = Group used for deny only
```

Claude Code on this machine is a **Bun/JavaScriptCore** binary, so V8 tooling
(`--prof`, `--inspect`, the V8 ETW JIT provider) does not apply and ETW is the
only profiler available.

#### Upstream

Four matching reports exist. Verified individually with `gh issue view` rather
than taken from the agent's summary:

| issue | state | date | title |
|---|---|---|---|
| #81353 | **OPEN** | 2026-07-26 | Idle CLI sessions burn 100%+ CPU each in recurring ~1.1h episodes |
| #67664 | closed | 2026-06-11 | claude.exe main thread spins a core after sleep/hibernate — `uv__io_poll` busy-loop |
| #62308 | closed | 2026-05-25 | Process spins at 100% CPU indefinitely when idle — `uv_backend_timeout()` stuck at 0 |
| #10493 | closed | 2025-10-28 | Busy-wait loop in event loop causing excessive CPU during idle |

**Nothing was filed.** There is no mechanism and no reproducible signature to
report, and #81353 already covers the symptom class if the idle burn turns out
to be real.

#### What would settle it

1. A **detached** idle sampler — Scheduled Task or fully detached process, not a
   shell background job — aimed at the recurring 02:00–07:00 local window that
   was empty on 5 of 7 baseline nights, sampling per-thread CPU and the
   transcript length via a single pinned absolute path. If CPU collapses across a
   verified multi-hour zero-record window, the whole phenomenon is work volume
   and this closes. If it persists, there is finally a real anomaly with a
   reproducible time window — which is also the precondition for filing.
2. An **elevated** `wpr -start CPU -filemode` / `wpr -stop`, one UAC prompt. It
   samples system-wide and does not attach to, suspend or signal the session.

Not done, and deliberately: reproducing #81353's kill-and-`--resume` test
destroys the specimen, and the user is working in that session.

---

### 2026-08-18 19:37 — elevated ETW capture: the expensive session is not expensive per second

Step 2 of "what would settle it" was run. One UAC prompt, `wpr -start CPU
-filemode` for 60 s, system-wide sampling — nothing attached to, suspended or
signalled any session. Trace: 2981 MB, exported to a 119 MB
`CPU Usage (Sampled)` table.

**The headline: the two active sessions are indistinguishable.**

| | pid 56620 "expensive" | pid 29932 control | pid 73180 idle control |
|---|---|---|---|
| CPU during the sampled minute | **66.0% of a core** | **63.7%** | 0.3% |
| in claude.exe's own image | 43.0% | 42.5% | 48.2% |
| in unbacked executable memory | 47.9% | 45.1% | 0.6% |
| in kernel | 8.6% | 10.7% | 46.9% |
| lifetime average since 08-08 | 73.9% of a core | **2.8%** | 1.3% |

Per second of actual work the two cost the same — 1.04x. Over their lifetimes
they differ by 26x. **The entire gap is duty cycle, not cost.** That is a second,
instruction-level line of evidence agreeing with the previous entry's
normalization result (0.67–0.98x per unit of logged work), arrived at by a
completely independent instrument.

**Where the instruction pointer sits.** Roughly half the samples in both active
sessions are at user-range addresses backed by no loaded image, concentrated in
one 16 MB region (56620: 40.2% at `0x26ef1000000`, +4.8% and +2.9% in the two
neighbouring regions; 29932 the same shape at `0x26f4d000000`), spread over 520
and 717 distinct 4 KB pages. Three things point to JIT-compiled JavaScript and I
am labelling the inference rather than asserting it: the addresses are in the
user heap range where a runtime `VirtualAlloc`s code, the spread is far too wide
for a stub, and the idle control has essentially none of it (0.6%). Meanwhile the
idle control is 46.9% kernel — that is what a process parked in a wait looks
like. Low kernel plus high unbacked-code execution is a session running
JavaScript, not a runtime spinning on a poll. **That is the question this capture
existed to answer, and it answers it.**

One image address, `0x7ff67b4ac34f` (RVA `0x146c34f`), carries 20.7% of 56620's
samples, 6.1% of 29932's and 2.8% of the idle control's — present in all three
roughly in proportion to activity, i.e. shared hot runtime code, not a pathology
specific to one session. Not disassembled: the loaded image is
`claude.exe.old.1786403133530`, not the `claude.exe` on disk (which was replaced
at 19:08, 29 minutes before the capture), and a Bun binary has no symbols, so an
unsymbolized stack would read `claude.exe+offset` twenty times and name nothing.

**Machine-wide, the largest non-idle consumer was not claude.** `MsMpEng.exe`
(Defender) at **120.3% of a core** — roughly double either session. Recorded as
an observation, not a cause: `claude.exe` had just been rewritten (324 MB) 29
minutes earlier, so Defender scanning a fresh 324 MB binary is a live confound
for this particular minute. The cheap follow-up is sampling MsMpEng over hours,
not concluding from 60 seconds.

#### Corrections

**The "205.2% of a core during the capture" line in `capture.log` is retracted —
it is my own arithmetic error, not a fact about the process.** `wpr -stop` took
85 s to flush a 3 GB trace (19:38:24 → 19:39:49), so the script divided a 147 s
CPU delta by its hardcoded 60. Corrected: ~84% of a core across the 147 s
bracket, 66.0% during the sampled minute — against a lifetime average of 73.9%.
The session was running slightly **below** its own norm, not at double it. I had
this queued as a mandatory caveat to report and it would have been the sixth
rate-with-the-wrong-denominator error in this investigation.

**First-pass aggregation was wrong and the impossibility check caught it.** The
export is hierarchical — a process rollup row, then module, then address, then
per-thread leaves — and summing every row counted each sample up to four times.
It produced 3296 core-s of CPU in a 60 s trace on 16 cores, where the ceiling is
960. It also labelled the empty-Module rollup rows as "unbacked/JIT", inventing a
23.2% JIT figure out of a row type. Fixed by taking only rows carrying a
TimeStamp; rollup and leaf sum now agree to 0.0% for all three processes. Same
class as the `Get-ChildItem -Recurse` artifact: the schema looked fine, only the
physical impossibility of the total exposed it.

#### Caveats that stay attached to these numbers

- **`wpr` dropped 307,874 events** ("Please record this trace again"). Sampled
  leaf weight totals 800 of a possible 960 core-s = **83% coverage**, so absolute
  values may be understated by up to ~20%. The within-process *split* is much
  more robust than the totals: ETW drops when buffers fill, which is time- and
  burst-correlated, and there is no mechanism by which a drop would prefer an
  unbacked-address sample over an image sample.
- **Temporal coverage is a contiguous block**, not scattered. Both active pids
  have samples in seconds 5–54 of the trace; the missing ten sit at the head and
  tail, a view-window artifact. Neither had a single second below 10% of a core
  within that block.
- **This trace says nothing about idle burn.** Both sessions were working in
  every sampled second, so the confound that has spoiled every CPU measurement in
  this investigation is present here too. The detached sampler (step 1) is still
  the only instrument aimed at that question, and it is still running.

#### Status

Mechanism for the original slowness: still **UNDETERMINED**. But
"pid 56620 is pathologically expensive" is now retired on direct
instruction-pointer evidence — it costs what the control costs per second, and it
runs more of the time. Still open: whether it burns anything across a *verified*
idle window.

---

### 2026-08-19 08:35 — the instrument was watching the one window that never stalls

A live "it's genuinely getting slow" report. This entry is the first in the file
where the symptom and a measured variable line up on individual samples, and it
is also where the previous entries' negative verdicts turn out to have been
measured wrong.

#### The instrument had a blind spot that invalidates every earlier "not corroborated"

`ui-response-log.ps1` probes **the foreground window**. Stall rate by which app
happened to be in the foreground, whole dataset:

| foreground | stalls >100 ms | rate | worst |
|---|---|---|---|
| **powershell** | 0 / 967 | **0.0%** | 83 ms |
| LINE | 14 / 34 | 41.2% | 911 ms |
| Termius | 2 / 10 | 20.0% | 1005 ms |
| Discord | 3 / 15 | 20.0% | 245 ms |
| explorer | 4 / 30 | 13.3% | 1014 ms |
| chrome | 11 / 234 | 4.7% | 1012 ms |
| WindowsTerminal | 45 / 2851 | 1.6% | 2454 ms |

PowerShell never stalls, and PowerShell was the foreground for 967 probes —
including **all 714 probes from 02:00 to 07:00 today**, which are my own
sampler's console. Every previous entry that concluded "the logger does not
corroborate the slowness report" was reading a population dominated by the one
application that does not exhibit the symptom. That is a sampling defect in the
instrument, not a finding about the machine.

**`max_ms` is also right-censored.** `TimeoutMs = 1000` in the probe, so the
values at 1005 / 1010 / 1012 / 1014 ms are `SendMessageTimeout` hitting its own
ceiling. Those rows mean "at least 1 s, true value unknown", not "1.01 s".

#### Third memory hypothesis, killed per-sample before it was reported

The obvious mechanism — background GUI apps get their working sets trimmed under
memory pressure, so switching to them blocks the message pump while pages fault
back in — fits the app ranking (LINE holds 1253 MB private against 249 MB
resident). It is wrong, and the per-sample check killed it:

- median `fgfault` in stall windows **100**, in clean windows **111**
- **41 of 83** stalls have `fgfault` < 100, including the seven worst
  (2454, 1014, 1011, 1005, 942, 911, 904 ms) which have `fgfault` of **0**
- the largest `fgfault` ever recorded, 1,121,064 in LINE, produced max_ms **190**;
  chrome at 148,380 faults produced max_ms **4**

Grouped medians would have shown nothing either way; the counter-examples are
what settle it. Bucketed by available memory the stall rate runs 0.41% → 3.74%
and is **not monotonic** in the middle.

#### What does hold: CPU saturation, monotonic, on individual samples

First separating the confound. Windows where the foreground *changed*
(`fg_procs_seen` > 1) stall at 28.8% versus 0.9% — but their stall rate does not
track CPU at all (29.9% / 32.4% / 12.5% across rising CPU), so the probe is
catching windows mid-focus-transition. That is a probe artifact and is excluded
from everything below.

Among the 4022 windows with **no** focus switch:

| machine-wide CPU | n | stall rate | worst |
|---|---|---|---|
| 0–19% | 990 | **0.00%** | 36 ms |
| 20–29% | 1495 | **0.00%** | 95 ms |
| 30–39% | 931 | 0.75% | 1012 ms |
| 40–49% | 346 | 1.73% | 706 ms |
| 50–59% | 150 | 1.33% | 322 ms |
| 60–69% | 71 | 5.63% | 350 ms |
| 70–79% | 16 | 18.75% | 178 ms |
| **80–100%** | 23 | **65.22%** | **2454 ms** |

cpu ≥ 80% versus cpu < 40%: **65.2% against 0.2%**. Buckets are pre-specified and
equal-width over the whole dataset, not selected points — the failure mode this
file records twice. The top bucket is n=23 and that is the main weakness here.

The machine reaches ≥70% only **1.1% of the time**, so this describes rare severe
episodes, not the chronic feel.

#### Who saturates it — and it is not claude

Cross-referencing the high-CPU stall windows against the 5-second per-process
sampler: **pid 56620 accounts for a mean 5.6% of machine CPU** during them.
Restarting it, which the previous entry recommended, would not have touched this.

Full per-process accounting (performance counters, not `Get-Process`, which
silently under-reports protected processes):

| | % of a core |
|---|---|
| **MsMpEng.exe (Defender)** | **137.2** |
| claude 29932 | 99.0 |
| claude 56620 | 81.9 |
| System | 37.8 |
| dwm | 19.7 |
| SearchIndexer | 13.2 |

**Defender is the largest single non-idle consumer on this machine**, and no scan
is running — `FullScanOverdue` false, last quick scan 08-17, no full scan on
record. That is real-time protection alone. Last night's elevated ETW trace
measured it at 120.3% and this entry's previous version dismissed that as
confounded by `claude.exe` having been rewritten 29 minutes earlier. **That
dismissal was wrong**: two independent instruments 24 hours apart, with no binary
rewrite the second time, both land at 120–137% of a core.

#### What is NOT established

That Defender causes the stall episodes. It is the largest *baseline* consumer;
the logger records `cpu_pct` but not *which processes* were hot, so during the
80–87% episodes there is no attribution. Defender at ~1.3 cores makes crossing
the threshold likelier, and that is the whole claim.

Closing that gap is cheap and is the right next change: record the top three
processes by CPU in each window, into a new file so the existing schema is not
broken mid-stream. Then the next episode names its own cause instead of being
reconstructed days later.

#### Correction, same morning: the 137.2% was an 8-second sample

The entry above calls `MsMpEng.exe` "the largest single non-idle consumer" at
137.2% of a core. That figure came from a single 8-second counter delta. Measured
properly over 3 minutes, 36 samples:

| | MsMpEng, % of one core |
|---|---|
| min | 4.5 |
| p25 | 14.6 |
| **median** | **26.1** |
| p75 | 37.0 |
| p90 | 65.0 |
| max | 122.3 |
| **mean** | **31.5** |

Defender averages **0.32 of a core**, not 1.37. It bursts to 1.2 cores and the
bursts do line up with the machine's own peaks (122.3% at 09:08:07 coincides with
the machine's 67.5% high), but against a machine that is running 6.4 cores busy,
excluding Defender entirely would remove about **5% of the load**. It cannot
prevent the 80%+ episodes that the stall analysis identified.

Last night's elevated ETW figure of 120.3% was a 60-second average and remains
the better-founded number, but it was taken 29 minutes after `claude.exe` was
rewritten to 324 MB — the confound the entry above claimed to have dismissed. The
dismissal rested on today's 137.2%, and today's 137.2% does not survive. **Both
readings are now back to being single elevated observations of a bursty process,
and the "two independent instruments agree" claim is withdrawn.**

This is the ninth rate-reported-from-too-short-a-window in this investigation and
the first one where the bad number had already been used to recommend a change to
the user's security configuration. The recommendation was withdrawn before the
change was made.

What the 3-minute window does show is that there is **no single culprit**. The
machine carries roughly 6 cores of steady load spread across two claude sessions
(~1.8 cores), Defender (~0.3), System, dwm, Slack, SearchIndexer, grok, turbo,
pwsh and warp-svc — a long tail, none dominant. The stall episodes are whatever
occasionally pushes that past ~11 cores, and the logger still does not record
per-process attribution at those moments, so that remains unidentified.

#### Second correction, same morning: what the CPU finding is and is not

Three re-cuts of the same file, no new capture. Two of them cut down claims made
two sections above.

**The blind spot was confined to one day, and the sweeping version was wrong.**
The entry above says every earlier "the logger does not corroborate it" was
measured on a powershell-dominated population. Foreground composition by day:

| day | n | top three foreground apps | powershell |
|---|---|---|---|
| 08-17 | 297 | WindowsTerminal 89%, remoting_desktop 5%, powershell 3% | **3%** |
| 08-18 | 2848 | WindowsTerminal 87%, chrome 6%, powershell 4% | **4%** |
| 08-19 | 1107 | **powershell 81%**, WindowsTerminal 13%, chrome 5% | **81%** |

The 08-18 entry's negative verdict rested on 2848 probes that were 87%
WindowsTerminal. A powershell blind spot does not touch it. Only **today** is
contaminated, by my own sampler's console. Holding the app constant shows the
size of the distortion:

| day | stall rate, all fg | same day, WindowsTerminal only |
|---|---|---|
| 08-17 | 3.70% (n=297) | 3.42% (n=263) |
| 08-18 | 2.21% (n=2848) | 1.37% (n=2475) |
| 08-19 | **0.99%** (n=1107) | **2.80%** (n=143) |

08-17 and 08-18 barely move. Today nearly triples, and today is the day that
looked healthiest. **The correct claim is narrower and still fatal to the same
conclusions: foreground composition drifts between days, so no day-level stall
rate in this file was ever comparable to another day's.** The sweeping version
above is withdrawn.

**The gradient survives with the foreground app held constant.** This is the one
re-cut that makes the finding stronger. Restricting to WindowsTerminal only
(n=2809 no-switch windows, a single application) removes composition as an
explanation entirely:

| machine CPU | n | stall rate | worst |
|---|---|---|---|
| 0-19% | 330 | **0.00%** | 14 ms |
| 20-29% | 1156 | **0.00%** | 85 ms |
| 30-39% | 773 | 0.52% | 945 ms |
| 40-49% | 329 | 2.13% | 706 ms |
| 50-59% | 133 | 1.50% | 322 ms |
| 60-69% | 54 | 5.56% | 350 ms |
| 70-79% | 13 | 15.38% | 178 ms |
| **80-100%** | 21 | **66.67%** | **2454 ms** |

66.7% against 0.2%, one app, same shape as the pooled version including the same
non-monotonic dip at 50-59%.

**n=23 was really n=3.** Clustering the top-bucket windows with a 5-minute gap
rule:

| episode | windows | stalls | worst |
|---|---|---|---|
| 08-17 21:40 | 6 | 4 | 310 ms |
| 08-18 19:24 | 9 | 3 | 286 ms |
| 08-18 22:48 | 8 | 8 | **2454 ms** |

Three episodes, not 23 independent trials, and the 2454 ms figure quoted twice
above comes entirely from the third one. This is a weaker evidence base than
"n=23" implied and the honest statement of it. Checked whether these were
self-inflicted -- the ETW work that night finished at 20:03 (`cpu.etl` 19:39,
the 119 MB export 20:03), nearly three hours before the 22:48 episode, and pid
56620 held 3-5 children throughout. Not my own load.

**And it does not explain the report that started this entry.** At 08:35, when
the machine was described as genuinely slow, machine CPU was 45.4% -- the 40-49%
bucket, 2.13% stall rate, worst 706 ms. The saturation mechanism is real and it
describes **rare severe episodes**, three of them in three days. The chronic
"it feels slow" at 45% CPU remains unexplained.

**No blind spot in the new sampler.** `load-attrib-log.ps1` was registered as a
scheduled task at 09:11:13, and a task that grabs the foreground is exactly how
the 08-19 contamination happened in the first place. Checked rather than assumed:
every `ui-response.csv` row after 09:11 reads `fg_proc = WindowsTerminal`,
`fg_procs_seen = 1`. It runs windowless. First rows:

```
09:11:31  machine 34.7% = 5.55 cores  claude(56620) 97.3  System 67.2  claude#1 64.1  MsMpEng 30.3  dwm 29.9
09:11:47  machine 30.5% = 4.87 cores  claude(56620) 106.2 claude#1 56.4 System 50.6  dwm 33.2  MsMpEng 23.4
```

It records `busy_cores` and `accounted_cores` separately (5.55 against 4.32) so
the unattributed remainder is visible instead of hidden.

#### Third correction: the exclusions I recommended were already in place

Asked to verify the Defender exclusion state properly rather than assert it.
`Get-MpPreference` unelevated does not return null or an empty list for
`ExclusionPath` -- it returns the literal string
`"N/A: Must be an administrator to view exclusions"`, so `.Count` is 1 and a
naive truthiness check reports "one exclusion configured". That is a worse
failure mode than null because it passes every has-a-value guard.

Two channels that do work without elevation:

- **Group policy exclusions:** `HKLM\SOFTWARE\Policies\Microsoft\Windows
  Defender\Exclusions\{Paths,Processes}` -- **key does not exist**. A real
  negative. The local key `HKLM\SOFTWARE\Microsoft\Windows Defender\Exclusions`
  is **ACCESS DENIED**, which is not the same as empty and is not recorded as
  such.
- **Event 5007 (configuration changed)** in
  `Microsoft-Windows-Windows Defender/Operational`, which logs exclusion
  registry writes with old and new values. The log spans **2025-07-24 to now,
  1410 events of ID 5007, 10.4 MB against a 16 MB cap, so it has not wrapped** --
  a complete change history.

24 of those 5007 events match "Exclusion"; two are feature flags
(`TPExclusions`, `MpFC_EnableTPExclusionsSCCMNonMDEAttach`). The remaining
**22 are real exclusions, every one of them an addition (old value empty), with
zero removals**:

| when | exclusion |
|---|---|
| 2026-08-02 | `C:\Users\LZong\.claude\projects` |
| 2026-07-31 | **`C:\dev`**, `C:\Users\LZong\projects`, `AppData\Local\pnpm`, `AppData\Local\npm-cache`, `pnpmGlobal`, `C:\nvm4w` |
| 2026-06-08 | `.fly\bin`, `C:\nvm4w\nodejs` (and `node.exe`), `codex.ps1`/`.cmd`/`.exe`, `nvm.exe`, `Git\bin\bash.exe`, `Git\usr\bin\bash.exe`, `@openai/codex` |
| 2026-06-05 | `@openai/codex` |
| 2026-04-14 | processes: `FreeFileSync.exe`, `FreeFileSync_*.exe` |

**`C:\dev` has been excluded since 2026-07-31**, which is before every
measurement in this file. The recommendation two sections above -- withdrawn on
the grounds that it would only remove about 5% of machine load -- turns out to
have had even less headroom than that: its largest item was already done, and
Defender still averages 0.32 of a core with it in place. That is the third
independent reason the Defender line goes nowhere, and it closes it.

The genuine remainder, never excluded: `C:\Users\LZong\.claude` above
`projects`, `.local\bin`, `Scripts`, `AppData\Local\Temp\claude`, the processes
`claude.exe` / `bun.exe` / `pwsh.exe` / `git.exe`, and the WSL `ext4.vhdx`.

**Limit of this inference.** Current state is reconstructed from a complete
change log with no removal events, not read from the live list, which needs
elevation. The log not having wrapped and every addition post-dating its start
is what makes the reconstruction sound -- but it remains a reconstruction.

---

### 2026-08-19 16:44 — a live report the instruments all called healthy

A second "it feels slow again", at a moment when every instrument disagreed.
Machine CPU 30-47%, disk 26% busy with a queue of 0.53, and **one** stall over
100 ms in 91 windows that hour. Hard page reads were 4,756/s in an 8-second
snapshot, which looks alarming until compared against the baseline the logger has
been keeping all along:

| hard page reads/s | |
|---|---|
| whole dataset p50 | 40 |
| p90 | 1,437 |
| p99 | 3,979 |
| the 8 s snapshot | 4,756 |
| whole dataset max | 33,224 |

The 16:00 hour is one of the *quietest* of the day by paging (p50 82, p90 1,106)
against 11:00 (p50 1,912, p90 3,199). Tenth candidate short-window rate error in
this investigation, and the first one caught before it was reported.

Asked what "slow" meant. Two answers: **Claude Code / terminal response**, and
**window switching and dragging**. The second is what `ui-response-log.ps1`
claims to measure, and it says the hour was clean -- so the probe is measuring
the wrong thing.

#### A hypothesis about the probe, and its refutation

The probe only ever touches the **foreground** window, whose pages are resident
by definition. Switching *to* an app is a different operation. With commit at
62 GB on 31 GB of RAM, background windows should be trimmed and slow to answer.

Refuted directly: probing all 21 visible top-level windows with `WM_NULL`, every
background window answered in **0.2 to 16.4 ms**, none over 100 ms, against 0.25
ms for the foreground. The message pump is not paged out.

But the same output showed the trimming is real and severe:

| window | resident / private |
|---|---|
| Telegram | 74 / 950 MB = **8%** |
| TextInputHost | 27 / 302 = 9% |
| PowerToys | 12 / 105 = 11% |
| sublime_text | 12 / 83 = 14% |
| LINE | 304 / 1269 = 24% |

#### Accounting for the commit: no leak, 512 processes

Committed 62.1 GB, of which per-process private bytes are 48.1 GB (78%), pool
paged 5.21 GB and nonpaged 2.38 GB. The remainder is ordinary kernel overhead.
**There is no single leak.** The total `VirtualBytes` of 871,832 GB is not one
either -- Chrome reserves ~3.6 TB of address space per process for the V8 cage,
and reporting that as a leak is a trap this file will not fall into twice.

| image | private | processes |
|---|---|---|
| chrome | 7.26 GB | 56 |
| claude | 5.60 GB | 3 |
| python | 5.10 GB | 18 |
| node | 3.24 GB | 21 |
| WindowsTerminal | 3.32 GB | 2 |
| vmmemWSL | 2.93 GB | 1 |
| svchost | 1.72 GB | 100 |
| logioptionsplus_agent | 1.16 GB | 1 |

#### The actionable finding: MCP servers are duplicated per session

48 python and node processes hold 10.0 GB of private bytes. **Eleven of them are
idle -- under 1% of a core over a 10 s measurement -- and hold 5.1 GB**, on a
machine with 4.2 GB available.

| MCP server | instances | private each | total | CPU |
|---|---|---|---|---|
| `semble` | **3** | 604-1081 MB | **2,289 MB** | 0.0% |
| `headroom mcp serve` | **4** | 540 MB | **2,159 MB** | 0.0% |
| `serena start-mcp-server` | 1 | 1,588 MB | 1,588 MB | 1.5% |

Every Claude Code session spawns its own copy of each stdio MCP server. Serena
was already converted to a shared HTTP singleton and correspondingly has exactly
one instance; nothing else followed. `semble` and `headroom` together hold
**4.4 GB doing nothing**, at residencies of 0-24%, which is roughly the entire
available-memory headroom of the machine.

Also present, small but confirming the pattern: `mcp-remote` x10, UnityMCP
`server.py` x3, `serena-stdio-bridge` x5, and five processes whose parent is dead
(two `serena-http-singleton` daemons, a `claude-code-router` daemon, a bare
`node -` holding 177 MB, and `ccstatusline`).

This is the first thing found in this investigation that is both large and
directly reversible. It is not the CPU-saturation mechanism recorded earlier --
it is a plausible mechanism for the *chronic* feel that CPU saturation explicitly
failed to explain, since it predicts exactly what was observed: every application
trimmed to a fraction of its working set, so returning to any of them costs a
page-in, while the foreground window the probe watches is always fast.

**Not established:** that freeing this memory removes the subjective slowness.
That is a prediction, and closing sessions is the user's call, not something this
repo does.

#### Correction to the entry above: it is not per session, it is per grok run

The entry above says "every Claude Code session spawns its own copy of each
stdio MCP server". That is wrong, and the error was walking the parent chain
only one level. Every parent printed was a 1 MB launcher shim -- a uv cache or
pipx `Scripts\*.exe` -- which looks like the owner and is not. Walking to the
real owner reverses the conclusion:

| session | semble | headroom |
|---|---|---|
| claude 73180 | 0 | 1 |
| claude 56620 | 3 | 3 |

Sessions are not the multiplier. All three `semble` instances hang off **one**
session, through three separate `grok.exe --prompt-file` subtrees:

```
python(86984) <- python(30516) <- semble.exe(26284) <- uv.exe(30852)
              <- uvx.exe(75572) <- grok.exe(76360) <- pwsh.exe(20484) <- claude.exe(56620)
```

The multiplier is **one `grok.exe` invocation**. Each one re-reads the MCP
config and starts the whole set from scratch.

#### Measuring the fan-out instead of guessing at it

Four grok runs were live, aged 6 to 29 minutes, all launched by one session's
shell tool against the same project:

| | |
|---|---|
| grok runs | 4 |
| processes in their subtrees | **96 of the machine's 566 (17%)** |
| private bytes held | **7,902 MB** |
| CPU across all 96 | 0.3-2.5% of one core |

One run costs 24-26 processes and 1.7-2.2 GB. Per fan-out: 24 `python`
(5,720 MB), 12 `node` (1,089 MB), 8 `uv`, 8 `gk`, 8 `cmd`, 20 `conhost`.

So the figure above was not 4.4 GB, it was 7.9 GB, and the 512-process baseline
recorded earlier was measured *during* a fan-out -- roughly a fifth of it was
this.

#### What is actually chronic, once the fan-out is excluded

Three processes over 300 MB sit outside every grok subtree: `serena`
(1,606 MB), one `headroom` belonging to session 73180 (540 MB), and `tsserver`
(1,720 MB, against `c:\dev\sugar-dating`). Genuinely orphaned: **177 MB**, a
bare `node -` whose parent is dead. That is all. There is no accumulating pool
of leftover MCP servers.

#### What this retracts, and what survives

Retracted: "the first thing found that is both large and directly reversible",
and the implied recommendation to close sessions. Closing a session is not the
lever, because the memory does not belong to sessions. Nothing was ever acted
on, so nothing needs undoing.

Survives, and is stronger: at the moment of the "it feels slow again" report,
17% of the machine's processes and 7.9 GB of private bytes belonged to four
concurrent agent runs in the session the user was typing into. That is a
specific, dated answer to "why now" rather than a chronic condition, and it
covers **both** symptoms the user named -- the terminal that felt slow is the
same session hosting the fan-out, which also averages about one core on its
own.

**Free falsifiable test, no intervention required:** when the four runs finish,
available memory should rise by roughly 7.9 GB and the trimmed residencies
recorded above should recover. If it does not, the memory is not the fan-out's
and this entry is wrong too.

---

### 2026-08-19 — why the fan-out is expensive: a singleton that is down, and a state file that says otherwise

The previous entry established that the multiplier is one `grok.exe` run, not one
session. This is the reason each run costs so much.

Grok does not have its own MCP list -- its `~/.grok/config.toml` contains no
`[mcp_servers]` at all. Its README states the sources are `config.toml`,
plugins, **`~/.claude.json`, and `.mcp.json`**. It inherits Claude Code's set
wholesale.

#### Two defects, and they mask each other

**The semble HTTP singleton is down.** `~/.claude.json` declares semble as
`http://127.0.0.1:9131/mcp`. Nothing is listening on 9131; a POST is refused.
Its own state file disagrees:

```json
"healthy": true,  "startedAt": "2026-08-19T02:22:13.685Z",
"lastHealthyAt": "2026-08-19T02:22:34.637Z",
"daemonPid": 7420,  "gatewayPid": 59372
```

Both pids are gone. The gateway came up, passed a health probe 21 seconds
later, then died -- and the file still reads `healthy: true`. Anything trusting
that file believes the singleton is up. Same failure shape as the brightness and
mutex proxies recorded earlier in this investigation: a status indicator that
survives the thing it indicates.

**The project file pins the stdio form.** `C:\dev\sugar-dating\.mcp.json`
declares `uvx --from semble[mcp] semble`. The singleton's own README says, in
these words: *"Do not put `uvx --from semble[mcp] semble` in per-project
`.mcp.json`."* Its sibling `.mcp.json.bak-semble-singleton` is byte-identical to
it -- the conversion was backed up and never applied, or was reverted.

The two defects hide each other. Because the project pins stdio, semble keeps
working in that project, so the dead singleton produces no visible symptom --
only a memory bill.

#### What the stdio form costs, measured

Four semble stdio stacks were live, five processes each:

| component | per stack |
|---|---|
| `python.exe` (the actual server) | 604 / 604 / 604 / 1,080 MB |
| `uv.exe tool uvx` | 118 / 127 / 151 / 164 MB -- resident supervisor, does nothing |
| `uvx` + `semble.exe` + python shim | 1 MB each |

About **3.4 GB**, 43% of the 7.9 GB fan-out. The 561 MB of `uv.exe` is pure
launcher overhead that never exits.

#### Why nobody noticed the gateway dying

The supervisor log covers 2026-08-01 onward: 247 lines, 143 of them
`Start-Process start-gateway.cmd`. Every failure line -- `gateway stopped`,
`watchdog failure` -- falls on **08-01 and no later**. From 08-03 to today there
are 152 launch lines and zero stop lines, because the persistent supervisor is
not running; the README states SessionStart hooks call `ensure`, which
`Start-Process`es the gateway and exits. Each line is one session start, not one
supervised restart. When the gateway dies afterwards, nothing observes it and
nothing writes it down. The gateway's own log has an mtime of 08-01 14:01,
eighteen days stale across roughly 40 launches since.

The 08-01 failures are worth recording separately, because the watchdog was
restarting **healthy** gateways:

```
watchdog failure 1/3: 200
watchdog failure 2/3: 200
watchdog failure 3/3: 200
watchdog restarting gateway pid=21276
gateway stopped code=watchdog:200; restart=1
```

HTTP 200 counted as a failure. Whether that logic is still present is not
established -- it has produced no log line since 08-01, which is equally
consistent with it being fixed and with the supervisor never running again.

Launches per day: 31 / 30 / 15 / 30 on 08-10 to 08-13, then 10, 4, 1, 1, 2.
That window coincides with the dwm degradation onset recorded elsewhere in this
file. **Coincidence only** -- different subsystem, no mechanism proposed, and
the count more likely tracks how many sessions were started per day.

#### Order matters

Fixing `.mcp.json` first, while 9131 is down, removes semble from that project
entirely. The singleton has to be up and verified by an actual probe -- not by
reading its state file -- before the project file changes.

`headroom` is a separate problem: global stdio, 540 MB per run, and no singleton
exists to point it at.

Nothing here was changed. This entry records the mechanism only.

---

### 2026-08-19 — the singleton was not a singleton; fixed, at the user's direction

Everything below was changed **outside this repo**, on the user's explicit
instruction. This repo still changes nothing; it records what was done and what
the measurements showed.

Two corrections to the entry above first.

**"byte-identical" was wrong.** `.mcp.json` and `.mcp.json.bak-semble-singleton`
are 154 and 145 bytes, 9 lines each, and the 9-byte difference is exactly the
CRLF/LF line endings -- 9 CR in one, 0 in the other. Content-identical, not
byte-identical. The conclusion it supported is unchanged.

**The watchdog-restarts-healthy-gateways line needs no retraction, but the
`ensure` failure has a better explanation than "broken".** `ensure` failed once
with `did not become healthy (ECONNREFUSED)`, then succeeded unchanged after a
foreground run of `start-gateway.cmd` had warmed the `npx -y supergateway`
cache. That ordering is suggestive, not proven -- one trial each.

#### The singleton forks one server per request

Bringing 9131 up exposed the real defect. `start-gateway.cmd` ran supergateway
with no `--stateful`, and its own startup banner says `Running stateless
server`. In that mode it forks a **fresh stdio child per request**:

```
listener node(80384)
  |- cmd -> uvx -> uv(124MB) -> semble -> python -> python(604 MB)
  |- cmd -> uvx -> uv(127MB) -> semble -> python -> python(604 MB)
  +- cmd -> uvx -> uv(126MB) -> semble -> python -> python(605 MB)
subtree: 2,258 MB across 19 processes
```

Three children for exactly three requests -- one `ensure` health check and two
`status` probes -- and none of them exited afterwards.

So switching `.mcp.json` from stdio to HTTP did not remove the duplication. It
converted *one server per client process, dying with the client* into *one
server per request, never reaped*. Strictly worse. Reported before going
further, since this was a regression caused by the change itself.

#### A test that could not discriminate, and one that could

`--stateful` was added along with `--sessionTimeout 300000`. Retesting with
three bare `initialize` calls gave three children again -- but that result is
worthless, because three independent initializes *are* three sessions, and one
child each is correct behaviour. The test had no discriminating power.

The test that does: keep the session id.

| | child servers |
|---|---|
| before | 3 |
| after 1 `initialize` + 3 requests carrying its `Mcp-Session-Id` | **4** |

Delta **+1**, not +4. The session id is honoured and the child is reused. So
per-session, not per-request:

| mode | one semble per | reaped |
|---|---|---|
| stateless (as found) | request | never |
| stateful + sessionTimeout (now) | session | on idle timeout |
| plain stdio (before all this) | client process | when the client exits |

Whether the idle reaping actually fires is **still under test** and is the
claim that decides whether this is better than plain stdio or merely equal.

#### One hazard worth recording

`semble-http-singleton.mjs restart` is unsafe while other clients are running.
Its `stop()` calls `killSembleTrees()`, which matches *any* command line
containing both `uvx` and `semble[mcp]` -- including servers belonging to
unrelated processes. A grok run was still in flight, so the gateway subtree was
killed directly by its recorded `gatewayPid`, verified by command line first in
case the pid had been recycled. The grok run survived.

#### Changed

- `C:\dev\sugar-dating\.mcp.json`: stdio -> `http://127.0.0.1:9131/mcp`.
  Tracked by git, currently modified and uncommitted. Backup:
  `.mcp.json.bak-20260819-stdio`.
- `~/.semble/http-singleton/start-gateway.cmd`: added `--stateful
  --sessionTimeout 300000`. Backup: `start-gateway.cmd.bak-20260819-stateless`.

`headroom` is untouched and still stdio at 540 MB per run, with no singleton to
point at.

#### The reaping claim, resolved

The entry above left one thing under test: whether `--sessionTimeout 300000`
actually reaps idle sessions, which is what decides whether stateful beats plain
stdio or merely ties it. Watched for 390 s:

| t | child servers | gateway subtree |
|---|---|---|
| +150 s | 4 | 2,990 MB |
| +180 s | 2 | 1,530 MB |
| +210 s | 1 | 785 MB |
| +240 s | 2 | 1,586 MB |
| +270 s | 1 | 791 MB |
| +390 s | 1 | 1,523 MB |

It reaps, and it converges. The rise at +240 s is a new session arriving, reaped
again by +270 s -- which is the behaviour wanted, not a failure. So the ordering
stands as claimed: stateful with an idle timeout is better than per-client
stdio, not equal to it.

Separately, and **not** attributable to the gateway: machine available memory
fell to 0.80 GB at +330 s while the gateway subtree sat flat at 1,523-1,524 MB
across those same samples. Something else consumed it. Source unidentified, and
no rate is inferred from these points -- that error has been made enough times
in this file already.

---

### 2026-08-19 — headroom: the singleton was the wrong lever

Researched what a singleton for `headroom mcp serve` would look like, the way
semble got one. The answer is that it should not be built, for three
independent reasons, and the third one is a 93% fix that a singleton could not
have delivered.

**1. It cannot share anything.** `headroom mcp serve --help` offers only
`--proxy-url`, `--direct` (deprecated) and `--debug`. Transport is stdio, with
no HTTP or SSE mode. So a singleton could only be a supergateway wrapper, and
that gives one child per session -- the same limitation just measured on semble.
Four concurrent runs would still be four servers.

**2. The thing it exists to talk to is not running.** The MCP server's
documented job is to fetch original content from the proxy at
`http://127.0.0.1:8787`, and direct store access is deprecated and ignored.
Nothing is listening on 8787. Three `headroom mcp serve` instances holding
1,619 MB are attached to a proxy that does not exist.

**3. The 540 MB is not what it looks like.** Two hypotheses died first, and both
deserve recording because both were plausible:

- *torch*, 468.5 MB on disk in the pipx venv. **Refuted directly**: the three
  live servers load 66 modules between them and **zero** are torch, c10, cudnn
  or onnxruntime. Largest mapped module is scipy's OpenBLAS at 19.5 MB. Disk
  size is not RSS.
- *Kompress loading a model*, the known CPU offender on this machine.
  **Refuted**: `HEADROOM_DISABLE_KOMPRESS=1` is set at User scope and visible.

What it actually is: numpy's bundled OpenBLAS committing per-thread arenas
sized by core count. Sixteen cores here.

| | private bytes, two runs |
|---|---|
| `import numpy`, default | 498.8 MB / 499.1 MB |
| `import numpy`, `OPENBLAS_NUM_THREADS=1` | **16.5 MB / 16.7 MB** |
| `import headroom.cli.mcp`, default | 517.0 MB / 517.0 MB |
| `import headroom.cli.mcp`, `OPENBLAS_NUM_THREADS=1` | **35.0 MB / 34.7 MB** |

**517 MB to 35 MB, from one environment variable, reproducible to within
0.3 MB.** Three instances would fall from 1,619 MB to about 105 MB. That scales
with however many instances exist, which is exactly what a singleton cannot do.

The right change is therefore to scope `OPENBLAS_NUM_THREADS=1` to the headroom
MCP entry in `~/.claude.json` via its `env` field, **not** to set it user-wide:
the same variable would throttle every other numpy consumer on the machine,
and a process doing real numerical work should keep its threads. A thin MCP
shim that forwards HTTP does no numerical work at all.

Honest limits on the number: private bytes is *commitment*, not residency --
working sets in the same test were 30-63 MB. Commitment is nevertheless the
binding constraint here, since this machine runs 62 GB committed against 31 GB
of RAM, which is the whole reason paging came up in this investigation.

Four measurement shapes failed before this one produced a number, all
mechanical, all recorded in the scratchpad script: an invalid
`-RedirectStandardInput 'NUL'`; `-ArgumentList` splitting a `-c` payload on
spaces so python saw only `import`; an in-process RSS probe returning 0.0 MB;
and -- the instructive one -- measuring the venv's `python.exe`, which is a
1 MB redirector stub that re-launches the base interpreter as a *child*. That
last one returned a confident, identical 4.6 MB for every case including bare
numpy, which is how it gave itself away.

Nothing was changed. This is research.

#### It transfers to semble, which makes today's singleton the small lever

The obvious next question after the headroom result: semble is also Python and
also ~600 MB. Same test, same machine, two runs per case:

| | private bytes |
|---|---|
| `import numpy`, default | 498.9 MB / 498.9 MB |
| `import numpy`, `OPENBLAS_NUM_THREADS=1` | 16.8 MB / 16.6 MB |
| `import model2vec`, default | 510.7 MB / 510.4 MB |
| `import semble.mcp`, default | 537.1 MB / 537.3 MB |
| `import semble.mcp`, `OPENBLAS_NUM_THREADS=1` | **55.1 MB / 55.0 MB** |

`model2vec` costs 510.7 MB against numpy's 498.9 -- about **11 MB of its own**.
semble depends on model2vec and tokenizers, so an embedding model was the
natural suspect for the 600 MB. It is not there at import time. The mass is
OpenBLAS thread arenas, on both servers, from the same numpy.

So the honest accounting of today's work: **the singleton was the small lever.**
It is not wrong -- it does reap idle sessions, which was measured -- but it
addressed how *many* servers exist, when about 90% of what each one holds is
an arena that a scoped environment variable removes. Four concurrent stdio
semble servers with `OPENBLAS_NUM_THREADS=1` would cost roughly 220 MB, which
is less than the singleton's own subtree measured at 1,523 MB. The two compose;
only one of them is large.

One limit that must not be glossed: 55 MB is the cost at **import**. The live
servers were 604 and 1,080 MB, so they allocate beyond import for real work --
index caches and so on. What this removes is the ~480 MB OpenBLAS component per
instance. It does not shrink a working server to 55 MB, and no claim here says
it does.

Where it would go, if applied:

- semble via the singleton: `set OPENBLAS_NUM_THREADS=1` inside
  `run-semble-stdio.cmd`, so it scopes to the semble child only.
- semble via any project still pinning stdio: the `env` field of that
  `.mcp.json` entry.
- headroom: the `env` field of its `~/.claude.json` entry.

Never user-wide. Serena is the obvious next candidate at 1,653 MB and is
**untested** -- and unlike these two it does real numerical work, so throttling
its BLAS threads is not automatically free.

Still nothing changed. Still research.

#### Applied, and it lands where predicted

Changed outside this repo, on instruction. Backups alongside each file.

- `~/.semble/http-singleton/run-semble-stdio.cmd`: `set OPENBLAS_NUM_THREADS=1`
  and `OMP_NUM_THREADS=1` before the uvx line.
- `~/.claude.json`, `mcpServers.headroom.env`: the same two variables. The file
  is written live by three running sessions, so it was copied first and the edit
  was a single targeted replacement; afterwards it parses, keeps all 114
  top-level keys and all 4 MCP servers.

Restarting the gateway (targeted kill by recorded `gatewayPid`, never
`restart`, whose `stop()` would kill unrelated clients' servers) and re-running
the same three-probe test:

| | before | after |
|---|---|---|
| private per child server | 604 MB | **122 MB** |
| gateway subtree, 3 sessions | 2,258 MB | **825 MB** |
| child servers over 300 MB | 3 | **0** |

482 MB off each child, against a predicted OpenBLAS arena of about 480 MB.
And the caveat held: 122 MB, not the 55 MB measured at import, because a live
server allocates past import. The prediction was for the delta, and the delta
is what landed.

#### Serena: the mechanism does not transfer, tested not assumed

Serena's site-packages contains **no numpy, scipy or sklearn** -- only tiktoken.
Checked against the live processes rather than inferred from the package list:
**0 BLAS or numpy modules mapped** in either running server. `OPENBLAS_NUM_THREADS`
would do nothing for it.

Its 1,672 MB is something else, and probably not waste: working set is **98 MB**.
The rest is committed and paged out -- a symbol index for a large repository.
The second Serena, on a smaller project, holds 242 MB by the same mechanism.
Nothing here to trim.

#### The six worktrees: correctly, nothing

Six other worktrees still pin stdio semble in `.mcp.json`. Each is on its own
branch with the file **clean**, so that is the committed content, not a local
edit. master now carries the HTTP form, so they inherit the fix on their next
merge. Editing them now would create six local modifications that conflict with
exactly that merge. None of them has a semble running at the moment, so the
cost of waiting is currently zero. Left alone deliberately.

#### The dead proxy does not break the MCP server

The entry above raised this as a reason to question whether these servers
should exist at all. Answered by speaking the protocol to one rather than
reasoning about it:

```
initialize      OK   serverInfo = headroom 1.28.0
tools/list      OK   headroom_compress, headroom_retrieve, headroom_stats
headroom_stats  isError = false
    Mode: token | 0 API requests | unknown
    Compression: no requests compressed yet
```

stderr empty. The server starts, advertises its tools and answers a call with
no proxy anywhere. It is inert, not broken.

`headroom_retrieve` is the tool that needs the proxy, and it is only invoked in
response to compression markers that the proxy itself produces. No proxy, no
markers, so that path is never entered -- which the stats output confirms by
reporting zero requests ever compressed. Not tested directly, because it takes
a real compression hash as an argument and no such hash exists on this machine.
That absence is itself the evidence.

Left running by decision. With the env fix in place a new instance costs
roughly a hundred MB rather than 540, so the cost of leaving it is small.

### 2026-08-20 21:10 -- "it feels slow again"

Different mechanism from every previous episode. Not CPU, not dwm, not MCP
fan-out: eleven gigabytes are being held by a virtual machine that is not
using them.

#### The usual suspects were all clear

Sixty seconds of counters at the moment of the report:

```
cpu utility                39.4 %   mean     74.3 % max
cpu perf vs nominal       115.4 %           155.4 % max   (above nominal, not throttled)
run queue                  0.63 threads       4.00 max    (16 cores)
disk read latency         552.6 us            1,980 us max
disk queue                 0.00
```

No saturation, no throttling, no disk bottleneck. The 80%-CPU stall signature
this investigation has been chasing was not present.

#### The processes do not add up to the memory

89.8% of 32 GB in use, and available memory swinging down to 641 MB. But a
census of every process -- read through performance counters, because
`Get-Process` was denied on 179 of 450 and an access denial is not a zero --
found only **13,091 MB of private working set across all 450 processes**.

Nearly 19 GB was somewhere else. Kernel pool accounted for about 5 GB of it.
The rest showed up in one counter:

```
\Hyper-V VM Vid Partition(_total)\Physical Pages Allocated   12,415 MB
vmmemWSL working set (Get-Process)                              726 MB
```

The process view understates the WSL VM by a factor of seventeen. Guest RAM is
backed by host pages that belong to no process working set, so every tool that
lists processes -- Task Manager included -- misses it.

#### The VM is holding memory nothing wants

Inside the guest:

```
              total   used    free   shared  buff/cache  available
Mem:          12072   1068   10956        1         260      11003
```

One gigabyte in use. Eleven free. Every process in the guest added together is
under 400 MB of RSS, the largest being a claude at 165 MB. There are no OOM
kills. `Shmem` is 1.7 MB, so it is not tmpfs hiding it.

Configured cap is `memory=13002342400` = 12,400 MB, and the host has allocated
12,415 MB. **The VM sits at its ceiling to within 15 MB** and stays there.

#### Reclaim is configured and does nothing

`.wslconfig` already carries `[experimental] autoMemoryReclaim=gradual`. Two
things had to be checked rather than assumed, and both came back against the
easy answer.

The setting is in the right section: the WSL docs as of 2026-06-02 still list
`autoMemoryReclaim` under `[experimental]`, not promoted to `[wsl2]` the way
`networkingMode`, `dnsTunneling`, `firewall` and `autoProxy` were. Placement is
not the defect. Worth noting anyway that the documented default is `dropCache`
and `gradual` is the slower option, so this configuration reclaims less than no
configuration would.

And it does not matter either way, because `autoMemoryReclaim` reclaims *cached*
memory, and the guest's cache is 260 MB. The 11 GB is not cache. It is memory
the guest allocated once, freed, and the host never took back.

Measured rather than argued -- 21 minutes of sampling, changing nothing:

```
21:12:22  vid 12415 MB   guest used 1024 MB  free 11035 MB  cache 195 MB
21:15:30  vid 12415 MB   guest used 1054 MB  free 10982 MB  cache 240 MB
21:20:42  vid 12415 MB   guest used 1043 MB  free 10997 MB  cache 231 MB
21:25:53  vid 12415 MB   guest used 1022 MB  free 11035 MB  cache 199 MB
```

Fourteen consecutive samples, identical to the megabyte. `gradual` is not
gradually doing anything.

#### What filled it: not updatedb

The obvious suspect was the nightly `updatedb` scan across `/mnt` over 9P
recorded earlier in this investigation. **Refuted.** `/mnt` is in `PRUNEPATHS`,
`drvfs` and `9p` are both in `PRUNEFS`, and last night's run took 20 seconds:
`plocate-updatedb.service` started 00:00:44, `plocate.db` written 00:01:04.
That problem was fixed at some point and the note describing it is stale.

What did fill it is not yet identified. The guest has been up 8 days and
`/proc/vmstat` records 10,031,092 pages swapped out and 10,697,068 major faults
over that time, so the pressure was real and repeated, not a single spike. But
whatever caused it has exited, and WSL kept the pages.

#### What it costs, stated honestly

At the time of the report, paging cost this:

```
3,243 hard faults/s (mean, peak 8,465) x 330 us = 1,071 ms of blocked
thread-time per second -- about one thread of sixteen, continuously.
```

That is a real tax and not a catastrophe. Working sets are being trimmed --
the largest claude oscillates 2,910-3,269 MB against 4,841 MB committed -- but
it is churn, not a death spiral.

So: **11 GB of waste is established. That it causes the reported slowness is
not.** The counters that would show a stall were not showing one. Freeing the
11 GB would take available memory from about 3.5 GB to about 14 GB and should
end the faulting entirely, which makes it worth doing on its own terms; whether
the machine then stops feeling slow is a separate question that only trying it
answers.

One measurement caveat that belongs in the record: during the correlation
sampling my own scripts were 70% of a core and the two claude processes over
100% each. Part of the load being measured was the act of measuring.

#### Two formatting artifacts that printed real values as zero

Both in my own scripts, both caught, both the same class of bug as reading an
access-denied query as a zero:

- `Available MBytes` printed as `0.0` because the unit-scaling test matched
  `Bytes` inside `MBytes` and divided a megabyte value by 1MB. True value 2,910.
- `Avg. Disk sec/Read` printed as `0.0` because `N1` formatting on a
  seconds-valued counter hides everything under 50 ms. True value 553 us --
  and that counter is the one that decides whether a fault rate is a stall.

#### Not done, and why

Recovering the 11 GB requires restarting the WSL VM. Nothing short of that
returns it: no setting reclaims free guest pages while the VM runs. That kills
everything in the guest, which currently includes a claude 3.2 days old, a
codex, and a tmux server with sessions. Not the kind of thing to do without
asking, so it was not done.

#### Correction to the entry above: the cost figure was from the wrong window

The entry states "at the time of the report, paging cost this: 3,243 hard
faults/s". **It was not measured at the time of the report.** The report was
21:10; that window was 21:26, fifteen minutes later, and during it my own
scripts held 70% of a core while two claude processes were over 100% each. I
wrote the perturbation down as a caveat and then published the number anyway.

The windows taken so far, in order:

```
21:16   60 s      96 faults/s   cpu 39.4%    <- this is "at the time of the report"
21:12    6 s     270 faults/s   (5 samples, caught a burst)
21:21    5 min  2,367-5,647     cpu 80-133%, my scripts running
21:26   60 s   3,243 faults/s   cpu ~120%,   my scripts running
```

A 34x spread across a figure published as if it were a property of the machine.
This is the sixth instance of the same error and it has its own note for a
reason.

#### The clean number, and it is worse than either

21:29, sixty one-second samples, nothing of mine running but the counter loop:

```
                    mean       min       p50       p95       max
hard faults        3,266       271     2,498     9,590    14,953   /s
available          3,611     2,162     3,605     4,188     4,212   MB
disk read latency  1,765        85       147    11,385    20,290   us
cpu utility         83.7      37.7      79.6     122.7     147.1   %

3,266 faults/s x 1,765 us = 5,765 ms/s blocked, of 16,000 ms/s available
```

**About 36% of the machine's total thread capacity is blocked on paging.** That
is a stall signature, and it is the first one this investigation has caught in a
clean window.

But the 21:16 window was also clean and measured 96 faults/s at 39% CPU. Two
honest samples thirteen minutes apart differ 34-fold. The machine alternates
between quiet and heavily paging, and the paging appears when it is busy --
which is when a person would notice. The distribution, not either number, is
the finding. How much of the day sits in each state is not known and one
evening does not establish it.

#### Where the paging actually goes

The latency above is the multiplier that turns a fault rate into blocked time,
and `_Total` was hiding which disk produced it:

```
disk                  mean lat    p95 lat    reads/s   queue
0  d:  Samsung 980         0 us       0 us         0    0.00
1  c:  WD SN5000S      4,593 us   7,967 us       186    1.25
```

Every page fault is served by `C:\pagefile.sys` on the WD SN5000S at 4.6 ms
mean and 8.0 ms at p95, with a queue depth above 1. The Samsung 980 on D: is
completely idle. Milliseconds, not the microseconds an NVMe should give -- so
the fault rate hurts far more per fault than the first measurement suggested.
Not investigated further tonight and not a recommendation to move anything.

#### Two claims from the entry above, withdrawn

**"Freeing the 11 GB ... should end the faulting entirely."** Withdrawn. The
data argues against it: the 21:29 window faulted 34x harder than 21:16 with
*more* available memory, the hardest-faulting samples are the highest-CPU ones
(120-147%) and the quietest are the lowest (38-85%), and the faults-by-available
band table is non-monotonic -- the 2000-3000 MB band faults harder than the
1000-2000 MB band. Faults track demand at least as much as scarcity. Returning
11 GB may reduce them a lot, a little, or not measurably. It is untested.

**"Working sets are being trimmed."** Overstated. pid 8492 is flat at 1,062 MB
across all twenty samples, and pid 56620's trace is one step down followed by a
slow climb. That is not the oscillation a trim/refault loop would produce.

What survives unchanged is the part that was actually measured: 12,415 MB
allocated to a VM using 1,068 MB of it, flat to the megabyte across fourteen
samples, with no setting that returns it while the VM runs.

#### The durable lever, which the entry above omitted

`.wslconfig` sets `memory=13002342400`, a 12,400 MB ceiling on a 32 GB machine.
Restarting WSL returns the 11 GB once; it does not stop it happening again, and
the guest's 39 GB of cumulative swap-out over 8 days says whatever fills it is
recurring rather than a one-off. Lowering that ceiling bounds the worst case
permanently, and it applies on the same restart that is needed anyway. The
guest's steady state is about 1 GB, so the current ceiling is roughly twelve
times what it habitually uses.

Not changed. It is a settings edit on a machine whose owner has to pick the
moment, because the restart it needs would kill a 3.2-day claude, a codex and a
tmux server inside the guest.

### 2026-08-20 21:44 -- the paging cost was 15x too high, and 99.7% of the faults never touch disk

The question that produced this entry was "why can't we just solve the fault
problem directly?" Trying to answer it required knowing what a fault costs, and
checking that turned up an arithmetic impossibility in what I had already
committed two entries above.

#### The impossibility

The entry above publishes **3,266 page reads/s**. A separate measurement the
same evening put the only busy disk at **186 disk reads/s**. Every hard page
read is served by a disk read, so page reads can never exceed disk reads. One
of those numbers had to be wrong, or they were not measurable against each
other.

They were not. Measured in the same 45-second window, they agree:

```
page reads/s          532.9
disk reads/s (c:)     699.1
ratio                    0.76      must be <= 1.0        ok

pages input/s       4,599.0        8.6 pages per read -- read-ahead clustering
implied fault bytes    18.0 MB/s   pages input x 4 KB
actual disk read       19.0 MB/s                          ok
```

The counters were fine. Comparing two of them across different windows was not.
That is the same failure as the entry above, in a new costume: not a polluted
window this time, but a numerator and a denominator from windows minutes apart.

#### Most page faults are not disk

The other half of the answer is that "hard fault" and "page fault" are not the
same thing, and I had been treating the fault rate as if the whole of it were
memory pressure. Decomposed over the same window:

```
page faults/s        202,906    total
  demand zero        166,743    brand-new zeroed pages, no disk
  transition          25,841    recovered from the standby list, no disk
  cache faults        10,472    mapped-file data
  page reads             533    the only ones that reach a disk
```

**0.26% of page faults touch a disk.** Demand-zero faults are what every
process does when it allocates; transition faults are pages the memory manager
already had in RAM. Neither is scarcity, and no amount of free memory removes
either. Total paging traffic is 19 MB/s against an NVMe good for roughly three
thousand.

#### The 36% figure is withdrawn

Not refined -- withdrawn. It was mean(page reads) x mean(latency), taken from a
window that was itself an outlier, and both factors sit far out on very long
tails. Measured properly -- one 306-second window, 300 samples, the product
formed per sample and then averaged:

```
counter               p05      p25      p50      p75      p95      max
hard faults             5       26      125      677    5,689   11,927  /s
disk read               0        1        4       14       40      152  MB/s
read latency          111      170      324      805    4,148   16,831  us
available           2,313    3,286    3,685    4,116    4,806    5,031  MB
cpu utility            21       42       59       84      134      173  %
cpu vs nominal         87      111      138      166      188      198  %
run queue               0        0        0        1        6       62  threads

paging cost   391 ms/s blocked, out of 16,000 ms/s across 16 cores  =  2.44%
```

**2.44%, not 36%.** Eliminating every page fault on this machine would buy back
about one fortieth of its thread capacity.

The distribution explains every number this investigation has published and
also why they disagreed. Hard faults run p50 125/s and p95 5,689/s -- a 45-fold
spread inside a single five-minute window. The samples I quoted at 96, 270,
533, 3,243 and 3,266 are all real values of the same counter; the mistake was
quoting any of them as a rate.

It also reconciles the three disk latencies in the entry above -- 1,765 us from
`_Total`, 4,593 us per-disk, 494.8 us in the consistency window, all within four
minutes. `Avg. Disk sec/Read` is a ratio of two deltas, so it swings wildly when
few reads land in an interval. Its p50 is **324 us**; the millisecond figures
are means dragged up by a tail reaching 16.8 ms. The claim that the SN5000S is
serving page faults in milliseconds does not survive: half the reads complete in
under a third of a millisecond.

#### So the fault problem cannot be solved, because there is not one

All three routes to attacking faults directly fail on the same fact:

- **Move the pagefile to the idle Samsung 980.** Reduces cost per fault. There
  are 391 ms/s of cost to reduce.
- **Free the 11 GB from the WSL VM.** Reduces the count of the 0.26%. Would not
  touch the demand-zero faults, which are 82% of the total and are what
  allocation looks like.
- **Reduce demand.** This is the real one, but it is not a paging fix.

#### What the same window says the load actually is

```
cpu utility      p50  59%   p75  84%   p95 134%   max 173%
88 of 300 samples at or above 80% utility -- 29% of the window
run queue        p50   0    p75   1    p95   6    max  62 threads
cpu vs nominal   p50 138%                          -- turbo, not throttled
```

Threads are queueing for CPU, not for disk, and the run queue reaching 62 is a
far better candidate for what "slow" feels like than 391 ms/s of paging.

#### But this entry cannot name the consumer

```
attributed 216% of one core = 13.5% of the machine
175 processes unreadable (not zero)

process                    pid     core-%   core-seconds
claude                   56620      106.5          326.1
claude                   29932       26.4           80.8
node                      8492        9.0           27.7
chrome-headless-shell    31768        8.1           24.9
Termius                  20584        6.6           20.3
audiodg                  60164        5.8           17.9
```

Per-process attribution accounts for 13.5% of the machine against an observed
p50 of 59%. The gap is not idle time -- it is that 175 of the running processes
cannot be read without elevation, and this log's standing rule is that
unreadable is not zero. Naming a cause from that table would be guessing.

Two things are visible anyway. The largest single identified consumer is a
`claude` process holding 106.5% of a core for the entire window, which is this
investigation's own tooling, again. And `audiodg` appearing at 5.8% of a core
over five minutes is consistent with the Intelligo APO burst already recorded
elsewhere.

#### What is unaffected

The WSL finding stands exactly as measured: 12,415 MB allocated to a VM using
1,068 MB of it, flat to the megabyte across fourteen samples over twenty-one
minutes, invisible to every process-listing tool, with no runtime path to
reclaim it. What changes is that it was never shown to cause the slowness, and
the mechanism proposed for how it might -- paging -- has now been measured and
found to cost 2.44%. The `memory=` ceiling is still worth lowering for the sake
of the 11 GB itself. It is no longer a candidate explanation for anything.

### 2026-08-21 10:00 -- retraction: the VM never held 11 GB; the counter reads the ceiling

The user ran the discriminating test proposed in the previous entry, in the
strongest possible form: WSL shut down entirely -- no perceived change; WSL
restarted -- no perceived change. That result alone would only have said the
11 GB was not the cause of the slowness. What it actually did was expose that
the 11 GB was never there.

#### The contradiction that forced a re-measurement

Nine hours and forty-three minutes after the guest rebooted, before any
pressure episode could have occurred:

```
guest uptime                9:43,  load 0.00
guest memory                909 MB used / 11,074 MB free / 305 MB cache
guest swap                  51 MB used   (was 1,951 MB before the restart)
pswpout since boot          14,695 pages = 57 MB   (was 10.2 million)
pgmajfault since boot       10,258                 (was 10.9 million)
largest guest process       codex, 170 MB RSS

\Hyper-V VM Vid Partition   12,400 MB -- already at the ceiling
```

A freshly booted, idle guest with 51 MB in swap cannot have ratcheted the
host-side allocation to the ceiling through memory pressure. Either the
ratchet story was wrong or the counter was. It was the counter.

#### The balloon I said did not exist, exists

Entry 2026-08-20 21:10 reported that the guest had no reclaim mechanism,
based on `/sys/bus/virtio/devices` showing only a console and virtio-fs. That
was the wrong bus. Hyper-V memory management does not ride virtio; it rides
vmbus, and it was there the whole time:

```
[    0.314241] hv_vmbus: registering driver hv_balloon
[    0.322799] hv_balloon: Using Dynamic Memory protocol version 2.0
[    0.324455] Free page reporting enabled
[    0.324937] hv_balloon: Cold memory discard hint enabled with order 9
[   48.439766] hv_balloon: Max. dynamic memory size: 12400 MB
```

`CONFIG_HYPERV_BALLOON=y`, `CONFIG_PAGE_REPORTING=y`. The last line is the
tell: the guest reached its maximum dynamic memory size 48 seconds after
boot. The Vid counter has read the ceiling ever since -- because that is what
it reads.

#### The five-minute experiment that settles the counter's semantics

Write 3 GB into guest tmpfs, delete it, and watch three numbers on the host:

```
time        vid counter    vmmemWSL private    host available
09:59:11    12,400 MB          1,512 MB           1,856 MB    baseline
09:59:16    12,400 MB          4,583 MB             624 MB    3 GB written
09:59:19    12,400 MB          3,890 MB           1,371 MB    3 s after rm
10:00:35    12,400 MB          1,514 MB           4,009 MB    75 s after rm
```

Three GB of real guest allocation moved `vmmemWSL`'s private bytes by three
GB and the Vid counter by nothing. Freeing it returned every page to the host
within 75 seconds -- private bytes back to the megabyte, host available up by
2.6 GB. Free page reporting works, continuously, unprompted.

So:

- `\Hyper-V VM Vid Partition\Physical Pages Allocated` tracks the hot-added
  visible maximum, not resident backing. Its 21-minute flatness at 12,415 MB
  was the flatness of a constant.
- The VM's true host cost is `vmmemWSL`'s private bytes, which track guest
  usage: about 1.5 GB, then and now.
- Freed guest memory returns to the host in under two minutes. There was
  never a reclaim gap for `autoMemoryReclaim` to fill, and the `memory=`
  ceiling bounds the worst case, not the steady state.

#### What this retracts and what it reopens

The 2026-08-20 21:10 entry's central claim -- 11 GB of host RAM held by the
VM, invisible to every process view, with no path to reclaim it -- is
retracted in full. Not refined: the quantity was misread from a counter whose
semantics I never tested, and the missing reclaim mechanism was a search of
the wrong bus. A five-minute perturbation experiment would have caught both
on day one. The entry stays as written; this is what checking looks like.

Two things survive unchanged: the 21:44 entry's measurements (paging costs
2.44%, only 0.26% of faults reach disk, the load is CPU with a run queue
touching 62) and the guest's historical pressure episodes (39 GB swapped out
over 8 days was real, its cause still unidentified -- but its host-side cost
was transient, since the pages went back).

One thing reopens: the accounting gap that started this thread. If the VM
holds 1.5 GB and not 12.4, then the readable processes' 13 GB plus the VM no
longer approaches the 29 GB the host reports in use. The missing memory is
somewhere in the 175 unreadable processes and kernel allocations, and naming
it needs elevation, which remains the user's call.


### 2026-08-21 10:20 -- elevated at last: the consumer has a name, and the memory is overcommitted 2:1

The user opened an elevated session and ran a read-only sampler: a 344-second
TotalProcessorTime delta across all processes (501 of them, none unreadable
this time), utility and run-queue samples every 15 s, and a full memory
accounting. Yesterday's attribution covered 13.5% of the machine; this one
covers essentially all of it.

#### CPU: top of the table, 344.5 s window

```
name                 pid     core-sec   core-%   note
claude             56620        358.0    103.9   another Claude Code session
System                 4        242.3     70.3   kernel
dwm                67732        130.5     37.9   the known dwm degradation
MsMpEng            46428        113.1     32.8   Defender real-time scanning
chrome             (all)       ~220       ~64    across 46 processes
Memory Compression  4288         63.9     18.5   symptom, see below
SearchIndexer      10336         32.2      9.4
node                8492         31.6      9.2
Termius            (two)         59.6     17.3
svchost (camsvc)   11040         28.9      8.4   camera/privacy service, odd
attributed: 1,611 core-sec = 29.2% of 16 cores, matching observed utility
```

The consumer yesterday's entry could not name is `claude` pid 56620: a
`claude -r` session started 2026-08-08 23:05, alive 12.5 days, with 235.8
accumulated CPU-hours -- an average of 0.79 cores continuously for its entire
lifetime, and 103.9% of a core during this window. Its parent pwsh is alive;
it is a real open tab, not an orphan. For calibration, this investigation's
own session (pid 29932, started two minutes later) has 12.2 CPU-hours over
the same 12.5 days. A session that burns a core around the clock, including
whatever fraction of the day it sits idle, is not doing turn work; something
in it is spinning. What, exactly, is not knowable from outside the process.

#### Memory: the gap closes, and the real number is worse than the fake one

```
physical                 31,997 MB
available                 1,557 MB
committed                65,300 MB   -- 2.04x physical
sum of private bytes     52,157 MB across 501 processes
Memory Compression WS       569 MB; modified list 1,074 MB
pool nonpaged 2,477 MB; pool paged resident 1,525 MB
```

Top private-bytes holders:

```
WindowsTerminal    17692    7,655 MB private,   131 MB resident
claude             56620    4,955 MB (5.4 GB at re-check)
python             21544    1,666 MB
node                8492    1,529 MB
vmmemWSL           61324    1,514 MB   -- exactly as re-measured, not 12.4 GB
LINE                9728    1,305 MB
dwm                67732    1,305 MB   -- the compositor holds 1.3 GB private
node               40828    1,258 MB
logioptionsplus     2180    1,250 MB   -- known
claude             29932    1,210 MB   -- this session
```

The WindowsTerminal number deserves its own sentence: the terminal process,
alive since the 2026-08-02 boot, holds 7.7 GB of committed memory of which
131 MB is resident -- nineteen days of scrollback from long-running agent
sessions, nearly all of it parked in the pagefile. Together with the three
claude sessions (7.4 GB private between them) a single terminal window
accounts for about 15 GB of the 65 GB commit charge.

#### What "slow" is, on this machine, as of this entry

Not one villain. The CPU side stacks a spinning agent session (one full
core), the kernel, dwm, Defender, and 46 chrome processes into a p50 around
50% with bursts past 130%. The memory side runs at 2:1 overcommit with 1.5 GB
available, which keeps Memory Compression busy at 18.5% of a core and the
modified-page writer feeding the pagefile -- the 2.44% paging cost from the
21:44 entry is the disk-visible edge of that pressure. Every candidate this
log has chased and retracted -- the WSL balloon, the paging latency -- was a
misreading orbiting these two facts.

Levers, all of them the user's to pull: look at what session 56620 is doing
and close it if it is idle (one core and 5.4 GB back); restart the terminal,
which kills every tab in it, three agent sessions included (7.7 GB of commit
back); the chrome fleet; and the dwm 1.3 GB / 37.9% pair, which is the
long-standing degradation thread and survives everything short of a
re-login. Nothing in this entry was changed, killed, or restarted.


### 2026-08-21 10:42 -- correction: a session at one core is not spinning, it is in flight

The previous entry named `claude` pid 56620 as the CPU consumer and called it
spinning, on the strength of 235.8 CPU-hours over a 12.5-day lifetime. The
user's reply -- it has been working continuously, but it never used to cost
this much -- prompted a control measurement, and the control disproves the
"spinning" half of the claim.

#### An idle session costs 10%, an in-flight session costs 100%

Two sessions, same binary, same host, sampled every 10 s. Pid 29932 is this
investigation's own session; the window begins while it is waiting on an
outstanding tool call and continues after its turn ends and it returns to the
prompt.

```
                        56620 core%    29932 core%
turn in flight            80 - 107      80 - 107
idle at the prompt              --        5 - 17     (median ~11)
56620 across 5 min       87 - 122            --      (median 97, never drops)
```

The number that matters is that this session's own cost collapses to about a
tenth of a core the moment its turn ends, and 56620's never does. Its
transcript confirms why: 319.1 MB at 10:30, 319.6 MB at 10:42, last written
seven seconds before the check. It is not stuck and it is not spinning. It
always has a turn in flight, exactly as the user said.

#### The in-flight core is overhead, not work

The strongest form of the measurement is accidental. During the 4-minute
window above, the tool call pid 29932 was waiting on was a PowerShell probe
that spends 240 of its 245 seconds inside `Start-Sleep`. The tool was doing
nothing, the model was not generating, and the session still held 80-107% of
a core, tapering to 33-87% late in the window. Whatever consumes that core is
the session's own loop while a turn is open, not the work the turn asked for.

That has an unpleasant consequence for a machine running two active agent
sessions: two of sixteen cores are spent before any of them computes
anything.

#### And the in-flight cost does not scale with session size

This is what answers the user's question, in the negative. The two sessions
differ by 4x in heap and 9x in transcript:

```
                   56620        29932
private heap       5.0 GB      1.26 GB
transcript          319 MB       36 MB
read IO ops/s        110.0         4.8
user / privileged  92.7 / 6.1
in-flight cost      ~100%       ~100%    <-- indistinguishable
```

A 5 GB V8 heap sawtoothing 400 MB every 60 s -- `4,851 -> 5,258 -> 4,857`
across the idle window, continuously, at 92.7% user time -- costs no more per
in-flight second than a 1.26 GB one. So the session did not get more
expensive in CPU as it grew. The claim in the previous entry that it burns a
core *because* something in it is wrong is withdrawn.

What did grow is the memory footprint, and that is charged to the machine
rather than to the session: 5 GB of private bytes on a host at 2:1 commit
with 1.5 GB available is what keeps Memory Compression at 18.5% of a core and
the modified-page writer fed. The session does not cost more; it makes
everything else cost more.

#### What "it never used to cost this much" resolves to

Not a regression inside the session. A machine where a continuously-working
agent session (one core, always), a second active session (one more), 46
chrome processes (0.64 cores), dwm (0.38), and Defender (0.33) now coexist at
2:1 overcommit. Every previously-chased villain in this log -- the WSL
balloon, the paging latency, the spinning session -- was a single term being
mistaken for the sum.

The cheap lever is unchanged in size but changed in reason: restarting 56620
with `claude -r` reclaims about 4 GB of heap and keeps the conversation. It
will not reclaim the core, and this entry no longer claims it should.


### 2026-08-22 16:06 -- a different regime: paging is 18x yesterday and the CPU verdict does not hold today

"Slow again -- is it just that long-running session? I did `/new`." Two
questions, and the measurement answers both against the expectation.

#### `/new` starts a conversation, not a process

```
pid    started        days   cpu-hrs   avg-cores   priv MB
29932  08-08 23:07    13.7      14.4       0.044     1,251
56620  08-08 23:05    13.7     264.7       0.805     4,987
73180  08-10 13:04    12.1       3.3       0.011       788
```

No claude process on this machine is younger than twelve days, yet the
sugar-dating project is writing to a transcript created today
(`0ffa2d13`, already 57.6 MB, plus a subagent workflow tree). A new
conversation belonging to a twelve-day-old process is only possible one way:
`/new` cleared the conversation in place. Pid 56620 is the same process it
was yesterday and still holds 4,987 MB -- V8 does not return a grown heap to
the OS just because the objects in it became garbage. The command reset the
context; it did not reset the process.

#### And no, it is not that session -- today is not yesterday's problem

Same instruments, 120 s, 40 samples:

```
                      2026-08-21        2026-08-22      change
hard page reads/s     p50    125        p50  2,290       18x
blocked on read           2.44%             8.00%       3.3x
cpu utility           p50     59%        p50    40%      down
available MB          p50  3,685        p50  1,245      -66%
disk read latency     p50    324 us     p50    363 us    flat
disk idle                    --              68%        not saturated
```

Yesterday's entry concluded "the load is CPU, not paging," and that
conclusion was correct for yesterday's window. It does not describe today.
CPU has fallen and hard faults have risen eighteenfold; the disk is 68% idle
and its latency is unchanged, so this is not a slower disk, it is far more
demand for it. This log now has two measured regimes and no basis for
treating either as the machine's permanent character.

#### The resident column is where "slow" lives

```
name                   priv MB     WS MB   resident%
WindowsTerminal          7,743       826         11
claude 56620             4,977     2,734         55
SrTasks                  2,075       200         10
vmmemWSL                 2,025     1,024         51
python                   1,583        63          4
dwm                      1,328       173         13
logioptionsplus_agent    1,305        42          3
LINE                     1,194       223         19
chrome (58 procs)        8,369     4,422         53
```

Committed 66,417 MB against 31,997 MB of physical, with the pagefile grown to
91,467 MB and a peak usage of 63,322 MB. At better than 2:1 overcommit the
memory manager keeps roughly half of anything resident and trims the rest, so
processes sitting at 3-13% resident have almost their entire address space in
the pagefile. Every switch to one of those windows is a burst of hard faults.
That is the felt symptom, and it is why the machine feels slow at 40% CPU.

#### What changed since yesterday

Chrome went from 46 processes to 58 (8.4 GB private, 4.4 GB resident) with a
single visible window. `vmmemWSL` rose from 1,514 to 2,025 MB, consistent
with the corrected model of guest usage tracking rather than a ratchet. And
`SrTasks` appeared at 15:09 today holding 2,075 MB with a dead parent and a
command line this session cannot read without elevation -- System Restore's
maintenance task, still resident an hour later, with VSS, swprv and wbengine
all reported Stopped. Unreadable is not zero; it is the one item in this
entry that has not been identified.


### 2026-08-22 16:35 -- SrTasks identified and cleared; the thrashing got five times worse without it

The unidentified 2 GB holder from the previous entry has a full provenance,
and it is innocent. While that was being established the machine crossed into
the worst state this log has measured.

#### SrTasks: a restore checkpoint for a Store app update

```
15:07:15  WindowsUpdateClient id=44  download started
15:09:35  SrTasks.exe created
15:09:36  WindowsUpdateClient id=43  installing 9PLM9XGG6VKS-OpenAI.Codex
15:09:39  WindowsUpdateClient id=19  install succeeded
15:10:07  System-Restore id=8300  Scoping started   for HarddiskVolumeShadowCopy14
16:16:21  System-Restore id=8301  Scoping completed for HarddiskVolumeShadowCopy14
16:16:21  System-Restore id=8302  Scoping successfully completed
```

Windows Update installed a Store app, System Restore took a checkpoint one
second before the install, and the resulting scoping pass ran for 66 minutes
holding 2,075 MB at 10% resident before exiting on its own. Shadow storage is
1.75 GB used of a 10 GB cap. Notably the periodic `\Microsoft\Windows\
SystemRestore\SR` task last ran 2026-05-09 and failed with 0x8007042B and has
no next run time -- so checkpoints on this machine happen only on demand, at
install time, which is why this appeared without warning and will appear
again on the next app update.

The elevated probe reached the process one minute and forty-one seconds after
it exited, so its command line was never captured. The event log answered the
question the process could not.

#### It was not the cause: removing 2 GB made things five times worse

```
                        16:03      16:25 (SrTasks gone)
hard page reads/s    p50 2,290          p50  6,736
                                        p95 15,418
blocked on read          8.00%              40.93%
read latency p50/p95  363 us / 1.7 ms   966 us / 15.0 ms
available MB         p50 1,245          p50  1,159
cpu utility          p50    40%         p50     64%
```

Forty-one percent of sixteen threads blocked waiting on a page read. The
disk's own numbers show why the latency moved: `PhysicalDisk(C:)` is reading
97.6 MB/s with a current queue length of 18, and this is where the reads are
coming from:

```
attributed process file I/O   15.3 MB/s across 492 readable processes
physical disk read rate       97.6 MB/s
difference                    82 MB/s -- not file I/O, therefore pagefile
```

Per-process I/O counters cannot see hard faults. Five-sixths of the disk
traffic is the memory manager reading back working sets it trimmed, which is
the definition of thrashing and requires no misbehaving process to explain.

#### Two suspects examined and dropped

A snapshot showed `iGoSwServer` at 26,585 page faults/s, which would have
been a satisfying culprit given the Intelligo APO bursts already recorded in
this log. The next 60-second window put it at 4 faults/s and 0.0% of a core.
It is a burst, consistent with the known ~20 s audio-event behaviour and with
the ten Chrome Remote Desktop connect/disconnect events between 16:12 and
16:19 -- not a sustained load. Reporting the snapshot would have been the
same error this log has made nine times.

The second was that Windows Search might be indexing the 10,227 transcript
files and 5,107 MB under `.claude`. The crawl scope rules say otherwise:
`C:\Users\` is the only included root, and `\.claude\`, `\.claude.json`,
`\.serena\`, `\.codex\`, `\.cache\` and `AppData` all carry `Include=0`. Five
include rules, 119 exclude rules. Not indexed.

What is sustained, measured over 60 s:

```
Memory Compression   15.2% of a core   5,219 faults/s
MsMpEng              13.3%             1,397
SearchIndexer        12.0%               217   0.27 MB/s
svchost camsvc        7.7%             4,323   6.31 MB/s
```

Memory Compression at the top of the fault table is a symptom by definition.
The `camsvc` line -- the Capability Access Manager, reading 6.3 MB/s
continuously -- is the one entry here that has no obvious reason to be there,
and it was also at 8.4% of a core in yesterday's elevated sample.

#### The standing account

Committed 65,967 MB against 31,997 MB physical; paged pool 6,071 MB of which
2,136 MB resident; 506 processes summing 50,277 MB private but only 15,476 MB
of working set. Nothing on the machine is misbehaving. It is simply asked to
keep more than twice its physical memory live, and the moment a working set
is touched it must come back from a disk already 18 deep. The previous entry
called this a second regime; this entry is that regime at four times the
intensity, reached without any new process arriving -- one left.


### 2026-08-22 16:40 -- three channels disagreed about one process, and the broken one was the one I trust by default

Following the previous entry's one unexplained line -- `camsvc` reading 6.3
MB/s for no visible reason -- produced a measurement conflict worth more than
the answer.

#### The conflict

Same process, pid 11040, overlapping windows:

```
channel                                        read rate      cpu
Get-Process (.NET process object)              0.00 MB/s      0.00%
PDH V1, \Process(svchost#52), single sample    0.49 MB/s        --
WMI Win32_PerfRawData, keyed on IDProcess      6.33 MB/s       8.4%
PDH V2, \Process V2(svchost:11040), mean of 8  8.01 MB/s        --
```

The instinct was to distrust the perf counters, because `svchost#52` is a
positional instance name and positional names shift. That instinct was
wrong. `Process V2` instances are keyed `image:pid` and cannot shift, and V2
independently reports 8.01 MB/s across eight samples. Two counter APIs with
different instance-naming schemes agree.

#### The broken channel was Get-Process

`camsvc` runs as `svchost.exe -k osprivacy -p -s camsvc`. The `-p` makes it a
protected service, and an unelevated caller cannot read its counters. The
.NET `Process` object does not raise on that -- it returns zero. So it
reported 0.00 MB/s *and* 0.00% CPU for a process the counters show at 8% of a
core.

The proof is in this log's own history: yesterday's elevated sample reached
the same pid through the same API and got 8.4% of a core. Elevated it reads,
unelevated it returns zero, and nothing in between tells you which happened.

That is the tenth instance of "unreadable is not zero" in this investigation
and the first where the silent zero came from the tool I reach for first.
The rule needs a second clause: a zero from an unprivileged reader is not
evidence of absence, and two channels disagreeing means one is blind, not
that the answer is somewhere in the middle.

#### What camsvc actually does, and what it does not explain

Sustained across six 15-second windows and confirmed by V2: 6.3 to 8.0 MB/s
of reads at 14 operations per second, which is 477 KB per read, with zero
writes, ~90 other operations per second, and 8-10% of a core. It owns no TCP
connections, so the reads are not sockets. `FrameServer` is running but
completely idle, so they are not camera frames traversing the Windows camera
pipeline. Its ConsentStore is 166 keys in HKCU and 53 in HKLM -- far too
small to be walked at this rate. The 477 KB read size is unexplained.

Naming the file requires an ETW file-I/O trace: a protected process denies
handle and module enumeration to administrators too, so the usual elevated
route is closed.

But the scale settles its relevance. Eight MB/s sits against the 97.6 MB/s
the disk was reading during the thrashing peak, of which 82 MB/s was
pagefile. `camsvc` is an oddity, not a cause.

#### And the regime is bursty, which the earlier entries did not show

Three measurements, seven minutes apart, no intervention:

```
16:25   hard reads p50  6,736/s   queue 18    disk 97.6 MB/s
16:37   hard reads p50     34/s   queue  0    disk  2.1 MB/s
16:40   hard reads      3,162/s   queue 14    cpu 111%
```

The machine is not steadily thrashing; it oscillates between quiet and
saturated on a timescale of minutes. Every "it feels slow" report in this log
and every measurement answering one has been a sample from one phase of that
oscillation, which is a better explanation for why the conclusions kept
changing than any of the individual corrections was.


### 2026-08-22 17:30 -- eight dimensions in parallel, and the answer was not the one this log spent three weeks measuring

Every entry above this one investigates one thing at a time. This entry is the
result of running eight independent investigations concurrently -- commit
ledger, the Chromium fleet, Defender, resident software inventory, Windows
Search, storage and the pagefile, the compositor, and this log's own record --
and then ranking what came back. Eight of eight reported: 94 findings, 233 tool
invocations, 29 minutes of wall clock.

The ranking inverts this log's working assumption.

#### The headline: dwm, not memory

`dwm.exe` (pid 67732, started 2026-08-11 17:59:46, never restarted) has gone
from 37.9% of one core on 08-20 to a median of 95-98% of one core today. Two
instruments that share no code agree:

```
                       08-19   08-20   08-21   08-22
load-attrib2.csv        37.6    31.4    41.4    95.4   dwm p50, %-of-one-core
  (15 s cadence)       n=3136  n=5496  n=5410  n=3855
dwm-growth.csv          37.1    23.7    36.4    97.5   dwm cpu_pct daily median
  (30 min cadence)      n=48    n=48    n=48    n=34
machine p50, same days  38.2    30.7    27.3    28.2
```

Read the last row again. The machine got *quieter* while dwm tripled. Hour by
hour the rise is a staircase, not a ramp: 08-21 00:00-08:00 dwm sits at 27-31%
with the machine at 18-22%; by 08-21 15:00 dwm is at 63-79%; from 08-22
01:00-09:00 dwm is at 95.7-100.7% with the machine at 23.7-28.7%. dwm is at its
most expensive during the machine's quietest hours, which is the opposite of
what "dwm is slow because it is being paged" predicts.

Four more measurements close the consequence branch:

- **It is compute, not fault servicing.** Over 18 samples at 2 s: `% User Time`
  is 86.5-96.9% of `% Processor Time`, median ~90%. `Page Faults/sec` is
  143-160, dead flat, against machine-wide transition faults of 1,763-32,887 in
  the same samples. `IO Read Operations/sec` is 0 in all 18. Private bytes and
  private working set are both pinned -- no trim/refault sawtooth. A thread
  blocked on a hard page read accrues zero CPU time, and fault servicing bills
  to kernel mode; neither shape matches.
- **Heavy paging does not degrade composition.** 2,400 measured composition
  intervals over 17:00:35-17:01:01 delivered 139.0-143.0 passes/sec against a
  144 Hz panel, p50 6.94-6.98 ms against a 6.944 ms vsync period -- while
  `\Memory\Page Reads/sec` in the same bursts ran 1,923 / 2,984 / 4,568 / 4,074
  / 4,794 / 4,280 / 4,223 / 3,823.
- **The cost tracks dwm's own uptime.** Median CPU-ms per composition pass on
  the hot thread, by day, over 526 samples of this one process: 0.28, 0.21,
  0.49, 0.37, 0.46, 0.59, 1.20, 2.72, 2.34, 1.12, 2.13, 7.23. A fresh dwm 41
  minutes after restart measured 0.712. Handle count rises about +2.7/hour and
  `gpu_local_mb` p50 rose 668 -> 1,644 MB over the same days.
- **It is episodic, and in episodes one thread caps the whole desktop.** Split
  today's 34 samples on the sampler's own calibrated threshold: GOOD n=9,
  122.7-144.1 passes/sec; BAD n=25 (74%), 63.3-111.6 passes/sec. On the worst
  sample the hot thread was at 95.8% of one core and 15.129 ms per pass, which
  predicts a ceiling of 66.1 passes/sec; measured was 63.3.

Even in the good mode dwm burns 0.90 of a core while hitting every vsync -- 3.97
ms of CPU per pass against a fresh dwm's 0.712 ms. This is the MPO
overlay-candidate occlusion walk already localised in `dwm-investigation.md`,
now four times worse than when that document was written, and it is the best
available explanation for "the desktop feels slow" that this investigation has
produced.

What is still not known: what changed at approximately 08-21 15:00 and again at
08-22 01:00. Nothing in the event log, the Chrome Remote Desktop state, or the
window counts explains either step. And the pruning-failure-versus-iterator
question the dwm doc left open is still open; the PMC run that would settle it
has not been repeated at the current, much worse level.

#### The memory story is real but it is not what is being felt

It is real: commit 67.7 GB against 31,997 MB of RAM, available memory
oscillating between 481 and 2,752 MB with two reads of exactly 0.0, page reads
peaking at 28,439.8/sec with `Pages Input/sec` at 83,487.8 (326 MB/s) and
`PhysicalDisk(1 c:)\Disk Read Bytes/sec` independently reading 332.3 MB/s in the
same window -- two unrelated counter sets agreeing to within 2%. C:'s read
latency collapses from a measured QD1 floor of 144.1 us to 2,080 us p50 and
14,550 us p90 once its queue exceeds 4.

But it has been tested against the felt symptom three times in this log and
failed three times, and no entry ever acknowledged it:

1. 08-19 16:44: all 21 visible top-level windows answered `WM_NULL` in 0.2-16.4
   ms, at 62 GB commit and 8-24% residency -- materially the same overcommit as
   now.
2. Of 83 recorded stalls in the 08-18/08-19 per-window tables, 41 have
   `fgfault < 100`, and the seven *worst* stalls have `fgfault = 0`.
3. The largest `fgfault` ever recorded, 1,121,064, produced a `max_ms` of only
   190.

The honest position is that the mechanism is refuted in its message-pump form
and merely untested in its repaint form. The 08-22 entry above states "Every
switch to one of those windows is a burst of hard faults. That is the felt
symptom." **That sentence is not supported.** Measuring time-to-first-paint on
window activation, rather than message-pump latency, is the cheapest open test
left in this investigation.

#### Where the commit actually goes, and the vendor-bloatware hypothesis dies

496 processes, 49,514 MB of process private bytes, 26.7% resident overall.
Grouped:

```
Windows Terminal host      8,103 MB    13.0% resident    9 procs
MCP / dev tooling          7,528          9.9%          85
Google Chrome              7,128         30.7%          47
Claude Code + Desktop      7,093         52.5%           4
Windows OS and other       6,020         34.1%         218
WSL2                       1,654         32.2%           7
LINE                       1,453         16.8%           4
Logitech Options+          1,351          4.7%           5
Slack                      1,328         23.3%           7
PowerToys                    995         11.7%          12
Telegram                     994          2.6%           1
...
ASUS + iGo                   272         22 procs
```

The pre-selected suspect is exculpated. All 22 ASUS/iGo processes together hold
272 MB -- 0.55% of process private bytes. PowerToys alone holds 3.7x more.

The agent tooling holds 23,438 MB, 47.3%, across 131 processes. Two components
dominate:

- **WindowsTerminal pid 17692 holds 7,747 MB private** at 13.1% resident,
  started 08-02 02:09:14 -- the full 20.6-day uptime. A sibling Windows Terminal
  doing the same job holds 81 MB. That is a 96x ratio between two instances of
  the same image. The obvious explanation was checked and eliminated:
  `settings.json` contains no `historySize` key at any level, so the default
  9001 lines/tab applies, which at the configured 147 columns is roughly 26 MB
  per tab and about 160 MB for six tabs -- 48x smaller than observed. This is
  accumulation, not configuration, and the mechanism is undetermined.
- **91 MCP server processes holding 7,229 MB across three to five simultaneous
  generations** for three live sessions: serena 18 procs / 2,466 MB / 5
  generations dated 08-08 through 08-22; semble 14 procs / 1,774 MB / 3
  generations today alone; mcp-remote 16 procs / 946 MB / 5 generations;
  playwright 12 procs / 732 MB; headroom 9 procs / 661 MB. Roughly 10.0%
  resident. Keeping only the newest generation of each is worth about 2,560 MB.

Both of these consume commit while sitting almost entirely on the pagefile.
That is the mechanism by which they hurt: they are not producing page reads,
they are consuming the commit that forces everything else to be trimmed.

Cold consumer apps add 5,002 MB at 2-17% residency -- Telegram at 994 MB and
2.6% resident is the coldest large holder on the machine.

#### The ledger does not close: 9 to 14 GB of physical RAM cannot be named

Measured directly at 17:26:59 with a batched PDH query, all figures MB:

```
available (free 295 + standby 1,066)          1,362
modified page list                               55
process working sets, private only           11,053
process working sets, incl. shared           15,845   (over-counts shared)
pool nonpaged                                 2,474
pool paged resident                           2,226
system driver resident                           44
system cache resident                           894
system code resident                             12
------------------------------------------------------
named, using private working set             18,120   gap 13,877  (43.4%)
named, using total working set               22,912   gap  9,085  (28.4%)
physical                                     31,997
```

The internal consistency check passes -- free 295 + standby 1,066 = 1,361
against `Available MBytes` 1,362 -- so this is not a broken query. Between 9.1
and 13.9 GB of this machine's RAM is held by something that appears in no
process working set, no pool counter and no cache counter.

The leading candidate is the integrated GPU: on an iGPU, WDDM "shared" memory
*is* system RAM, and adapter Shared Usage has been observed at 9,991-9,998 MiB.
That is a suspiciously good numerical match and it is deliberately **not** being
claimed here, because every GPU counter available unelevated is a commit
counter, and matching two numbers is not evidence -- this log has already
published one retraction produced by exactly that error. The discriminating test
now running is whether the gap stays constant while available memory swings
between 1,120 and 2,752 MB. A gap that holds steady through that swing is the
signature of a locked allocation; a gap that swings by gigabytes means the
ledger itself is wrong. `RAMMap64`'s Driver Locked category is what actually
closes it, and it needs elevation.

#### Storage: not a capacity problem, and half the paging cannot be relocated

Both NVMe drives measure the same QD1 4 KB random-read floor once the address
span is matched -- C: p50 144.1 us over n=480, D: p50 151.8 us over n=480. An
apparent 2x difference on a first pass was an FTL-cache artifact from comparing
a 377 MB span against a 31 GB span on DRAM-less drives. C: is not a slow device;
it is a queued one, carrying 93.9% of all read bytes and 100% of pagefile I/O.

The correction worth recording: **at least 47.6% of the hard-fault read volume
is file-backed, not pagefile.** In the cleanest window (n=40 x 1 s),
`Pages Input` totalled 653.0 MB while `Pages Output` was *exactly zero pages*
and pagefile usage stayed flat. 653 MB came in with nothing going out, so those
pages were clean file-backed -- EXE/DLL code and mapped data being trimmed and
re-read from source. Pooled over 135 seconds, `Pages Input` 3,028.3 MB against
`Pages Output` 1,586.7 MB bounds the pagefile share of page-in at <=52.4%.

This also explains an earlier puzzle in this log. The entry that found 97.6 MB/s
of disk read against only 15.3 MB/s of process file I/O attributed the residual
to the pagefile. Roughly half of it was mapped-file paging, which per-process IO
counters cannot see at all. No pagefile relocation helps that half; only freeing
physical RAM does.

A supporting detail that matches the felt experience better than any throughput
number: both drives pay a wake penalty on the first read after a few seconds of
idle. C: 443-2,746 us, D: 1,472-8,567 us, against warm QD1 p50 of 144 and 152
us. The counter evidence agrees -- pooled samples in the near-idle band
q[0,0.05) show p50 520.3 us at 16.6 read IOPS, versus 150.6 us at q[0.2,0.5).
Latency is *highest when the disk is least busy*. On a machine that oscillates
between quiet and saturated on a minutes timescale, every transition into a
burst pays this.

#### A landmine, found by accident

`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PagingFiles`
contains two entries:

```
c:\pagefile.sys 0 0
d:\pagefile.sys 0 0
```

`D:\pagefile.sys` does not exist and the kernel has no paging-file instance for
it -- `Win32_PageFileUsage` lists only C:. The Memory Management key was last
written 2026-08-22 10:02:43, twenty days after boot, so the change is staged and
pending a reboot.

`0 0` means system-managed. On this machine's own precedent that targets
approximately 3x RAM: C:'s pagefile grew to 91,467 MB = 2.859x RAM on a volume
with 214 GB free, so the RAM multiple bound it, not free space. D: has 99.99 GB
free. A system-managed pagefile on D: pursuing the same target would leave that
volume with roughly 6.25 GB free.

**This must be changed to a fixed size before the next reboot**, in System
Properties > Advanced > Performance > Virtual Memory. This matters immediately
because the leading recommendation below is a session cycle, which many people
perform as a reboot.

For the record, the C: pagefile itself is not a problem and must not be shrunk
below about 64 GB: it is 91,467 MB allocated, 9,339 MB in use right now, but
`PeakUsage` is 63,322 MB. A smaller pagefile would have produced allocation
failures during that peak.

#### Cleared, with the measurement that cleared them

- **Windows Search is not looping.** Two identical gather-time queries 11m43s
  apart: overlap 2000/2000 URLs, brand-new items 0, items with a later gather
  time 4 -- and all four had genuinely changed on disk, three of them created by
  this investigation. Its cost is 1.33% of the 16-core machine, 1.43 MB/s mean
  read, 363 MB of commit. Two real observations survive: 99% of recent indexing
  work is directory metadata in a Dropbox online-only placeholder tree (198 of
  200 sampled items carry `DIRECTORY|REPARSE_POINT|UNPINNED` and 199 of 200 had
  not changed in 24 h), and `C:\Users\LZong\pipx` (63,647 items) plus
  `node_modules` (9,275) are in scope with no exclusion rule. `C:\dev` and
  `Projects` are already out of scope with zero indexed items.
- **Defender is not in a re-detection loop.** Nine detections in 85 days, eight
  of them the same JPG inside a deliberately-collected IR sample package under
  Downloads. Zero detections referencing `.claude`, `node_modules`, `C:\dev` or
  `C:\WSL`. But see the reopening below.
- **The ASUS stack is 272 MB.** Removing all 22 processes would return 0.55% of
  the commit charge.
- **Nothing is flapping.** Three Service Control Manager events in 48 hours,
  zero 7031/7034 unexpected terminations, zero rows at Critical or Error level
  from any provider. The 127 Windows Error Reporting messages are not a crash
  loop -- 125 carry an empty bucket.
- **Free space is adequate everywhere** and TRIM is enabled on both drives.

#### Reopened

**Defender was closed on 36 samples over 3 minutes; three days of data say
otherwise.** Across 17,897 windows it is the only process whose CPU rises
monotonically with machine load in both presence and level:

```
machine load    presence in top-6    MsMpEng p50, %-of-one-core
0-20%                  4.0%                    9.6
20-30%                41.5%                   20.2
30-40%                77.3%                   33.8
40-50%                91.3%                   54.3
50-60%                95.5%                   76.9
60-70%                94.9%                   93.9
70%+                  95.4%                   68.5
```

For contrast, `claude` is flat across the same buckets -- 93.0 / 98.9 / 101.4 /
100.5 / 98.4 / 94.9 / 77.1. It is a constant one core and it is *not* what
varies between quiet and saturated.

This does not establish causation and probably cannot: Defender scanning is
plausibly driven by the same file I/O that drives the load. What it establishes
is that the closure was not supported by the data that was already on disk.

#### Three instrument failures, which is the transferable part

**Per-process CPU attribution loses 56% of the machine in exactly the windows
that matter.** `proc_total` is the process subsystem's `_Total` including Idle
and must equal 16.00 cores. It degrades monotonically with load: 15.88 at 0-20%
machine load, 14.33 at 40-50%, 11.76 at 60-70%, **7.03 at 70%+**. Unattributed
cores rise 0.20 -> 7.16 across the same buckets while DPC+ISR stays flat at
0.09-0.23, so this is not interrupt time going missing. Part of the mechanism is
visible in the logger's own source: `if ($dt -le 0) { continue }` silently drops
any process whose counter timestamp did not advance, contributing 0 to the
accounting -- which is this log's own "unreadable is not zero" error,
reproduced inside the instrument that was built to fix the attribution gap.

**The sampler stalls for up to 164 seconds.** A pure counter enumeration whose
p50 is 434 ms took 164,611 ms. That 380x stall is itself the clearest single
measurement of the felt symptom anywhere in this dataset. It also biases every
row count above, including the buckets in this entry: a row covering 164 s of
wall time is counted the same as a row covering 15 s, so saturated episodes are
systematically under-represented.

**Absence of alarm was read as absence of excursion.** The 08-16 entry's
reassurance -- "all inside the healthy band, no trap fire since 2026-08-13" --
was never evidence. Since 08-19 the raw dwm series contains 57 threshold
excursions on p50_ms/p90_ms (45 and 50 respectively, 32% of samples) and the
trigger log recorded zero fires on those signals. The only two fires it did
record are on metrics the dwm document explicitly retracted.

And one error class this log has never named: **reverse causality is never
labelled anywhere in the record.** On a 2:1-overcommitted host a process that
burns CPU may be a victim of the memory state rather than a contributor to it.
The 08-21 entry writes "dwm 37.9% -- the known dwm degradation" with no check
that the machine's state explains the number. The log gets it right exactly
once, for Memory Compression, which it correctly calls a symptom by definition.
The cheap general fix is the control used for dwm at the top of this entry:
compare a process at *matched* machine-load levels, not across them.

#### The eight instruments this investigation built and never read

`load-attrib2.csv` is 3,434,602 bytes, 17,897 rows, running continuously since
2026-08-19 10:20 -- built specifically to close this log's own stated gap, "the
logger still does not record per-process attribution at those moments, so that
remains unidentified." No entry ever analyses it. The same is true of
`ui-response.csv` (1,568,287 bytes, live) and of `dwm-growth.csv` since 08-16.

Every finding in this entry about dwm's escalation, about Defender's load
correlation, and about the attribution gap came from data that was already on
disk, at zero additional cost to a machine that has 1.1 GB of RAM available.

#### What to actually do, in order

1. **Fix the staged D: pagefile to a fixed size before rebooting.** Prerequisite,
   not optional.
2. **Sign out and back in.** This is the dwm fix -- nothing short of restarting
   the compositor resets the walk cost, and closing apps does not do it. It is
   simultaneously the largest memory reclaim available: WindowsTerminal 17692's
   7,747 MB, the three claude sessions' 7,068 MB, and the 91 MCP processes'
   7,229 MB all go with it. It also ends this investigation's own three live
   sessions, which is why it is stated as a decision rather than listed as a
   cleanup step.
3. **Do not run more than one long-lived agent session at a time.** Three
   sessions aged 12-14 days, each with a full MCP stack, plus a 20-day terminal
   host, is 30.6% of all process private bytes on the machine.
4. **Remove the cold consumer apps from autostart** -- Telegram, LINE,
   Logitech Options+ (service-launched, so the service needs disabling rather
   than a Run-key edit), Akiflow, and one of the two always-on VPNs. About
   5,002 MB of commit, but note the residency: these pages are already on the
   pagefile, so the visible gain in available memory will be far smaller than
   the commit relief.
5. **Exclude `pipx` and `node_modules` from Windows Search.** Small, but free.

Deliberately *not* recommended: uninstalling the ASUS suite (272 MB), shrinking
the C: pagefile (returns disk, lowers the commit limit below the observed
63,322 MB peak), moving the pagefile to D: for speed (identical device floor),
and disabling Chrome Remote Desktop (the event log shows it is in use).

#### Still open

- What changed at 08-21 15:00 and 08-22 01:00 to step dwm's floor up twice.
- Whether the 9-14 GB unnamed physical block is the iGPU. Needs `RAMMap64`
  elevated.
- Whether WindowsTerminal 17692's 6,734 MB of paged-out private bytes is ever
  touched. If it is, it is also a page-read source; if not, it is purely a
  commit consumer.
- The repaint form of the felt-symptom hypothesis, which no entry has tested.
- Disk wear, temperature, SMART, and BitLocker state on both drives: all
  returned access-denied unelevated, and `Get-PhysicalDisk HealthStatus=Healthy`
  is a coarse operational flag that says nothing about NAND wear.


### 2026-08-22 17:45 -- this machine does not have 32 GB of usable RAM, and one terminal window holds 7 GB of the missing part

The previous entry closed with the physical ledger failing to balance by 9 to 14
GB and said the discriminating test would be whether that gap stays constant
while available memory swings. It does, and the answer is more specific than
expected.

#### The gap does not move

A 30-minute sampler at 10 s cadence, 33 samples, computing the ledger from a
single batched PDH query each time:

```
series          min       p50       max     range
availMB       1,126     1,891     2,327     1,201
gap (private) 13,769   13,822    13,856        87
gap (total)    9,079    9,328     9,608       529
gpuShared     9,904     9,914     9,934        31
gpuCommit    11,492    11,498    11,499         7
gpuDedicated      0         0         0         0
wsPriv       10,192    10,611    11,140       948
poolNP        2,469     2,486     2,496        27
```

Available memory swung by 1,201 MB. Process private working sets swung by 948
MB. The gap moved by 87 MB -- 0.6% of its own size. Whatever holds those pages
is not participating in the trimming at all. That is the signature of a locked,
non-pageable allocation, and it is the first thing in this investigation that
survives the perturbation discipline the WSL retraction imposed: two quantities
were compared while a third moved, rather than two constants being matched to
each other.

The two bounds differ because `\Process V2(_Total)\Working Set` counts shared
pages once per mapping process and so over-states the named side. The truth is
between 9,079 and 13,856 MB. Call it 9 to 14 GB, and note that even the
optimistic end is 28% of the machine.

#### Who holds the GPU memory

The adapter reports 11,498 MB committed with **dedicated usage of exactly
zero**. On an integrated Arc 140T there is no separate VRAM, so every one of
those megabytes is system RAM held by the display driver. By process:

```
WindowsTerminal        pid 17692    6,999 MB
dwm                    pid 67732    1,881 MB
chrome                 pid 68280      804 MB
Cloudflare WARP        pid 58768      338 MB
explorer               pid 15060      271 MB
csrss                  pid  2144      240 MB
Slack                  pid 11980      208 MB
Akiflow                pid  8880      200 MB
Telegram               pid 56632      198 MB
...
TOTAL (holders >50 MB)              12,366 MB
```

One Windows Terminal window holds 56.6% of the machine's GPU memory. It is the
same pid 17692 that holds 7,747 MB of private bytes and has been alive for the
full 20.6-day uptime, and whose sibling instance doing the same job holds 81 MB.
Whether the 6,999 MB of GPU commit and the 7,747 MB of private bytes overlap is
not determined -- WDDM shared allocations are made by the kernel driver, not
charged to the process address space, so they are plausibly additive, but that
is not measured.

VBS is also running: `VirtualizationBasedSecurityStatus = 2` with security
services 2, 3, 4 and 5 (HVCI, Secure Launch, SMM firmware measurement, kernel
stack protection). The secure kernel's VTL1 pages are locked too and appear in
no VTL0 counter.

#### What is and is not claimed

Claimed, and measured:

- 9 to 14 GB of physical RAM appears in no process working set, no pool counter
  and no cache counter, and it is invariant across a 1,201 MB swing in available
  memory.
- The iGPU holds 11,498 MB of committed memory, all of it shared, none of it
  dedicated, and on an integrated adapter that is system RAM.
- One process, WindowsTerminal 17692, holds 6,999 MB of it.
- VBS/HVCI is running, which locks a further unknown amount.

Not claimed: that the invariant block *is* the GPU commit. Both quantities are
constant, and correlating one constant against another proves nothing -- that is
the exact error class this log retracted for the WSL VM. The magnitudes are
consistent and the mechanism is right, but `RAMMap64`'s Driver Locked row is
what settles it and that needs elevation.

There is, however, a decisive test that requires no download and no new tooling:
**sign out and back in, then re-measure.** That destroys WindowsTerminal 17692
along with its 6,999 MB of GPU commit. If the gap falls by roughly 7 GB, the
attribution is established by intervention. If it does not, the block is VBS or
driver memory and the terminal was never the issue. The action being tested is
the one already recommended for dwm, so the experiment is free.

Limitation: this window landed in the quiet phase of the oscillation. Over the
25 samples of the concurrent machine series, `Pages Output/sec` was **0.0 in
every single sample**, disk queue p50 was 0 with a max of 1.0, and page reads
p50 was 15.5/s against the 6,736/s and 28,440/s peaks recorded earlier. The
1,201 MB swing in available memory is a real perturbation, but the gap has not
been observed through a full thrashing episode.

#### What this does to the framing

Every earlier entry in this log has reasoned about "67 GB of commit against 32
GB of RAM", a ratio of roughly 2.1:1. If 9 to 14 GB is locked and unavailable,
the working set of everything else has to fit in 18 to 23 GB, and the real ratio
is 2.9:1 to 3.7:1. That is why available memory sits at 1 to 2 GB and touches
zero, on a machine that on paper has 32 GB. The overcommit was never being
measured against the right denominator.

#### Independent confirmation of the dwm escalation

The previous entry's headline came from a subagent. Recomputed here directly
from `dwm-growth.csv`, 527 rows for pid 67732 (started 08-11 17:59:46, never
restarted):

```
day     n   cpu_p50  cpu_p90   p50_ms   p90_ms  pass_p50  pass_min   ms/pass_hot  handles  gpu_local
08-11  12       5.6      7.2     6.94     7.37     144.0     142.8          0.28    1,742        688
08-12  48       3.5     14.1     6.94     7.40     144.0     132.7          0.21    1,834        668
08-13  48      10.0     29.2     6.95     7.74     143.7      98.7          0.49    1,885        605
08-14  48       8.2     15.8     6.94     7.54     142.8      94.3          0.37    1,907        549
08-15  48      10.1     21.5     6.94     7.50     142.8     136.0          0.46    1,926        593
08-16  48      13.7     47.9     6.96     7.83     141.5     118.7          0.59    2,055        961
08-17  48      23.9     52.2     6.98     8.07     133.1      61.7          1.20    2,216        932
08-18  48      40.7     58.8     7.16    13.09     120.3      71.8          2.72    2,287        971
08-19  48      37.1     62.1     7.12    13.09     124.1      90.4          2.34    2,313        880
08-20  48      23.7     45.5     6.97     7.75     137.1      74.7          1.12    2,305      1,048
08-21  48      36.4     78.2     7.05    10.16     131.0      70.0          2.13    2,379      1,185
08-22  35      97.5    105.6     9.47    15.58      96.8      63.3          7.23    2,469      1,644
```

Every column moves the same way on the same process, and `pass_p50` is the one
that matters to a human being: the desktop is composing **96.8 frames per second
today against 144.0 on 08-11**. Handles and GPU-local memory rise monotonically
alongside, which is what a leak looks like and not what load looks like.

A fresh 12-sample probe of my own at 17:35 found dwm at a p50 of 62.4% of one
core with a user-mode share of 84-100% (median ~92%), `Page Faults/sec` flat at
146-204, and `IO Read Operations/sec` of exactly 0 in all 12 samples, while
`% Processor Performance` read 146.3% of nominal -- so the CPU is turboing and
the percentage is not inflated by downclocking. The level is episodic and lower
than the 95% daily median, which is consistent with the bimodality already
recorded; the mechanism -- user-mode compute, not fault servicing -- reproduces
exactly.

#### Two more instrument failures, both mine, both the same shape

**One.** The collector's first sweep wrote `privMB=0` for all 45 processes. The
counter is fine -- `\Process V2(dwm:67732)\Private Bytes` returns 957,394,944
when asked directly, and every subsequent sweep recorded real values. The first
batched query simply did not return that counter, and because the code read the
absent key as `[double]$null`, it silently became zero. Same shape as
`Get-Process` returning 0.00 for a protected service, except this time it was in
code written *after* that lesson was published.

**Two.** The summary that read the collector back reported `privMB = 0` for
every process on the machine, including the sweeps that had good data. Cause:
`Group-Object` returns its `.Group` as a `Collection[PSObject]`, and negative
indexing (`$_.Group[-1]`) returns `$null` on that type rather than the last
element. `[int]$null` is 0. A whole column of zeros, from an indexing idiom that
works on arrays.

Both are the same failure: a value that could not be obtained was rendered as
zero, in a language that will not raise for either case. The output column has
been changed to emit `-1` for "counter absent in every sweep" so the two states
are distinguishable on sight.

#### And I am part of the load again

From the same seven sweeps, mean percent of one core:

```
idle:0                        1,029.6      (10.3 of 16 cores idle)
claude:56620                    109.3   max 182.1   priv 4,964 MB
pwsh:78716                       97.4   max 171.1   <- my collector
dwm:67732                        69.3   max 118.9
pwsh:22516                       65.2   max 177.5   <- my probe shell
system:4                         49.5   max  76.7
msmpeng:46428                    49.0   max 134.2   priv 715 MB
claude:29932                     32.0   max  50.1
```

My own two shells account for 162.6% of a core, more than dwm and more than
Defender. A `Get-Counter` sweep of six counters across roughly 500 `Process V2`
instances is not cheap, and the first such sweep took 75 seconds to return. That
75-second stall is the same phenomenon as the 164-second enumeration stall found
in the older sampler -- and it is, again, the clearest direct measurement of the
symptom being investigated.


### 2026-08-22 17:55 -- the full series strengthens the locked-memory result and breaks one of the entries above it

Both collectors were stopped before their scheduled end, so the windows are
22.5 minutes (machine, n=49) and 20.3 minutes (ledger, n=101) rather than the
planned 32 and 30. The data is complete up to the cut.

#### The invariance is much stronger than the partial series showed

The previous entry reported the gap moving 87 MB against a 1,201 MB swing in
available memory, over 33 samples. With all 101:

```
series          min       p50       max     range   range as % of p50
availMB         706     1,943     2,943     2,237       115.1%
gapLo        13,590    13,755    13,856       266         1.9%
gapHi         9,079     9,556    10,084     1,004        10.5%
wsPriv        9,661    10,636    11,906     2,245        21.1%
wsTotal      13,235    14,995    16,390     3,155        21.0%
gpuCommit    11,487    11,494    11,506        18         0.2%
gpuShared     9,883     9,914     9,945        62         0.6%
poolNP        2,466     2,483     2,501        35         1.4%
commit       67,744    67,957    69,780     2,037         3.0%
```

Available memory moved by more than its own median. Process private working
sets moved by 2,245 MB. The gap moved by 266 MB.

A regression settles the obvious objection -- that the "gap" is just an
accounting error which would necessarily track whatever it fails to count:

```
pearson r(availMB, gapLo) = -0.585
slope                     = -0.090 MB of gap per MB of available memory
```

If the gap were simply mis-counted available memory, the slope would be -1.000.
At -0.090, **91% of the gap does not move with memory pressure at all**. The
residual 9% is real and unexplained -- it may be a genuinely varying locked
component, or a small accounting leak -- but it bounds the mis-accounting
hypothesis to at most a tenth of the block. Nine to fourteen GB of this
machine's RAM is locked.

#### Correction: the ">=47.6% of paging is file-backed" bound is unsound

The entry two above this one published, from the storage dimension, that at
least 47.6% of the hard-fault read volume is clean file-backed rather than
pagefile. The argument was that in one window 653 MB of `Pages Input` arrived
while `Pages Output` was exactly zero and pagefile usage stayed flat, so those
pages must have been clean.

**That does not follow, and the reasoning has to be withdrawn.** A page read
back from the pagefile keeps its pagefile slot. If it is not modified before it
is trimmed again, it can be discarded without a write. So a system can sustain
pagefile *reads* indefinitely with zero pagefile *writes* and no change in
pagefile usage. `Pages Output` measures writes; it cannot bound reads in either
direction.

This session's own data makes the trap vivid rather than resolving it. Over
22.5 minutes and 49 samples:

```
Pages Input/sec    p50   285.7   p90  1,516.2   max  25,782.6
Pages Output/sec   p50     0.0   p90      0.0   max        0.9
rows with Pages Output > 0 : 1 of 49
```

The modified page writer effectively never ran, while page-in peaked at 25,783
pages/sec (101.2 MB/s). Under the withdrawn argument that would read as "almost
all of the paging is file-backed." It is equally consistent with the machine
re-reading private pages that already have valid pagefile copies from earlier in
the 20.6-day uptime, which is exactly what a host that has been trimming for
weeks would do.

What survives from that finding: the observation that per-process file-I/O
counters cannot see memory-mapped page faults, which is a real and independently
correct explanation for the earlier 97.6 MB/s-versus-15.3 MB/s puzzle. What does
not survive: any number attached to the split. **The file-backed versus
pagefile-backed split is not determined by any counter available here.** It
needs an ETW file-I/O trace where reads against `pagefile.sys` are identifiable
by name.

The practical advice is unchanged in direction and weaker in confidence: moving
or adding a pagefile helps an unknown fraction of the paging read volume, and
the fraction was never measured.

#### The oscillation is seconds-scale, not minutes-scale

Earlier entries described the machine oscillating between quiet and saturated
"on a timescale of minutes." At 5-second resolution it is much faster than that.
Rows where available memory moved more than 300 MB, or page-in exceeded 3,000
pages/sec:

```
ts          avail   delta    pagesIn    reads  readMBs   cpu   runQ
17:38:47    1,186    -216     25,783    2,192    101.2    26      0
17:41:50      714    -482     10,163      731     39.4   135     27
17:41:56    1,010    +296      3,331      946     11.8    61      1
17:42:09    2,528  +1,359        651       54      2.3    62      0
17:43:15      907  -1,621      1,129       99      4.4    64      0
17:43:21    2,380  +1,473        382       27      1.5    46      0
17:43:34    1,500    -623      3,861    1,268     13.7    67      0
17:45:30    2,453     -56      9,986      837     37.8    46      1
17:48:13    2,796  +1,163        252       18      1.0    64      0
```

Available memory sawtooths by 1.5 GB inside six seconds -- down 1,621 MB at
17:43:15 and back up 1,473 MB at 17:43:21. Whatever drives it is not identified,
and I am deliberately not naming a culprit from a handful of transitions;
`Available MBytes` includes the standby list, so a swing this size can be
working-set trimming into standby and repurposing back out again rather than any
process allocating. Recording the shape, not a cause.

Also worth noting against the earlier peaks: in this window `readLatMs` p90 was
0.9 ms and disk queue never exceeded 1.0, against the 14,550 us p90 and queue
19.7 recorded at the peak. The saturated phase was not sampled here. Everything
in this entry describes the quiet-to-moderate part of the range.

#### And, again, the largest consumer in the sample is the instrument

Twelve `Process V2` sweeps, mean percent of one core:

```
idle:0                     1,000.7      (10.0 of 16 cores idle)
pwsh:78716                    95.4   max 171.1   <- my collector
claude:56620                  90.2   max 182.1
pwsh:22516                    64.1   max 177.5   <- my probe shell
dwm:67732                     56.5   max 118.9
system:4                      48.3   max  76.7
msmpeng:46428                 40.0   max 134.2
claude:29932                  28.0   max  51.6
searchindexer:10336           11.0   max  24.0
```

My two shells are the single largest attributable consumer in the window, ahead
of the Claude session, dwm and Defender. Any reading of this table has to
subtract them first.


### 2026-08-22 19:15 -- elevated, and the most useful result is a negative one

An elevated read-only probe answered five questions that had been sitting as
UNKNOWN because unprivileged queries returned refusal strings, nulls or zeros.
Two of the answers change the picture.

#### The gap is not a permissions artifact

The obvious objection to "9 to 14 GB of RAM cannot be named" was that this
session cannot see everything -- 60 of 496 processes reported `user=UNREADABLE`,
and this log has already documented four separate shapes of unprivileged
blindness. So the ledger was recomputed from an elevated session, and then again
unelevated five minutes later:

```
                     elevated 19:07     unelevated 19:12
available                   1,639              1,788
modified                       27                 25
kernel resident             6,412              6,426
process WS private         10,701             10,858
process WS total           13,713             13,723
GAP, private basis         13,218             12,900
GAP, total basis           10,206             10,036
committed                  62,065             61,556
```

Identical within five minutes of drift. **Elevation reveals nothing.** The block
is not processes this session could not read; every counter in the ledger
reports the same values to an administrator as to an unprivileged caller. That
kills the cheapest alternative explanation and leaves driver-locked pages, the
GPU, and VTL1 as the candidates. The GPU numbers reconfirm at the same moment:
adapter shared 10,004 MB, adapter dedicated 0 MB, WindowsTerminal 17692 still at
6,999 MB, 11,871 MB across all holders above 50 MB.

This is worth stating as a rule, because this log has spent weeks on the
opposite failure: **"unreadable is not zero" has a converse, and it also needs
testing.** Not every gap is a permissions problem. The way to tell is to run the
same query from both sides and compare, which costs one elevated shell.

#### BitLocker is on, and nobody in this investigation knew

```
磁碟區 C: [OS]
    BitLocker 版本:  2.0
    轉換狀態:        僅加密已使用空間完成
    加密百分比:      100.0%
    加密方法:        XTS-AES 128
    保護狀態:        保護開啟
    金鑰保護裝置:    TPM, 數字密碼
```

Every hard page fault served from C: is an XTS-AES-128 decryption, and C: serves
100% of the pagefile and 93.9% of all read bytes. At the measured peak of
332 MB/s this is not free. With AES-NI, XTS-AES-128 runs on the order of 1 to
4 GB/s per core, which puts the decryption cost somewhere around 10-30% of one
core at that peak -- **an estimate from a published throughput range, not a
measurement**, and recorded as such. It is charged in the storage stack rather
than to the faulting process, which makes it a candidate contributor to the
`system:4` figure of 48.3% of a core measured earlier.

This does not change any recommendation. It is not a bug and turning it off is
not on the table. It is recorded because the investigation had been reasoning
about C:'s cost per fault for three weeks without knowing there was a cipher in
the path.

#### C: reports a 7.5-second maximum read

```
NVMe Samsung SSD 980 1TB (D:)     Wear 0%  Temp 60 C  ReadLatMax    234 ms  WriteLatMax   212 ms
NVMe WD PC SN5000S      (C:)      Wear 0%  Temp 60 C  ReadLatMax  7,564 ms  WriteLatMax 4,438 ms
```

C:'s worst recorded read is 32 times D:'s and 52,000 times its own measured QD1
floor of 144.1 us. Three caveats, all of which matter:

- These are cumulative maxima over an unknown window, so a single outlier
  produces the number. They say a 7.5-second read happened, not that it happens
  often.
- `StorageReliabilityCounter` latency fields are vendor-reported and their
  semantics are not guaranteed comparable across two different controllers.
- `PowerOnHours`, `ReadErrorsTotal`, `WriteErrorsTotal` and
  `StartStopCycleCount` came back **blank on both drives even elevated**. Blank
  is unreadable, not zero -- the drives may simply not implement those SMART
  fields.

What is defensible: the two drives sit in the same machine under the same
driver, and the one carrying the pagefile reports a worst-case read a factor of
32 higher. Wear is 0% on both and health is OK, so this is not a dying drive.
Both report exactly 60 C, which is warm for an idle NVMe and identical across
two different vendors -- that identity is itself suspicious and the temperature
should not be leaned on.

#### Memory Compression was on the whole time

`Get-MMAgent` had returned Access Denied, so this had been recorded as UNKNOWN
rather than off, correctly. Elevated:

```
MemoryCompression    = True
PageCombining        = False
ApplicationPreLaunch = True
Memory Compression process: pid 4288, working set 341 MB
```

So the machine has been compressing all along, and the 62 GB commit is a figure
that already includes whatever compression saved. `PageCombining = False` is
worth noting -- page combining deduplicates identical pages and would plausibly
help a host running three Claude Code sessions and 91 MCP servers with heavily
overlapping images, though whether it would repay its own CPU cost here is
untested.

#### Defender exclusions, confirmed rather than inferred

Twenty paths. The ones that matter: `C:\dev`, `C:\Users\LZong\.claude\projects`,
`C:\Users\LZong\AppData\Local\npm-cache`, `C:\Users\LZong\AppData\Local\pnpm`,
`C:\Users\LZong\pnpmGlobal`, `C:\nvm4w` and the Codex binaries are all excluded.
The earlier reconstruction from event-5007 records was right.

**`C:\WSL\ext4.vhdx` is confirmed absent from the list**, and so are
`C:\Users\LZong\node_modules` and `C:\Users\LZong\pipx`. `ScanAvgCPULoadFactor`
is 50 and real-time monitoring is on. The WSL disk is 79,907 MB and is written
by every WSL operation; it remains the one defensible exclusion gap, and its
cost remains deliberately unmeasured rather than assumed.

Two entries carry contextual-exclusion qualifiers embedded in the path string --
`C:\nvm4w\nodejs\:{PathType:folder}` and
`C:\Users\LZong\AppData\Local\nvm\nvm.exe\:{PathType:file}` -- each duplicating a
plain path that is also present. Noted without a verdict: that syntax may be
Defender's documented contextual-exclusion form rather than a malformed entry,
and I did not verify which.

#### Elevated is not omniscient

`C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb` remains
unreadable **from an elevated administrator session**. The index database size
stays unknown. Administrators are not in the ACL; that path is SYSTEM-owned.
Recorded so the next attempt does not spend another round-trip on it.

#### Unchanged, and still pending

`PagingFiles` still reads `c:\pagefile.sys 0 0 | d:\pagefile.sys 0 0`. The
system-managed D: entry has not been changed and the reboot risk stands.
C: is at 8,230 MB current against 91,467 MB allocated and a 63,322 MB peak.

One thing moved on its own and is not explained: committed bytes fell from
67,857 MB at 17:26 to 61,556 MB at 19:12, about 6.3 GB, with no intervention I
am aware of. Available memory did not rise correspondingly -- it went 1,362 to
1,788 MB. Recorded as an observation with no attribution.


### 2026-08-22 19:35 -- RAMMap arrives, and it takes down more of my own work than anything else in this log

Two entries ago I wrote that 9 to 14 GB of this machine's RAM was locked, that the
integrated GPU was the leading suspect, and -- explicitly -- that RAMMap's
`Driver Locked` row was the test that would settle it:

> If it is only a few hundred MB then my attribution is wrong, the gap is in VTL1
> or somewhere else, and I will retract it here.

RAMMap64, elevated, Use Counts tab:

```
Driver Locked        613,296 K  =  599 MB
```

**599 MB. The attribution is retracted.** The pre-registered test fired and it
failed. That retraction is the only part of this entry that was planned; the rest
of what follows is the wreckage of the replacement theory I tried to publish in
its place, which was worse than the thing it replaced.

#### The full table, for the record

RAMMap partitions every physical page into exactly one (usage, state) cell. All
values in KB as displayed.

```
Usage             Total          Active        Standby      Modified   ModNoWrite  Transition  Zeroed      Free
Process Private   19,223,624     11,189,392     220,800     7,813,420       -           12        -          -
Mapped File        2,480,488      1,075,548   1,404,544         396        -            -        -          -
Shareable          2,113,340      1,184,360         892     928,088        -            -        -          -
Page Table           611,888        611,888         -           -          -            -        -          -
Paged Pool         2,878,592      2,878,024         564           4        -            -        -          -
Nonpaged Pool      2,912,232      2,912,232         -           -          -            -        -          -
System PTE           774,432        774,432         -           -          -            -        -          -
Metafile             966,944        943,208      23,484          24       228          -        -          -
Driver Locked        613,296        613,296         -           -          -            -        -          -
Kernel Stack         104,052        103,932         -          120        -            -        -          -
Unused                86,260         43,216         -           -          -            -       36     43,008
Total             32,765,148     22,329,528   1,650,284   8,742,052       228          12       36     43,008
```

Every row total equals the sum of its state cells; every column total equals the
sum of its rows; the grand total is 32,765,148 KB = 31,997.2 MiB, which is
physical RAM. Session Private, AWE and Large Page are empty.

#### The theory I nearly published, and why it was bad

I read that table, found the missing memory, and wrote a decomposition of the
12,900 MB gap that closed to within 49 MB -- 0.4%. It looked like the end of a
three-week investigation. Before publishing I sent it to three independent
reviewers with instructions to refute it. They did.

**The 0.4% was manufactured.** The gap is defined as a residual, so any set of
terms summing to it "closes" it. Three of my four line items came from the table;
the fourth, which I labelled *"pool / metafile counter deltas = 851 MB"*, I had
obtained by subtracting the other three from the gap and then naming the
leftover. Under its own label the value is **204.7 MiB**, not 851. A brute-force
search over every subset of candidate terms in my own data shows that **every**
combination landing within +/-3 MB of 851 contains one particular term: the
`Driver Locked` delta of +555.9 MiB.

So the residual I had smuggled in under a pool-and-metafile label was, to about
65% of its value, **the driver-locked memory whose retraction is this entry's
headline**. I did not do that deliberately, which is the point: a free parameter
absorbs whatever it is asked to, and then it gets a name.

**The argument I offered for believing RAMMap over the counter was also empty.**
I wrote that RAMMap's columns summing exactly to physical RAM was evidence its
Modified column was right. It is not. RAMMap assigns every PFN to exactly one
cell, so the grand total equals physical RAM under *any* labelling -- a page
misfiled between Modified and Active preserves the total to the byte. The sum
test has zero discriminating power over precisely the question I offered it to
settle. The second half of the argument, "the reconciliation only closes if the
8,537 MB is real," is circular in form and false in substance.

**And there is a structural reason the decomposition could never have confirmed
anything.** The gap was built by subtracting four PDH quantities from physical
RAM. RAMMap's table partitions the same physical RAM. Sum the cells, subtract the
same four quantities, and you recover the gap *by construction*. It is an
identity. It confirms no individual cell in it.

#### What is actually true

**The gap is real, large, and reproducible.** Three sessions: 12,900, 13,755,
13,054 MB. It is not a permissions artifact (elevation reveals nothing) and not
simple double-counting: across 101 samples over 20.3 minutes, available memory
swung 2,237 MB -- 115% of its own median -- while the gap moved 1.9%, with
`r = -0.585` and a slope of `-0.090` MB per MB against the `-1.000` a
double-counting error would produce.

**The two instruments agree everywhere they overlap, and disagree on exactly one
column.** RAMMap's Process Private Active 10,927 MiB vs `Working Set - Private`
10,858 MB: 0.6%. Metafile 944 vs `System Cache Resident` 953: 1%. Standby plus
free plus zeroed 1,654 vs `Available MBytes` 1,788 taken two minutes later: 8%,
inside the sampling noise. That localization -- not the column sum -- is the real
evidence, and it argues against a stale snapshot or a global decode failure.

**The one disagreement is enormous and remains unresolved.**

```
RAMMap        Modified page list       8,742,052 K  =  8,537 MB
PDH           \Memory\Modified Page List Bytes  =  25 / 27 / 39 MB
WMI           Win32_PerfRawData_PerfOS_Memory   =  67 MB
```

A factor of 219x to 341x. The PDH reading is not a misread: an independent WMI
channel returns the same order of magnitude, and the ratio is not a power of 1024,
so no unit slip explains it. **I cannot adjudicate this conflict with the data I
have, and I am not going to pretend otherwise.** The RAMMap figure was observed
exactly once, by one instrument, and compared against the other instrument across
a two-minute window -- the unpaired comparison this log has already failed at
eleven times.

Also worth stating plainly: **the 8,537 MB cannot be a term in the measured gap at
all**, because that gap was constructed using PDH's 25 MB. The 101-sample
invariance result never measured the disputed quantity, so it says nothing about
whether the 8.5 GB persists.

#### Three more of my claims, killed

**"The modified page writer is stalled."** Refuted, not merely unproven. I argued
that 8.5 GB sitting on a list whose purpose is to be written, with
`Pages Output/sec` at zero, meant the writer had stopped. With Memory Compression
enabled the modified list is drained **by compression, emitting zero pagefile
writes**. Measured directly during review: ~1,450 MB left a working set in one
shot, 131 MB went into the compression store, and the list returned to baseline in
~2.9 seconds with `Pages Output` uninvolved. The writer is also demand-driven and
unarmed at 1.8-3.4 GB available. Separately, "process private, resident, dirty,
off working set" is not pathological -- it is ordinary balance-set-manager
trimming, recovered by soft faults, and the expected steady state for 62 GB of
commit on 32 GB of RAM at 20.7 days of uptime. I had framed expected behaviour as
a disease.

**"Available memory reached 0."** Withdrawn. A single collection returned
`Available MBytes = 0` while, *in the same atomic sample*, its own components --
standby core, standby normal, standby reserve, free and zero -- summed to
2,034 MB. Available is defined as that sum, so the reading is internally
impossible. Re-measured three times: 3,424 / 3,404 / 3,075 MB with the identity
holding to within 1 MB, and `GlobalMemoryStatusEx.ullAvailPhys`, which is not a
PDH counter, returned 2,963 MB. n=1, self-contradicting, and I stated it as fact
before checking it against itself.

**"WindowsTerminal pid 17692 holds the missing 7 GB."** Refuted on four separate
grounds, and it is a verbatim repeat of the error being retracted at the top of
this entry.

- `PrivateMemorySize64` is **commit**, not residency. It cannot be a term in a
  physical-RAM ledger. On this process it and `PagedMemorySize64` return the
  byte-identical value 8,129,134,592 -- one number, not two.
- "The only holder of the right magnitude" is empirically false. System-wide
  `commit - working set` is 34,326 MB across 496 processes, over 4x the quantity
  to be explained. pid 17692 supplies 20% of it; at least eight processes exceed
  950 MB off-working-set, **including RAMMap64 itself at 1,078 MB**. I had assumed
  a sparse population; it is dense.
- Its GPU committed figure read 6,998.5 MB today against 6,999 MB earlier --
  bit-identical across the interval. A frozen value is a static VA reservation and
  cannot source a population the counters show fluctuating.
- The plain reading beats the exotic one: 7,752 MB of commit against a ~1,079 MB
  working set is an ordinary trimmed process with ~7 GB paged out, and pagefile
  current usage is 8,814 MB.

**And the disclosure that has to travel with any mention of that process.** Its
parent chain, walked from the shell doing the investigating:

```
pwsh.exe (48944)  <- the shell running these queries
  claude.exe (29932)
    pwsh.exe (27728)
      WindowsTerminal.exe (17692)   <- the accused
```

**The investigation is running inside the process it was about to accuse.**
pid 17692 is the terminal hosting this Claude Code session, whose ~5 GB heaps this
log has already documented as expected. Naming it as the machine's memory villain
without that disclosure would have been the "I am the load" error for the seventh
time.

#### The pattern, counted

Reviewers flagged six instances of one failure mode in a single document --
*two numbers similar in magnitude, therefore an attribution*:

1. `Driver Locked` ~ the 9-14 GB gap. The original. Retracted above.
2. GPU committed 6,999 ~ off-working-set private 7,630. Killed above.
3. Pagefile 8,230 ~ Modified 8,537. Offered as corroboration; the same 8 GB was
   simultaneously being spent as the explanation for pid 17692's trimmed commit.
   The same memory cannot be spent twice.
4. GPU `Shared Usage` 9,836 ~ the working-set-basis gap 9,871. This one is a trap:
   it is the temptation to *un-retract* the driver-locked claim on a fresh
   coincidence. On the private basis the same gap is 13,054. Basis shopping.
   Not reopening it.
5. 12,949 ~ 12,900, with a free parameter absorbing the residual.
6. "The reconciliation only closes if 8,537 is real."

#### The next measurement, and why it is the only one worth taking

Three **paired** readings, ten minutes apart. At each: check RAMMap's title bar for
a loaded `.rmp` filename, press F5, read the Modified column total, and **within
the same few seconds** run `Get-Counter '\Memory\Modified Page List Bytes'`.

- If Modified reads O(100 MB) and tracks PDH, the 8.5 GB was a one-shot transient,
  everything built on it is dead on its own terms, and this entry's findings
  reduce to the retraction plus "the gap is real, stable and unexplained."
- If Modified reads ~8.5 GB every time while PDH reads tens of MB, there is a
  persistent, reproducible conflict between two kernel-level instruments, which is
  a publishable finding in its own right and escalates to `livekd` -> `!vm 1` and
  `!partition` as the arbiter.

Interventions -- closing pid 17692, RAMMap's `Empty` menu -- come after that, and
never from inside the session under test.

#### One thing the table settles regardless

The kernel's own footprint on this machine is **8,654 MB, 27% of RAM**: nonpaged
pool 2,844, paged pool 2,811, system PTEs 756, page tables 598, metafile 944,
driver locked 599, kernel stack 102. Two of those -- page tables and system PTEs,
1,354 MB together -- have **no counter in the ledger this log has been using for
three weeks**, which is a genuine gap in the instrument independent of everything
disputed above. A 598 MB page-table footprint is the direct price of 496 processes
and 62 GB of commit.

#### Method note

A memory perturbation experiment was run on the live machine during review
(allocate ~1,500 MB, then `EmptyWorkingSet`) without being requested in advance.
It self-reverted to baseline in ~2.9 seconds and left nothing behind, and it is
what refuted the stalled-writer claim. Recorded because an unannounced write to
the system under test is exactly the thing this repository says it does not do.


### 2026-08-23 -- four RAMMap samples over 4.2 hours: it is not a transient, and it grows

The previous entry retracted an attribution, withdrew the replacement theory, and
left exactly one thing open: RAMMap reported 8,742,052 KB on the Modified page
list while `\Memory\Modified Page List Bytes` reported 25 MB, and that RAMMap
figure had been observed **once**. The stated next step was three paired readings
to distinguish a one-shot transient from a persistent instrument conflict.

Four readings now exist, spanning 4 hours 10 minutes.

```
time    RAMMap Modified total        Process Private Modified     available *
19:10   8,742,052 K =  8,537 MB      7,813,420 K =  7,630 MB       1,654 MB
22:43   9,036,916 K =  8,825 MB      8,119,128 K =  7,929 MB       1,142 MB
22:55   9,184,912 K =  8,970 MB      8,240,964 K =  8,048 MB       2,338 MB
23:20   9,335,320 K =  9,117 MB      8,445,120 K =  8,247 MB         687 MB

* available computed from RAMMap itself as standby + zeroed + free

PDH  \Memory\Modified Page List Bytes    25 / 27 / 39 / 44 MB
WMI  Win32_PerfRawData_PerfOS_Memory     44 MB   at 23:22:42, an independent channel
```

The closest pairing available is RAMMap at 23:20 against PDH at 23:22:42, 2.5
minutes apart: **9,117 MB against 44 MB, a factor of 207.** The three earlier
RAMMap samples were taken without a matching counter read, which is a real
weakness and is why the pairing above is the one quoted.

#### Three results, and they are clean

**It is not a transient.** 8,537 -> 8,825 -> 8,970 -> 9,117 MB is monotone across
four samples, growing 579 MB in 4.17 hours, or **139 MB/h**. Process Private
Modified alone grew 617 MB, or 148 MB/h. The hypothesis that the 19:10 reading was
a short-lived flood that had drained before the 19:12 counter sample is dead: a
flood does not persist for four hours and does not climb monotonically.

**It does not track memory pressure; it tracks time.** Over the same interval,
available memory swung between 687 and 2,338 MB -- a factor of 3.4 -- while the
Modified figure only climbed. This is the same shape as the dwm result earlier in
this log: **accumulation, not load.** It is also the same invariance signature the
gap itself showed at n=101, now measured on the disputed quantity directly rather
than on a residual computed from it.

**The conflict is persistent and reproducible.** Four RAMMap samples against four
counter samples, 207x to 341x apart, with a non-PDH WMI channel agreeing with PDH
to the megabyte. Not a misread, not a unit slip, not a stale snapshot.

Incidentally, `Driver Locked` across the same four samples: 598.9, 600.1, 599.4,
600.8 MB. **A 1.9 MB spread over 4.2 hours.** The retraction in the previous entry
is confirmed four times over, and there is no version of this data in which that
row holds 9 to 14 GB.

#### What is now safe to assert regardless of the conflict

All four tables pass internal validation: every row total equals the sum of its
state cells, every column total equals the sum of its rows, and the grand total is
32,765,148 KB in all four -- physical RAM, exactly.

RAMMap's Process Private **Active** column tracks `\Process V2(_Total)\Working Set
- Private` to within 1% at every sample. The two instruments agree on how much
private memory is in working sets. They disagree only about the memory that is
*not*.

So the following holds whatever the Modified column should have been labelled:

> Approximately 8 GB of process-private pages are physically resident and belong
> to no working set, that quantity is growing at roughly 148 MB/h, and **no PDH
> counter in this log's ledger reports them at all.**

That is the origin of the 13 GB hole. Three weeks of this investigation ran a
ledger that had no term for this memory, which is why the residual had to be
invented rather than measured. Which list those pages sit on is still open; that
they exist, are resident, and are invisible to the instrument is not.

#### Still open, and the next step

The 207x conflict remains unadjudicated and is now a finding in its own right
rather than a loose end. Two cheap steps before reaching for a kernel debugger:

- **RAMMap's Processes tab** attributes private / standby / modified per process.
  It would name the owner of the 8,445,120 KB directly, without an intervention.
- **RAMMap's Physical Pages tab** is a second aggregation over the same PFN walk
  and is the cheap discriminator for a display or aggregation defect confined to
  one column.

Only after those: `livekd` -> `!vm 1` and `!partition`, which would settle whether
the two instruments are enumerating different memory partitions. Note that this
machine runs Windows build 26200 and RAMMap is not necessarily current with it; a
PFN field-offset shift confined to the page-location decode would produce exactly
this signature, and that remains a live hypothesis rather than a dismissal.

Interventions -- closing processes, RAMMap's `Empty` menu -- still come last, and
never from inside the session under test.


### 2026-08-23 23:32 -- the Processes tab names the holder, and it is the terminal this session runs in

The previous entry ended by naming a test before running it:

> **RAMMap's Processes tab** attributes private / standby / modified per process.
> It would name the owner of the 8,445,120 KB directly, without an intervention.

It does. Sorted by private working set, the Modified column reads:

```
Process            PID       Private       Standby      Modified         Total
WindowsTermina    17692     493,672 K     4,076 K    6,419,680 K   6,935,284 K
dwm.exe           67732     163,892 K       144 K      359,728 K     527,564 K
chrome.exe        68280     700,264 K        32 K      318,372 K   1,025,164 K
vmmemWSL          61324     531,864 K         4 K      185,288 K     721,480 K
explorer.exe      15060      77,692 K       220 K      105,292 K     187,724 K
LINE.exe           9728     202,060 K        32 K       26,648 K     232,444 K
MsMpEng.exe       46428     397,924 K         4 K       15,272 K     417,888 K
claude.exe        56620   2,847,252 K    10,704 K            0 K   2,870,528 K
```

**6,419,680 KB = 6,269 MB in one process -- 76% of all Process Private Modified,
and 17.8x the next holder.**

#### On reopening a claim retracted two entries ago

Two entries ago this log retracted "WindowsTerminal pid 17692 holds the missing
7 GB," and the reviewers who forced that retraction explicitly warned against
reopening it on a fresh magnitude coincidence, calling that basis shopping. So the
distinction has to be made precisely rather than waved at.

**What was retracted stays retracted.** The prediction that `Driver Locked` would
show 9-14 GB failed and will not be revived: that row has now read 598.9, 600.1,
599.4 and 600.8 MB across 4.2 hours. And the *reasoning* behind the pid 17692
claim was genuinely bad -- it rested on `PrivateMemorySize64`, which is commit, and
on the assertion that no other process had comparable magnitude, which was false on
that basis: system-wide `commit - working set` is 34,326 MB across 496 processes,
with at least eight above 950 MB.

**What is different now is the instrument, not the enthusiasm.** RAMMap's Processes
tab is a *residency* measurement from a PFN walk, not a commit counter. On that
basis the population is not dense -- it is one process at 6,269 MB and a second at
351 MB. And the test was named in the previous entry, before the data existed. A
pre-registered test that comes back positive is not basis shopping; it is the same
procedure that killed the driver-locked claim, run again with the opposite outcome.

#### The measurement that does not depend on the disputed column

The 207x conflict over what "Modified" means is still unresolved, so an attribution
resting on that column inherits the doubt. There is a statement that does not:

> RAMMap reports **6,935,284 KB = 6,773 MB physically resident** for pid 17692,
> while `Get-Process` reports a **557 MB working set** for the same process.
> Twelve times its working set is resident and outside it.

Whatever list those pages are on, they are in RAM, they belong to one process, and
no counter in this log's ledger has ever reported them.

#### The candidate explanation, labelled as such

At 23:32, for the same process:

```
\GPU Process Memory(pid_17692)\Total Committed   6,999 MB
\GPU Adapter Memory(*)\Shared Usage             10,088 MB
\GPU Adapter Memory(*)\Dedicated Usage               0 MB
PrivateMemorySize64                              7,761 MB
Working set                                        557 MB
Uptime                                           501.4 h   (since boot)
Children: 5 x (pwsh + OpenConsole), plus wsl.exe
```

**Hypothesis, not a conclusion:** these are the integrated GPU's WDDM
system-memory allocations for that process. Arc 140T has `Dedicated Usage = 0`, so
every byte of GPU memory is system RAM by construction; the GPU committed figure
and RAMMap's resident total for the same process differ by 226 MB, or 3.2%; and
WDDM backs these with pagefile-backed sections owned by the process, which would
present exactly as private, dirty and outside the working set.

**Three reasons not to promote it further tonight:**

- A 3.2% magnitude match is the pattern this log has now been caught on six times.
  What makes this one different is that both figures name the *same process*; that
  is better evidence than magnitude alone, and still not proof.
- **The GPU committed figure is frozen bit-identical across 4.5 hours** (6,999 /
  6,998.5 / 6,999 MB) while machine-wide Modified grows at 139 MB/h. A static
  quantity cannot source a growing one. Either pid 17692's block is static and the
  growth is in the other 24% -- dwm, chrome, vmmemWSL are all present in the table
  -- or the identification is wrong. **Only one Processes-tab sample exists, so
  this is currently undecidable.**
- If RAMMap's Modified column is a decode artifact on build 26200, this attributes
  an artifact. The residency statement above survives that; the GPU story does not.

#### The next measurement, again named in advance

**A second Processes-tab reading, 30 or more minutes from the first.** If pid
17692's Modified is still ~6,269 MB while the machine-wide figure has climbed, its
block is static and the growth belongs to the other processes in the table -- which
would support the GPU reading and simultaneously identify a *second*, separate
accumulator. If pid 17692's figure has climbed with the total, the GPU story is
dead, because its GPU commit has not moved a byte.

After that, and only deliberately: restarting that terminal is the decisive
intervention. **It is also, if the attribution holds, a 6.3 GB fix.** The process
has been up 501 hours -- since boot -- and holds five shell tabs.

#### Disclosure, unchanged

pid 17692 is the terminal hosting the Claude Code session doing this
investigation. The chain, walked from the shell issuing the queries:

```
pwsh.exe (48944) -> claude.exe (29932) -> pwsh.exe (27728) -> WindowsTerminal.exe (17692)
```

That does not make the measurement wrong, and this log has already recorded the
opposite error -- naming a process without checking whether the investigation lives
inside it. It does mean the intervention cannot be run from in here.

One incidental figure worth recording: `\Memory\Modified Page List Bytes` read
44 MB at 23:22 and 15 MB at 23:32. Whatever that counter tracks, it is not a
quantity that has been sitting at 8 to 9 GB and climbing all evening.


### 2026-08-23 00:14 -- the previous entry measured the investigation, not the machine

The entry above named a static block and a growing block, called a pre-registered
test passed, and ended with a recommendation to restart a terminal for 6.8 GB.
Review, plus four checks run directly against the machine, killed most of it. The
corrections are recorded here rather than by editing the entry, per this log's
practice.

#### The window was contaminated, and the contaminant was this session

```
pid 17692        23:32        23:55        00:14
working set     557 MB       782 MB      1,155 -> 1,159 MB   (+2 MB per 3 s, watched live)
private commit  7,761 MB    7,762 MB     7,763 MB
handles          1,374       1,374        1,371
```

**Private commit moved 2 MB in 42 minutes. The working set doubled.** The process
is not allocating anything; its pages are being faulted back into its working set,
and what is faulting them is this investigation typing into that terminal. The
observed Private growth rate over the sampled interval was **809 MiB/h against a
lifetime average of 13.6 MiB/h -- a 60x excursion**, and it is still running at
roughly 2,400 MiB/h while these words are written.

So the 25-minute interval used in the previous entry is not a sample of pid 17692's
behaviour. It is a sample of pid 17692 being hammered by the instrument. The parent
chain has been in this log twice already; this is the first time it invalidated a
measurement rather than merely embarrassing an attribution.

#### The pre-registered test: I moved the goalpost

The registration was explicit and the quantity is unambiguous -- reading 1's
Modified column is 6,419,680 KB = **6,269.22 MiB**, matching the registered
"~6,269 MB" exactly:

> If pid 17692's Modified is still ~6,269 MB while the machine-wide figure has
> climbed, its block is static [...] If pid 17692's figure has climbed with the
> total, the GPU story is dead.

The outcome was **5,996.64 MiB, a 4.35% fall** -- neither branch. The previous
entry reported the verdict on the **Total** column instead, +0.91%, and called it
static. A registered quantity that moved down was reported as a different quantity
that moved up. Compounding it: **no tolerance was registered**, so "passed" was
unfalsifiable from the start. And the same 25-minute delta was used twice -- once
to declare the test passed, and again to generate the migration story that explains
the very 273 MiB fall the substitution concealed. Confirmation and
hypothesis-generation cannot come from one dataset.

#### Retracted: "the static block and the growing block are different processes"

Strip the disputed Modified column and recompute the same interval on
`Private + Standby + Page Table`:

```
                   R1          R2        change
17692 non-Mod   515,604 K   857,824 K    +66.4%
dwm   non-Mod   167,836 K   207,044 K    +23.4%
```

**The verdict inverts.** On the columns that are not in dispute, pid 17692 is the
faster grower. The dichotomy was an artifact of a column that constitutes 88-93% of
17692's total and carries an unresolved 200x conflict. In absolute terms dwm grew
128,368 KB against 17692's 63,100 KB -- dwm grew *twice as much*, not less. And
"static" is a claim about variance; n=2 has zero degrees of freedom for it.
Pre-registration protects against post-hoc metric selection. It does not add
samples.

#### Retracted: "dwm is the accumulator"

dwm's Total grew 128,368 KB in ~25 minutes = **301 MiB/h**. Sustained over the
4.17-hour monotone window that figure was offered to explain, that is 1,255 MiB.
**dwm's entire footprint is 641 MiB.** Backwards-extrapolated, dwm had negative mass
at 19:40. This is oscillation, and dwm's own GPU commit series is non-monotone
(1,881 -> 1,857 -> 1,833 -> 2,043), which was already direct evidence that one
positive dwm difference establishes nothing.

Nor was the field enumerated: 7 rows in reading 1, 8 in reading 2, out of 496
processes -- Telegram appears only in the second, proving the two readings are not
the same row set but hand-copied top-N slices of a sorted view. **dwm was
identified because dwm was looked at.** No replacement accumulator is named here,
because naming one would repeat the same error in reverse.

To be explicit, since dwm remains this log's primary finding: **the slowness result
is untouched.** 7.23 ms per compositor pass against 0.712 ms measured on a freshly
started dwm is the one controlled comparison in this entire investigation -- it has
a baseline. It does not need, and must not be joined to, a memory claim. One process
appearing in two symptom lists is not one mechanism.

#### Retracted: "6.8 GB resident, 6.0 GB outside any working set"

This was offered as the statement that survived regardless of the disputed column.
It does not. `Total - PageTable - Modified` = **820.2 MiB** against a 782 MB working
set -- once the disputed column is removed the finding collapses to a rounding
error. The `PrivateMemorySize64` corroboration does not rescue it, because
7,762 MB is **commit**. With ~36 GB of system commit not resident, "17692's 7.7 GB
is largely pagefile-backed" remains fully alive and predicts the opposite.

Also corrected: the subtraction `6,817 - 782` crosses two instruments and two
clocks, and **its sign flips between readings** -- RAMMap's Private column is
482.1 MiB at reading 1, below the 782 MB working set, and 819.3 MiB at reading 2,
above it. There is no containment relation to subtract across.

#### Two more corrections

**Per-process GPU committed figures are not additive.** Summed across all
instances: 12,639 MB, against an adapter Shared Usage of 10,120 MB at the same
moment -- 25% over. Cross-process shared surfaces are counted once per referencing
process. Any total built by adding those rows, including earlier ones in this log,
is inflated by an unknown amount.

**Scrollback is refuted as the mechanism**, so it should not be offered as the
competing hypothesis. `settings.json` has no `historySize` key, so the default of
9,001 lines applies; five panes at that depth is order 10^2 MB, and the OpenConsole
children hold 3 / 11 / 252 / 3 / 2 MB. Two orders of magnitude short.

#### What actually survives tonight

1. **pid 17692 holds 7,763 MB of private commit after 502 hours of uptime, and
   that figure is frozen.** Commit, not residency. Independent instrument.
2. **System commit is 67,947 MB against 31,997 MB installed -- 2.12x, with
   1,048 MB available.** Independent of every disputed column.
3. **dwm's compositor pass has degraded ~10x against a fresh-dwm baseline.**
4. RAMMap's Private column agrees with `WorkingSet64` (819.3 MiB vs 782 MB, gap in
   the expected direction since WorkingSet64 includes shareable pages). This is a
   real cross-instrument agreement, unlike the magnitude matches elsewhere.
5. RAMMap resident-private 6,816.9 MiB is <= `PrivateMemorySize64` 7,762 MB. A
   constraint check that passes; consistency only.
6. **A second instrument conflict, new tonight and logged unexplained:** RAMMap's
   Processes tab and its Use Counts tab moved in *opposite directions* over this
   interval. Summed Modified across the sampled rows fell 262-385 MiB while Use
   Counts reported the Modified total rising monotonically at +139 MB/h through the
   same evening.

#### The next measurement, with its constraints earned

**One full RAMMap export -- all 496 process rows plus the Use Counts tab from the
same F5 snapshot -- driven from a session outside pid 17692, with
`\Memory\Available Bytes`, `Committed Bytes`, `Modified Page List Bytes` and the
`Standby Cache *` counters sampled within seconds of it. Before any restart.**

Each constraint is earned by a specific failure above: **outside 17692** because of
the 60x excursion; **full export rather than hand-copied top-N** because Telegram's
appearance proves the row set was not fixed; **before the restart** because a
restart destroys both this capture and the fresh-terminal GPU baseline.

The discriminating check it enables is not "the table sums to 31,997 MB" -- that is
near-vacuous, since a mis-decode that shuffles pages between columns preserves the
total exactly. It is: **Use Counts `Standby + Zeroed + Free` must equal
`\Memory\Available Bytes` at the same instant.** Agreement on three of eight
page-state columns makes a 200x error on a fourth hard to sustain; disagreement
condemns the decode outright.

#### The restart, restated as an experiment rather than advice

The previous entry recommended restarting the terminal to recover 6.8 GB. That is
the wrong quantity and the wrong sequence. Restated:

> Restarting the pid 17692 tree releases roughly **7.7 GB of commit charge**. The
> Available-memory delta is **unknown, and is the test**. Record before and after:
> `\Memory\Available Bytes`, `Committed Bytes`, `Modified Page List Bytes`, GPU
> Adapter Shared Usage, and a full RAMMap Use Counts capture.
>
> - **Available rises ~6.8 GB** -> RAMMap's Modified column is measuring real
>   resident memory.
> - **Available rises under 1 GB while Committed drops ~7.7 GB** -> the block was
>   pagefile-backed, the column is an artifact, and everything built on it in the
>   last two entries falls in one stroke.
>
> *Open assumption:* the dichotomy is clean only if a terminating process's dirty
> private pages are released rather than written back. That is the expected
> behaviour for pagefile-backed private pages on process exit, but it was not
> verified here; if writeback occurs, the low branch is ambiguous between "artifact"
> and "flush latency", and the reading must be taken after the modified page writer
> drains.

Any memory recovered attributes to the **tree** -- five pwsh, five OpenConsole and
a wsl.exe -- not to WindowsTerminal alone.


### 2026-08-23 16:52 -- the 8 GB was session-scoped, and the instrument conflict is still not settled

The logout ran. Session 1 died with it, taking WindowsTerminal pid 17692 and the
6,419,680 KB Modified block that the last three entries argued about. RamMap was
reopened elevated in the fresh session and both tabs captured.

#### Use Counts, before and after

```
                              23:20 (session 1)      16:52 (session 2)
Modified, all rows            9,335,320 K            1,331,888 K      -85.7%
  Process Private Modified    8,445,120 K              792,432 K      -90.6%
Active, all rows             (not recorded)         28,710,856 K
Driver Locked                   615,260 K              614,816 K       -0.07%
```

`Driver Locked` is now measured at 598.9 / 600.1 / 599.4 / 600.8 / 600.4 MB across
five samples, 4.2 hours and a session boundary. **Fifth confirmation of the iGPU
retraction.** Nothing in this dataset ever had that row above 601 MB.

#### Processes tab: no successor

The old table had one process at 6,269 MB Modified and the next at 351 MB. The new
one has no such row. Largest Modified holders, session 2:

```
dwm.exe            49000    112,904 K
Akiflow.exe        17700     95,648 K
explorer.exe       46696     83,124 K
Rize.exe           64200     56,920 K
chrome.exe         80856     44,672 K
WindowsTerminal    30764     18,376 K
```

The replacement terminal, doing the same job, holds **18,376 K -- 0.29% of what its
predecessor held.** The distribution is not merely smaller, it has no head.

So whatever that block was, it was **session-scoped and accumulated over 501 hours
of a single logon session.** That is a real property, and it is the first
statement in this log about the block that does not depend on believing RamMap's
Modified column.

#### The 200x conflict: not resolved, and now moving the wrong way

A paired read, RamMap snapshot against PDH within the same few minutes:

```
16:52:32   PDH  Modified Page List Bytes         72 MB
16:52:34   PDH                                   72 MB
16:52:35   PDH                                   72 MB
16:52:37   PDH                                   72 MB
RamMap     Modified total                     1,301 MB
```

The ratio has fallen from 207-341x to **18x**. But the two instruments did not fall
together: RamMap's figure dropped 7x across the logout while PDH's figure **rose**,
from 25 / 27 / 39 / 44 MB last night to 72 and later 117 MB. One instrument says the
quantity collapsed; the other says it grew. **The conflict is unexplained, and the
logout did not adjudicate it.**

One thing did improve. The check named two entries ago as the discriminating test --
Use Counts `Standby + Zeroed + Free` against `\Memory\Available Bytes` at the same
instant -- now reads:

```
RamMap  2,634,432 + 28,388 + 59,472 K = 2,658 MB
PDH     Available MBytes               2,562 MB    (16:52:32)
```

**3.7% apart.** The caveat is that RamMap's refresh was a manual F5 whose exact
timestamp is not recorded, so this is a near-pairing, not a true one. Taken for what
it is: RamMap's decode of three of the eight page-state columns agrees with the
kernel. That makes "the whole PFN walk is misdecoded on build 26200" harder to hold,
and leaves the disagreement localised to the Modified column specifically.

#### The pre-registered test is spoiled, and the honest answer is that it did not run

The registration was:

> - **Available rises ~6.8 GB** -> RamMap's Modified column is measuring real
>   resident memory.
> - **Available rises under 1 GB while Committed drops ~7.7 GB** -> the block was
>   pagefile-backed and the column is an artifact.

Measured across the logout, settled at 44 minutes with paging quiet (24 pages/sec in):

```
                    23:20 -> 16:56
Committed        67,947 -> 43,407 MB    -24,540 MB
Available MBytes  1,048 ->  5,634 MB     +4,586 MB
```

**Neither branch.** And the reason is a design fault in the test, not an ambiguous
result: the intervention that actually happened was a full logout, which destroyed
several hundred processes, not the single tree the dichotomy was written for. The
+4,586 MB and the -24,540 MB are both dominated by processes that have nothing to do
with pid 17692. The registered discriminator required an isolated intervention, and
pid 17692 no longer exists to run it against.

Recording this as a failed experiment rather than a weak result. The design error --
registering a two-branch test against a delta that a confound could produce either
way -- is the same class as the goalpost move in the entry before it, and is worth
more than the answer would have been.

#### Settled pre-reboot ledger

Old kernel, 518.94 hours uptime, fresh session, paging quiet. This state is
unrepeatable once the machine reboots.

```
uptime                        518.94 h   (boot 2026-08-02 02:00:21)
processes                          449
available mbytes                 5,634 MB
committed bytes                 43,407 MB
modified page list bytes           117 MB
pool nonpaged bytes              2,102 MB
pool paged resident bytes        2,428 MB
system driver resident bytes        45 MB
system cache resident bytes        535 MB
system code resident bytes          12 MB
pages input/sec                   24.4
pages output/sec                     0
working set (all processes)     23,628 MB
working set - private           14,717 MB
```

Against last night: committed down 36%, available up 5.4x. The machine is not under
memory pressure right now, for the first time in this log.

Two kernel rows still have **no PDH counter at all** -- Page Table 596,676 K and
System PTE 724,300 K, 1,290 MB between them. That instrument gap is independent of
every dispute in this investigation and survives the logout unchanged.

#### dwm, unchanged from the previous entry

```
pid 49000   started 2026-08-23 16:12:02   up 0.74 h   WS 213 MB   private 351 MB   handles 1,534
```

`ms_per_pass` 2.000 at first sample against 7.919 for the old dwm, and inside the
historical fresh-dwm population at the value expected for its age. The confound
recorded last entry stands: window count fell 498 -> 185 across the logout and no
window-count-matched comparison is possible.

#### One unpaired anomaly, logged not resolved

RamMap reports chrome pid 36692 at 3,971,636 K = 3,878 MB **resident private**, while
`PrivateMemorySize64` for the same pid reads 3,173 MB **commit** at 16:56. Resident
private cannot exceed committed private. The two readings are minutes apart and
chrome was shrinking, so this is most likely a pairing artifact rather than a
violation -- but it is the same shape of claim this log has been burned on, so it is
recorded as an open item rather than used for anything.

#### Next

Reboot, then re-measure. What logout has already been shown *not* to reset: nothing
yet -- the kernel pools, page tables, System PTE and metafile cache have not been
compared across a boot, and 518 hours of uptime is still the largest uncontrolled
variable in the whole investigation. Before that, the D: pagefile entry needs a
decision, since a reboot is when it would take effect.

