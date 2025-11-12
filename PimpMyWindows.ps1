        # 7. Force Network Location to Private (with safety checks)
        $connectionProfiles = @(Get-NetConnectionProfile)
        $profilesToUpdate = @()

        foreach ($profile in $connectionProfiles) {
            $profileInfo = @{
                Name = $profile.Name
                InterfaceAlias = $profile.InterfaceAlias
                InterfaceIndex = $profile.InterfaceIndex
                NetworkCategory = $profile.NetworkCategory
            }

            $serializedProfile = $profileInfo | ConvertTo-Json -Compress
            Add-Content $logPath "## Default_Secure: NetworkProfile = $serializedProfile"

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
                Add-Content $logPath "## SKIP NetworkLocationCategory[$descriptor] = DomainAuthenticated"
                continue
            }

            if ($profile.NetworkCategory -eq 'Private') {
                Add-Content $logPath "## SKIP NetworkLocationCategory[$descriptor] = AlreadyPrivate"
                continue
            }

            $profilesToUpdate += [pscustomobject]@{
                Profile = $profile
                Descriptor = $descriptor
            }
        }

        if ($profilesToUpdate.Count -gt 0) {
            foreach ($item in $profilesToUpdate) {
                try {
                    Set-NetConnectionProfile -InterfaceIndex $item.Profile.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                    Add-Content $logPath "## SET NetworkLocationCategory[$($item.Descriptor)] = Private"
                }
                catch {
                    Add-Content $logPath "!! ERROR: Failed to set NetworkLocationCategory[$($item.Descriptor)] = Private : $_"
                }
            }
        }
        else {
            Add-Content $logPath "## INFO: NetworkLocationCategory already compliant or skipped."
        }
                '## Default_(Secure|Tradecraft): NoDriveTypeAutoRun\s*=\s*(\d+)' {
                    $value = [int]$Matches[1]
                    try {
                        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoDriveTypeAutoRun" -Value $value -Force -ErrorAction Stop
                        Add-Content $lastLog.FullName "## UNDO: NoDriveTypeAutoRun = $value"
                    }
                    catch {
                        Add-Content $lastLog.FullName "!! ERROR: Failed to restore NoDriveTypeAutoRun to $value : $_"
                    }
                }

                '## Default_(Secure|Tradecraft): NetworkProfile = (?<json>\{.+\})' {
                    try {
                        $profileInfo = $Matches['json'].Trim() | ConvertFrom-Json
                    }
                    catch {
                        Add-Content $lastLog.FullName "!! ERROR: Failed to parse NetworkProfile entry: $($Matches['json'])"
                        continue
                    }

                    $targetCategory = $profileInfo.NetworkCategory
                    $targetDescriptor = $null
                    $setParams = @{}

                    if ($profileInfo.InterfaceAlias) {
                        $setParams.InterfaceAlias = $profileInfo.InterfaceAlias
                        $targetDescriptor = $profileInfo.InterfaceAlias
                    }
                    elseif ($profileInfo.Name) {
                        $setParams.Name = $profileInfo.Name
                        $targetDescriptor = $profileInfo.Name
                    }
                    elseif ($null -ne $profileInfo.InterfaceIndex) {
                        $setParams.InterfaceIndex = [int]$profileInfo.InterfaceIndex
                        $targetDescriptor = "InterfaceIndex:$($setParams.InterfaceIndex)"
                    }

                    if (-not $targetCategory -or -not $targetDescriptor) {
                        Add-Content $lastLog.FullName "!! ERROR: NetworkProfile entry missing required data. Skipping."
                        continue
                    }

                    if ($targetCategory -eq 'DomainAuthenticated') {
                        Add-Content $lastLog.FullName "## UNDO: NetworkProfile $targetDescriptor skipped (DomainAuthenticated)"
                        continue
                    }

                    try {
                        Set-NetConnectionProfile @setParams -NetworkCategory $targetCategory -ErrorAction Stop
                        $undoRecord = @{ Target = $targetDescriptor; NetworkCategory = $targetCategory }
                        Add-Content $lastLog.FullName ("## UNDO: NetworkProfile = {0}" -f ($undoRecord | ConvertTo-Json -Compress))
                    }
                    catch {
                        Add-Content $lastLog.FullName "!! ERROR: Failed to restore NetworkProfile $targetDescriptor : $_"
                    }
                }

                # Remote Registry
                '## Default_(Secure|Tradecraft): RemoteRegistry\.StartType\s*=\s*(\w+)' {
                    $startup = $Matches[1]
                    try {
                        Set-Service -Name RemoteRegistry -StartupType $startup -ErrorAction Stop
                        Add-Content $lastLog.FullName "## UNDO: RemoteRegistry.StartType = $startup"
                    }
                    catch {
                        Add-Content $lastLog.FullName "!! ERROR: Failed to restore RemoteRegistry.StartType to $startup : $_"
                    }
            '## Default_.*: NoDriveTypeAutoRun\s*=\s*(\d+)' {
                $v = $Matches[1]
                $undoScript += 'if (-not (Test-Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies")) { New-Item -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion" -Name "Policies" -Force | Out-Null }; if (-not (Test-Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer")) { New-Item -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies" -Name "Explorer" -Force | Out-Null }; Set-ItemProperty -Path "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer" -Name "NoDriveTypeAutoRun" -Value ' + $v + ' -Force'
            }
            '## Default_.*: NetworkProfile = (?<json>\{.+\})' {
                try {
                    $profileInfo = $Matches['json'].Trim() | ConvertFrom-Json
                }
                catch {
                    continue
                }

                $category = $profileInfo.NetworkCategory
                if (-not $category -or $category -eq 'DomainAuthenticated') { continue }

                if ($profileInfo.InterfaceAlias) {
                    $escapedAlias = $profileInfo.InterfaceAlias -replace "'", "''"
                    $undoScript += ("Set-NetConnectionProfile -InterfaceAlias '{0}' -NetworkCategory {1}" -f $escapedAlias, $category)
                }
                elseif ($profileInfo.Name) {
                    $escapedName = $profileInfo.Name -replace "'", "''"
                    $undoScript += ("Set-NetConnectionProfile -Name '{0}' -NetworkCategory {1}" -f $escapedName, $category)
                }
                elseif ($null -ne $profileInfo.InterfaceIndex) {
                    $index = [int]$profileInfo.InterfaceIndex
                    $undoScript += "Set-NetConnectionProfile -InterfaceIndex $index -NetworkCategory $category"
                }
            }
            '## Default_.*: RemoteRegistry\.StartType\s*=\s*(\w+)' {
                $v = $Matches[1]
                $undoScript += "if (Get-Service -Name RemoteRegistry -ErrorAction SilentlyContinue) { Set-Service -Name RemoteRegistry -StartupType $v } else { Write-Warning \"RemoteRegistry service not present for undo.\" }"
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
        $warningMessage = "Secure Mode core hardening steps are not present in this build."
        Add-Content $logPath "!! WARNING: $warningMessage"
        Write-Warning $warningMessage
        [System.Windows.Forms.MessageBox]::Show($warningMessage, "Secure Mode") | Out-Null
    }
    catch {
        Add-Content $logPath "!! ERROR: Secure Mode failed : $_"
        [System.Windows.Forms.MessageBox]::Show("Secure Mode encountered an error. Review log for details.", "Secure Mode") | Out-Null
    }
    finally {
        $completionTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        Add-Content $logPath "=== HoneyBadger Secure Mode Completed @ $completionTimestamp ==="
    }
})
