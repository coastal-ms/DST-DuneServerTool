# Versioned API response, request ID, cursor, and audit primitives.

$script:DuneApiSchemaVersion = 1
$script:DuneApiCursorSecret = $null

function ConvertTo-DuneBase64Url {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

function ConvertFrom-DuneBase64Url {
    param([Parameter(Mandatory)][string]$Value)
    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        2 { $base64 += '==' }
        3 { $base64 += '=' }
        1 { throw 'Invalid base64url value.' }
    }
    return [Convert]::FromBase64String($base64)
}

function New-DuneRequestId {
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ConvertTo-DuneBase64Url $bytes
}

function Get-DuneSha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function Get-DuneApiPrincipalFingerprint {
    param($Principal)
    if (-not $Principal) { return Get-DuneSha256Hex 'anonymous' }
    $parts = @(
        [string]$Principal.type,
        [string]$Principal.id,
        [string]$Principal.role,
        [string]$Principal.account.id,
        [string]$Principal.session.id
    )
    return Get-DuneSha256Hex ($parts -join '|')
}

function Get-DuneApiCursorSecret {
    if (-not $script:DuneApiCursorSecret) {
        $script:DuneApiCursorSecret = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($script:DuneApiCursorSecret) } finally { $rng.Dispose() }
    }
    return $script:DuneApiCursorSecret
}

function Get-DuneCursorBinding {
    param(
        $Principal,
        [Parameter(Mandatory)][string]$MapId,
        [string[]]$Layers = @(),
        [string]$Bbox = '',
        [string]$Query = '',
        [Parameter(Mandatory)][string]$Generation
    )
    $normalizedLayers = @($Layers | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    return [ordered]@{
        principal = Get-DuneApiPrincipalFingerprint $Principal
        map = $MapId.Trim()
        layers = $normalizedLayers
        bbox = $Bbox.Trim()
        queryHash = Get-DuneSha256Hex $Query
        generation = $Generation.Trim()
    }
}

function Test-DuneFixedTimeBytes {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $diff = $Left.Length -bxor $Right.Length
    $limit = [Math]::Max($Left.Length, $Right.Length)
    for ($i = 0; $i -lt $limit; $i++) {
        $a = if ($i -lt $Left.Length) { $Left[$i] } else { 0 }
        $b = if ($i -lt $Right.Length) { $Right[$i] } else { 0 }
        $diff = $diff -bor ($a -bxor $b)
    }
    return ($diff -eq 0)
}

function New-DuneOpaqueCursor {
    param(
        $Principal,
        [Parameter(Mandatory)][string]$MapId,
        [string[]]$Layers = @(),
        [string]$Bbox = '',
        [string]$Query = '',
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)]$Position,
        [byte[]]$Secret
    )
    if (-not $Secret) { $Secret = Get-DuneApiCursorSecret }
    $payload = [ordered]@{
        version = 1
        binding = Get-DuneCursorBinding -Principal $Principal -MapId $MapId -Layers $Layers -Bbox $Bbox -Query $Query -Generation $Generation
        position = $Position
        issuedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    $payloadBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $hmac = [Security.Cryptography.HMACSHA256]::new($Secret)
    try { $signature = $hmac.ComputeHash($payloadBytes) } finally { $hmac.Dispose() }
    return "$(ConvertTo-DuneBase64Url $payloadBytes).$(ConvertTo-DuneBase64Url $signature)"
}

function Read-DuneOpaqueCursor {
    param(
        [Parameter(Mandatory)][string]$Cursor,
        $Principal,
        [Parameter(Mandatory)][string]$MapId,
        [string[]]$Layers = @(),
        [string]$Bbox = '',
        [string]$Query = '',
        [Parameter(Mandatory)][string]$Generation,
        [byte[]]$Secret
    )
    if (-not $Secret) { $Secret = Get-DuneApiCursorSecret }
    $parts = $Cursor.Split('.')
    if ($parts.Count -ne 2) { throw 'Invalid cursor.' }
    try {
        $payloadBytes = ConvertFrom-DuneBase64Url $parts[0]
        $providedSignature = ConvertFrom-DuneBase64Url $parts[1]
    } catch {
        throw 'Invalid cursor.'
    }
    $hmac = [Security.Cryptography.HMACSHA256]::new($Secret)
    try { $expectedSignature = $hmac.ComputeHash($payloadBytes) } finally { $hmac.Dispose() }
    if (-not (Test-DuneFixedTimeBytes $providedSignature $expectedSignature)) { throw 'Invalid cursor.' }

    try { $payload = [Text.Encoding]::UTF8.GetString($payloadBytes) | ConvertFrom-Json } catch { throw 'Invalid cursor.' }
    if ([int]$payload.version -ne 1) { throw 'Unsupported cursor version.' }
    $expected = Get-DuneCursorBinding -Principal $Principal -MapId $MapId -Layers $Layers -Bbox $Bbox -Query $Query -Generation $Generation
    foreach ($name in @('principal', 'map', 'bbox', 'queryHash', 'generation')) {
        if ([string]$payload.binding.$name -cne [string]$expected[$name]) { throw 'Cursor does not match this request.' }
    }
    if ((@($payload.binding.layers) -join "`n") -cne (@($expected.layers) -join "`n")) {
        throw 'Cursor does not match this request.'
    }
    return $payload
}

function New-DuneApiFreshness {
    param(
        [ValidateSet('fresh','refreshing','stale','unavailable','partial')][string]$State = 'fresh',
        [string]$ObservedAt = '',
        [string]$CachedAt = '',
        [Nullable[int]]$AgeSeconds = $null,
        [string]$LastErrorCode = ''
    )
    return [ordered]@{
        observedAt = if ($ObservedAt) { $ObservedAt } else { $null }
        cachedAt = if ($CachedAt) { $CachedAt } else { $null }
        ageSeconds = $AgeSeconds
        state = $State
        lastErrorCode = if ($LastErrorCode) { $LastErrorCode } else { $null }
    }
}

function New-DuneApiPage {
    param([int]$Limit = 0, [string]$NextCursor = '', [bool]$Truncated = $false)
    return [ordered]@{
        limit = $Limit
        nextCursor = if ($NextCursor) { $NextCursor } else { $null }
        truncated = $Truncated
    }
}

function New-DuneApiLayerEnvelope {
    param(
        [Parameter(Mandatory)][string]$LayerId,
        [ValidateSet('live','cache','static','mixed','unavailable')][string]$Source,
        [Parameter(Mandatory)]$Freshness,
        [int]$Count = 0,
        $Data = @(),
        $Page = $null,
        $Error = $null
    )
    if (-not $Page) { $Page = New-DuneApiPage }
    return [ordered]@{
        layerId = $LayerId
        source = $Source
        freshness = $Freshness
        count = $Count
        page = $Page
        error = $Error
        data = $Data
    }
}

function New-DuneApiV1Envelope {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [ValidateSet('live','cache','static','mixed','unavailable')][string]$Source,
        [Parameter(Mandatory)]$Freshness,
        [string[]]$Capabilities = @(),
        $Data = $null,
        $Page = $null
    )
    if (-not $Page) { $Page = New-DuneApiPage }
    return [ordered]@{
        schemaVersion = $script:DuneApiSchemaVersion
        requestId = $RequestId
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        source = $Source
        freshness = $Freshness
        capabilities = @($Capabilities)
        data = $Data
        page = $Page
    }
}

function New-DuneApiAggregateEnvelope {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][object[]]$Layers,
        [string[]]$Capabilities = @(),
        $Data = $null
    )
    $sources = @($Layers | ForEach-Object { [string]$_.source } | Sort-Object -Unique)
    $states = @($Layers | ForEach-Object { [string]$_.freshness.state } | Sort-Object -Unique)
    $availableLayers = @($Layers | Where-Object {
        [string]$_.source -ne 'unavailable' -and [string]$_.freshness.state -ne 'unavailable'
    })
    $source = if ($availableLayers.Count -eq 0) {
        'unavailable'
    } elseif ($sources.Count -eq 1) {
        $sources[0]
    } else {
        'mixed'
    }
    $state = if ($availableLayers.Count -eq 0) {
        'unavailable'
    } elseif ($availableLayers.Count -lt $Layers.Count -or $states.Count -gt 1) {
        'partial'
    } elseif ($states.Count -eq 1) {
        $states[0]
    } else {
        'unavailable'
    }
    $aggregate = [ordered]@{}
    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($key in $Data.Keys) { $aggregate[[string]$key] = $Data[$key] }
    } elseif ($null -ne $Data) {
        $aggregate.value = $Data
    }
    $aggregate.layers = @($Layers)
    return New-DuneApiV1Envelope `
        -RequestId $RequestId `
        -Source $source `
        -Freshness (New-DuneApiFreshness -State $state) `
        -Capabilities $Capabilities `
        -Data $aggregate
}

function ConvertTo-DuneAuditSafeValue {
    param($Value, [string]$Name = '')
    if ($Name -match '(?i)(password|passwd|pwd|token|secret|authorization|cookie|key)') { return '<redacted>' }
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[[string]$key] = ConvertTo-DuneAuditSafeValue $Value[$key] ([string]$key) }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { ConvertTo-DuneAuditSafeValue $_ })
    }
    $copy = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $copy[$property.Name] = ConvertTo-DuneAuditSafeValue $property.Value $property.Name
    }
    return $copy
}

function New-DuneAuditRecord {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$CapabilityId,
        [Parameter(Mandatory)]$Principal,
        [Parameter(Mandatory)][string]$Action,
        $Fields = @{}
    )
    return [ordered]@{
        schemaVersion = 1
        requestId = $RequestId
        occurredAt = (Get-Date).ToUniversalTime().ToString('o')
        capabilityId = $CapabilityId
        action = $Action
        actor = [ordered]@{
            type = [string]$Principal.type
            id = [string]$Principal.id
            role = [string]$Principal.role
        }
        fields = ConvertTo-DuneAuditSafeValue $Fields
    }
}
