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
  dwm-autocapture.ps1          full dump + symbolized stacks + 30 s ETL
  dwm-setup-elevated-task.ps1  registers the scheduled task at RunLevel Highest
```

Setup is one elevated run of `dwm-setup-elevated-task.ps1`. Because the task
runs at `RunLevel Highest`, it never raises a UAC prompt afterwards — capture
works with the screen off or over a remote session.

See [`docs/dwm-investigation.md`](docs/dwm-investigation.md).

Status as of 2026-08-02: **open.** A root-cause function has been identified
from a single degraded observation plus a single healthy control. The trap that
would produce a second degraded sample is armed and has not yet fired. Read the
document's confidence markers before relying on anything in it.

### Repo copy is a snapshot

The watcher scripts are running live from `C:\Users\LZong\Scripts` on this
machine, driven by a scheduled task. The copies here are a **snapshot**, not the
running instrument.

They are deliberately not unified yet, and not parameterized. Repointing the
scheduled task mid-investigation risks losing sampling continuity, and
generalizing hardcoded paths would produce code that is never executed — that
is, untested. Both happen at close-out, when the scripts can be re-run and
verified.

Hardcoded `C:\Users\LZong` paths throughout are expected until then.

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
