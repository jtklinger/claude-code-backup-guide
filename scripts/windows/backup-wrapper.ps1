# backup-wrapper.ps1 — Task Scheduler entry point.
# Runs backup.sh via Git-bash, captures result, logs to file + Event Log + state, toasts on success and failure,
# and re-emits the bash exit code so Task Scheduler's LastTaskResult stays truthful.
#   -Fast    passes --fast to backup.sh (size+mtime change detection; faster on large data).
#   -Silent  hides the console window so the run doesn't pop up on screen; toasts still show.
[CmdletBinding()]
param(
    [string]$BackupDir     = "C:\Users\me\claude-code-backup",
    [string]$BashExe       = $null,
    [string]$StateDir      = $null,
    [int]   $RetentionDays = 14,
    [switch]$Fast,
    [switch]$Silent
)

# ErrorActionPreference is intentionally left at the default ('Continue'). backup.sh runs under
# `set -e` and may write to stderr (git, the -l login shell). Capturing it with `& bash ... 2>&1`
# under 'Stop' would wrap each stderr line in a NativeCommandError and THROW before we read
# $LASTEXITCODE — turning a successful-but-chatty run into a false failure. We capture the exit
# code explicitly and use the try/catch below to fail loud on genuinely unexpected wrapper errors.

$EventSource = 'ClaudeCodeBackup'
. (Join-Path $PSScriptRoot 'toast.ps1')
if ($Silent) { Hide-ConsoleWindow }   # hide ASAP so the window doesn't linger on screen

function Write-BackupEvent {
    param([string]$EntryType, [int]$Id, [string]$Message)
    try {
        Write-EventLog -LogName Application -Source $EventSource -EntryType $EntryType -EventId $Id -Message $Message
    } catch { }  # source not registered yet (pre-install) — the log file still has the full record
}
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

$start     = Get-Date
# State + logs live next to the backup repo, NOT under %LOCALAPPDATA%: the packaged (MSIX) Claude
# desktop app virtualizes %LOCALAPPDATA% to a per-package LocalCache, so an AppData path resolves
# inconsistently between the scheduled task and other contexts. A path derived from -BackupDir is
# stable everywhere (the backup repo dir is writable + non-virtualized in every context).
if (-not $StateDir) { $StateDir = Join-Path (Split-Path $BackupDir -Parent) 'claude-code-backup-logs' }
$LogDir    = Join-Path $StateDir 'logs'
$stateFile = Join-Path $StateDir 'last-run.json'
$logFile   = Join-Path $LogDir ("backup-{0:yyyy-MM-dd}.log" -f $start)

try {
    New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction Stop | Out-Null

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
    $fastArg = if ($Fast) { ' --fast' } else { '' }
    $output  = & $bash -l -c "bash '$bashScript' '$bashBackupDir'$fastArg" 2>&1
    $code    = $LASTEXITCODE
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
        fast           = [bool]$Fast
        scriptVersion  = '2.4.0'
    } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding utf8

    # --- Event Log + toast (success and failure) ---
    if ($code -eq 0) {
        Write-BackupEvent -EntryType Information -Id 1000 -Message "Backup succeeded in ${duration}s. Log: $logFile"
        Show-BackupToast -Title "Claude Code backup succeeded" -Body "Completed in ${duration}s."
    } else {
        # Surface the cause at a glance: last non-empty output line, ANSI-stripped, length-capped.
        $lastErr = ($output | Out-String) -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1
        if ($lastErr) { $lastErr = ($lastErr -replace '\x1b\[[0-9;]*m', '').Trim() }
        $toastBody = if ($lastErr) { "Exit ${code}: $lastErr" } else { "Exit $code. See $logFile" }
        if ($toastBody.Length -gt 150) { $toastBody = $toastBody.Substring(0, 147) + '...' }
        Write-BackupEvent -EntryType Error -Id 1001 -Message "Backup FAILED (exit $code) in ${duration}s. Log: $logFile"
        Show-BackupToast -Title "Claude Code backup FAILED" -Body $toastBody
    }

    exit $code

} catch {
    # Genuinely unexpected wrapper failure — fail loud, never mask.
    $m = "Wrapper error: $($_.Exception.Message)"
    try { Add-Content -Path $logFile -Value "[$($start.ToString('o'))] $m" } catch { }
    Write-BackupEvent -EntryType Error -Id 1001 -Message $m
    try { Show-BackupToast -Title "Claude Code backup FAILED" -Body $m } catch { }
    exit 1
}
