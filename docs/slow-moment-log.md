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
