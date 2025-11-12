<#
.SYNOPSIS
    HoneyBadger Vanguard 2.0 orchestration entry point.
.DESCRIPTION
    The previous revision only logged the requested mode.  This version brings
    the core workflow back to life by coordinating the public modules shipped in
    the repository:
      • Applies Secure/Tradecraft postures via PimpMyWindows.ps1.
      • Optionally generates an undo script for the last posture change.
      • Drives repo_hunter.ps1 to maintain a local threat-intel snapshot.
      • Summarises hunting artefacts with auto_parse_hunting_results.ps1.
      • Captures environment readiness reports through HBV-HealthCheck.ps1.

    The script writes an execution log under %USERPROFILE%\HoneyCoreLogs and
    returns a summary object for automation scenarios.
#>

[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    [Parameter(ParameterSetName = 'Mode', Mandatory = $true)]
    [ValidateSet('Secure', 'Tradecraft')]
    [string]$Mode,

    [Parameter(ParameterSetName = 'Mode')]
    [Parameter(ParameterSetName = 'UndoOnly', Mandatory = $true)]
    [switch]$GenerateUndoScript,

    [Parameter(ParameterSetName = 'Mode')]
    [Parameter(ParameterSetName = 'UndoOnly')]
    [string]$UndoLog = 'latest',

    [switch]$RunRepoHunter,

    [string]$RepoSnapshotPath,

    [switch]$SummariseHunt,

    [string]$HuntInputPath,

    [string]$HuntSummaryPath,

    [switch]$RunHealthCheck,

    [string]$HealthReportPath,

    [switch]$DryRun,

    [switch]$Quiet
)

if (-not $IsWindows) {
    throw 'HBV-Core.ps1 is intended for Windows hosts running PowerShell.'
}

$script:CoreLogRoot = Join-Path -Path $env:USERPROFILE -ChildPath 'HoneyCoreLogs'
if (-not (Test-Path -Path $CoreLogRoot)) {
    New-Item -ItemType Directory -Path $CoreLogRoot -Force | Out-Null
}

$script:CoreLogPath = Join-Path -Path $CoreLogRoot -ChildPath ("HBV-Core-$(Get-Date -Format 'yyyyMMdd-HHmmss').log")
"=== HBV-Core started @ $(Get-Date -Format 's') ===" | Out-File -FilePath $CoreLogPath -Encoding utf8

function Write-CoreLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $Message | Out-File -FilePath $CoreLogPath -Encoding utf8 -Append
    if (-not $Quiet) {
        try {
            $oldColor = $Host.UI.RawUI.ForegroundColor
            $Host.UI.RawUI.ForegroundColor = $Color
            Write-Host $Message
            $Host.UI.RawUI.ForegroundColor = $oldColor
        }
        catch {
            Write-Host $Message
        }
    }
}

function Get-ModulePath {
    param([string]$Name)
    $root = Split-Path -Parent $PSCommandPath
    return (Join-Path -Path $root -ChildPath $Name)
}

$summary = [ordered]@{
    ModeApplied        = $null
    ModeLog            = $null
    UndoScript         = $null
    RepoSnapshot       = $null
    HuntSummary        = $null
    HealthReport       = $null
    DryRun             = [bool]$DryRun
    Timestamp          = Get-Date
}

function Invoke-HBVModule {
    param(
        [string]$ScriptPath,
        [hashtable]$Arguments
    )

    if (-not (Test-Path -Path $ScriptPath)) {
        throw "Module '$ScriptPath' was not found."
    }

    $argumentSummary = ''
    if ($Arguments) {
        $argumentSummary = ($Arguments.GetEnumerator() |
            ForEach-Object { "-$($_.Key) $($_.Value)" } |
            Sort-Object) -join ' '
        if ($argumentSummary) {
            $argumentSummary = " $argumentSummary"
        }
    }

    $moduleName = [IO.Path]::GetFileName($ScriptPath)
    Write-CoreLog -Message "## EXECUTE: $moduleName$argumentSummary"

    if ($DryRun) {
        Write-CoreLog -Message '## INFO: DryRun flag set – execution skipped.' -Color Yellow
        return $null
    }

    try {
        return & $ScriptPath @Arguments
    }
    catch {
        Write-CoreLog -Message "!! ERROR running $ScriptPath : $_" -Color Red
        throw
    }
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Mode') {
        $args = @{ Mode = $Mode; Quiet = $true }
        $result = Invoke-HBVModule -ScriptPath (Get-ModulePath 'PimpMyWindows.ps1') -Arguments $args
        if ($result) {
            $summary.ModeApplied = $result.Mode
            $summary.ModeLog = $result.LogPath
            Write-CoreLog -Message "## MODE: $($result.Mode) applied. Log => $($result.LogPath)" -Color Cyan
        }

        if ($GenerateUndoScript) {
            $undoArgs = @{ UndoFromLog = $UndoLog; Quiet = $true }
            $undoPath = Invoke-HBVModule -ScriptPath (Get-ModulePath 'PimpMyWindows.ps1') -Arguments $undoArgs
            $summary.UndoScript = $undoPath
            if ($undoPath) {
                Write-CoreLog -Message "## UNDO: Script generated at $undoPath" -Color Cyan
            }
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'UndoOnly' -and $GenerateUndoScript) {
        $undoArgs = @{ UndoFromLog = $UndoLog; Quiet = $true }
        $undoPath = Invoke-HBVModule -ScriptPath (Get-ModulePath 'PimpMyWindows.ps1') -Arguments $undoArgs
        $summary.UndoScript = $undoPath
        if ($undoPath) {
            Write-CoreLog -Message "## UNDO: Script generated at $undoPath" -Color Cyan
        }
    }

    if ($RunRepoHunter) {
        $repoArgs = @{}
        if ($RepoSnapshotPath) { $repoArgs.OutputPath = $RepoSnapshotPath }
        $repoResult = Invoke-HBVModule -ScriptPath (Get-ModulePath 'repo_hunter.ps1') -Arguments $repoArgs
        if ($repoResult) {
            $summary.RepoSnapshot = $repoResult.OutputPath
        }
    }

    if ($SummariseHunt) {
        if (-not $HuntInputPath) {
            throw 'SummariseHunt requires -HuntInputPath.'
        }
        $huntArgs = @{ InputPath = $HuntInputPath }
        if ($HuntSummaryPath) { $huntArgs.OutputPath = $HuntSummaryPath }
        $huntResult = Invoke-HBVModule -ScriptPath (Get-ModulePath 'auto_parse_hunting_results.ps1') -Arguments $huntArgs
        if ($huntResult) {
            $summary.HuntSummary = $huntResult.OutputPath
        }
    }

    if ($RunHealthCheck) {
        $healthArgs = @{ Quiet = $true }
        if ($HealthReportPath) { $healthArgs.OutputPath = $HealthReportPath }
        $healthResult = Invoke-HBVModule -ScriptPath (Get-ModulePath 'HBV-HealthCheck.ps1') -Arguments $healthArgs
        if ($healthResult) {
            $summary.HealthReport = $healthResult
        }
    }
}
finally {
    Write-CoreLog -Message "=== HBV-Core completed @ $(Get-Date -Format 's') ==="
}

[PSCustomObject]$summary
