$secureButton.Add_Click({
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator")) {
        Start-Process powershell -Verb runAs -ArgumentList "-File `"$PSCommandPath`""
        return
    }

    $logDir = "$env:USERPROFILE\HoneySecureLogs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = "$logDir\SecureMode-$timestamp.txt"
    Add-Content $logPath "=== HoneyBadger Secure Mode Activated @ $timestamp ==="

    [System.Windows.Forms.MessageBox]::Show("Secure Mode launched. Changes will be logged to:`n$logPath", "Secure Mode")

    try {
