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
