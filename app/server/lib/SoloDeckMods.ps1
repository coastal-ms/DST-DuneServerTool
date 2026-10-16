function Get-DuneDeckBytesHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-DuneSoloDeckModBundle {
    param([Parameter(Mandatory)]$Status, [Parameter(Mandatory)][string]$Output)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.IO.Compression.FileSystem, System.IO.Compression
    Assert-DuneSoloGameClosed
    $selected = @($Status.mods | Where-Object enabled)
    if (-not $selected.Count -or @($selected | Where-Object { @($_.errors).Count }).Count) { throw 'Resolve the enabled mod selection in Solo mods before syncing.' }
    $profiles = @(Get-DuneSoloRuntimeProfiles | Where-Object version -eq $Status.runtimeVersion)
    if ($profiles.Count -ne 1) { throw 'Select a supported Solo runtime before syncing.' }
    $profile = $profiles[0]
    $runtime = Join-Path $script:DuneSoloRuntimeAssets $profile.archive
    $configs = Join-Path $script:DuneSoloRuntimeAssets 'configs.zip'
    if ((Get-FileHash -LiteralPath $runtime).Hash -ine $profile.hash -or
        (Get-FileHash -LiteralPath $configs).Hash -ine '1B2420B7DEB237CD680D27306EADF26628699D992A322C89A963D80F580C9B78') { throw 'Bundled mod runtime verification failed. Repair DST.' }
    $contents = @{}
    $expandedBytes = 0L
    foreach ($source in @($runtime,$configs)) {
        $archive = [IO.Compression.ZipFile]::OpenRead($source)
        try {
            foreach ($entry in $archive.Entries) {
                if (-not $entry.Name) { continue }
                $name = $entry.FullName.Replace('\','/')
                if ($source -eq $runtime) {
                    if ($name.StartsWith('ue4ss/Mods/')) { continue }
                    $target = 'runtime/' + $name
                } else {
                    if (-not $name.StartsWith('DuneAwakening/') -or -not $name.EndsWith('.ini')) { continue }
                    $target = 'runtime/ue4ss/' + $entry.Name
                }
                if ($target -match '(^|/)\.\.?(/|$)|[:\\]' -or $entry.Length -gt 128MB) { throw 'Unsupported runtime archive entry.' }
                $stream=$entry.Open(); $memory=New-Object IO.MemoryStream
                try { $stream.CopyTo($memory);$contents[$target]=$memory.ToArray() }
                finally { $stream.Dispose();$memory.Dispose() }
            }
        } finally { $archive.Dispose() }
    }
    foreach ($mod in $selected) {
        if ($mod.folder -notmatch '^[A-Za-z0-9][A-Za-z0-9_. -]{0,100}$') { throw 'Unsupported mod folder.' }
        $folder = Join-Path $Status.folder $mod.folder
        foreach ($item in @((Get-Item -LiteralPath $folder -Force)) + @(Get-ChildItem -LiteralPath $folder -Recurse -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked mod folders and files cannot be synced.' }
            if ($item.PSIsContainer -or $item.Extension -in @('.log','.dmp','.tmp')) { continue }
            if ($item.Length -gt 128MB) { throw 'A mod file exceeds the transfer limit.' }
            $length=$item.Length;$modified=$item.LastWriteTimeUtc.Ticks
            $raw=[IO.File]::ReadAllBytes($item.FullName)
            $current=Get-Item -LiteralPath $item.FullName -Force
            if ($length -ne $current.Length -or $modified -ne $current.LastWriteTimeUtc.Ticks) { throw 'A PC mod file changed while preparing sync. Refresh the preview.' }
            $relative=$item.FullName.Substring($folder.TrimEnd('\','/').Length+1).Replace('\','/')
            $contents['Mods/'+$mod.folder+'/'+$relative]=$raw
            $expandedBytes += $raw.Length
            if ($expandedBytes -gt 1GB) { throw 'The enabled mods exceed the transfer limit.' }
        }
    }
    Assert-DuneSoloLaunchArguments ([string]$Status.soloArguments)
    # Parse the common quoted-token form without invoking a shell or expanding
    # variables. Unsupported quoting is rejected instead of changing arguments.
    $extra = [string]$Status.soloArguments
    if ($extra -match '\\"') { throw 'Escaped quotes in Solo arguments are not supported by Deck launch. Use plain quoted values.' }
    if ($extra.Contains('"') -and (($extra.ToCharArray() | Where-Object { $_ -eq '"' }).Count % 2)) { throw 'Close the quote in Solo launch arguments before syncing.' }
    $options = @('-nobattleye')
    if ($Status.skipIntro) { $options += @('-nosplash','-nostartupscreen') }
    foreach ($match in [regex]::Matches($extra,'(?:[^\s"]+|"[^"]*")+')) {
        $arg=$match.Value.Replace('"','')
        if ($arg -in @('-battleye','-usebattleye')) { throw 'Modded Solo cannot request BattlEye.' }
        if ($arg -ne '-nobattleye') { $options += $arg }
    }
    $hashes = [ordered]@{}
    [string[]]$names=@($contents.Keys);[Array]::Sort($names,[StringComparer]::Ordinal)
    foreach ($name in $names) { $hashes[$name]=Get-DuneDeckBytesHash $contents[$name] }
    $manifest = [ordered]@{protocol=1;runtimeVersion=[string]$profile.version;enabled=@($selected.folder)
        mods=@($selected | ForEach-Object {[ordered]@{folder=$_.folder;name=$_.name;version=$_.version}})
        launchOptions=$options;files=$hashes}
    $temp=$Output+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $archive=[IO.Compression.ZipFile]::Open($temp,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries=@($names)+@('manifest.json')
            foreach($name in $entries) {
                $entry=$archive.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                if($name -eq 'manifest.json') { $raw=[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 12 -Compress)) }
                else { $raw=$contents[$name] }
                $stream=$entry.Open();try{$stream.Write($raw,0,$raw.Length)}finally{$stream.Dispose()}
            }
        } finally {$archive.Dispose()}
        $bytes=(Get-Item -LiteralPath $temp).Length
        if($bytes -gt 128MB){throw 'The mod package exceeds the transfer limit.'}
        $hash=(Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
        Move-Item -LiteralPath $temp -Destination $Output -Force
        return @{sha256=$hash;bytes=$bytes;mods=$manifest.mods;enabled=$manifest.enabled;runtimeVersion=$profile.version}
    } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}

function Invoke-DuneSoloDeckModsPreview {
    $state=Get-DuneSoloDeckStatus
    if(-not $state.connected){throw 'Connect the Deck before syncing mods.'}
    if(@($state.report.game_processes).Count){throw 'Close Dune on the Deck before syncing mods.'}
    if('mods-sync-v1' -notin @($state.report.mod_capabilities)){throw 'Update and run the Deck Companion before syncing mods.'}
    $null=Start-DuneSoloDeckBridge
    $root=Get-DuneSoloDeckConnectionRoot
    $metadata=New-DuneSoloDeckModBundle -Status (Get-DuneSoloMods) -Output (Join-Path $root 'mods-bundle.zip')
    [IO.File]::WriteAllText((Join-Path $root 'mods-bundle.json'),($metadata|ConvertTo-Json -Depth 12 -Compress),(New-Object Text.UTF8Encoding($false)))
    $token=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $record=@{token=$token;expires=[DateTime]::UtcNow.AddMinutes(10).ToString('o');sha256=$metadata.sha256
        connectionHash=(Get-FileHash -LiteralPath (Join-Path $root 'connection.json')).Hash}
    [IO.File]::WriteAllText((Join-Path $root 'mods-preview.json'),($record|ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
    return @{ok=$true;token=$token;mods=$metadata.mods;runtimeVersion=$metadata.runtimeVersion;bytes=$metadata.bytes}
}

function Invoke-DuneSoloDeckModsApply {
    param([string]$Token,$Confirmed)
    if($Confirmed -isnot [bool] -or -not $Confirmed){throw 'Approve the mod sync preview.'}
    Assert-DuneSoloGameClosed
    $root=Get-DuneSoloDeckConnectionRoot
    $pending=Join-Path $root 'mods-preview.json'
    if(-not(Test-Path -LiteralPath $pending)){throw 'Prepare a fresh mod sync preview.'}
    $record=Get-Content -LiteralPath $pending -Raw|ConvertFrom-Json
    if($Token -cne $record.token -or [DateTime]::Parse($record.expires).ToUniversalTime() -lt [DateTime]::UtcNow -or
        (Get-FileHash -LiteralPath (Join-Path $root 'connection.json')).Hash -cne $record.connectionHash){throw 'Mod preview expired or pairing changed. Preview again.'}
    $metadata=New-DuneSoloDeckModBundle -Status (Get-DuneSoloMods) -Output (Join-Path $root 'mods-check.zip')
    try {if($metadata.sha256 -cne $record.sha256){throw 'PC mod files or selection changed. Prepare a fresh preview.'}}
    finally {Remove-Item -LiteralPath (Join-Path $root 'mods-check.zip') -Force -ErrorAction SilentlyContinue}
    $null=Start-DuneSoloDeckBridge
    $connection=Get-Content -LiteralPath (Join-Path $root 'connection.json') -Raw|ConvertFrom-Json
    # The local source address of SSH identifies the paired PC to the helper.
    # It was persisted by the authenticated companion pairing callback.
    if(-not $connection.pcAddress){throw 'Pair the updated companion with this PC before syncing mods.'}
    $request=@{action='sync-mods';url=('https://'+$connection.pcAddress+':18749/mods');sha256=$record.sha256}
    Remove-Item -LiteralPath $pending -Force
    return Invoke-DuneSoloDeckReader -Root $root -Connection $connection -Command 'dst-mods-v1' -Request $request
}
