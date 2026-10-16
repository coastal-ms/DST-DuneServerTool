# WGS file names are GUIDs. Resolve the logical game.db from container metadata,
# never from payload size, modification time, or the prepatch database.
function Get-DuneSoloXboxRoots {
    $packages = Join-Path $env:LOCALAPPDATA 'Packages'
    if (-not (Test-Path -LiteralPath $packages)) { return @() }
    return @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'FuncomOsloAS.ProjectSeabass_*' |
        ForEach-Object { Join-Path $_.FullName 'SystemAppData\wgs' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

function Read-DuneSoloXboxContainer {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8 -or [BitConverter]::ToUInt32($bytes, 0) -ne 4) { throw 'Unsupported Xbox container metadata.' }
    $count = [BitConverter]::ToUInt32($bytes, 4)
    if ($count -gt 4096 -or $bytes.Length -ne (8 + 160 * $count)) { throw 'Invalid Xbox container metadata length.' }
    $names = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $offset = 8 + 160 * $i
        $name = [Text.Encoding]::Unicode.GetString($bytes, $offset, 128).TrimEnd([char]0)
        if (-not $name -or $names.ContainsKey($name)) { throw 'Invalid or duplicate Xbox blob name.' }
        $names[$name] = $true
        $localId = [guid]::new([byte[]]$bytes[($offset + 128)..($offset + 143)]).ToString('N').ToUpperInvariant()
        $cloudId = [guid]::new([byte[]]$bytes[($offset + 144)..($offset + 159)]).ToString('N').ToUpperInvariant()
        # Divergent identities indicate a pending storage transition: do not guess.
        if ($localId -ne $cloudId) { throw 'Xbox save is still updating. Wait 10 seconds, then click Connect and validate again.' }
        [pscustomobject]@{ name = $name; path = Join-Path (Split-Path -Parent $Path) $localId }
    }
}

function Find-DuneSoloXboxProfiles {
    param([Parameter(Mandatory)][string]$DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) { return @() }
    $metadata = @(Get-ChildItem -LiteralPath $DataRoot -Filter 'container.*' -File -Recurse -ErrorAction Stop)
    foreach ($group in ($metadata | Group-Object DirectoryName)) {
        if ($group.Count -ne 1) { throw 'Xbox save is still updating. Wait 10 seconds, then click Connect and validate again.' }
        $file = $group.Group[0]
        $blobs = @(Read-DuneSoloXboxContainer -Path $file.FullName)
        $game = @($blobs | Where-Object name -CEQ 'game.db')
        if ($game.Count -eq 0) { continue }
        if (-not (Test-Path -LiteralPath $game[0].path -PathType Leaf)) { throw 'Xbox game.db blob is missing.' }
        $account = Split-Path -Parent $file.DirectoryName
        if (-not (Test-Path -LiteralPath (Join-Path $account 'containers.index') -PathType Leaf)) { throw 'Xbox account index is missing.' }
        $payload = Get-Item -LiteralPath $game[0].path
        [pscustomobject]@{
            id = ([IO.Path]::GetFileName($account) + ' / ' + $file.Directory.Name)
            channel = 'Xbox'; platform = 'xbox'; adapter = 'solo-retail-v1'; legacy = $false
            dbPath = $payload.FullName; modifiedAt = $payload.LastWriteTimeUtc.ToString('o'); bytes = [long]$payload.Length
            dataRoot = $DataRoot
        }
    }
}

function Get-DuneSoloXboxBlob {
    param([Parameter(Mandatory)][string]$Path, [switch]$ResolveCurrentGame)
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $metadata = @(Get-ChildItem -LiteralPath $dir -File -Filter 'container.*' -ErrorAction SilentlyContinue)
    if ($metadata.Count -eq 0) { return $null }
    if ($metadata.Count -ne 1) { throw 'Ambiguous Xbox container metadata.' }
    $blobs = @(Read-DuneSoloXboxContainer -Path $metadata[0].FullName)
    $games = @($blobs | Where-Object name -CEQ 'game.db')
    if ($games.Count -ne 1) { throw 'Xbox save connection is not ready. Wait for saving or cloud sync to finish, then click Connect and validate.' }
    if ($games[0].path -ine [IO.Path]::GetFullPath($Path)) {
        if (-not $ResolveCurrentGame -or @($blobs | Where-Object path -IEQ ([IO.Path]::GetFullPath($Path))).Count -gt 0 -or [IO.Path]::GetFileName($Path) -notmatch '^[A-Fa-f0-9]{32}$') {
            throw 'Selected Xbox blob is not the current game.db. Wait for Xbox sync to finish, then find saves again and click Connect and validate.'
        }
    }
    $account = Split-Path -Parent $dir
    if (-not (Test-Path -LiteralPath (Join-Path $account 'containers.index'))) { throw 'Xbox account index is missing.' }
    return @{ account = $account; container = $dir; metadata = $metadata[0].FullName; dbPath = $games[0].path }
}

function Backup-DuneSoloXboxAccount {
    param([Parameter(Mandatory)][hashtable]$Blob)
    Assert-DuneSoloGameClosed
    $destination = Join-Path (Get-DuneSoloBackupRoot) ('xbox-containers\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $Blob.account -File -Recurse -Force -ErrorAction Stop)
    $manifest = foreach ($file in $files) {
        $ancestor = $file.FullName
        while ($ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Xbox backup source contains a reparse point.' }
            $parent = Split-Path -Parent $ancestor
            if ($parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        $relative = $file.FullName.Substring($Blob.account.TrimEnd('\').Length + 1)
        $target = Join-Path $destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $before = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        [IO.File]::Copy($file.FullName, $target, $false)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $before -or
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $before) { throw 'Xbox save changed during backup; no save data was written.' }
        [ordered]@{ path = $relative; sha256 = $before }
    }
    $after = @(Get-ChildItem -LiteralPath $Blob.account -File -Recurse -Force -ErrorAction Stop)
    if ($after.Count -ne $files.Count) { throw 'Xbox account changed during backup; no save data was written.' }
    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path $Blob.account $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Xbox account changed during backup; no save data was written.' }
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'dst-backup-manifest.json') -Encoding utf8
    return $destination
}

# The product's Xbox mutation capabilities remain disabled until live acceptance.
# Preparation always mutates a private copy. Commit is used by the separately
# authorized acceptance test and subsequently by the common mutation boundary.
function New-DuneSoloXboxMutation {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][hashtable]$Arguments)
    Assert-DuneSoloGameClosed
    if ($Command -in @('inspect','diagnostics','codex','backup','list-blueprints','export-blueprint')) { throw 'Use the read-only helper for this command.' }
    $source = if ($Command -eq 'restore') { [string]$Arguments.target } else { [string]$Arguments.input }
    $blob = Get-DuneSoloXboxBlob -Path $source
    if (-not $blob) { throw 'Xbox mutation requires the exact current game.db blob.' }
    $index = Join-Path $blob.account 'containers.index'
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $indexHash = (Get-FileHash -LiteralPath $index -Algorithm SHA256).Hash
    $metadataHash = (Get-FileHash -LiteralPath $blob.metadata -Algorithm SHA256).Hash
    $backup = Backup-DuneSoloXboxAccount -Blob $blob
    $work = Join-Path (Get-DuneSoloBackupRoot) ('xbox-staging\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $candidate = Join-Path $work 'game.db'
    [IO.File]::Copy($source, $candidate, $false)
    if ((Get-FileHash -LiteralPath $candidate).Hash -ne $sourceHash) { throw 'Xbox save changed during preparation.' }
    $staged = $Arguments.Clone()
    $staged['safety-backup'] = Join-Path $work 'before.db'
    if ($Command -eq 'restore') { $staged.target = $candidate } else { $staged.input = $candidate }
    $result = Invoke-DuneSoloHelper -Command $Command -Arguments $staged
    $inspection = Invoke-DuneSoloHelper -Command inspect -Arguments @{
        input = $candidate; adapter = Get-DuneSoloDataFilePath -Name 'solo-retail-v1.json'
    }
    if ($inspection.integrity -ne 'ok' -or $inspection.characterCount -ne 1) { throw 'Prepared Xbox save failed integrity or character validation.' }
    $prepared = @{
        source = $source; sourceSha256 = $sourceHash; candidate = $candidate
        candidateSha256 = (Get-FileHash -LiteralPath $candidate).Hash
        index = $index; indexSha256 = $indexHash; metadata = $blob.metadata; metadataSha256 = $metadataHash
        backup = $backup; result = $result; inspection = $inspection
    }
    $prepared | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $work 'prepared.json') -Encoding utf8
    return $prepared
}

function Commit-DuneSoloXboxMutation {
    param([Parameter(Mandatory)][hashtable]$Prepared)
    Assert-DuneSoloGameClosed
    $blob = Get-DuneSoloXboxBlob -Path $Prepared.source
    if (-not $blob -or $blob.metadata -ine $Prepared.metadata -or (Join-Path $blob.account 'containers.index') -ine $Prepared.index) { throw 'Xbox save identity changed; nothing was written.' }
    foreach ($pair in @(@('source','sourceSha256'), @('candidate','candidateSha256'), @('index','indexSha256'), @('metadata','metadataSha256'))) {
        if ((Get-FileHash -LiteralPath $Prepared[$pair[0]] -Algorithm SHA256).Hash -ne $Prepared[$pair[1]]) { throw 'Xbox save or prepared data changed; nothing was written.' }
    }
    $temp = Join-Path $blob.container ('dst-write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $previous = "$temp.previous"
    $replaced = $false
    try {
        [IO.File]::Copy($Prepared.candidate, $temp, $false)
        Assert-DuneSoloGameClosed
        # Check immediately before replacement, after staging the bytes.
        foreach ($pair in @(@('source','sourceSha256'), @('index','indexSha256'), @('metadata','metadataSha256'))) {
            if ((Get-FileHash -LiteralPath $Prepared[$pair[0]]).Hash -ne $Prepared[$pair[1]]) { throw 'Xbox save changed before replacement; nothing was written.' }
        }
        [IO.File]::Replace($temp, $Prepared.source, $previous)
        $replaced = $true
        if ((Get-FileHash -LiteralPath $Prepared.source).Hash -ne $Prepared.candidateSha256) { throw 'Xbox replacement verification failed.' }
        return @{ ok = $true; path = $Prepared.source; containerBackup = $Prepared.backup; inspection = $Prepared.inspection }
    } catch {
        if ($replaced -and (Test-Path -LiteralPath $previous)) { [IO.File]::Replace($previous, $Prepared.source, $null) }
        throw
    } finally {
        foreach ($file in @($temp, $previous)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
    }
}
