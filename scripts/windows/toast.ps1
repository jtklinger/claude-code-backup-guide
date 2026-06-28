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
