# backup-watchdog.ps1 — read-only missed-run detector. Run at logon + every 4h.
# Warns (toast + Warning event) if no SUCCESSFUL backup within -MaxAgeHours, or if the
# last run failed, or if no success has ever been recorded. Never runs the backup itself.
[CmdletBinding()]
param([int]$MaxAgeHours = 13, [string]$BackupDir = "$env:USERPROFILE\claude-code-backup", [switch]$Silent)

$EventSource = 'ClaudeCodeBackup'
. (Join-Path $PSScriptRoot 'toast.ps1')
if ($Silent) { Hide-ConsoleWindow }   # no window flash on the periodic check
# Must match backup-wrapper.ps1's state location (next to the backup repo, not %LOCALAPPDATA%,
# which the packaged Claude desktop app virtualizes inconsistently across contexts).
$stateFile = Join-Path (Split-Path $BackupDir -Parent) 'claude-code-backup-logs\last-run.json'

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
