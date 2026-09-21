# install.ps1 — idempotent one-time setup. Run AS ADMINISTRATOR (Event Log source registration needs it).
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$BackupDir        = "$env:USERPROFILE\claude-code-backup",
    [string]$BackupTaskName   = "Claude Code Backup",
    [string]$WatchdogTaskName = "Claude Code Backup Watchdog",
    [switch]$Fast,    # bake --fast (size+mtime change detection) into the backup task
    [switch]$Silent   # run both tasks with a hidden window (no pop-up); toasts still show
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
#    -WindowStyle Hidden (PowerShell) + the wrapper's own Hide-ConsoleWindow give a
#    no-pop-up run; -Fast enables size+mtime change detection in backup.sh.
if (-not (Get-ScheduledTask -TaskName $BackupTaskName -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Scheduled task '$BackupTaskName' not found." -ForegroundColor Red
    Write-Host "This installer repoints an existing backup task at the wrapper; it does not create one."
    Write-Host "Create the '$BackupTaskName' task first (see scripts/windows/README.md), then re-run this script."
    exit 1
}
$backupPsArgs = "-NoProfile -ExecutionPolicy Bypass"
if ($Silent) { $backupPsArgs += " -WindowStyle Hidden" }
$backupPsArgs += " -File `"$wrapper`" -BackupDir `"$BackupDir`""
if ($Fast)   { $backupPsArgs += " -Fast" }
if ($Silent) { $backupPsArgs += " -Silent" }
$backupAction = New-ScheduledTaskAction -Execute $ps -Argument $backupPsArgs

# A backup must never be skipped just because the machine happened to be unplugged or asleep.
# Task Scheduler's defaults are hostile to that on a laptop: DisallowStartIfOnBatteries and
# StopIfGoingOnBatteries are ON (a run on battery is refused, or killed if you unplug mid-run,
# reported only as LastTaskResult 0x800710E0 "The operator or administrator has refused the
# request") and StartWhenAvailable is OFF (a run missed while the machine was off/asleep is
# never retried). Clear all three; on a desktop they are harmless no-ops. Settings are fetched
# from the live task so the rest of its configuration is preserved.
$backupSettings = (Get-ScheduledTask -TaskName $BackupTaskName).Settings
$backupSettings.DisallowStartIfOnBatteries = $false
$backupSettings.StopIfGoingOnBatteries     = $false
$backupSettings.StartWhenAvailable         = $true
Set-ScheduledTask -TaskName $BackupTaskName -Action $backupAction -Settings $backupSettings | Out-Null
Write-Host "Repointed '$BackupTaskName' at backup-wrapper.ps1 (Fast=$($Fast.IsPresent), Silent=$($Silent.IsPresent))."
Write-Host "  Cleared battery restrictions and enabled missed-run catch-up on '$BackupTaskName'."

# 3. Create/update the watchdog task: at logon + every 4h, interactive, limited.
$wdPsArgs = "-NoProfile -ExecutionPolicy Bypass"
if ($Silent) { $wdPsArgs += " -WindowStyle Hidden" }
# Pass -BackupDir explicitly: the watchdog derives the state-file path from it, so letting it
# fall back to its own default means a default that drifts from -BackupDir silently points the
# watchdog at a state file that does not exist -- which it reports as "no successful backup
# since never" on every check, burying real alerts in noise.
$wdPsArgs += " -File `"$watchdog`" -BackupDir `"$BackupDir`""
if ($Silent) { $wdPsArgs += " -Silent" }
$wdAction  = New-ScheduledTaskAction -Execute $ps -Argument $wdPsArgs
$tLogon    = New-ScheduledTaskTrigger -AtLogOn -User $user
$tRepeat   = New-ScheduledTaskTrigger -Once -At (Get-Date)
# A fresh -Once trigger has a null .Repetition, so build the pattern via its CIM class
# (every 4h; no Duration set = repeat indefinitely).
$repClass  = Get-CimClass -Namespace ROOT/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskRepetitionPattern
$rep       = New-CimInstance -CimClass $repClass -ClientOnly
$rep.Interval = "PT4H"
$rep.StopAtDurationEnd = $false
$tRepeat.Repetition = $rep
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $WatchdogTaskName -Action $wdAction `
    -Trigger @($tLogon, $tRepeat) -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed watchdog task '$WatchdogTaskName' (logon + every 4h)."

Write-Host "`nDone. Verify with:"
Write-Host "  (Get-ScheduledTask '$BackupTaskName').Actions"
Write-Host "  (Get-ScheduledTask '$BackupTaskName').Settings | Format-List DisallowStartIfOnBatteries,StopIfGoingOnBatteries,StartWhenAvailable"
Write-Host "  Get-ScheduledTaskInfo '$WatchdogTaskName'"
