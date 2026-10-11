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
        if ($localId -ne $cloudId) { throw 'Xbox save has a pending container transition. Launch and close the game to finish synchronization.' }
        [pscustomobject]@{ name = $name; path = Join-Path (Split-Path -Parent $Path) $localId }
    }
}

function Find-DuneSoloXboxProfiles {
    param([Parameter(Mandatory)][string]$DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) { return @() }
    $metadata = @(Get-ChildItem -LiteralPath $DataRoot -Filter 'container.*' -File -Recurse -ErrorAction Stop)
    foreach ($group in ($metadata | Group-Object DirectoryName)) {
        if ($group.Count -ne 1) { throw 'Xbox container has multiple metadata revisions. Launch and close the game before scanning.' }
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
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    $metadata = @(Get-ChildItem -LiteralPath $dir -File -Filter 'container.*' -ErrorAction SilentlyContinue)
    if ($metadata.Count -eq 0) { return $null }
    if ($metadata.Count -ne 1) { throw 'Ambiguous Xbox container metadata.' }
    $games = @(Read-DuneSoloXboxContainer -Path $metadata[0].FullName | Where-Object name -CEQ 'game.db')
    if ($games.Count -ne 1 -or $games[0].path -ine [IO.Path]::GetFullPath($Path)) { throw 'Selected Xbox blob is not the current game.db.' }
    $account = Split-Path -Parent $dir
    if (-not (Test-Path -LiteralPath (Join-Path $account 'containers.index'))) { throw 'Xbox account index is missing.' }
    return @{ account = $account; container = $dir; metadata = $metadata[0].FullName }
}

function Backup-DuneSoloXboxAccount {
    param([Parameter(Mandatory)][hashtable]$Blob)
    Assert-DuneSoloGameClosed
    $destination = Join-Path (Get-DuneSoloBackupRoot) ('xbox-containers\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $files = @(Get-ChildItem -LiteralPath $Blob.account -File -Recurse -ErrorAction Stop)
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
    $after = @(Get-ChildItem -LiteralPath $Blob.account -File -Recurse -ErrorAction Stop)
    if ($after.Count -ne $files.Count) { throw 'Xbox account changed during backup; no save data was written.' }
    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path $Blob.account $entry.path) -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Xbox account changed during backup; no save data was written.' }
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'dst-backup-manifest.json') -Encoding utf8
    return $destination
}
