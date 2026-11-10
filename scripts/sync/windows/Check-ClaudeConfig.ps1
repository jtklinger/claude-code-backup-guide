<#
.SYNOPSIS
    Daily drift check of the shared Claude Code config layer on Windows.

.DESCRIPTION
    The Windows counterpart to systemd/claude-config-check.timer. Runs
    sync-claude-config.sh --check through Git Bash against -SharedDir, appends the
    result to a dated log, and, when alert.env is present, emails on drift.

    Drift shows up three ways: an email if alert.env is present; the Task Scheduler
    "Last Run Result" column (0 = in sync, 1 = drift); and the log itself, under
    %LOCALAPPDATA%\claude-config-check\.

    Exits 0 in sync, 1 on drift, 2 if the check could not run at all.

.EXAMPLE
    .\Check-ClaudeConfig.ps1 -SharedDir C:\Users\me\claude-shared -NoEmail
#>
[CmdletBinding()]
param(
    # Your shared-config directory (the one holding settings.shared.json).
    [Parameter(Mandatory)]
    [string]$SharedDir,
    # Skip email delivery even if alert.env is present. For manual runs.
    [switch]$NoEmail
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Under Task Scheduler the console defaults to the OEM codepage, which mangles the UTF-8
# the sync script emits (an em dash logs as a mojibake run). Decode it as UTF-8.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$GuideRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$LogDir    = Join-Path $env:LOCALAPPDATA 'claude-config-check'
$Log       = Join-Path $LogDir ("check-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$AlertEnv  = Join-Path $PSScriptRoot 'alert.env'   # gitignored; see alert.env.example

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log([string]$Text) {
    Add-Content -Path $Log -Value $Text -Encoding UTF8
}

# C:\Users\x\dir -> /c/Users/x/dir  (string ops, not a scriptblock -replace,
# which Windows PowerShell 5.1 does not support)
function ConvertTo-MsysPath([string]$Path) {
    $Drive = $Path.Substring(0, 1).ToLower()
    $Rest  = $Path.Substring(2) -replace '\\', '/'
    return "/$Drive$Rest"
}

# Git Bash: the sync script is bash, and MSYS is what makes ~ and /c/... resolve.
$BashCandidates = @(
    'C:\Program Files\Git\bin\bash.exe'
    'C:\Program Files (x86)\Git\bin\bash.exe'
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
$Bash = $BashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Bash) {
    Write-Log "=== run started at $(Get-Date -Format o) ==="
    Write-Log 'error: Git Bash not found - install Git for Windows or edit $BashCandidates'
    Write-Log "=== run finished rc=2 at $(Get-Date -Format o) ==="
    exit 2
}
if (-not (Test-Path $SharedDir)) {
    Write-Log "=== run started at $(Get-Date -Format o) ==="
    Write-Log "error: shared-config directory not found: $SharedDir"
    Write-Log "=== run finished rc=2 at $(Get-Date -Format o) ==="
    exit 2
}
$SharedDir   = (Resolve-Path $SharedDir).Path
$MsysGuide   = ConvertTo-MsysPath $GuideRoot
$MsysShared  = ConvertTo-MsysPath $SharedDir

Write-Log "=== run started at $(Get-Date -Format o) ==="

# A stale checkout would report "in sync" against an old shared layer, so refresh the
# view of the remote first. A failed fetch is a warning, not a failure: being offline
# should not read as config drift.
# Native stderr arrives as ErrorRecords; under $ErrorActionPreference = 'Stop' a native
# `2>&1` throws before the exit code can be read. Both native calls below drop to
# 'Continue' so stderr is captured as text instead of aborting the run.
try {
    $Eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C $SharedDir fetch --quiet 2>&1 | ForEach-Object { Write-Log $_ }
    $Behind = & git -C $SharedDir log --oneline 'HEAD..@{u}' 2>$null
    if ($Behind) { Write-Log "note: the shared-config repo is behind its remote - run 'git pull' then re-sync" }
} catch {
    Write-Log "warning: fetch failed - checking against the local checkout ($($_.Exception.Message))"
} finally {
    $ErrorActionPreference = $Eap
}

$ErrorActionPreference = 'Continue'
$Output = & $Bash -lc "bash '$MsysGuide/scripts/sync/sync-claude-config.sh' --check '$MsysShared'" 2>&1
$rc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$Output | ForEach-Object { Write-Log $_ }
Write-Log "=== run finished rc=$rc at $(Get-Date -Format o) ==="

if ($rc -ne 0 -and -not $NoEmail -and (Test-Path $AlertEnv)) {
    $cfg = @{}
    Get-Content $AlertEnv | Where-Object { $_ -match '^\s*[^#\s]' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        if ($v) { $cfg[$k.Trim()] = $v.Trim() }
    }
    $host_ = $cfg['CLAUDE_CHECK_SMTP_HOST']
    $to    = $cfg['CLAUDE_CHECK_EMAIL_TO']
    $from  = $cfg['CLAUDE_CHECK_EMAIL_FROM']
    if ($host_ -and $to -and $from) {
        try {
            $port = if ($cfg['CLAUDE_CHECK_SMTP_PORT']) { [int]$cfg['CLAUDE_CHECK_SMTP_PORT'] } else { 25 }
            $body = "Shared Claude Code config drift on $env:COMPUTERNAME.`n`n" +
                    ($Output -join "`n") +
                    "`n`nFix: git pull in $SharedDir, then run sync-claude-config.sh.`nLog: $Log"
            $msg = New-Object System.Net.Mail.MailMessage($from, $to,
                "Claude config drift on $env:COMPUTERNAME", $body)
            $smtp = New-Object System.Net.Mail.SmtpClient($host_, $port)
            $smtp.Send($msg)
            Write-Log "alert: emailed $to"
        } catch {
            # Delivery failure must not mask the drift: the exit code still reports it.
            Write-Log "alert: email failed - $($_.Exception.Message)"
        }
    } else {
        Write-Log 'alert: alert.env present but incomplete - no email sent'
    }
}

exit $rc
