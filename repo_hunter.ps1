<#
.SYNOPSIS
    Maintains a curated list of offensive and defensive security repositories.
.DESCRIPTION
    The previous placeholder only wrote repository URLs to disk.  This update
    can optionally clone/update the repositories when git is available while
    still emitting a deterministic JSON snapshot for downstream tooling.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'hbv-repo-snapshot.json'),

    [string]$CloneRoot,

    [switch]$Update,

    [string[]]$Repositories
)

if (-not $Repositories) {
    $Repositories = @(
        'https://github.com/redcanaryco/atomic-red-team',
        'https://github.com/Yara-Rules/rules',
        'https://github.com/volatilityfoundation/volatility3'
    )
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($CloneRoot -and -not $git) {
    Write-Warning 'git executable not found. Clone operations will be skipped.'
}
$cloneResults = @()

if ($CloneRoot) {
    if (-not (Test-Path -Path $CloneRoot)) {
        New-Item -ItemType Directory -Path $CloneRoot -Force | Out-Null
    }
    $CloneRoot = (Resolve-Path -Path $CloneRoot).Path
}

foreach ($repo in $Repositories) {
    $name = [IO.Path]::GetFileNameWithoutExtension($repo)
    $record = [ordered]@{
        Name      = $name
        Url       = $repo
        Action    = 'listed'
        LocalPath = $null
    }

    if ($CloneRoot -and $git) {
        $target = Join-Path -Path $CloneRoot -ChildPath $name
        $record.LocalPath = $target
        if (-not (Test-Path -Path $target)) {
            Write-Host "[repo_hunter] Cloning $repo" -ForegroundColor Green
            try {
                & $git.Source -C $CloneRoot clone $repo $name | Out-Null
                $record.Action = 'cloned'
            }
            catch {
                Write-Warning "Failed to clone $repo : $_"
                $record.Action = 'clone_failed'
            }
        }
        elseif ($Update) {
            Write-Host "[repo_hunter] Updating $repo" -ForegroundColor Green
            try {
                & $git.Source -C $target pull --ff-only | Out-Null
                $record.Action = 'updated'
            }
            catch {
                Write-Warning "Failed to update $repo : $_"
                $record.Action = 'update_failed'
            }
        }
        else {
            $record.Action = 'present'
        }
    }

    $cloneResults += [PSCustomObject]$record
}

$snapshot = [ordered]@{
    Generated = (Get-Date).ToString('o')
    Items     = $cloneResults
}

$snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutputPath -Encoding utf8
Write-Host "[repo_hunter] Snapshot exported to $OutputPath" -ForegroundColor Green

[PSCustomObject]@{
    OutputPath = $OutputPath
    Items      = $cloneResults
    CloneRoot  = $CloneRoot
}
