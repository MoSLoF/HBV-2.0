<#
.SYNOPSIS
    Performs baseline environment validation for HoneyBadger Vanguard workflows.
.DESCRIPTION
    HBV-HealthCheck.ps1 inspects a host and reports on prerequisites that help
    the other automation entry points succeed.  The script focuses on checks
    that frequently break hardened lab deployments:
      • PowerShell version and architecture details.
      • Administrative privileges.
      • Availability of networking cmdlets relied on by PimpMyWindows.ps1.
      • Microsoft Defender service state (when present).
      • Git availability for repo_hunter.ps1 cloning operations.

    Results are returned as an object for automation but can also be written to
    a JSON file under %USERPROFILE%\HoneyCoreLogs by default.
#>

[CmdletBinding()]
param(
    [string]$OutputPath,

    [switch]$NoExport,

    [switch]$Quiet
)

if (-not $IsWindows) {
    throw 'HBV-HealthCheck.ps1 must be executed on a Windows host.'
}

function Test-HBVAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-HBVLogDirectory {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -Path $Path).Path
}

$logRoot = Join-Path -Path $env:USERPROFILE -ChildPath 'HoneyCoreLogs'
if (-not $OutputPath -and -not $NoExport) {
    $OutputPath = Join-Path -Path $logRoot -ChildPath ("HBV-HealthCheck-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$checks = New-Object System.Collections.Generic.List[object]

function Add-HBVCheck {
    param(
        [string]$Name,
        [ValidateSet('Pass', 'Warn', 'Fail', 'Info')]
        [string]$Status,
        [string]$Detail
    )

    $checks.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    }) | Out-Null
}

$psVersion = $PSVersionTable.PSVersion
$versionStatus = if ($psVersion.Major -gt 5 -or ($psVersion.Major -eq 5 -and $psVersion.Minor -ge 1)) { 'Pass' } else { 'Warn' }
Add-HBVCheck -Name 'PowerShell Version' -Status $versionStatus -Detail "Detected version: $psVersion"

$bitness = if ([Environment]::Is64BitProcess) { '64-bit' } else { '32-bit' }
Add-HBVCheck -Name 'PowerShell Architecture' -Status 'Info' -Detail "Process architecture: $bitness"

$osInfo = $null
try {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Add-HBVCheck -Name 'Operating System' -Status 'Info' -Detail "$($osInfo.Caption) ($($osInfo.Version))"
}
catch {
    Add-HBVCheck -Name 'Operating System' -Status 'Warn' -Detail "Unable to query OS details: $_"
}

if (Test-HBVAdministrator) {
    Add-HBVCheck -Name 'Administrator Rights' -Status 'Pass' -Detail 'Current process is elevated.'
}
else {
    Add-HBVCheck -Name 'Administrator Rights' -Status 'Warn' -Detail 'Not running with administrative privileges. Some modules require elevation.'
}

if (Get-Command -Name Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop
        $profileSummary = if ($profiles) {
            ($profiles | Select-Object -First 3 | ForEach-Object {
                if ($_.Name) { $_.Name } elseif ($_.InterfaceAlias) { $_.InterfaceAlias } else { "InterfaceIndex:$($_.InterfaceIndex)" }
            }) -join ', '
        } else {
            'No active profiles detected.'
        }
        Add-HBVCheck -Name 'NetTCPIP Module' -Status 'Pass' -Detail "Get-NetConnectionProfile accessible. Sample: $profileSummary"
    }
    catch {
        Add-HBVCheck -Name 'NetTCPIP Module' -Status 'Warn' -Detail "Cmdlet available but failed to enumerate profiles: $_"
    }
}
else {
    Add-HBVCheck -Name 'NetTCPIP Module' -Status 'Warn' -Detail 'Get-NetConnectionProfile cmdlet not available. Network posture enforcement will be skipped.'
}

try {
    $defenderService = Get-Service -Name 'WinDefend' -ErrorAction Stop
    $status = if ($defenderService.Status -eq 'Running') { 'Pass' } else { 'Warn' }
    Add-HBVCheck -Name 'Microsoft Defender' -Status $status -Detail "Service state: $($defenderService.Status)"
}
catch {
    Add-HBVCheck -Name 'Microsoft Defender' -Status 'Info' -Detail 'Service not found. Defender-specific actions will be skipped.'
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Add-HBVCheck -Name 'Git Availability' -Status 'Pass' -Detail "git located at $($git.Source)"
}
else {
    Add-HBVCheck -Name 'Git Availability' -Status 'Warn' -Detail 'git executable not found in PATH. repo_hunter cloning will be disabled.'
}

$report = [ordered]@{
    Generated  = Get-Date
    Computer   = $env:COMPUTERNAME
    Checks     = $checks
    ExportPath = $null
}

if ($OutputPath -and -not $NoExport) {
    $resolvedPath = if ([IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath
    }
    else {
        Join-Path -Path (Get-Location) -ChildPath $OutputPath
    }

    try {
        $directory = Split-Path -Path $resolvedPath -Parent
        if ($directory) {
            $resolvedDirectory = Get-HBVLogDirectory -Path $directory
            $resolvedPath = Join-Path -Path $resolvedDirectory -ChildPath (Split-Path -Path $resolvedPath -Leaf)
        }
        $report.ExportPath = $resolvedPath
        $report | ConvertTo-Json -Depth 5 | Out-File -FilePath $resolvedPath -Encoding utf8
        if (-not $Quiet) {
            Write-Host "[HBV-HealthCheck] Report exported to $resolvedPath" -ForegroundColor Green
        }
    }
    catch {
        Add-HBVCheck -Name 'Report Export' -Status 'Warn' -Detail "Failed to write report to $resolvedPath : $_"
        $report.ExportPath = $null
    }
}
elseif ($NoExport) {
    if (-not $Quiet) {
        Write-Host '[HBV-HealthCheck] Export suppressed via -NoExport.' -ForegroundColor Yellow
    }
}

if (-not $Quiet) {
    foreach ($check in $checks) {
        $color = switch ($check.Status) {
            'Pass' { 'Green' }
            'Info' { 'Gray' }
            'Warn' { 'Yellow' }
            'Fail' { 'Red' }
        }
        Write-Host ("[{0}] {1} - {2}" -f $check.Status, $check.Name, $check.Detail) -ForegroundColor $color
    }
}

[PSCustomObject]$report
