# toast.ps1 — minimal, dependency-free Windows helpers (shared by the wrapper +
# watchdog). Dot-source this file, then call Show-BackupToast / Hide-ConsoleWindow.

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

function Hide-ConsoleWindow {
    # Hide THIS process's console window — used by -Silent so a Task Scheduler
    # run doesn't flash a window on screen during the (multi-minute) backup.
    # Affects only the visible window: toasts (separate API) and stdout/stderr
    # capture are unaffected, and the child bash process inherits the hidden
    # console (no second window). Idempotent and best-effort.
    try {
        if (-not ('Native.Win32Window' -as [type])) {
            Add-Type -Namespace Native -Name Win32Window -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $h = [Native.Win32Window]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][Native.Win32Window]::ShowWindow($h, 0) }  # 0 = SW_HIDE
    } catch {
        Write-Warning "Hide-ConsoleWindow failed: $($_.Exception.Message)"
    }
}
