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
