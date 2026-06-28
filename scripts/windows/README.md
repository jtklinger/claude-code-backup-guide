# Windows logging & alerts

An optional **Windows-only** layer that makes the scheduled backup observable: every run is logged to a file and the Windows Event Log, a toast confirms success or failure, and a watchdog warns if a scheduled run is missed. The portable `backup.sh` is **not** modified — this wraps it.

## What it does

- **`backup-wrapper.ps1`** — the Task Scheduler entry point. Runs `..\backup.sh` via Git-bash, captures its output and exit code, writes a daily log file + a Windows Event Log entry, updates a state file, and shows a toast (success *and* failure). It re-emits the bash exit code so `LastTaskResult` stays accurate.
- **`backup-watchdog.ps1`** — read-only. Run at logon + every 4h; toasts + writes a Warning event if no successful backup happened within ~13h (one missed scheduled slot).
- **`install.ps1`** — idempotent one-time setup (registers the Event Log source, re-points the backup task at the wrapper, creates the watchdog task).
- **`toast.ps1`** — shared toast helper (built-in Windows toast API; no external module).

## One-time setup

From an **elevated** PowerShell prompt (Run as administrator — required to register the Event Log source):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\me\projects\claude-code-backup-guide\scripts\windows\install.ps1"
```

Re-running it is safe; it updates the tasks in place.

## Where things live

- **Logs + state:** `%LOCALAPPDATA%\ClaudeCodeBackup\`
  - `logs\backup-YYYY-MM-DD.log` — full captured output, one file per day, kept 14 days
  - `last-run.json` — `{ lastRunIso, exitCode, result, lastSuccessIso, logPath, scriptVersion }` (read by the watchdog)
- **Event Log:** `Application` log, source `ClaudeCodeBackup`

| Event ID | Level | Meaning |
|----------|-------|---------|
| 1000 | Information | Backup run succeeded |
| 1001 | Error | Backup run failed (non-zero exit) |
| 2000 | Warning | Watchdog: no successful backup within ~13h |

View recent events:

```powershell
Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 20 | Format-Table TimeGenerated,EntryType,EventID,Message -Wrap
```

## Toasts

Toasts use the built-in `Windows.UI.Notifications` API and render because the tasks run in your interactive logged-on session. If toasts don't appear on your machine, install the fallback and they'll work without any other change:

```powershell
Install-Module BurntToast -Scope CurrentUser
```

then swap the body of `Show-BackupToast` in `toast.ps1` to use `New-BurntToastNotification -Text $Title,$Body` (keep the function name and parameters identical).

## Manual removal

```powershell
# Stop watching for missed runs
Unregister-ScheduledTask -TaskName "Claude Code Backup Watchdog" -Confirm:$false

# Re-point the backup task back at bash directly (adjust paths if needed)
$bash = New-ScheduledTaskAction -Execute "C:\Program Files\Git\bin\bash.exe" `
    -Argument '-l -c "bash /c/Users/me/projects/claude-code-backup-guide/scripts/backup.sh /c/Users/me/claude-code-backup"'
Set-ScheduledTask -TaskName "Claude Code Backup" -Action $bash

# Remove the Event Log source (elevated) and the logs/state
Remove-EventLog -Source ClaudeCodeBackup        # run as administrator
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\ClaudeCodeBackup"
```
