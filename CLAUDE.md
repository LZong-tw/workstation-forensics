# Working rules for this repo

This repo is an investigation log as much as a toolbox. Most of its value is in
being honest about what is known versus guessed, so these rules are about
evidence discipline rather than code style.

## Claims carry confidence markers

Every factual claim in `docs/` is tagged:

- **[MEASURED]** — observed directly, with the numbers reproduced in the file.
- **[INFERRED]** — follows from measurements but not independently confirmed.
- **[ASSUMPTION]** — unverified. Nothing may be built on these.
- **[RETRACTED]** — previously claimed here, since disproved.

Do not promote a claim to [MEASURED] because it sounds right. A single
observation plus a plausible mechanism is [INFERRED].

## Retracted claims stay in the file

When something here turns out to be wrong, it moves to a "Retracted claims"
section with the reason. It does not get quietly deleted. The pattern of how
these investigations went wrong is part of what the repo is for — two of the
findings in `docs/` were only reached because an earlier wrong answer failed
in an informative way.

## Measure, do not estimate, and say which you did

Timings, costs, and thresholds in this repo are measured on real hardware and
the measurement is shown. Where a number is an estimate it is labelled as one,
with the arithmetic visible so a reader can check it.

Before optimising anything, measure where the time actually goes. The capture
script went from 30.5 s to ~15 s because the cost was measured per section
rather than guessed at.

## Instruments must not perturb what they measure

Learned the hard way: the capture script's own startup beep woke an audio APO
that then burned 90% of a core, and it duly appeared as the top CPU consumer
in its own output. Anything added here must be checked for whether it changes
the thing being observed.

A silent control run is the cheapest way to catch this and should be the first
move, not the last.

## Read-only toward system state

Nothing here changes settings, restarts services, edits the registry, or kills
processes. It writes dumps and traces of targets; it never modifies one.

Remediation scripts do not belong in this repo even when they were written
during the same investigation — shipping them next to tools that promise
read-only behaviour makes the promise meaningless.

## Never commit captured evidence

`evidence/`, `slow-capture/`, `dwm-capture/`, `*.dmp`, `*.etl`, `*.wer` are
git-ignored. They contain hostnames, BIOS identifiers, installed-software
inventories, crash reports, and full process memory. Once in history it is
permanent, so check `git status --short` before the first `add` of any new
output directory rather than scrubbing later.

## Check prior art before claiming a finding

Both findings in `docs/` cite what was already publicly reported and state
precisely what is new relative to it. A mechanism nobody has published is a
contribution; a symptom everyone has hit is not.

## PowerShell specifics

- **Scripts are pure ASCII.** PowerShell 5.1 reads BOM-less UTF-8 as ANSI,
  which turns non-ASCII comments into cascading parser errors. `test/Test-Scripts.ps1`
  enforces this.
- **Parse-check in both hosts** before committing. 5.1 and 7 disagree.
- Use `-ErrorAction SilentlyContinue` for wide wildcard counter sets. Under
  `-Stop`, one unavailable path aborts the whole batch and blanks every section
  that depended on it.
