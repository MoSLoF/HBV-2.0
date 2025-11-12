<#
.SYNOPSIS
    Minimal but functional BOF hunting orchestrator.
.DESCRIPTION
    The historical GUI exposed controls for running Volatility against a memory
    image and triaging dumps with YARA.  The open-source release only shipped a
    placeholder window.  This script restores a practical interface capable of:
      • Selecting a memory image, Volatility executable, and YARA binary.
      • Running a chosen Volatility plugin (default: windows.malfind) with an
        optional dump directory.
      • Scanning Volatility artefacts with recursive YARA rules.
      • Capturing command output inside the GUI for quick review.

    While lightweight, the form provides enough structure for analysts to plug
    in their existing tooling and verify workflows in lab environments.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Select-FilePath {
    param(
        [string]$Title,
        [string]$Filter = 'All files (*.*)|*.*'
    )

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
}

function Select-FolderPath {
    param([string]$Description = 'Select folder')
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.SelectedPath
    }
    return $null
}

function Append-Log {
    param(
        [System.Windows.Forms.TextBox]$Control,
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($Control.Text)) {
        $Control.AppendText([Environment]::NewLine)
    }
    $Control.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $Message")
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HBV BOF Hunter'
$form.Size = New-Object System.Drawing.Size(640, 520)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Font = $font

$labels = @(
    @{ Text = 'Memory Image';        Location = [System.Drawing.Point]::new(20, 20) },
    @{ Text = 'Volatility Executable'; Location = [System.Drawing.Point]::new(20, 80) },
    @{ Text = 'Volatility Plugin';     Location = [System.Drawing.Point]::new(20, 140) },
    @{ Text = 'Dump Directory';        Location = [System.Drawing.Point]::new(320, 140) },
    @{ Text = 'YARA Executable';       Location = [System.Drawing.Point]::new(20, 200) },
    @{ Text = 'YARA Rules Folder';     Location = [System.Drawing.Point]::new(320, 200) }
)

foreach ($labelInfo in $labels) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labelInfo.Text
    $label.Location = $labelInfo.Location
    $label.AutoSize = $true
    $form.Controls.Add($label)
}

$memoryBox = New-Object System.Windows.Forms.TextBox
$memoryBox.Size = New-Object System.Drawing.Size(460, 24)
$memoryBox.Location = New-Object System.Drawing.Point(20, 40)
$form.Controls.Add($memoryBox)

$memoryBrowse = New-Object System.Windows.Forms.Button
$memoryBrowse.Text = 'Browse'
$memoryBrowse.Location = New-Object System.Drawing.Point(500, 38)
$memoryBrowse.Size = New-Object System.Drawing.Size(100, 28)
$memoryBrowse.Add_Click({
    $path = Select-FilePath -Title 'Select memory image'
    if ($path) { $memoryBox.Text = $path }
})
$form.Controls.Add($memoryBrowse)

$volatilityBox = New-Object System.Windows.Forms.TextBox
$volatilityBox.Size = New-Object System.Drawing.Size(460, 24)
$volatilityBox.Location = New-Object System.Drawing.Point(20, 100)
$form.Controls.Add($volatilityBox)

$volBrowse = New-Object System.Windows.Forms.Button
$volBrowse.Text = 'Browse'
$volBrowse.Location = New-Object System.Drawing.Point(500, 98)
$volBrowse.Size = New-Object System.Drawing.Size(100, 28)
$volBrowse.Add_Click({
    $path = Select-FilePath -Title 'Select volatility executable' -Filter 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    if ($path) { $volatilityBox.Text = $path }
})
$form.Controls.Add($volBrowse)

$pluginBox = New-Object System.Windows.Forms.ComboBox
$pluginBox.DropDownStyle = 'DropDownList'
$pluginBox.Items.AddRange(@('windows.malfind', 'windows.pslist', 'windows.psscan', 'windows.memdump'))
$pluginBox.SelectedIndex = 0
$pluginBox.Location = New-Object System.Drawing.Point(20, 160)
$pluginBox.Size = New-Object System.Drawing.Size(180, 24)
$form.Controls.Add($pluginBox)

$dumpBox = New-Object System.Windows.Forms.TextBox
$dumpBox.Size = New-Object System.Drawing.Size(220, 24)
$dumpBox.Location = New-Object System.Drawing.Point(320, 160)
$form.Controls.Add($dumpBox)

$dumpBrowse = New-Object System.Windows.Forms.Button
$dumpBrowse.Text = 'Browse'
$dumpBrowse.Location = New-Object System.Drawing.Point(550, 158)
$dumpBrowse.Size = New-Object System.Drawing.Size(50, 28)
$dumpBrowse.Add_Click({
    $folder = Select-FolderPath -Description 'Select dump output folder'
    if ($folder) { $dumpBox.Text = $folder }
})
$form.Controls.Add($dumpBrowse)

$yaraBox = New-Object System.Windows.Forms.TextBox
$yaraBox.Size = New-Object System.Drawing.Size(220, 24)
$yaraBox.Location = New-Object System.Drawing.Point(20, 220)
$form.Controls.Add($yaraBox)

$yaraBrowse = New-Object System.Windows.Forms.Button
$yaraBrowse.Text = 'Browse'
$yaraBrowse.Location = New-Object System.Drawing.Point(250, 218)
$yaraBrowse.Size = New-Object System.Drawing.Size(50, 28)
$yaraBrowse.Add_Click({
    $path = Select-FilePath -Title 'Select YARA executable' -Filter 'Executable (*.exe)|*.exe|All files (*.*)|*.*'
    if ($path) { $yaraBox.Text = $path }
})
$form.Controls.Add($yaraBrowse)

$ruleBox = New-Object System.Windows.Forms.TextBox
$ruleBox.Size = New-Object System.Drawing.Size(220, 24)
$ruleBox.Location = New-Object System.Drawing.Point(320, 220)
$form.Controls.Add($ruleBox)

$ruleBrowse = New-Object System.Windows.Forms.Button
$ruleBrowse.Text = 'Browse'
$ruleBrowse.Location = New-Object System.Drawing.Point(550, 218)
$ruleBrowse.Size = New-Object System.Drawing.Size(50, 28)
$ruleBrowse.Add_Click({
    $folder = Select-FolderPath -Description 'Select YARA rules folder'
    if ($folder) { $ruleBox.Text = $folder }
})
$form.Controls.Add($ruleBrowse)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = 'Run Output'
$outputLabel.Location = New-Object System.Drawing.Point(20, 260)
$outputLabel.AutoSize = $true
$form.Controls.Add($outputLabel)

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ScrollBars = 'Vertical'
$outputBox.Location = New-Object System.Drawing.Point(20, 280)
$outputBox.Size = New-Object System.Drawing.Size(580, 180)
$outputBox.ReadOnly = $true
$form.Controls.Add($outputBox)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = 'Run Hunt'
$runButton.Location = New-Object System.Drawing.Point(20, 470)
$runButton.Size = New-Object System.Drawing.Size(120, 30)
$form.Controls.Add($runButton)

$openDumpButton = New-Object System.Windows.Forms.Button
$openDumpButton.Text = 'Open Dump Folder'
$openDumpButton.Location = New-Object System.Drawing.Point(160, 470)
$openDumpButton.Size = New-Object System.Drawing.Size(160, 30)
$openDumpButton.Add_Click({
    if (Test-Path $dumpBox.Text) {
        Start-Process explorer.exe $dumpBox.Text
    }
    else {
        [System.Windows.Forms.MessageBox]::Show('Dump folder not found.', 'HBV BOF Hunter') | Out-Null
    }
})
$form.Controls.Add($openDumpButton)

function Run-VolatilityHunt {
    param(
        [string]$MemoryPath,
        [string]$VolatilityPath,
        [string]$Plugin,
        [string]$DumpDirectory,
        [string]$YaraPath,
        [string]$YaraRules,
        [System.Windows.Forms.TextBox]$LogControl
    )

    if (-not (Test-Path $MemoryPath)) {
        Append-Log -Control $LogControl -Message 'Memory image not found. Aborting.'
        return
    }

    if ($DumpDirectory) {
        if (-not (Test-Path -Path $DumpDirectory)) {
            New-Item -ItemType Directory -Path $DumpDirectory -Force | Out-Null
            Append-Log -Control $LogControl -Message "Created dump directory $DumpDirectory"
        }
    }

    if ($VolatilityPath) {
        if (-not (Test-Path $VolatilityPath)) {
            Append-Log -Control $LogControl -Message 'Volatility executable not found. Skipping memory scan.'
        }
        else {
            Append-Log -Control $LogControl -Message "Running Volatility ($Plugin)..."
            $volArgs = @('-f', $MemoryPath, $Plugin)
            if ($DumpDirectory) {
                $volArgs += '--dump-dir'
                $volArgs += $DumpDirectory
            }

            $output = & $VolatilityPath @volArgs 2>&1
            if ($output) {
                Append-Log -Control $LogControl -Message ($output -join [Environment]::NewLine)
            }
            Append-Log -Control $LogControl -Message "Volatility exit code: $LASTEXITCODE"
        }
    }
    else {
        Append-Log -Control $LogControl -Message 'Volatility path not provided. Skipping.'
    }

    if ($YaraPath -and $YaraRules) {
        if (-not (Test-Path $YaraPath)) {
            Append-Log -Control $LogControl -Message 'YARA executable not found. Skipping YARA scan.'
        }
        elseif (-not (Test-Path $YaraRules)) {
            Append-Log -Control $LogControl -Message 'YARA rules folder not found.'
        }
        else {
            $scanTarget = if ($DumpDirectory -and (Test-Path $DumpDirectory)) { $DumpDirectory } else { Split-Path -Parent $MemoryPath }
            Append-Log -Control $LogControl -Message "Running YARA against $scanTarget"
            $yaraArgs = @('-r', $YaraRules, $scanTarget)
            $yaraOutput = & $YaraPath @yaraArgs 2>&1
            if ($yaraOutput) {
                Append-Log -Control $LogControl -Message ($yaraOutput -join [Environment]::NewLine)
            }
            Append-Log -Control $LogControl -Message "YARA exit code: $LASTEXITCODE"
        }
    }
    else {
        Append-Log -Control $LogControl -Message 'YARA stage skipped (executable or rules not supplied).'
    }
}

$runButton.Add_Click({
    $runButton.Enabled = $false
    $outputBox.Clear()
    try {
        Run-VolatilityHunt -MemoryPath $memoryBox.Text -VolatilityPath $volatilityBox.Text -Plugin $pluginBox.SelectedItem -DumpDirectory $dumpBox.Text -YaraPath $yaraBox.Text -YaraRules $ruleBox.Text -LogControl $outputBox
        Append-Log -Control $outputBox -Message 'Hunt completed.'
    }
    catch {
        Append-Log -Control $outputBox -Message "Error: $_"
    }
    finally {
        $runButton.Enabled = $true
    }
})

[void]$form.ShowDialog()
