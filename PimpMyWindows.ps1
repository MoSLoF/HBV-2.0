<#
.SYNOPSIS
    HoneyBadger Vanguard Windows posture switcher.
.DESCRIPTION
    The original project shipped a partially copied script that no longer
    exposed a functional GUI or reliable automation.  This rebuild provides a
    complete, documented interface that can toggle between hardened "Secure"
    and permissive "Tradecraft" postures.

    Features:
      • Dual entry points – GUI (default) or CLI via the -Mode parameter.
      • Deterministic logging with undo-script generation.
      • Pragmatic Windows adjustments: network profile enforcement, AutoRun
        policy tuning, Remote Registry start mode, and Microsoft Defender
        real-time monitoring (when available).

    Each run records the previous values before applying changes, making it
    safe to roll back by generating an undo script from the most recent log.

    NOTE: Administrative rights are required for posture changes.  When the GUI
    is used the script can relaunch itself elevated; CLI callers must run from
    an elevated prompt.
#>

[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Cli', Mandatory = $true)]
    [ValidateSet('Secure', 'Tradecraft')]
    [string]$Mode,

    [Parameter(ParameterSetName = 'Undo', Mandatory = $true)]
    [string]$UndoFromLog,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListLogs,

    [string]$LogDirectory = (Join-Path -Path $env:USERPROFILE -ChildPath 'HoneyBadgerLogs'),

    [Parameter(ParameterSetName = 'Cli')]
    [Parameter(ParameterSetName = 'Gui')]
    [switch]$Quiet
)

if (-not $IsWindows) {
    throw 'PimpMyWindows.ps1 only runs on Windows platforms.'
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

function Ensure-HBVAdministrator {
    param(
        [string]$ModeForRelaunch,
        [switch]$AllowRelaunch
    )

    if (Test-HBVAdministrator) {
        return $true
    }

    if ($AllowRelaunch -and $ModeForRelaunch) {
        $psPath = (Get-Process -Id $PID).Path
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Mode $ModeForRelaunch -LogDirectory ""$LogDirectory"""
        Start-Process -FilePath $psPath -Verb RunAs -ArgumentList $arguments | Out-Null
        return $false
    }

    throw 'Administrative privileges are required to modify system settings.'
}

function Get-HBVLogDirectory {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path -Path $Path).Path
}

function New-HBVLog {
    param(
        [ValidateSet('Secure', 'Tradecraft')]
        [string]$Mode,
        [string]$Directory
    )

    $resolved = Get-HBVLogDirectory -Path $Directory
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = "HBV-${Mode}Mode-$timestamp.log"
    $logPath = Join-Path -Path $resolved -ChildPath $fileName
    "=== HoneyBadger $Mode Mode started @ $(Get-Date -Format 's') ===" |
        Out-File -FilePath $logPath -Encoding utf8
    return $logPath
}

function Write-HBVLog {
    param(
        [string]$Path,
        [string]$Message
    )

    $Message | Out-File -FilePath $Path -Encoding utf8 -Append
    if (-not $Quiet) {
        Write-Host $Message
    }
}

function Get-HBVNetworkProfiles {
    if (-not (Get-Command -Name Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        return @()
    }
    return @(Get-NetConnectionProfile)
}

function Set-HBVNetworkCategory {
    param(
        [Microsoft.Management.Infrastructure.CimInstance[]]$Profiles,
        [string]$TargetCategory,
        [string]$LogPath,
        [string]$ModeName
    )

    if (-not $Profiles) {
        Write-HBVLog -Path $LogPath -Message '## INFO: No network profiles detected or NetTCPIP module unavailable.'
        return
    }

    foreach ($profile in $Profiles) {
        $profileInfo = [PSCustomObject]@{
            Name            = $profile.Name
            InterfaceAlias  = $profile.InterfaceAlias
            InterfaceIndex  = $profile.InterfaceIndex
            NetworkCategory = $profile.NetworkCategory
        }

        $json = $profileInfo | ConvertTo-Json -Compress
        Write-HBVLog -Path $LogPath -Message ("## Default_{0}: NetworkProfile = {1}" -f $ModeName, $json)

        $descriptor = if ($profile.InterfaceAlias) {
            $profile.InterfaceAlias
        }
        elseif ($profile.Name) {
            $profile.Name
        }
        else {
            "InterfaceIndex:$($profile.InterfaceIndex)"
        }

        if ($profile.NetworkCategory -eq 'DomainAuthenticated') {
            Write-HBVLog -Path $LogPath -Message ("## SKIP {0}: NetworkLocationCategory[{1}] = DomainAuthenticated" -f $ModeName, $descriptor)
            continue
        }

        if ($profile.NetworkCategory -eq $TargetCategory) {
            Write-HBVLog -Path $LogPath -Message ("## SKIP {0}: NetworkLocationCategory[{1}] = Already{2}" -f $ModeName, $descriptor, $TargetCategory)
            continue
        }

        try {
            Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory $TargetCategory -ErrorAction Stop
            Write-HBVLog -Path $LogPath -Message ("## SET NetworkLocationCategory[{0}] = {1}" -f $descriptor, $TargetCategory)
        }
        catch {
            Write-HBVLog -Path $LogPath -Message "!! ERROR: Failed to set NetworkLocationCategory[$descriptor] = $TargetCategory : $_"
        }
    }
}

function Set-HBVNoDriveTypeAutoRun {
    param(
        [int]$Value,
        [string]$LogPath,
        [string]$ModeName
    )

    $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $existing = $null
    try {
        $existing = Get-ItemProperty -Path $regPath -Name 'NoDriveTypeAutoRun' -ErrorAction Stop | Select-Object -ExpandProperty NoDriveTypeAutoRun
    }
    catch {
        Write-HBVLog -Path $LogPath -Message '## INFO: No existing NoDriveTypeAutoRun value detected.'
    }

    if ($null -ne $existing) {
        Write-HBVLog -Path $LogPath -Message ("## Default_{0}: NoDriveTypeAutoRun = {1}" -f $ModeName, $existing)
    }

    try {
        if (-not (Test-Path -Path $regPath)) {
            $parent = Split-Path -Path $regPath
            if (-not (Test-Path -Path $parent)) {
                New-Item -Path $parent -Force | Out-Null
            }
            New-Item -Path $regPath -Force | Out-Null
        }

        Set-ItemProperty -Path $regPath -Name 'NoDriveTypeAutoRun' -Value $Value -Force -ErrorAction Stop
        Write-HBVLog -Path $LogPath -Message ("## SET NoDriveTypeAutoRun = {0}" -f $Value)
    }
    catch {
        Write-HBVLog -Path $LogPath -Message "!! ERROR: Failed to set NoDriveTypeAutoRun = $Value : $_"
    }
}

function Set-HBVRemoteRegistry {
    param(
        [string]$StartupType,
        [string]$LogPath,
        [string]$ModeName
    )

    $service = Get-Service -Name RemoteRegistry -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-HBVLog -Path $LogPath -Message '## INFO: RemoteRegistry service not present.'
        return
    }

    Write-HBVLog -Path $LogPath -Message ("## Default_{0}: RemoteRegistry.StartType = {1}" -f $ModeName, $service.StartType)

    if ($service.StartType -eq $StartupType) {
        Write-HBVLog -Path $LogPath -Message ("## SKIP RemoteRegistry already set to {0}" -f $StartupType)
        return
    }

    try {
        Set-Service -Name RemoteRegistry -StartupType $StartupType -ErrorAction Stop
        Write-HBVLog -Path $LogPath -Message ("## SET RemoteRegistry.StartType = {0}" -f $StartupType)
    }
    catch {
        Write-HBVLog -Path $LogPath -Message "!! ERROR: Failed to set RemoteRegistry.StartType = $StartupType : $_"
    }
}

function Set-HBVDefenderRealtime {
    param(
        [bool]$DisableRealtimeMonitoring,
        [string]$LogPath,
        [string]$ModeName
    )

    if (-not (Get-Command -Name Set-MpPreference -ErrorAction SilentlyContinue)) {
        Write-HBVLog -Path $LogPath -Message '## INFO: Defender cmdlets unavailable on this platform.'
        return
    }

    try {
        $prefs = Get-MpPreference
        $current = [bool]$prefs.DisableRealtimeMonitoring
        Write-HBVLog -Path $LogPath -Message ("## Default_{0}: Defender.DisableRealtimeMonitoring = {1}" -f $ModeName, $current)

        if ($current -eq $DisableRealtimeMonitoring) {
            Write-HBVLog -Path $LogPath -Message ("## SKIP Defender.DisableRealtimeMonitoring already set to {0}" -f $DisableRealtimeMonitoring)
            return
        }

        Set-MpPreference -DisableRealtimeMonitoring:$DisableRealtimeMonitoring -ErrorAction Stop
        Write-HBVLog -Path $LogPath -Message ("## SET Defender.DisableRealtimeMonitoring = {0}" -f $DisableRealtimeMonitoring)
    }
    catch {
        Write-HBVLog -Path $LogPath -Message "!! ERROR: Failed to adjust Defender real-time monitoring : $_"
    }
}

function Invoke-HBVMode {
    param(
        [ValidateSet('Secure', 'Tradecraft')]
        [string]$Mode,
        [switch]$AllowRelaunch
    )

    $elevated = Ensure-HBVAdministrator -ModeForRelaunch $Mode -AllowRelaunch:$AllowRelaunch
    if (-not $elevated) {
        # Relaunch requested – nothing else to do in the original session.
        if ($AllowRelaunch) {
            return $null
        }

        throw 'Elevated privileges required.'
    }

    $logPath = New-HBVLog -Mode $Mode -Directory $LogDirectory

    switch ($Mode) {
        'Secure' {
            Set-HBVNetworkCategory -Profiles (Get-HBVNetworkProfiles) -TargetCategory 'Private' -LogPath $logPath -ModeName $Mode
            Set-HBVNoDriveTypeAutoRun -Value 255 -LogPath $logPath -ModeName $Mode
            Set-HBVRemoteRegistry -StartupType 'Disabled' -LogPath $logPath -ModeName $Mode
            Set-HBVDefenderRealtime -DisableRealtimeMonitoring:$false -LogPath $logPath -ModeName $Mode
        }
        'Tradecraft' {
            Set-HBVNoDriveTypeAutoRun -Value 145 -LogPath $logPath -ModeName $Mode
            Set-HBVRemoteRegistry -StartupType 'Manual' -LogPath $logPath -ModeName $Mode
            Set-HBVDefenderRealtime -DisableRealtimeMonitoring:$true -LogPath $logPath -ModeName $Mode
        }
    }

    Write-HBVLog -Path $logPath -Message "=== HoneyBadger $Mode Mode completed @ $(Get-Date -Format 's') ==="

    return [PSCustomObject]@{
        Mode      = $Mode
        LogPath   = $logPath
        Timestamp = Get-Date
    }
}

function Get-HBVLogs {
    param([string]$Directory)
    if (-not (Test-Path -Path $Directory)) {
        return @()
    }
    return Get-ChildItem -Path $Directory -Filter 'HBV-*.log' | Sort-Object LastWriteTime -Descending
}

function Get-HBVLastLog {
    param([string]$Directory)
    return (Get-HBVLogs -Directory $Directory | Select-Object -First 1)
}

function New-HBVUndoScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [string]$OutputPath
    )

    if (-not (Test-Path -Path $LogPath)) {
        throw "Log path '$LogPath' was not found."
    }

    if (-not $OutputPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutputPath = Join-Path -Path (Split-Path -Path $LogPath) -ChildPath "HBV-Undo-$timestamp.ps1"
    }

    $lines = Get-Content -Path $LogPath
    $commands = New-Object System.Collections.Generic.List[string]
    $trackedNetwork = @{}

    foreach ($line in $lines) {
        switch -Regex ($line) {
            '## Default_.*: NoDriveTypeAutoRun\s*=\s*(\d+)' {
                $value = [int]$Matches[1]
                $commands.Add("# Restore AutoRun policy")
                $commands.Add('if (-not (Test-Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies")) { New-Item -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion" -Name "Policies" -Force | Out-Null }')
                $commands.Add('if (-not (Test-Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer")) { New-Item -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies" -Name "Explorer" -Force | Out-Null }')
                $commands.Add("Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer' -Name 'NoDriveTypeAutoRun' -Value $value -Force")
            }
            '## Default_.*: RemoteRegistry\.StartType\s*=\s*(\w+)' {
                $startup = $Matches[1]
                $commands.Add("if (Get-Service -Name RemoteRegistry -ErrorAction SilentlyContinue) { Set-Service -Name RemoteRegistry -StartupType $startup } else { Write-Warning 'RemoteRegistry service not present.' }")
            }
            '## Default_.*: Defender\.DisableRealtimeMonitoring\s*=\s*(True|False)' {
                $state = $Matches[1]
                $commands.Add("if (Get-Command -Name Set-MpPreference -ErrorAction SilentlyContinue) { Set-MpPreference -DisableRealtimeMonitoring:`$${state} } else { Write-Warning 'Defender cmdlets unavailable on this system.' }")
            }
            '## Default_.*: NetworkProfile = (?<json>\{.+\})' {
                try {
                    $profileInfo = $Matches['json'] | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    continue
                }

                $descriptor = $profileInfo.InterfaceAlias
                if (-not $descriptor) {
                    $descriptor = if ($profileInfo.Name) { $profileInfo.Name } else { "InterfaceIndex:$($profileInfo.InterfaceIndex)" }
                }

                if (-not $trackedNetwork.ContainsKey($descriptor)) {
                    $trackedNetwork[$descriptor] = $profileInfo
                }
            }
        }
    }

    foreach ($key in $trackedNetwork.Keys) {
        $profileInfo = $trackedNetwork[$key]
        if (-not $profileInfo.NetworkCategory -or $profileInfo.NetworkCategory -eq 'DomainAuthenticated') {
            continue
        }

        $setCommand = if ($profileInfo.InterfaceAlias) {
            "Set-NetConnectionProfile -InterfaceAlias '$($profileInfo.InterfaceAlias.Replace("'", "''"))' -NetworkCategory $($profileInfo.NetworkCategory)"
        }
        elseif ($profileInfo.Name) {
            "Set-NetConnectionProfile -Name '$($profileInfo.Name.Replace("'", "''"))' -NetworkCategory $($profileInfo.NetworkCategory)"
        }
        elseif ($null -ne $profileInfo.InterfaceIndex) {
            "Set-NetConnectionProfile -InterfaceIndex $([int]$profileInfo.InterfaceIndex) -NetworkCategory $($profileInfo.NetworkCategory)"
        }

        if ($setCommand) {
            $commands.Add("if (Get-Command -Name Set-NetConnectionProfile -ErrorAction SilentlyContinue) { $setCommand } else { Write-Warning 'NetConnectionProfile cmdlets unavailable.' }")
        }
    }

    $scriptHeader = @'
<#
.SYNOPSIS
    Undo script generated by PimpMyWindows.ps1.
.DESCRIPTION
    Applies the baseline configuration captured before a HoneyBadger Vanguard
    posture switch.  Review the commands carefully before execution.
#>

[CmdletBinding()]
param()

if (-not $IsWindows) {
    throw 'Undo script can only run on Windows.'
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator privileges are required.'
}
'@

    if ($commands.Count -eq 0) {
        $commands.Add("Write-Warning 'No reversible actions were recorded in the selected log.'")
    }

    $scriptContent = $scriptHeader + [Environment]::NewLine + ($commands -join [Environment]::NewLine) + [Environment]::NewLine
    $scriptContent | Out-File -FilePath $OutputPath -Encoding utf8

    return $OutputPath
}

function Show-HBVGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'HoneyBadger Vanguard 2.0'
    $form.Size = New-Object System.Drawing.Size(480, 260)
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false
    $form.FormBorderStyle = 'FixedDialog'

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose a posture to apply. Logs are stored in:`n$LogDirectory"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(18, 20)
    $form.Controls.Add($label)

    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Multiline = $true
    $outputBox.ScrollBars = 'Vertical'
    $outputBox.ReadOnly = $true
    $outputBox.Size = New-Object System.Drawing.Size(430, 100)
    $outputBox.Location = New-Object System.Drawing.Point(18, 120)
    $form.Controls.Add($outputBox)

    function Update-OutputBox {
        param([string]$Text)
        if ($outputBox.Text) {
            $outputBox.AppendText([Environment]::NewLine)
        }
        $outputBox.AppendText($Text)
    }

    $secureButton = New-Object System.Windows.Forms.Button
    $secureButton.Text = 'Secure Mode'
    $secureButton.Size = New-Object System.Drawing.Size(130, 40)
    $secureButton.Location = New-Object System.Drawing.Point(18, 60)
    $secureButton.Add_Click({
        Update-OutputBox -Text 'Applying Secure Mode...'
        $result = Invoke-HBVMode -Mode 'Secure' -AllowRelaunch
        if ($result) {
            Update-OutputBox -Text "Secure Mode complete. Log: $($result.LogPath)"
        }
        else {
            Update-OutputBox -Text 'Secure Mode request forwarded for elevation.'
        }
    })
    $form.Controls.Add($secureButton)

    $tradeButton = New-Object System.Windows.Forms.Button
    $tradeButton.Text = 'Tradecraft Mode'
    $tradeButton.Size = New-Object System.Drawing.Size(130, 40)
    $tradeButton.Location = New-Object System.Drawing.Point(172, 60)
    $tradeButton.Add_Click({
        Update-OutputBox -Text 'Applying Tradecraft Mode...'
        $result = Invoke-HBVMode -Mode 'Tradecraft' -AllowRelaunch
        if ($result) {
            Update-OutputBox -Text "Tradecraft Mode complete. Log: $($result.LogPath)"
        }
        else {
            Update-OutputBox -Text 'Tradecraft Mode request forwarded for elevation.'
        }
    })
    $form.Controls.Add($tradeButton)

    $undoButton = New-Object System.Windows.Forms.Button
    $undoButton.Text = 'Generate Undo Script'
    $undoButton.Size = New-Object System.Drawing.Size(160, 40)
    $undoButton.Location = New-Object System.Drawing.Point(326, 60)
    $undoButton.Add_Click({
        $lastLog = Get-HBVLastLog -Directory $LogDirectory
        if (-not $lastLog) {
            Update-OutputBox -Text 'No log files found to build an undo script.'
            return
        }

        try {
            $undoPath = New-HBVUndoScript -LogPath $lastLog.FullName
            Update-OutputBox -Text "Undo script created: $undoPath"
        }
        catch {
            Update-OutputBox -Text "Failed to create undo script: $_"
        }
    })
    $form.Controls.Add($undoButton)

    [void]$form.ShowDialog()
}

switch ($PSCmdlet.ParameterSetName) {
    'Cli' {
        $result = Invoke-HBVMode -Mode $Mode
        if ($result) {
            return $result
        }
    }
    'Undo' {
        $targetLog = $UndoFromLog
        if ($UndoFromLog -in @('latest', 'last')) {
            $file = Get-HBVLastLog -Directory $LogDirectory
            if (-not $file) {
                throw 'No HoneyBadger logs were found.'
            }
            $targetLog = $file.FullName
        }

        $undoPath = New-HBVUndoScript -LogPath $targetLog
        if (-not $Quiet) {
            Write-Host "Undo script created at $undoPath" -ForegroundColor Cyan
        }
        return
    }
    'List' {
        $logs = Get-HBVLogs -Directory $LogDirectory
        if (-not $logs) {
            Write-Host 'No HoneyBadger logs available.'
            return
        }

        $logs | Select-Object @{Name = 'LastWriteTime'; Expression = { $_.LastWriteTime } }, Name, FullName
        return
    }
    default {
        Show-HBVGui
    }
}
