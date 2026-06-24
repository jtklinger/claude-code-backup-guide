# Windows Backup Observability — Design (v2.3.0)

**Date:** 2026-06-23
**Status:** Approved (brainstorm); pending spec review
**Repo:** claude-code-backup-guide

## Problem

On this Windows 11 desktop the backup runs via Task Scheduler:

```
bash.exe -l -c "bash /c/Users/jtkli/projects/claude-code-backup-guide/scripts/backup.sh /c/Users/jtkli/claude-code-backup"
```

at 07:00 and 19:00 daily. The bash `log_info/log_warn/log_error` helpers only `echo` to stdout, which Task Scheduler discards. The **only** durable signal a run leaves behind is `LastTaskResult` (the exit code). When v2.2.0 shipped a truncated `backup.sh` that failed to parse (`exit 2`), the backup silently did nothing — no log, no Windows Event Log entry, no alert — and was noticed only by chance.

**Goal:** durable per-run success/failure logging **+** an active alert on failure **+** detection of missed runs, all **desktop-local** (no server/network dependency), **without modifying the cross-platform `backup.sh`**.

## Scope / Non-goals

**In scope:** a Windows-only wrapper layer (PowerShell) that captures each run's result to a log file and the Windows Event Log, shows a toast on failure, and a watchdog that flags missed runs. Shipped as a v2.3.0 release of the tool.

**Non-goals (explicitly out):**
- No changes to `backup.sh` / `restore.sh` / `init.sh` *logic* (only the shared `SCRIPT_VERSION` bumps, per the tool's versioning convention).
- No server integration (Uptime Kuma, OpenObserve, email, ntfy) — desktop-only was chosen.
- No success toasts (success is silent; failure toasts only).
- No `uninstall.ps1` — manual removal is documented in the Windows README instead.

## Architecture

```
Task Scheduler ──► backup-wrapper.ps1 ──► (Git bash) backup.sh ──► backup repo
                        │
                        ├─► log file  (%LOCALAPPDATA%\ClaudeCodeBackup\logs\)
                        ├─► Windows Event Log  (Application / source "ClaudeCodeBackup")
                        ├─► last-run.json  (state for the watchdog)
                        └─► toast  (failure only)

(logon / every 4h) ──► backup-watchdog.ps1 ──► reads last-run.json ──► toast + Warning event if stale
```

The wrapper owns all capture / logging / alerting. `backup.sh` stays untouched and portable. All new code is Windows-specific and isolated under `scripts/windows/`.

**New files (all under `scripts/windows/`):**
- `backup-wrapper.ps1` — scheduled-task entry point
- `backup-watchdog.ps1` — missed-run detector
- `install.ps1` — idempotent one-time setup
- `toast.ps1` — shared toast helper (dot-sourced by the other two)
- `README.md` — setup, what is logged, where, and manual removal

**State + logs directory:** `%LOCALAPPDATA%\ClaudeCodeBackup\`
- `logs\backup-YYYY-MM-DD.log` — full captured output, one file per day
- `last-run.json` — run state

## Component: `backup-wrapper.ps1`

The new Task Scheduler entry point (replaces the direct `bash` action).

**Parameters:** `-BackupDir` (default `C:\Users\jtkli\claude-code-backup`), `-BashExe` (default: auto-detect `C:\Program Files\Git\bin\bash.exe`), `-LogDir` (default `%LOCALAPPDATA%\ClaudeCodeBackup\logs`), `-RetentionDays` (default 14).

**Steps:**
1. Resolve paths; create `LogDir` if missing. If `BashExe` not found → write Error event 1001 + toast + `exit 9` (do not silently succeed).
2. Record start time.
3. Convert `BackupDir` to a bash path and run, capturing merged stdout+stderr and the exit code:
   `& $BashExe -l -c "bash '<backup.sh>' '<bash-backupdir>'"`
4. Write the day's log file: header (ISO start time, hostname, script version) + full captured output + footer (exit code, duration seconds).
5. Rotate: delete `backup-*.log` older than `RetentionDays`.
6. Write the Windows Event Log entry (source `ClaudeCodeBackup`, log `Application`):
   - exit 0 → Information, event ID **1000**, message "Backup succeeded in {N}s. Log: {path}"
   - exit ≠ 0 → Error, event ID **1001**, message "Backup FAILED (exit {code}) in {N}s. Log: {path}"
7. Write `last-run.json` (overwrite): `{ lastRunIso, exitCode, result, lastSuccessIso, logPath, scriptVersion }` where `result` is `"success"|"failure"` and `lastSuccessIso` is updated **only** on success (otherwise carried forward from the previous file).
8. On failure only: show a toast — title "Claude Code backup FAILED", body "Exit {code}. See {logPath}".
9. `exit <bash exit code>` so Task Scheduler's `LastTaskResult` stays truthful.

## Component: `backup-watchdog.ps1`

Read-only missed-run detector. **Parameter:** `-MaxAgeHours` (default 13 = 12h cadence + 1h grace).

**Steps:**
1. Read `last-run.json`. If missing or unparseable → treat as stale/unknown.
2. Compute `age = now − lastSuccessIso`.
3. If the file is missing, OR `age > MaxAgeHours`, OR the last result was `failure` → toast (title "Claude Code backup may be stale", body "No successful backup since {lastSuccessIso} — last result: {result}") + Event Log Warning, event ID **2000**.
4. Otherwise: silent (no toast, no event).

The watchdog never runs the backup itself.

## Component: `install.ps1`

Idempotent; run **once, elevated** (Event Log source registration needs admin).

**Steps:**
1. If Event Log source `ClaudeCodeBackup` is not registered → `New-EventLog -LogName Application -Source ClaudeCodeBackup`.
2. Reconfigure the existing "Claude Code Backup" task: set its action to
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<...>\backup-wrapper.ps1" -BackupDir "<dir>"`.
   Preserve existing triggers (07:00 / 19:00) and principal (`jtkli` / Interactive / Limited).
3. Create or update a "Claude Code Backup Watchdog" task: action
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<...>\backup-watchdog.ps1"`;
   triggers: AtLogon **and** a repetition every 4h; principal `jtkli` / Interactive / Limited.
4. Print a summary and the verification commands.

`install.ps1` is re-runnable: it updates the tasks in place rather than erroring if they exist.

## Toast mechanism (`toast.ps1`)

A shared helper exposing `Show-BackupToast -Title <t> -Body <b>`. Implementation uses the **built-in** `Windows.UI.Notifications` toast API via PowerShell (PowerShell's registered AppUserModelID) — **no BurntToast dependency**. Toasts render because the tasks run in the interactive logged-on session (verified: `LogonType = Interactive`).

**Risk / fallback:** the raw UWP toast + AppId path can be finicky from a scripted context. This is the first thing to validate during implementation. If it proves unreliable, the documented fallback is the `BurntToast` module (`Install-Module BurntToast -Scope CurrentUser`); the helper interface (`Show-BackupToast`) stays the same so only `toast.ps1` changes.

## Event Log schema

| Event ID | Level | Source | Emitted when |
|----------|-------|--------|--------------|
| 1000 | Information | ClaudeCodeBackup | Backup run succeeded (exit 0) |
| 1001 | Error | ClaudeCodeBackup | Backup run failed (exit ≠ 0) |
| 2000 | Warning | ClaudeCodeBackup | Watchdog: no successful backup within MaxAgeHours |

## Data flow

- **Run:** Task fires → wrapper runs `backup.sh`, captures output+exit → writes {log file, Event Log, `last-run.json`} → toast iff failure → re-emits exit code → `LastTaskResult`.
- **Watch:** logon or 4h repetition → watchdog reads `last-run.json` → {toast + Warning event} iff stale.

## Error handling / edge cases

- **Git bash not found** → Error event 1001 + toast + non-zero exit (never a false success).
- **`backup.sh` parse error / crash** (the v2.2.0 case) → non-zero exit → failure path triggers. This is the scenario the feature exists to catch.
- **Log dir missing** → created on demand.
- **`last-run.json` missing/corrupt** → watchdog treats as stale and warns; wrapper overwrites cleanly.
- **Wrapper internal exception** → trap, write Error event + toast, exit non-zero (fail loud, never mask).
- **Overlapping runs** → already prevented by the task's `MultipleInstances = IgnoreNew`.
- **Exit code fidelity** → the wrapper must always re-emit the bash exit code; it must never substitute its own success.

## Testing (Windows smoke)

The repo has no unit-test framework (bash side uses a smoke recipe); PowerShell here is verified the same way — manual smoke against real state:

1. **Success:** run `backup-wrapper.ps1` manually → assert Event Log Information 1000 + a new day log file + `last-run.json` `result=success` + **no** toast + exit 0.
2. **Failure:** run the wrapper pointed at a deliberately broken script (or one that `exit 2`s) → assert Event Log Error 1001 + toast shown + `last-run.json` `result=failure` + the non-zero exit code propagated to `$LASTEXITCODE`.
3. **Watchdog stale:** set `last-run.json` `lastSuccessIso` to 14h ago → run `backup-watchdog.ps1` → assert Warning 2000 + toast. Reset to now → assert silent.
4. **End-to-end:** trigger the real "Claude Code Backup" task → `LastTaskResult = 0` + Event Log + log + state all updated.

The existing bash smoke test is unaffected (`backup.sh` unchanged) but is re-run once to confirm no regression.

## Release (v2.3.0)

Handled via the `claude-code-backup-maintenance` skill's cut-release workflow. Minor version (additive feature, no config-schema change):
- `SCRIPT_VERSION` → `2.3.0` across `init.sh` / `backup.sh` / `restore.sh` (tool-version coherence, even though their logic is unchanged).
- README: changelog entry v2.3.0 + "Current release" callout + a short "Windows: logging & alerts" pointer to `scripts/windows/README.md`.
- `CLAUDE.md`: note the Windows helper layer under `scripts/windows/`.
- Branch → PR → merge → tag `v2.3.0` → GitHub Release.
- Run `install.ps1` (elevated, once) on this desktop to activate the wrapper + watchdog.

## Open questions / risks

- **Toast reliability** from a scheduled-task context is the main implementation risk — validate the built-in toast path early; BurntToast is the fallback.
- **One-time elevation** for Event Log source registration is required and acceptable (documented in the Windows README).
