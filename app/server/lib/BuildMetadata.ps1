# Immutable metadata embedded by Build-Exe.ps1 in the compiled entrypoint.

function Get-DuneBuildMetadata {
    $default = @{ commit = ''; prerelease = $false; tag = ''; present = $false }
    try {
        if (-not [bool]$script:DuneBuildMetadataPresent) { return $default }
        $commit = ([string]$script:DuneBuildCommit).Trim().ToLowerInvariant()
        if ($commit -notmatch '^[0-9a-f]{7,40}$') { $commit = '' }
        $tag = ([string]$script:DuneBuildTag).Trim()
        if ($tag -and $tag -notmatch '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { $tag = '' }
        return @{ commit = $commit; prerelease = ([bool]$script:DuneBuildPrerelease); tag = $tag; present = $true }
    } catch {
        return $default
    }
}
