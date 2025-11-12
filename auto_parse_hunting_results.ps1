<#
.SYNOPSIS
    Generates structured summaries from hunting artefacts.
.DESCRIPTION
    The original placeholder only listed files.  This release adds richer
    analytics including optional SHA256 hashing, per-extension statistics, and a
    Markdown report that can be dropped directly into detection engineering
    notes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'hbv-hunting-summary.json'),

    [switch]$IncludeHashes,

    [switch]$GroupByExtension,

    [string]$MarkdownPath
)

if (-not (Test-Path -Path $InputPath)) {
    throw "Input path '$InputPath' was not found."
}

$files = Get-ChildItem -Path $InputPath -File -Recurse -ErrorAction SilentlyContinue
$items = @()
$totalSize = 0

foreach ($file in $files) {
    $record = [ordered]@{
        Name      = $file.Name
        FullName  = $file.FullName
        Extension = $file.Extension
        SizeBytes = $file.Length
        LastWrite = $file.LastWriteTimeUtc.ToString('o')
    }

    $totalSize += [int64]$file.Length

    if ($IncludeHashes) {
        try {
            $record.SHA256 = (Get-FileHash -Algorithm SHA256 -Path $file.FullName -ErrorAction Stop).Hash
        }
        catch {
            $record.SHA256 = $null
        }
    }

    $items += [PSCustomObject]$record
}

$extensionStats = @()
if ($GroupByExtension) {
    $extensionStats = $items | Group-Object -Property Extension | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Extension      = if ($_.Name) { $_.Name } else { '<none>' }
            Count          = $_.Count
            TotalSizeBytes = ($_.Group | Measure-Object -Property SizeBytes -Sum).Sum
        }
    }
}

$summary = [ordered]@{
    Generated        = (Get-Date).ToString('o')
    Source           = (Resolve-Path -Path $InputPath).Path
    FileCount        = $items.Count
    TotalSizeBytes   = $totalSize
    GroupByExtension = [bool]$GroupByExtension
    Files            = $items
}

if ($GroupByExtension) {
    $summary.ExtensionSummary = $extensionStats
}

$summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputPath -Encoding utf8

if ($MarkdownPath) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# HoneyBadger Hunting Summary")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("*Generated:* $($summary.Generated)")
    [void]$sb.AppendLine("*Source:* $($summary.Source)")
    [void]$sb.AppendLine("*Files:* $($summary.FileCount)")
    [void]$sb.AppendLine("*Total Size (bytes):* $totalSize")
    [void]$sb.AppendLine()

    if ($GroupByExtension -and $extensionStats) {
        [void]$sb.AppendLine('## Files by Extension')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Extension | Count | Size (bytes) |')
        [void]$sb.AppendLine('|-----------|-------|--------------|')
        foreach ($stat in $extensionStats) {
            [void]$sb.AppendLine("| $($stat.Extension) | $($stat.Count) | $($stat.TotalSizeBytes) |")
        }
        [void]$sb.AppendLine()
    }

    [void]$sb.AppendLine('## Files')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Extension | Size (bytes) | Last Write (UTC) | SHA256 |')
    [void]$sb.AppendLine('|------|-----------|--------------|------------------|--------|')
    foreach ($item in $items) {
        $hash = if ($IncludeHashes) { $item.SHA256 } else { '' }
        [void]$sb.AppendLine("| $($item.Name) | $($item.Extension) | $($item.SizeBytes) | $($item.LastWrite) | $hash |")
    }

    $sb.ToString() | Out-File -FilePath $MarkdownPath -Encoding utf8
}

Write-Host "[auto_parse_hunting_results] Summary exported to $OutputPath" -ForegroundColor Yellow
if ($MarkdownPath) {
    Write-Host "[auto_parse_hunting_results] Markdown exported to $MarkdownPath" -ForegroundColor Yellow
}

[PSCustomObject]@{
    OutputPath     = $OutputPath
    MarkdownPath   = $MarkdownPath
    FileCount      = $items.Count
    TotalSizeBytes = $totalSize
    Grouped        = $extensionStats
}
