function Publish-DuneBuildArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $temporary = [IO.Path]::GetFullPath($TemporaryPath)
    $destination = [IO.Path]::GetFullPath($DestinationPath)
    if ($temporary -eq $destination) {
        throw 'Temporary and destination build paths must be different.'
    }
    if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) {
        throw "Compiled artifact was not produced: $temporary"
    }

    $destinationDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    $backup = "$destination.$([guid]::NewGuid().ToString('N')).previous"
    $published = $false
    try {
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            # Replace the directory entry instead of overwriting its file record.
            # This breaks any accidental NTFS hardlink to an installed executable.
            [IO.File]::Replace($temporary, $destination, $backup, $true)
        } else {
            [IO.File]::Move($temporary, $destination)
        }
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
            (Test-Path -LiteralPath $temporary)) {
            throw "Compiled artifact publication failed: $destination"
        }
        $published = $true
    } finally {
        if ($published -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
            Remove-Item -LiteralPath $backup -Force
        }
    }
}

function Get-DuneExistingTagCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BuildTag
    )

    $output = & git -C $RepoRoot rev-parse --verify --quiet "refs/tags/$BuildTag^{commit}" 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { return '' }
    $commit = "$output".Trim().ToLowerInvariant()
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "Existing release tag $BuildTag returned an invalid commit id."
    }
    return $commit
}
