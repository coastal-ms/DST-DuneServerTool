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

function Get-DuneVersionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)

    $value = $Version.Trim()
    $identifier = '(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
    $pattern = "^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-(?<pre>$identifier(?:\.$identifier)*))?$"
    $match = [regex]::Match($value, $pattern)
    if (-not $match.Success) {
        throw "Version must be a SemVer-compatible release version without build metadata (got '$Version')."
    }

    $core = "$($match.Groups['major'].Value).$($match.Groups['minor'].Value).$($match.Groups['patch'].Value)"
    return [pscustomobject]@{
        Version = $value
        CoreVersion = $core
        NumericVersion = "$core.0"
        IsPrerelease = $match.Groups['pre'].Success
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

function Test-DunePrereleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildTag)

    $tag = $BuildTag.Trim()
    $version = if ($tag.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $tag.Substring(1)
    } else {
        $tag
    }
    return [bool](Get-DuneVersionInfo -Version $version).IsPrerelease
}

function Assert-DuneTagPrereleaseConsistency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildTag,
        [switch]$Prerelease
    )

    $tag = $BuildTag.Trim()
    try {
        $tagIsPrerelease = Test-DunePrereleaseTag -BuildTag $tag
    } catch {
        throw 'BuildTag must be a release tag such as v15.0.0 or v15.0.0-test9.'
    }
    if ($tagIsPrerelease -and -not $Prerelease) {
        throw "Prerelease tag $tag requires -Prerelease."
    }
    if (-not $tagIsPrerelease -and $Prerelease) {
        throw "Stable tag $tag must not use -Prerelease."
    }
}

function Get-DuneReleaseTagsAtCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Commit
    )

    $output = @(& git -C $RepoRoot tag --points-at $Commit 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect release tags at commit $Commit."
    }
    return @($output |
        ForEach-Object { "$_".Trim() } |
        Where-Object {
            try {
                $null = Test-DunePrereleaseTag -BuildTag $_
                $true
            } catch {
                $false
            }
        } |
        Sort-Object -Unique)
}

function Resolve-DuneBuildIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$BuildCommit = '',
        [string]$BuildTag = '',
        [switch]$Prerelease,
        [switch]$BuildCommitSpecified
    )

    $headCommit = "$(& git -C $RepoRoot rev-parse HEAD 2>$null)".Trim().ToLowerInvariant()
    if ($LASTEXITCODE -ne 0 -or $headCommit -notmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve checkout HEAD to a full Git commit id.'
    }

    $tag = $BuildTag.Trim()
    if (-not $tag) {
        $headTags = @(Get-DuneReleaseTagsAtCommit -RepoRoot $RepoRoot -Commit $headCommit)
        if ($headTags.Count -gt 0) {
            $tagList = $headTags -join ', '
            $exampleTag = $headTags[0]
            $prereleaseArg = if (Test-DunePrereleaseTag -BuildTag $exampleTag) { '-Prerelease ' } else { '' }
            $example = "& '.\app\installer\Build-Installer.ps1' $prereleaseArg-BuildCommit $headCommit -BuildTag $exampleTag"
            if ($headTags.Count -gt 1) {
                throw "Checkout HEAD $headCommit has multiple release tags ($tagList), but -BuildTag was omitted. Refusing an ambiguous manual build. Specify the intended immutable tag and commit explicitly, for example: $example"
            }
            throw "Checkout HEAD $headCommit already has release tag $exampleTag, but -BuildTag was omitted. Refusing to embed '(manual)' identity. Run: $example"
        }
        $commit = if ($BuildCommitSpecified) { $BuildCommit.Trim().ToLowerInvariant() } else { $headCommit }
        if ($commit -and $commit -notmatch '^[0-9a-f]{7,40}$') {
            throw 'BuildCommit must be a 7-40 character hexadecimal Git commit id.'
        }
        return [pscustomobject]@{
            Commit = $commit
            Tag = ''
            Prerelease = [bool]$Prerelease
            HeadCommit = $headCommit
        }
    }

    Assert-DuneTagPrereleaseConsistency -BuildTag $tag -Prerelease:$Prerelease
    if (-not $BuildCommitSpecified) {
        throw "Tagged build $tag requires an explicit full -BuildCommit."
    }
    $commit = $BuildCommit.Trim().ToLowerInvariant()
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        throw "Tagged build $tag requires a full 40-character BuildCommit."
    }

    $tagCommit = Get-DuneExistingTagCommit -RepoRoot $RepoRoot -BuildTag $tag
    if (-not $tagCommit) {
        throw "Tagged build $tag requires an existing immutable Git tag."
    }
    if ($headCommit -ne $tagCommit) {
        throw "Existing release tag $tag resolves to $tagCommit, but checkout HEAD is $headCommit. Check out the exact tag before rebuilding its installer."
    }
    if ($commit -ne $tagCommit) {
        throw "BuildCommit $commit does not match existing release tag $tag at $tagCommit."
    }

    return [pscustomobject]@{
        Commit = $tagCommit
        Tag = $tag
        Prerelease = [bool]$Prerelease
        HeadCommit = $headCommit
    }
}

function Get-DuneExecutableBuildMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $path = [IO.Path]::GetFullPath($ExecutablePath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "DuneServer executable was not found: $path"
    }

    $assembly = [Reflection.Assembly]::LoadFile($path)
    $resourceNames = @($assembly.GetManifestResourceNames() | Where-Object {
        $_ -match '^DuneServer(?:\.[0-9a-f]{32})?\.generated\.ps1$'
    })
    if ($resourceNames.Count -ne 1) {
        throw "DuneServer executable has $($resourceNames.Count) recognized embedded script resources."
    }

    $stream = $assembly.GetManifestResourceStream($resourceNames[0])
    if (-not $stream) {
        throw 'DuneServer executable has no readable embedded script resource.'
    }
    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }

    $presentMatch = [regex]::Match($text, '(?m)^\$script:DuneBuildMetadataPresent\s*=\s*\$true\s*$')
    $commitMatch = [regex]::Match($text, "(?m)^\`$script:DuneBuildCommit\s*=\s*'([^']*)'\s*$")
    $prereleaseMatch = [regex]::Match($text, '(?m)^\$script:DuneBuildPrerelease\s*=\s*\$(true|false)\s*$')
    $tagMatch = [regex]::Match($text, "(?m)^\`$script:DuneBuildTag\s*=\s*'([^']*)'\s*$")
    return [pscustomobject]@{
        present = $presentMatch.Success
        valid = $presentMatch.Success -and $commitMatch.Success -and $prereleaseMatch.Success -and $tagMatch.Success
        commit = if ($commitMatch.Success) { $commitMatch.Groups[1].Value.Trim().ToLowerInvariant() } else { '' }
        prerelease = $prereleaseMatch.Success -and $prereleaseMatch.Groups[1].Value -eq 'true'
        tag = if ($tagMatch.Success) { $tagMatch.Groups[1].Value.Trim() } else { '' }
        resource = $resourceNames[0]
    }
}

function Assert-DuneBuildMetadataMatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedTag,
        [Parameter(Mandatory)][string]$ExpectedCommit,
        [switch]$ExpectedPrerelease
    )

    $tag = $ExpectedTag.Trim()
    $commit = $ExpectedCommit.Trim().ToLowerInvariant()
    if ($tag) {
        Assert-DuneTagPrereleaseConsistency -BuildTag $tag -Prerelease:$ExpectedPrerelease
    }
    $commitPattern = if ($tag) { '^[0-9a-f]{40}$' } else { '^[0-9a-f]{7,40}$' }
    if ($commit -notmatch $commitPattern) {
        throw $(if ($tag) {
            'ExpectedCommit must be a full 40-character Git commit id for a release build.'
        } else {
            'ExpectedCommit must be a 7-40 character hexadecimal Git commit id.'
        })
    }

    $matches = [bool]$Metadata.present -and [bool]$Metadata.valid -and
        ([string]$Metadata.tag -ceq $tag) -and
        ([string]$Metadata.commit -ceq $commit) -and
        ([bool]$Metadata.prerelease -eq [bool]$ExpectedPrerelease)
    if (-not $matches) {
        $actual = "tag='$([string]$Metadata.tag)', commit='$([string]$Metadata.commit)', prerelease=$([bool]$Metadata.prerelease), present=$([bool]$Metadata.present), valid=$([bool]$Metadata.valid)"
        throw "Built DuneServer.exe identity mismatch. Expected tag='$tag', commit='$commit', prerelease=$([bool]$ExpectedPrerelease); found $actual."
    }
    return $Metadata
}
