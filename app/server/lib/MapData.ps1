# Read-only live data adapters for Maps. These functions intentionally expose
# narrow map projections rather than raw database rows or generic game entities.

$script:DuneMapDataSpiceMaxRows = 200
$script:DuneMapDataPoiMaxRows = 250
$script:DuneMapDataStaticPoiPayloadType = 'EMarkerPayloadType::StaticLocation'
$script:DuneMapDataCapabilityCacheTtlSec = 1800
$script:DuneMapDataCapabilityCache = $null

function Get-DuneMapDataCapabilityCache {
    if (-not $script:DuneMapDataCapabilityCache) {
        $script:DuneMapDataCapabilityCache = [Collections.Hashtable]::Synchronized(@{})
    }
    return $script:DuneMapDataCapabilityCache
}

function Clear-DuneMapDataCapabilityCache {
    param([string]$Ip)

    $cache = Get-DuneMapDataCapabilityCache
    [Threading.Monitor]::Enter($cache.SyncRoot)
    try {
        if ($Ip) {
            [void]$cache.Remove($Ip.Trim().ToLowerInvariant())
        } else {
            $cache.Clear()
        }
    } finally {
        [Threading.Monitor]::Exit($cache.SyncRoot)
    }
}

function Copy-DuneMapDataCapabilityResult {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 8 -Compress | ConvertFrom-Json)
}

function Add-DuneMapDataCapabilityProbeMetadata {
    param(
        [Parameter(Mandatory)]$Capability,
        [bool]$Cached,
        [Parameter(Mandatory)][datetime]$ObservedAt,
        [Nullable[datetime]]$ExpiresAt,
        [Parameter(Mandatory)][int]$CadenceSeconds,
        [bool]$Stale = $false
    )

    $copy = Copy-DuneMapDataCapabilityResult $Capability
    if (-not $copy.PSObject.Properties['source']) {
        $copy | Add-Member -NotePropertyName source -NotePropertyValue ([pscustomobject]@{})
    }
    $copy.source | Add-Member -Force -NotePropertyName capabilityProbe -NotePropertyValue ([pscustomobject]@{
        cached         = $Cached
        stale          = $Stale
        cadenceSeconds = $CadenceSeconds
        observedAt     = $ObservedAt.ToUniversalTime().ToString('o')
        expiresAt      = if ($null -ne $ExpiresAt) {
            ([datetime]$ExpiresAt).ToUniversalTime().ToString('o')
        } else {
            $null
        }
    })
    return $copy
}

function Get-DuneMapDataCachedCapabilities {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [switch]$AllowExpired,
        [datetime]$Now = [datetime]::UtcNow
    )

    $cache = Get-DuneMapDataCapabilityCache
    $key = $Ip.Trim().ToLowerInvariant()
    [Threading.Monitor]::Enter($cache.SyncRoot)
    try {
        $entry = $cache[$key]
    } finally {
        [Threading.Monitor]::Exit($cache.SyncRoot)
    }
    if (-not $entry) { return $null }
    $stale = $entry.expiresAt -le $Now.ToUniversalTime()
    if ($stale -and -not $AllowExpired) { return $null }
    return Add-DuneMapDataCapabilityProbeMetadata `
        -Capability $entry.result `
        -Cached $true `
        -ObservedAt $entry.observedAt `
        -ExpiresAt $entry.expiresAt `
        -CadenceSeconds ([int]$entry.cadenceSeconds) `
        -Stale $stale
}

function Test-DuneMapDataSchemaSignatureError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return $Message -match (
        '(?i)(SQLSTATE\s+(?:42703|42P01|42704|42883)|' +
        '(?:column|relation|type|function)\s+.+\s+does not exist|' +
        'cached plan must not change result type)')
}

function ConvertTo-DuneMapDataRowMaps {
    param($Result)

    $maps = @()
    if (-not $Result -or -not $Result.ok -or -not $Result.columns) { return $maps }
    $columns = @($Result.columns)
    $resultRows = @($Result.rows)
    if ($resultRows.Count -eq 1 -and
        $resultRows[0] -is [System.Array] -and
        $resultRows[0].Count -gt 0 -and
        $resultRows[0][0] -is [System.Array]) {
        $resultRows = @($resultRows[0])
    }
    foreach ($row in $resultRows) {
        $rowValues = $row
        while ($rowValues -is [System.Array] -and
            $rowValues.Count -eq 1 -and
            $rowValues[0] -is [System.Array]) {
            $rowValues = $rowValues[0]
        }
        $map = @{}
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $map[[string]$columns[$i]] = if ($i -lt $rowValues.Length) { $rowValues[$i] } else { $null }
        }
        $maps += ,$map
    }
    return $maps
}

function ConvertTo-DuneMapDataLong {
    param($Value)

    $number = 0L
    if ([Int64]::TryParse([string]$Value, [ref]$number)) { return $number }
    return 0L
}

function ConvertTo-DuneMapDataDouble {
    param($Value)

    $number = 0.0
    if ([double]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return $null
}

function Get-DuneMapDataSchemaFingerprint {
    param([object[]]$Rows)

    $canonical = @($Rows | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|{5}' -f
            [string]$_['item_kind'],
            [string]$_['object_name'],
            [string]$_['member_name'],
            [string]$_['data_type'],
            [string]$_['udt_name'],
            [string]$_['is_nullable']
    } | Sort-Object) -join "`n"

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-DuneMapDataParameterizedSql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][hashtable]$ParameterTypes
    )

    $token = '/*__DST_PARAMETERS__*/'
    if (-not $Sql.Contains($token)) {
        throw "Parameterized map SQL is missing the $token token."
    }

    $allowedTypes = @('text', 'integer', 'bigint', 'boolean', 'double precision', 'timestamptz')
    $payload = [ordered]@{}
    $definitions = @()
    foreach ($name in @($Parameters.Keys | Sort-Object)) {
        if ([string]$name -notmatch '^[a-z][a-z0-9_]*$') {
            throw "Invalid map SQL parameter name '$name'."
        }
        if (-not $ParameterTypes.ContainsKey($name)) {
            throw "Map SQL parameter '$name' has no declared PostgreSQL type."
        }
        $type = ([string]$ParameterTypes[$name]).ToLowerInvariant()
        if ($allowedTypes -notcontains $type) {
            throw "Map SQL parameter '$name' uses unsupported PostgreSQL type '$type'."
        }
        $payload[$name] = $Parameters[$name]
        $definitions += '"' + $name + '" ' + $type
    }

    foreach ($name in $ParameterTypes.Keys) {
        if (-not $Parameters.ContainsKey($name)) {
            throw "Map SQL type declaration '$name' has no parameter value."
        }
    }

    $json = $payload | ConvertTo-Json -Compress -Depth 5
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $cte = "_dst_parameters AS (" +
        "SELECT * FROM jsonb_to_record(" +
        "convert_from(decode('$encoded', 'base64'), 'UTF8')::jsonb" +
        ") AS p($($definitions -join ', '))" +
        ")"
    return $Sql.Replace($token, $cte)
}

function Invoke-DuneMapDataQuery {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][hashtable]$ParameterTypes,
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')]
        [string]$SourceKey,
        [int]$MaxRows,
        [int]$TimeoutSec = 20
    )

    try {
        $effectiveSql = New-DuneMapDataParameterizedSql `
            -Sql $Sql `
            -Parameters $Parameters `
            -ParameterTypes $ParameterTypes
        $effectiveSql = "/* dst-source:$SourceKey */`n$effectiveSql"
    } catch {
        return @{ ok = $false; error = "Could not bind map query parameters: $($_.Exception.Message)" }
    }

    return Invoke-DuneSqlQuery `
        -Ip $Ip `
        -Sql $effectiveSql `
        -ReadOnly $true `
        -MaxRows $MaxRows `
        -TimeoutSec $TimeoutSec
}

function Test-DuneMapDataQueryResult {
    param(
        $Result,
        [Parameter(Mandatory)][string[]]$ExpectedColumns
    )

    if (-not $Result -or -not $Result.ok) {
        return @{
            ok = $false
            reasonCode = 'query-failed'
            error = if ($Result -and $Result.error) { [string]$Result.error } else { 'Map data query failed.' }
        }
    }
    if ([string]$Result.message -match '^Parse error:') {
        return @{
            ok = $false
            reasonCode = 'parse-error'
            error = [string]$Result.message
        }
    }

    $columns = @($Result.columns | ForEach-Object { [string]$_ })
    $missing = @($ExpectedColumns | Where-Object { $columns -notcontains $_ })
    if ($missing.Count -gt 0) {
        return @{
            ok = $false
            reasonCode = 'malformed-result'
            error = "Map data query result is missing expected columns: $($missing -join ', ')."
            missingColumns = $missing
        }
    }
    return @{ ok = $true }
}

function New-DuneMapDataFreshness {
    param(
        [Parameter(Mandatory)][datetime]$ObservedAt,
        [int]$StaleAfterSec,
        [datetime]$Now = [datetime]::UtcNow
    )

    $observedUtc = $ObservedAt.ToUniversalTime()
    $ageSeconds = [Math]::Max(0, [int][Math]::Floor(($Now.ToUniversalTime() - $observedUtc).TotalSeconds))
    return [ordered]@{
        state         = if ($ageSeconds -gt $StaleAfterSec) { 'stale' } else { 'fresh' }
        observedAt    = $observedUtc.ToString('o')
        ageSeconds    = $ageSeconds
        staleAfterSec = $StaleAfterSec
    }
}

function Invoke-DuneMapDataCapabilitiesProbe {
    param([Parameter(Mandatory)][string]$Ip)

    $sql = @'
/* dst-source:maps.schema */
SELECT 'column'::text AS item_kind,
       c.table_name AS object_name,
       c.column_name AS member_name,
       c.data_type,
       c.udt_name,
       c.is_nullable
FROM information_schema.columns c
WHERE c.table_schema = 'dune'
  AND c.table_name IN ('resourcefield_state', 'markers')
UNION ALL
SELECT 'attribute',
       'marker',
       a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod),
       '',
       ''
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
JOIN pg_class composite ON composite.oid = t.typrelid
JOIN pg_attribute a ON a.attrelid = composite.oid
WHERE n.nspname = 'dune'
  AND t.typname = 'marker'
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY item_kind, object_name, member_name
LIMIT 128;
'@
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 128 -TimeoutSec 15
    if (-not $result.ok) {
        return @{
            ok         = $false
            status     = 'error'
            reasonCode = 'schema-probe-failed'
            error      = $result.error
            source     = @{ queryDurationMs = $result.durationMs }
        }
    }

    $rows = @(ConvertTo-DuneMapDataRowMaps -Result $result)
    $columnsByTable = @{}
    foreach ($table in @('resourcefield_state', 'markers')) {
        $columnsByTable[$table] = @($rows |
            Where-Object { $_['item_kind'] -eq 'column' -and $_['object_name'] -eq $table } |
            ForEach-Object { [string]$_['member_name'] })
    }
    $markerAttributes = @($rows |
        Where-Object { $_['item_kind'] -eq 'attribute' -and $_['object_name'] -eq 'marker' } |
        ForEach-Object { [string]$_['member_name'] })

    $spiceRequired = @(
        'field_id', 'map', 'dimension_index', 'spawn_time', 'value_remaining', 'field_kind_id'
    )
    $spiceMissing = @($spiceRequired | Where-Object {
        $columnsByTable['resourcefield_state'] -notcontains $_
    })

    # Coordinates are accepted only under an explicit world-coordinate schema;
    # field IDs are never decoded or correlated to guessed positions.
    $spiceCoordinateRequired = @('world_x', 'world_y', 'world_z', 'coordinate_system')
    $spiceCoordinatesVerified = (@($spiceCoordinateRequired | Where-Object {
        $columnsByTable['resourcefield_state'] -notcontains $_
    }).Count -eq 0)

    $markerRequired = @(
        'marker_hash_id', 'dimension_index', 'marker', 'payload', 'map_name_id',
        'is_private', 'owner_account_id'
    )
    $markerMissing = @($markerRequired | Where-Object {
        $columnsByTable['markers'] -notcontains $_
    })
    $markerAttributeRequired = @('marker_type', 'x', 'y', 'z', 'payload_type')
    $markerAttributeMissing = @($markerAttributeRequired | Where-Object {
        $markerAttributes -notcontains $_
    })
    $poiMissing = @($markerMissing + ($markerAttributeMissing | ForEach-Object { "marker.$_" }))

    $fingerprint = Get-DuneMapDataSchemaFingerprint -Rows $rows
    $spiceAvailable = ($spiceMissing.Count -eq 0)
    $poiAvailable = ($poiMissing.Count -eq 0)
    return [ordered]@{
        ok                = $true
        status            = if ($spiceAvailable -and $poiAvailable) { 'ready' } else { 'partial' }
        schemaFingerprint = $fingerprint
        source            = [ordered]@{
            adapter        = 'postgresql'
            schema         = 'dune'
            queryDurationMs = $result.durationMs
        }
        activeSpice       = [ordered]@{
            available          = $spiceAvailable
            missingColumns     = $spiceMissing
            spatialStatus      = if ($spiceCoordinatesVerified) { 'verified' } else { 'unresolved' }
            coordinateColumns  = @($(if ($spiceCoordinatesVerified) {
                'world_x', 'world_y', 'world_z'
            }))
        }
        publicStaticPoi   = [ordered]@{
            available      = $poiAvailable
            category       = 'static-location'
            payloadType    = $script:DuneMapDataStaticPoiPayloadType
            missingMembers = $poiMissing
            privacyProof   = if ($poiAvailable) {
                'Explicit is_private=false and owner_account_id IS NULL predicates'
            } else {
                'Unavailable: schema cannot prove exclusion of private or owned markers'
            }
        }
    }
}

function Get-DuneMapDataCapabilities {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [switch]$ForceRefresh,
        [ValidateRange(1,86400)][int]$CacheTtlSec = $script:DuneMapDataCapabilityCacheTtlSec,
        [datetime]$Now = [datetime]::UtcNow
    )

    $cache = Get-DuneMapDataCapabilityCache
    $key = $Ip.Trim().ToLowerInvariant()
    $nowUtc = $Now.ToUniversalTime()
    $entry = $null
    [Threading.Monitor]::Enter($cache.SyncRoot)
    try {
        if ($ForceRefresh) {
            [void]$cache.Remove($key)
        } else {
            $entry = $cache[$key]
        }
    } finally {
        [Threading.Monitor]::Exit($cache.SyncRoot)
    }

    if ($entry -and $entry.expiresAt -gt $nowUtc) {
        return Add-DuneMapDataCapabilityProbeMetadata `
            -Capability $entry.result `
            -Cached $true `
            -ObservedAt $entry.observedAt `
            -ExpiresAt $entry.expiresAt `
            -CadenceSeconds ([int]$entry.cadenceSeconds) `
            -Stale $false
    }

    $result = Invoke-DuneMapDataCapabilitiesProbe -Ip $Ip
    $observedAt = $nowUtc
    $expiresAt = $null
    # Failed probes keep any prior evidence only for the explicit stale fallback.
    # The platform source owns retry timing through its independent backoff.
    if ($result.ok) {
        $expiresAt = $observedAt.AddSeconds($CacheTtlSec)
        $stored = [pscustomobject]@{
            observedAt = $observedAt
            expiresAt  = $expiresAt
            cadenceSeconds = $CacheTtlSec
            result     = Copy-DuneMapDataCapabilityResult $result
        }
        [Threading.Monitor]::Enter($cache.SyncRoot)
        try {
            $cache[$key] = $stored
        } finally {
            [Threading.Monitor]::Exit($cache.SyncRoot)
        }
    }

    return Add-DuneMapDataCapabilityProbeMetadata `
        -Capability $result `
        -Cached $false `
        -ObservedAt $observedAt `
        -ExpiresAt $expiresAt `
        -CadenceSeconds $CacheTtlSec `
        -Stale $false
}

function Get-DuneActiveSpiceLive {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Limit = $script:DuneMapDataSpiceMaxRows,
        $Capability,
        [ValidateRange(1,120)][int]$TimeoutSec = 20
    )

    $Limit = [Math]::Max(1, [Math]::Min($Limit, $script:DuneMapDataSpiceMaxRows))
    if (-not $Capability) { $Capability = Get-DuneMapDataCapabilities -Ip $Ip }
    if (-not $Capability.ok) {
        return @{
            ok = $false; status = 'error'; capability = 'active-spice'
            error = $Capability.error; source = $Capability.source
        }
    }
    if (-not $Capability.activeSpice.available) {
        return [ordered]@{
            ok         = $false
            status     = 'unavailable'
            capability = 'active-spice'
            reasonCode = 'unsupported-schema'
            evidence   = @{ missingColumns = @($Capability.activeSpice.missingColumns) }
            source     = @{ schemaFingerprint = $Capability.schemaFingerprint }
        }
    }

    $coordinateSelect = if ($Capability.activeSpice.spatialStatus -eq 'verified') {
        'world_x::text AS x, world_y::text AS y, world_z::text AS z, coordinate_system,'
    } else {
        "NULL::text AS x, NULL::text AS y, NULL::text AS z, ''::text AS coordinate_system,"
    }
    $sql = @"
WITH /*__DST_PARAMETERS__*/,
active_fields AS (
    SELECT field_id::text AS field_id,
           map,
           dimension_index,
           spawn_time::text AS spawn_time,
           value_remaining::text AS value_remaining,
           field_kind_id,
           $coordinateSelect
           count(*) OVER ()::text AS source_count
    FROM dune.resourcefield_state
    WHERE field_kind_id = 1
      AND value_remaining > 0
      AND map LIKE ((SELECT map_prefix FROM _dst_parameters) || '%')
    ORDER BY map, dimension_index, field_id
    LIMIT ((SELECT row_limit FROM _dst_parameters) + 1)
)
SELECT *
FROM active_fields
ORDER BY map, dimension_index, field_id;
"@
    $result = Invoke-DuneMapDataQuery `
        -Ip $Ip `
        -Sql $sql `
        -Parameters @{ row_limit = $Limit; map_prefix = 'DeepDesert' } `
        -ParameterTypes @{ row_limit = 'integer'; map_prefix = 'text' } `
        -SourceKey 'maps.active-spice' `
        -MaxRows ($Limit + 1) `
        -TimeoutSec $TimeoutSec
    $validation = Test-DuneMapDataQueryResult -Result $result -ExpectedColumns @(
        'field_id', 'map', 'dimension_index', 'spawn_time', 'value_remaining',
        'field_kind_id', 'x', 'y', 'z', 'coordinate_system', 'source_count'
    )
    if (-not $validation.ok) {
        return [ordered]@{
            ok         = $false
            status     = 'error'
            capability = 'active-spice'
            reasonCode = $validation.reasonCode
            error      = $validation.error
            source     = [ordered]@{
                schemaFingerprint = $Capability.schemaFingerprint
                queryDurationMs    = $result.durationMs
            }
        }
    }

    $observedAt = [datetime]::UtcNow
    $rawRows = @(ConvertTo-DuneMapDataRowMaps -Result $result)
    $sourceCount = if ($rawRows.Count -gt 0) {
        ConvertTo-DuneMapDataLong $rawRows[0]['source_count']
    } else {
        0L
    }
    $truncated = ($result.truncated -or $rawRows.Count -gt $Limit -or $sourceCount -gt $Limit)
    $selectedRows = @($rawRows | Select-Object -First $Limit)
    $fields = @()
    $observations = @()
    foreach ($row in $selectedRows) {
        $fieldId = [string]$row['field_id']
        $spatialStatus = [string]$Capability.activeSpice.spatialStatus
        $position = [ordered]@{
            status           = $spatialStatus
            coordinateSystem = if ($spatialStatus -eq 'verified') {
                [string]$row['coordinate_system']
            } else {
                $null
            }
            x                = if ($spatialStatus -eq 'verified') {
                ConvertTo-DuneMapDataDouble $row['x']
            } else {
                $null
            }
            y                = if ($spatialStatus -eq 'verified') {
                ConvertTo-DuneMapDataDouble $row['y']
            } else {
                $null
            }
            z                = if ($spatialStatus -eq 'verified') {
                ConvertTo-DuneMapDataDouble $row['z']
            } else {
                $null
            }
            reason           = if ($spatialStatus -eq 'verified') {
                $null
            } else {
                'No independently verified coordinate columns are available; field_id was not decoded.'
            }
        }
        $field = [ordered]@{
            fieldId       = $fieldId
            map           = [string]$row['map']
            dimensionIndex = [int](ConvertTo-DuneMapDataLong $row['dimension_index'])
            fieldKindId   = [int](ConvertTo-DuneMapDataLong $row['field_kind_id'])
            state         = 'active'
            spawnTime     = ConvertTo-DuneMapDataDouble $row['spawn_time']
            valueRemaining = ConvertTo-DuneMapDataLong $row['value_remaining']
            position      = $position
        }
        $fields += $field
        $observations += [ordered]@{
            identity        = "resourcefield_state:$fieldId"
            observedAt      = $observedAt.ToString('o')
            state           = 'active'
            valueRemaining  = $field.valueRemaining
            sourceFingerprint = $Capability.schemaFingerprint
        }
    }

    [string[]]$partialReasons = @()
    if ($truncated) { $partialReasons = @('row-limit') }
    return [ordered]@{
        ok            = $true
        status        = if ($truncated) { 'partial' } else { 'ready' }
        capability    = 'active-spice'
        fields        = $fields
        observations  = $observations
        historyStatus = 'current-observation-only'
        totalAvailable = $sourceCount
        returned      = $fields.Count
        truncated     = $truncated
        partialReasons = $partialReasons
        freshness     = New-DuneMapDataFreshness -ObservedAt $observedAt -StaleAfterSec 60
        source        = [ordered]@{
            schema            = 'dune.resourcefield_state'
            schemaFingerprint = $Capability.schemaFingerprint
            queryDurationMs    = $result.durationMs
            spatialStatus     = [string]$Capability.activeSpice.spatialStatus
        }
    }
}

function Get-DunePublicStaticPoiLive {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Limit = $script:DuneMapDataPoiMaxRows,
        $Capability
    )

    $Limit = [Math]::Max(1, [Math]::Min($Limit, $script:DuneMapDataPoiMaxRows))
    if (-not $Capability) { $Capability = Get-DuneMapDataCapabilities -Ip $Ip }
    if (-not $Capability.ok) {
        return @{
            ok = $false; status = 'error'; capability = 'public-static-poi'
            error = $Capability.error; source = $Capability.source
        }
    }
    if (-not $Capability.publicStaticPoi.available) {
        return [ordered]@{
            ok         = $false
            status     = 'unavailable'
            capability = 'public-static-poi'
            category   = 'static-location'
            reasonCode = 'privacy-proof-unavailable'
            evidence   = [ordered]@{
                missingMembers = @($Capability.publicStaticPoi.missingMembers)
                privacyProof   = $Capability.publicStaticPoi.privacyProof
            }
            source     = @{ schemaFingerprint = $Capability.schemaFingerprint }
        }
    }

    $sql = @'
WITH /*__DST_PARAMETERS__*/,
public_markers AS (
    SELECT marker_hash_id::text AS marker_hash_id,
           dimension_index,
           map_name_id,
           (marker).marker_type AS marker_type,
           (marker).x::text AS x,
           (marker).y::text AS y,
           (marker).z::text AS z,
           COALESCE(payload->>'DisplayName', '') AS display_name,
           COALESCE(payload->>'LocationKey', '') AS location_key,
           count(*) OVER ()::text AS source_count
    FROM dune.markers
    WHERE (marker).payload_type = (SELECT payload_type FROM _dst_parameters)
      AND is_private IS FALSE
      AND owner_account_id IS NULL
      AND NOT (COALESCE(payload, '{}'::jsonb) ?| ARRAY[
          'OwnerId', 'OwnerAccountId', 'PlayerId', 'AccountId',
          'Private', 'IsPrivate', 'Visibility', 'PermissionActorId'
      ])
    ORDER BY marker_hash_id
    LIMIT ((SELECT row_limit FROM _dst_parameters) + 1)
)
SELECT *
FROM public_markers
ORDER BY marker_hash_id;
'@
    $result = Invoke-DuneMapDataQuery `
        -Ip $Ip `
        -Sql $sql `
        -Parameters @{
            payload_type = $script:DuneMapDataStaticPoiPayloadType
            row_limit    = $Limit
        } `
        -ParameterTypes @{
            payload_type = 'text'
            row_limit    = 'integer'
        } `
        -SourceKey 'maps.public-poi' `
        -MaxRows ($Limit + 1) `
        -TimeoutSec 20
    $validation = Test-DuneMapDataQueryResult -Result $result -ExpectedColumns @(
        'marker_hash_id', 'dimension_index', 'map_name_id', 'marker_type',
        'x', 'y', 'z', 'display_name', 'location_key', 'source_count'
    )
    if (-not $validation.ok) {
        return [ordered]@{
            ok         = $false
            status     = 'error'
            capability = 'public-static-poi'
            category   = 'static-location'
            reasonCode = $validation.reasonCode
            error      = $validation.error
            source     = [ordered]@{
                schemaFingerprint = $Capability.schemaFingerprint
                queryDurationMs    = $result.durationMs
            }
        }
    }

    $observedAt = [datetime]::UtcNow
    $rawRows = @(ConvertTo-DuneMapDataRowMaps -Result $result)
    $sourceCount = if ($rawRows.Count -gt 0) {
        ConvertTo-DuneMapDataLong $rawRows[0]['source_count']
    } else {
        0L
    }
    $truncated = ($result.truncated -or $rawRows.Count -gt $Limit -or $sourceCount -gt $Limit)
    $pois = @($rawRows | Select-Object -First $Limit | ForEach-Object {
        [ordered]@{
            markerId      = [string]$_['marker_hash_id']
            category      = 'static-location'
            markerType    = [string]$_['marker_type']
            label         = [string]$_['display_name']
            locationKey   = [string]$_['location_key']
            mapNameId     = [int](ConvertTo-DuneMapDataLong $_['map_name_id'])
            dimensionIndex = [int](ConvertTo-DuneMapDataLong $_['dimension_index'])
            position      = [ordered]@{
                status = 'verified'
                x      = ConvertTo-DuneMapDataDouble $_['x']
                y      = ConvertTo-DuneMapDataDouble $_['y']
                z      = ConvertTo-DuneMapDataDouble $_['z']
            }
        }
    })

    [string[]]$partialReasons = @()
    if ($truncated) { $partialReasons = @('row-limit') }
    return [ordered]@{
        ok             = $true
        status         = if ($truncated) { 'partial' } else { 'ready' }
        capability     = 'public-static-poi'
        category       = 'static-location'
        pois           = $pois
        totalAvailable = $sourceCount
        returned       = $pois.Count
        truncated      = $truncated
        partialReasons = $partialReasons
        freshness      = New-DuneMapDataFreshness -ObservedAt $observedAt -StaleAfterSec 1800
        source         = [ordered]@{
            schema            = 'dune.markers'
            schemaFingerprint = $Capability.schemaFingerprint
            payloadType       = $script:DuneMapDataStaticPoiPayloadType
            privacyProof      = $Capability.publicStaticPoi.privacyProof
            queryDurationMs   = $result.durationMs
        }
    }
}
