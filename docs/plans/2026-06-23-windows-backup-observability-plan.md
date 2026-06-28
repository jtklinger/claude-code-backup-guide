# Windows Backup Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Windows scheduled backup durable per-run logging (file + Event Log), a toast on every run, and a watchdog that catches missed runs — without touching the cross-platform `backup.sh`.

**Architecture:** A Windows-only PowerShell wrapper layer under `scripts/windows/`. Task Scheduler calls `backup-wrapper.ps1` (instead of `bash` directly); the wrapper runs Git-bash `backup.sh`, captures its output + exit code, and records the result to a daily log file, the Windows Event Log, and a `last-run.json` state file, toasting on every run (success and failure). A separate `backup-watchdog.ps1` (logon + every 4h) reads the state file and warns if no successful backup happened within ~13h. `install.ps1` wires it all up idempotently.

**Tech Stack:** Windows PowerShell 5.1, Windows Event Log (`Application` / source `ClaudeCodeBackup`), built-in `Windows.UI.Notifications` toasts (no BurntToast), `ScheduledTasks` cmdlets, Git-bash.

**Spec:** `docs/plans/2026-06-23-windows-backup-observability-design.md`

**Testing note:** This repo has no unit-test framework; verification is **manual smoke** against real machine state (Event Log, log files, the state file, visible toasts, the real scheduled task), exactly as the spec defines. Several steps require *watching the screen* to confirm a toast renders — that human-visible check is intentional and is why inline execution is recommended over fully autonomous subagents.

---

## File Structure

All new files under `scripts/windows/` (the portable bash scripts are untouched except the version string):

| File | Responsibility |
|------|----------------|
| `scripts/windows/toast.ps1` | `Show-BackupToast -Title -Body` — the only shared helper; dot-sourced by wrapper + watchdog |
| `scripts/windows/backup-wrapper.ps1` | Scheduled-task entry point: run `backup.sh`, capture, log (file + Event Log), state file, toast (success + failure), re-emit exit code |
| `scripts/windows/backup-watchdog.ps1` | Read `last-run.json`, toast + Warning event if stale |
| `scripts/windows/install.ps1` | Register Event Log source; repoint backup task at wrapper; create watchdog task (idempotent, elevated) |
| `scripts/windows/README.md` | Setup, what is logged + where, manual removal |
| `scripts/{backup,init,restore}.sh` | `SCRIPT_VERSION` → `2.3.0` only |
| `README.md`, `CLAUDE.md` | Changelog/callout + Windows pointer; data-flow note |

State + logs live at `%LOCALAPPDATA%\ClaudeCodeBackup\` (`logs\backup-YYYY-MM-DD.log`, `last-run.json`) — outside both repos.

---

## Task 1: Toast helper (de-risk first)

The spec flags toast reliability as the #1 risk — build and prove it before anything depends on it.

**Files:**
- Create: `scripts/windows/toast.ps1`

- [ ] **Step 1: Write `toast.ps1`**

```powershell
# toast.ps1 — minimal, dependency-free Windows toast helper.
# Dot-source this file, then call Show-BackupToast.

function Show-BackupToast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Body
    )
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
                   [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $xml.GetElementsByTagName('text')
        [void]$nodes.Item(0).AppendChild($xml.CreateTextNode($Title))
        [void]$nodes.Item(1).AppendChild($xml.CreateTextNode($Body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        # Well-known AppUserModelID for Windows PowerShell (Start Menu shortcut) so the toast renders.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # Never let a notification failure mask the real result; the Event Log + log file remain the source of truth.
        Write-Warning "Toast failed: $($_.Exception.Message)"
    }
}
```

- [ ] **Step 2: Smoke-verify the toast renders**

Run (in a normal, logged-on PowerShell window):
```powershell
. C:\Users\me\projects\claude-code-backup-guide\scripts\windows\toast.ps1
Show-BackupToast -Title "Backup test" -Body "If you can read this, toasts work."
```
Expected: a Windows toast notification appears (top-right / Action Center). **If it does NOT appear**, switch `toast.ps1` to the BurntToast fallback: `Install-Module BurntToast -Scope CurrentUser`, then implement `Show-BackupToast` with `New-BurntToastNotification -Text $Title,$Body`. Keep the function name/signature identical so nothing else changes.

- [ ] **Step 3: Commit**

```bash
git add scripts/windows/toast.ps1
git commit -m "Add Windows toast helper for backup notifications"
```

---

## Task 2: Backup wrapper

**Files:**
- Create: `scripts/windows/backup-wrapper.ps1`

- [ ] **Step 1: Write `backup-wrapper.ps1`**

```powershell
# backup-wrapper.ps1 — Task Scheduler entry point.
# Runs backup.sh via Git-bash, captures result, logs to file + Event Log + state, toasts on success and failure,
# and re-emits the bash exit code so Task Scheduler's LastTaskResult stays truthful.
[CmdletBinding()]
param(
    [string]$BackupDir     = "C:\Users\me\claude-code-backup",
    [string]$BashExe       = $null,
    [string]$LogDir        = (Join-Path $env:LOCALAPPDATA "ClaudeCodeBackup\logs"),
    [int]   $RetentionDays = 14
)

$ErrorActionPreference = 'Stop'
$EventSource = 'ClaudeCodeBackup'
. (Join-Path $PSScriptRoot 'toast.ps1')

function Write-BackupEvent {
    param([string]$EntryType, [int]$Id, [string]$Message)
    try {
        Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId $Id -Message $Message
    } catch { }  # source not registered yet (pre-install) — the log file still has the full record
}

$stateFile = Join-Path (Split-Path $LogDir -Parent) 'last-run.json'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$start   = Get-Date
$logFile = Join-Path $LogDir ("backup-{0:yyyy-MM-dd}.log" -f $start)

function Resolve-BashExe {
    param($Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return $Explicit }
    foreach ($c in @("C:\Program Files\Git\bin\bash.exe","C:\Program Files (x86)\Git\bin\bash.exe")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}
function ConvertTo-BashPath {
    param([string]$Path)
    $full = $Path
    try { $full = (Resolve-Path $Path -ErrorAction Stop).Path } catch { }
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        '/' + $matches[1].ToLower() + '/' + ($matches[2] -replace '\\','/')
    } else { $full }
}

$bash = Resolve-BashExe $BashExe
if (-not $bash) {
    $msg = "Git bash not found (looked in Program Files). Backup did not run."
    Add-Content -Path $logFile -Value "[$($start.ToString('o'))] ERROR: $msg"
    Write-BackupEvent -EntryType Error -Id 1001 -Message $msg
    Show-BackupToast -Title "Claude Code backup FAILED" -Body $msg
    exit 9
}

$scriptSh      = Join-Path (Split-Path $PSScriptRoot -Parent) 'backup.sh'   # scripts/backup.sh
$bashScript    = ConvertTo-BashPath $scriptSh
$bashBackupDir = ConvertTo-BashPath $BackupDir

# Run the backup. Capture stdout+stderr, then read $LASTEXITCODE IMMEDIATELY (next line) —
# backup.sh runs under `set -e`, so a failure (e.g. the v2.2.0 `exit 2`) surfaces ONLY as a
# non-zero exit code, never a PowerShell exception. Do not use $? or try/catch to detect it.
$output = & $bash -l -c "bash '$bashScript' '$bashBackupDir'" 2>&1
$code   = $LASTEXITCODE
$duration = [int]((Get-Date) - $start).TotalSeconds

# --- log file ---
Add-Content -Path $logFile -Value "===== run $($start.ToString('o')) host=$env:COMPUTERNAME ====="
($output | Out-String) | Add-Content -Path $logFile
Add-Content -Path $logFile -Value "===== exit=$code duration=${duration}s ====="

# --- rotate old logs ---
Get-ChildItem -Path $LogDir -Filter 'backup-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

# --- state file (carry lastSuccessIso forward on failure; null if never succeeded) ---
$prev = $null
if (Test-Path $stateFile) { try { $prev = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { } }
$lastSuccess = if ($code -eq 0) { $start.ToString('o') }
               elseif ($prev -and $prev.lastSuccessIso) { $prev.lastSuccessIso }
               else { $null }
[ordered]@{
    lastRunIso     = $start.ToString('o')
    exitCode       = $code
    result         = if ($code -eq 0) { 'success' } else { 'failure' }
    lastSuccessIso = $lastSuccess
    logPath        = $logFile
    scriptVersion  = '2.3.0'
} | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

# --- Event Log + toast (success and failure) ---
if ($code -eq 0) {
    Write-BackupEvent -EntryType Information -Id 1000 -Message "Backup succeeded in ${duration}s. Log: $logFile"
    Show-BackupToast -Title "Claude Code backup succeeded" -Body "Completed in ${duration}s."
} else {
    Write-BackupEvent -EntryType Error -Id 1001 -Message "Backup FAILED (exit $code) in ${duration}s. Log: $logFile"
    Show-BackupToast -Title "Claude Code backup FAILED" -Body "Exit $code. See $logFile"
}

exit $code
```

- [ ] **Step 2: Register the Event Log source once (so the smoke checks below can write events)**

Run **as Administrator**:
```powershell
if (-not [System.Diagnostics.EventLog]::SourceExists('ClaudeCodeBackup')) {
    New-EventLog -LogName Application -Source 'ClaudeCodeBackup'
}
```
(`install.ps1` formalizes this in Task 4; this is just to enable testing now.)

- [ ] **Step 3: Smoke-verify SUCCESS path**

```powershell
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\backup-wrapper.ps1
"exit=$LASTEXITCODE"
Get-Content "$env:LOCALAPPDATA\ClaudeCodeBackup\last-run.json"
Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 1 | Format-List EventID,EntryType,Message
```
Expected: `exit=0`; a `backup-YYYY-MM-DD.log` exists with the backup output; `last-run.json` shows `result=success` and a `lastSuccessIso`; newest event is **1000 / Information**; **a "succeeded" toast appears** (confirm on screen).

- [ ] **Step 4: Smoke-verify FAILURE path**

```powershell
# Run against a dir with no backup-config.json so backup.sh exits non-zero:
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\backup-wrapper.ps1 -BackupDir $env:TEMP
"exit=$LASTEXITCODE"
Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 1 | Format-List EventID,EntryType,Message
Get-Content "$env:LOCALAPPDATA\ClaudeCodeBackup\last-run.json"
```
Expected: non-zero `exit`; newest event is **1001 / Error**; `last-run.json` `result=failure` with `lastSuccessIso` **carried forward** from Step 3 (not overwritten); **a failure toast appears**. Confirm the toast on screen.

> Note: the cleanest forced-failure check is to run the wrapper against a directory with no `backup-config.json` (e.g. `$env:TEMP`) so `backup.sh` exits non-zero, OR temporarily edit the inner `-c` string to call `$broken`. Revert any such temporary edit before committing.

- [ ] **Step 5: Commit**

```bash
git add scripts/windows/backup-wrapper.ps1
git commit -m "Add Windows backup wrapper with file + Event Log logging and toast notifications"
```

---

## Task 3: Watchdog

**Files:**
- Create: `scripts/windows/backup-watchdog.ps1`

- [ ] **Step 1: Write `backup-watchdog.ps1`**

```powershell
# backup-watchdog.ps1 — read-only missed-run detector. Run at logon + every 4h.
# Warns (toast + Warning event) if no SUCCESSFUL backup within -MaxAgeHours, or if the
# last run failed, or if no success has ever been recorded. Never runs the backup itself.
[CmdletBinding()]
param([int]$MaxAgeHours = 13)

$EventSource = 'ClaudeCodeBackup'
. (Join-Path $PSScriptRoot 'toast.ps1')
$stateFile = Join-Path $env:LOCALAPPDATA "ClaudeCodeBackup\last-run.json"

function Write-BackupEvent {
    param([string]$EntryType, [int]$Id, [string]$Message)
    try {
        Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId $Id -Message $Message
    } catch { }
}

$stale = $false; $since = 'never'; $result = 'unknown'
if (-not (Test-Path $stateFile)) {
    $stale = $true
} else {
    try {
        $s = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($s.result)  { $result = $s.result }
        if (-not $s.lastSuccessIso) {
            $stale = $true                      # never succeeded (e.g. first run failed)
        } else {
            $since = $s.lastSuccessIso
            $age = (Get-Date) - [datetime]::Parse($s.lastSuccessIso)
            if ($age.TotalHours -gt $MaxAgeHours -or $s.result -eq 'failure') { $stale = $true }
        }
    } catch { $stale = $true }                  # missing/corrupt -> assume stale
}

if ($stale) {
    $msg = "No successful Claude Code backup since $since (last result: $result). Check the Event Log / $stateFile."
    Write-BackupEvent -EntryType Warning -Id 2000 -Message $msg
    Show-BackupToast -Title "Claude Code backup may be stale" -Body $msg
}
```

- [ ] **Step 2: Smoke-verify STALE warns**

```powershell
$sf = "$env:LOCALAPPDATA\ClaudeCodeBackup\last-run.json"
(Get-Content $sf -Raw | ConvertFrom-Json) |
    ForEach-Object { $_.lastSuccessIso = (Get-Date).AddHours(-14).ToString('o'); $_ } |
    ConvertTo-Json | Set-Content $sf -Encoding utf8
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\backup-watchdog.ps1
Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 1 | Format-List EventID,EntryType,Message
```
Expected: **Warning / 2000** event + a "may be stale" toast on screen.

- [ ] **Step 3: Smoke-verify FRESH is silent**

```powershell
# Re-run the real wrapper to write a fresh success state, then run the watchdog.
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\backup-wrapper.ps1 | Out-Null
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\backup-watchdog.ps1
```
Expected: **no toast**, **no new 2000 event** (newest event remains the 1000 from the wrapper run).

- [ ] **Step 4: Commit**

```bash
git add scripts/windows/backup-watchdog.ps1
git commit -m "Add Windows backup watchdog for missed-run detection"
```

---

## Task 4: Installer

**Files:**
- Create: `scripts/windows/install.ps1`

- [ ] **Step 1: Write `install.ps1`**

```powershell
# install.ps1 — idempotent one-time setup. Run AS ADMINISTRATOR (Event Log source registration needs it).
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BackupDir        = "C:\Users\me\claude-code-backup",
    [string]$BackupTaskName   = "Claude Code Backup",
    [string]$WatchdogTaskName = "Claude Code Backup Watchdog"
)
$ErrorActionPreference = 'Stop'
$wrapper  = Join-Path $PSScriptRoot 'backup-wrapper.ps1'
$watchdog = Join-Path $PSScriptRoot 'backup-watchdog.ps1'
$ps       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$user     = "$env:USERDOMAIN\$env:USERNAME"

# 1. Event Log source
if (-not [System.Diagnostics.EventLog]::SourceExists('ClaudeCodeBackup')) {
    New-EventLog -LogName Application -Source 'ClaudeCodeBackup'
    Write-Host "Registered Event Log source 'ClaudeCodeBackup'."
} else { Write-Host "Event Log source already registered." }

# 2. Repoint the existing backup task at the wrapper (preserves triggers + principal).
$backupAction = New-ScheduledTaskAction -Execute $ps `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`" -BackupDir `"$BackupDir`""
Set-ScheduledTask -TaskName $BackupTaskName -Action $backupAction | Out-Null
Write-Host "Repointed '$BackupTaskName' at backup-wrapper.ps1."

# 3. Create/update the watchdog task: at logon + every 4h, interactive, limited.
$wdAction  = New-ScheduledTaskAction -Execute $ps `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$watchdog`""
$tLogon    = New-ScheduledTaskTrigger -AtLogOn -User $user
$tRepeat   = New-ScheduledTaskTrigger -Once -At (Get-Date)
$tRepeat.Repetition.Interval = "PT4H"
$tRepeat.Repetition.Duration = ""            # empty = repeat indefinitely
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $WatchdogTaskName -Action $wdAction `
    -Trigger @($tLogon, $tRepeat) -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed watchdog task '$WatchdogTaskName' (logon + every 4h)."

Write-Host "`nDone. Verify with:"
Write-Host "  (Get-ScheduledTask '$BackupTaskName').Actions"
Write-Host "  Get-ScheduledTaskInfo '$WatchdogTaskName'"
```

> Implementation caveat to validate during execution: the exact way to express an **indefinitely repeating** 4h trigger via `New-ScheduledTaskTrigger` varies by Windows build. The `$tRepeat.Repetition.Interval = "PT4H"` (ISO-8601 duration) approach above is the most portable; if `Register-ScheduledTask` rejects it, fall back to building the trigger with a long finite duration (e.g. `Duration = "P9999D"`). Confirm the registered task shows a 4-hour repetition.

- [ ] **Step 2: Smoke-verify install is idempotent + correct**

Run **as Administrator**:
```powershell
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\install.ps1
(Get-ScheduledTask "Claude Code Backup").Actions | Format-List Execute,Arguments
(Get-ScheduledTask "Claude Code Backup Watchdog").Triggers
& C:\Users\me\projects\claude-code-backup-guide\scripts\windows\install.ps1   # run twice — must not error
```
Expected: backup task action is now `powershell.exe ... backup-wrapper.ps1 -BackupDir ...`; its 07:00/19:00 triggers and `me`/Interactive principal are unchanged (`Get-ScheduledTask "Claude Code Backup" | % Triggers` / `.Principal`); watchdog task exists with AtLogon + 4h repetition; second run completes without error.

- [ ] **Step 3: Commit**

```bash
git add scripts/windows/install.ps1
git commit -m "Add idempotent Windows installer for backup logging + watchdog tasks"
```

---

## Task 5: Windows README

**Files:**
- Create: `scripts/windows/README.md`

- [ ] **Step 1: Write `scripts/windows/README.md`** covering: what this layer does; one-time setup (`powershell -ExecutionPolicy Bypass -File install.ps1` from an elevated prompt); where logs + state live (`%LOCALAPPDATA%\ClaudeCodeBackup\`); the Event Log source + IDs (1000/1001/2000) and how to view them (`Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 20`); the watchdog cadence + threshold; the toast fallback (BurntToast); and **manual removal** (`Unregister-ScheduledTask "Claude Code Backup Watchdog"`; repoint the backup task back at bash; `Remove-EventLog -Source ClaudeCodeBackup`; delete `%LOCALAPPDATA%\ClaudeCodeBackup\`).

- [ ] **Step 2: Commit**

```bash
git add scripts/windows/README.md
git commit -m "Document Windows logging layer (setup, logs, Event Log, removal)"
```

---

## Task 6: Version bump + top-level docs (v2.3.0)

**Files:**
- Modify: `scripts/backup.sh:18`, `scripts/init.sh:15`, `scripts/restore.sh:24` (`SCRIPT_VERSION`)
- Modify: `README.md` (callout + changelog + Windows pointer)
- Modify: `CLAUDE.md` (note the Windows helper layer)

- [ ] **Step 1: Bump `SCRIPT_VERSION` to 2.3.0 in all three scripts**

```bash
cd /c/Users/me/projects/claude-code-backup-guide
sed -i 's/^SCRIPT_VERSION="2.2.1"/SCRIPT_VERSION="2.3.0"/' scripts/backup.sh scripts/init.sh scripts/restore.sh
grep -h '^SCRIPT_VERSION=' scripts/*.sh | sort -u   # expect a single line: 2.3.0
```

- [ ] **Step 2: Update `README.md`** — set the "Current release" callout to `v2.3.0`, add a changelog entry (headline: Windows logging & failure/missed-run alerts; note no schema change), and add a one-line pointer to `scripts/windows/README.md` in the Windows section.

- [ ] **Step 3: Update `CLAUDE.md`** — add a sentence noting the optional Windows observability layer under `scripts/windows/` (wrapper + watchdog + installer) that logs to file + Event Log and toasts on every run; portable `backup.sh` is unchanged.

- [ ] **Step 4: Verify nothing bash-side regressed**

```bash
for s in backup.sh init.sh restore.sh; do bash -n scripts/$s && echo "$s OK"; done
```
Expected: all three `OK`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ README.md CLAUDE.md
git commit -m "Bump to v2.3.0: Windows logging & alerting layer"
```

---

## Task 7: Activate + end-to-end verification

This task has no code — it activates the feature on this desktop and proves the real scheduled-task path.

- [ ] **Step 1: Run the installer elevated** — `install.ps1` (Task 4 already did this during its smoke test; re-run if the branch was reset).

- [ ] **Step 2: Trigger the real backup task and confirm the full chain**

```powershell
Start-ScheduledTask -TaskName "Claude Code Backup"
# wait for State -> Ready, then:
(Get-ScheduledTaskInfo "Claude Code Backup").LastTaskResult        # expect 0
Get-EventLog -LogName Application -Source ClaudeCodeBackup -Newest 1 # expect 1000 / Information
Get-Content "$env:LOCALAPPDATA\ClaudeCodeBackup\last-run.json"      # result=success, fresh lastSuccessIso
```
Expected: `LastTaskResult = 0`, a 1000 event, a fresh log file, `result=success`, and a "succeeded" toast. This is the exact path that silently failed in the v2.2.0 incident — now fully observable.

- [ ] **Step 3: Re-run the bash smoke test** once to confirm `backup.sh` itself is unregressed (it was only version-bumped). Use the recipe in `CLAUDE.md` → "Testing Changes" (canonical version: the `claude-code-backup-maintenance` skill's smoke-test reference): `mkdir /tmp/test-backup && bash scripts/init.sh /tmp/test-backup && bash scripts/backup.sh /tmp/test-backup`, then a second `bash scripts/backup.sh /tmp/test-backup` should report "No changes detected". Cleanup: `rm -rf /tmp/test-backup`.

- [ ] **Step 4: Cut the v2.3.0 release** via the `claude-code-backup-maintenance` skill's cut-release workflow: push branch → PR → merge to master → tag `v2.3.0` → GitHub Release. (Pushing/publishing is gated on explicit user approval per the user's standing rule.)

---

## Done when

- All five `scripts/windows/` files exist and pass their smoke checks.
- The real "Claude Code Backup" task runs through the wrapper, exits 0, and leaves a 1000 event + log + success state + a success toast.
- A forced failure produces a 1001 event + toast + `result=failure` (with `lastSuccessIso` preserved).
- The watchdog warns on a 14h-stale state and is silent on a fresh one.
- `v2.3.0` is tagged + released (after user approval to push).
