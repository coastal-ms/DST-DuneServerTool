# Requests are local, character-bound and durable. This path never writes game.db.
function Get-DuneSoloNativeGrantRoot {
    param([string]$ProfileToken)
    if ($ProfileToken -cnotmatch '^[a-f0-9]{64}$') { throw 'Connect and validate a Solo profile first.' }
    $root = Join-Path $script:DuneSoloLoaderRoot "NativeGrants\$ProfileToken"
    foreach ($path in @($script:DuneSoloLoaderRoot, (Split-Path $root -Parent), $root)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Solo grant folders cannot be linked directories.' }
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Write-DuneSoloGrantFile([string]$Path, [string]$Value) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Solo grant files cannot be linked files.' }
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $Value, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
}

function Read-DuneSoloGrantFile([string]$Path, [int]$Limit=262144) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -gt $Limit -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid Solo grant file.' }
    return [IO.File]::ReadAllText($Path)
}

function Initialize-DuneSoloNativeGrantContext {
    Assert-DuneSoloGameClosed
    $profile = Get-DuneSoloProfile
    if (-not $profile.dbPath) { return $null }
    $token = Get-DuneSoloProfileToken -DbPath $profile.dbPath
    $root = Get-DuneSoloNativeGrantRoot $token
    $identity = Invoke-DuneSoloHelper -Command 'native-grant-identity' -Arguments @{input=$profile.dbPath}
    Write-DuneSoloGrantFile (Join-Path $root 'identity.json') ($identity | ConvertTo-Json -Compress)
    $nonce = [guid]::NewGuid().ToString('N')
    Write-DuneSoloGrantFile (Join-Path $root 'session.txt') $nonce
    Remove-Item -LiteralPath (Join-Path $root 'ready.txt') -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root 'bridge-error.txt') -ErrorAction SilentlyContinue
    Write-DuneSoloGrantFile (Join-Path $script:DuneSoloModsRoot 'dst-solo-grants\Scripts\dst-command-root.txt') "$root|$nonce"
    Update-DuneSoloNativeGrantDispatch -Root $root
    return $root
}

function Get-DuneSoloNativeGrantResult([string]$Root, [string]$RequestId) {
    if ($RequestId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid Solo grant request.' }
    $metadata = Read-DuneSoloGrantFile (Join-Path $Root "$RequestId.json")
    if (-not $metadata) { throw 'Solo grant request was not found for this profile.' }
    $job = $metadata | ConvertFrom-Json
    $status, $completed, $message = 'queued', 0, 'Queued for your next DST Solo launch.'
    $receipt = Read-DuneSoloGrantFile (Join-Path $Root "$RequestId.result") 512
    if (-not $receipt -and (Read-DuneSoloGrantFile (Join-Path $Root "$RequestId.claim") 64)) {
        $status = if ((Get-DuneSoloRuntime).gameRunning) { 'processing' } else { 'uncertain' }
        $message = 'Delivery was started. Check your backpack before creating another grant if its result cannot be confirmed.'
    }
    if ($receipt) {
        $parts = $receipt -split '\|', 3
        if ($parts.Count -ne 3 -or $parts[0] -cnotin @('processing','delivered','uncertain') -or $parts[1] -notmatch '^\d+$') { throw 'Invalid Solo grant receipt.' }
        $status, $completed, $message = $parts[0], [int]$parts[1], $parts[2]
        if ($completed -gt @($job.items).Count) { throw 'Invalid Solo grant receipt count.' }
        if ($status -eq 'processing' -and -not (Get-DuneSoloRuntime).gameRunning) {
            $status = 'uncertain'; $message = 'Delivery was interrupted. Check your backpack before creating another grant.'
        }
    }
    return @{ok=$true;mode='native';requestId=$RequestId;status=$status;completed=$completed;total=@($job.items).Count;message=$message}
}

function Update-DuneSoloNativeGrantDispatch([string]$Root) {
    $ids = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Filter '*.json' -File | Where-Object BaseName -cmatch '^[a-f0-9]{32}$' | Sort-Object CreationTimeUtc,Name)) {
        $receipt = Read-DuneSoloGrantFile (Join-Path $Root ($file.BaseName+'.result')) 512
        if (-not $receipt -or $receipt.StartsWith('processing|')) { $ids += $file.BaseName }
    }
    Write-DuneSoloGrantFile (Join-Path $Root 'queue.txt') ($ids -join "`n")
}

function Invoke-DuneSoloNativeItemGrant {
    param([string]$Destination, [object[]]$Items, [string]$Confirm, [string]$RequestId)
    Assert-DuneSoloSupportedPlatform
    if ($Confirm -cne 'GIVE SOLO ITEMS') { throw 'Confirm the Solo item grant before continuing.' }
    if ($RequestId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid Solo grant request.' }
    if ($Items.Count -lt 1 -or $Items.Count -gt 200) { throw 'Grant between 1 and 200 item templates per operation.' }
    $profile = Get-DuneSoloProfile
    Assert-DuneSoloAdapterCapability -Profile $profile -Capability 'item-grant' | Out-Null
    $root = Get-DuneSoloNativeGrantRoot (Get-DuneSoloProfileToken -DbPath $profile.dbPath)
    if (-not (Get-DuneSoloRuntime).gameRunning) {
        $identity = Invoke-DuneSoloHelper -Command 'native-grant-identity' -Arguments @{input=$profile.dbPath}
        Write-DuneSoloGrantFile (Join-Path $root 'identity.json') ($identity | ConvertTo-Json -Compress)
    } else {
        $cached = Read-DuneSoloGrantFile (Join-Path $root 'identity.json') 8192
        $sessionText = Read-DuneSoloGrantFile (Join-Path $script:DuneSoloLoaderRoot 'session.json')
        $session = if ($sessionText) { $sessionText | ConvertFrom-Json } else { $null }
        if (-not $cached -or -not $session -or $session.nativeGrantRoot -cne $root) { throw 'Launch Solo through DST before sending in-game grants.' }
        $identity = $cached | ConvertFrom-Json
    }
    if ($Destination -cne $identity.backpackKey) { throw 'In-game grants require the selected Solo backpack.' }
    $catalog = Get-Content -LiteralPath (Get-DuneSoloGameplayCatalogPath) -Raw | ConvertFrom-Json
    $normalized = @($Items | ForEach-Object {
        $template = [string]$_.templateId
        $quantity, $quality = [double]$_.quantity, [double]$_.quality
        if ($template -cnotmatch '^[A-Za-z0-9_()/\-]{1,180}$' -or $template -match '^\d+$' -or (-not $catalog.names.PSObject.Properties[$template] -and -not $catalog.items.PSObject.Properties[$template])) { throw 'Choose an item from the DST catalog.' }
        if ($quantity -lt 1 -or $quantity -gt 100000 -or $quantity -ne [Math]::Truncate($quantity) -or $quality -lt 0 -or $quality -gt 5 -or $quality -ne [Math]::Truncate($quality)) { throw 'Choose a whole quantity from 1 to 100000 and quality from 0 to 5.' }
        if (@($_.augments | Where-Object { $null -ne $_ }).Count) { throw 'In-game grants do not apply augments. Grant the item, then augment it in game.' }
        [ordered]@{templateId=$template;quantity=[int]$quantity;quality=[int]$quality}
    })
    $plan = [ordered]@{destination=$Destination;items=@($normalized);accountId=[string]$identity.accountId;controllerId=[string]$identity.controllerId;characterName=[string]$identity.characterName}
    $serialized = $plan | ConvertTo-Json -Depth 6 -Compress
    $metadataPath = Join-Path $root "$RequestId.json"
    $existing = Read-DuneSoloGrantFile $metadataPath
    if ($existing) {
        if ($existing -cne $serialized) { throw 'This grant request identifier already belongs to a different grant.' }
        return Get-DuneSoloNativeGrantResult $root $RequestId
    }
    $pending = @(Get-ChildItem -LiteralPath $root -Filter '*.request' -File | Where-Object {
        $receipt = Read-DuneSoloGrantFile (Join-Path $root ($_.BaseName+'.result')) 512
        -not $receipt -or $receipt.StartsWith('processing|')
    })
    if ($pending.Count -ge 50) { throw 'Finish the queued Solo grants before adding more.' }
    $nameHex = ([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes([string]$identity.characterName))).Replace('-','').ToLowerInvariant()
    if ([string]$identity.accountId -notmatch '^-?\d+$' -or [string]$identity.controllerId -notmatch '^-?\d+$' -or -not $nameHex) { throw 'Solo character identity is unavailable.' }
    $lines = @("1|$RequestId|$($identity.accountId)|$($identity.controllerId)|$nameHex")
    $lines += @($normalized | ForEach-Object { "$($_.templateId)|$($_.quantity)|$($_.quality)" })
    # Publish the payload before metadata makes the job eligible for dispatch.
    Write-DuneSoloGrantFile (Join-Path $root "$RequestId.request") ($lines -join "`n")
    Write-DuneSoloGrantFile $metadataPath $serialized
    Update-DuneSoloNativeGrantDispatch $root
    return Get-DuneSoloNativeGrantResult $root $RequestId
}
