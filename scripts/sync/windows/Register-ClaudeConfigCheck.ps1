<#
.SYNOPSIS
    Install (or update) the daily Scheduled Task that runs Check-ClaudeConfig.ps1.

.DESCRIPTION
    The Windows counterpart to `systemctl --user enable --now claude-config-check.timer`.
    Re-running is safe: an existing task of the same name is replaced.

    The task runs as the current user with Interactive logon, so it fires only while
    logged on. It needs no stored password, and a config check on a machine nobody is
    using has nothing to report. -StartWhenAvailable is the equivalent of systemd's
    Persistent=true, catching up a run missed while the machine was off.

.EXAMPLE
    .\Register-ClaudeConfigCheck.ps1 -SharedDir C:\Users\me\claude-shared
    .\Register-ClaudeConfigCheck.ps1 -SharedDir C:\Users\me\claude-shared -At 07:30
    .\Register-ClaudeConfigCheck.ps1 -Unregister
#>
[CmdletBinding()]
param(
    # Your shared-config directory (the one holding settings.shared.json).
    [string]$SharedDir,
    [string]$TaskName = 'Claude config drift check',
    [datetime]$At = '09:00',
    [switch]$Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task: $TaskName"
    return
}

if (-not $SharedDir) { throw '-SharedDir is required (the folder holding settings.shared.json)' }
if (-not (Test-Path $SharedDir)) { throw "not found: $SharedDir" }
$SharedDir = (Resolve-Path $SharedDir).Path

$Script = Join-Path $PSScriptRoot 'Check-ClaudeConfig.ps1'
if (-not (Test-Path $Script)) { throw "not found: $Script" }

$Action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`" -SharedDir `"$SharedDir`""
$Trigger   = New-ScheduledTaskTrigger -Daily -At $At
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited
$Settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Principal $Principal -Settings $Settings -Force `
    -Description "Daily --check of the shared Claude Code config layer in $SharedDir." | Out-Null

Write-Host "Registered '$TaskName' - daily at $($At.ToString('HH:mm'))."
Write-Host "Run now:   Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Result:    (Get-ScheduledTaskInfo -TaskName '$TaskName').LastTaskResult   # 0 = in sync, 1 = drift"
Write-Host "Log:       $env:LOCALAPPDATA\claude-config-check\"
