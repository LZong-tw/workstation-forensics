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
