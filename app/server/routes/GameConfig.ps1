# GameConfig API — read/write UserGame.ini + UserEngine.ini on the BG VM.
# Two endpoints + one schema endpoint.

# -----------------------------------------------------------------------------
# GET /api/gameconfig/schema — static schema (no SSH).
# Returned shape:
#   { schema: [ { section, fields: [ { key, file, type, label, options?, ... } ] } ] }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/schema' -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body @{ schema = Get-DuneGameConfigSchemaApi }
}

# -----------------------------------------------------------------------------
# GET /api/gameconfig — fetch live INI values from the BG VM.
# Returns:
#   { available: true, source: 'live'|'template'|'cache',
#     game: { path, values, raw }, engine: { path, values, raw } }
# 503 with message when VM not available.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $cfg = Get-DuneGameConfig -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            available = $true
            source    = $cfg.source
            game      = $cfg.game
            engine    = $cfg.engine
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config load failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/gameconfig — apply updates.
# Body: { updates: { "<key>": "<value>", ... } }   (schema-keyed; section/file
#        resolved from the schema), OR
#        { updates: [ { file, section, key, value }, ... ] } (explicit/raw).
# Every touched section is relocated into the DST-managed block (whole-section
# absorption); any pre-existing dune-admin block is migrated. Returns the
# freshly-fetched config so the client can refresh its state.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/gameconfig' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }

    $updates = $null
    if ($body -is [hashtable] -and $body.ContainsKey('updates')) { $updates = $body.updates }
    elseif ($body.updates) { $updates = $body.updates }
    if (-not $updates) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include an "updates" object or array.'
        return
    }

    # Build a schema lookup: key -> @{ section; file }.
    $schemaMap = @{}
    foreach ($f in $script:DuneGameConfigSchema) { $schemaMap[$f.Key] = @{ section = $f.Section; file = $f.File } }

    $structured = New-Object 'System.Collections.Generic.List[object]'
    if ($updates -is [System.Collections.IEnumerable] -and -not ($updates -is [hashtable]) -and -not ($updates -is [string])) {
        # Explicit array form: each item already carries file/section/key/value.
        foreach ($u in $updates) {
            $sec = "$($u.section)"; $file = "$($u.file)"; $key = "$($u.key)"
            if (-not $key) { continue }
            if (-not $sec -or -not $file) {
                if ($schemaMap.ContainsKey($key)) { if (-not $sec) { $sec = $schemaMap[$key].section }; if (-not $file) { $file = $schemaMap[$key].file } }
            }
            if (-not $sec -or -not $file) { continue }
            $structured.Add(@{ file = $file; section = $sec; key = $key; value = "$($u.value)" })
        }
    } else {
        # Schema-keyed object form: resolve section/file from the schema.
        $keys = if ($updates -is [hashtable]) { $updates.Keys } else { $updates.PSObject.Properties.Name }
        foreach ($k in $keys) {
            if (-not $schemaMap.ContainsKey($k)) { continue }
            $v = if ($updates -is [hashtable]) { $updates[$k] } else { $updates.$k }
            $structured.Add(@{ file = $schemaMap[$k].file; section = $schemaMap[$k].section; key = $k; value = "$v" })
        }
    }

    if ($structured.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'No recognized keys in updates.'
        return
    }

    try {
        Save-DuneGameConfig -Ip $ctx.ip -Updates $structured.ToArray()
        $cfg = Get-DuneGameConfig -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            ok      = $true
            applied = $structured.Count
            source  = $cfg.source
            game    = $cfg.game
            engine  = $cfg.engine
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# GET /api/gameconfig/spicefields — list rows from dune.spicefield_types.
# Returns: { available: true, rows: [ { spicefieldTypeId, mapName, fieldType,
#                                       dimensionIndex,
#                                       maxActive, maxPrimed,
#                                       currentActive, currentPrimed,
#                                       isSpawningActive, spawnWeight } ] }
# 503 when VM not available.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/spicefields' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $raw = Get-V6SpicefieldTypes -Ip $ctx.ip
        $rows = @($raw | ForEach-Object {
            @{
                spicefieldTypeId = [int]$_.spicefield_type_id
                mapName          = "$($_.map_name)"
                fieldType        = "$($_.field_type)"
                dimensionIndex   = [int]$_.dimension_index
                maxActive        = [int]$_.max_globally_active
                maxPrimed        = [int]$_.max_globally_primed
                currentActive    = [int]$_.current_globally_active
                currentPrimed    = [int]$_.current_globally_primed
                isSpawningActive = [bool]$_.is_spawning_active
                spawnWeight      = [double]$_.global_spawn_weight
            }
        })
        Write-DuneJson -Response $res -Body @{ available = $true; rows = $rows }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Spicefield types load failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/gameconfig/spicefields/{id} — update one spicefield_type row.
# Body: { maxActive, maxPrimed, isSpawningActive, spawnWeight }
# Returns the freshly-fetched row.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/gameconfig/spicefields/{id}' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }
    $typeId = 0
    if (-not [int]::TryParse("$($routeParams.id)", [ref]$typeId) -or $typeId -le 0) {
        Write-DuneError -Response $res -Status 400 -Message 'Invalid spicefield_type id.'
        return
    }
    if (-not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object.'
        return
    }
    try {
        $maxA = 0; $maxP = 0; $sw = 0.0
        try { $maxA = [int]$body.maxActive } catch {}
        try { $maxP = [int]$body.maxPrimed } catch {}
        if ($null -ne $body.spawnWeight) {
            try { $sw = [double]::Parse("$($body.spawnWeight)", [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
        }
        $isActive = [bool]$body.isSpawningActive
        Set-V6SpicefieldType -Ip $ctx.ip -TypeId $typeId `
            -MaxActive $maxA -MaxPrimed $maxP `
            -IsSpawningActive $isActive -SpawnWeight $sw

        $rows = Get-V6SpicefieldTypes -Ip $ctx.ip
        $row  = $rows | Where-Object { [int]$_.spicefield_type_id -eq $typeId } | Select-Object -First 1
        if (-not $row) {
            Write-DuneError -Response $res -Status 404 -Message "Spicefield type $typeId not found after update."
            return
        }
        Write-DuneJson -Response $res -Body @{
            ok  = $true
            row = @{
                spicefieldTypeId = [int]$row.spicefield_type_id
                mapName          = "$($row.map_name)"
                fieldType        = "$($row.field_type)"
                dimensionIndex   = [int]$row.dimension_index
                maxActive        = [int]$row.max_globally_active
                maxPrimed        = [int]$row.max_globally_primed
                currentActive    = [int]$row.current_globally_active
                currentPrimed    = [int]$row.current_globally_primed
                isSpawningActive = [bool]$row.is_spawning_active
                spawnWeight      = [double]$row.global_spawn_weight
            }
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Spicefield type save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# PUT /api/gameconfig/spicefields/{id}/spawning — live toggle.
# Body: { "active": true|false }   — must be a JSON boolean. No other shape
# is accepted; null, missing, strings, numbers all 400.
#
# This endpoint exists specifically so the per-row checkbox in the UI can
# commit each click straight to the live DB without involving the bulk
# editor. The DB layer (Set-V6SpicefieldSpawning) only ever mutates
# is_spawning_active for the given spicefield_type_id — no other columns,
# no NULL, only literal TRUE/FALSE.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/gameconfig/spicefields/{id}/spawning' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }

    $typeId = 0
    if (-not [int]::TryParse("$($routeParams.id)", [ref]$typeId) -or $typeId -le 0) {
        Write-DuneError -Response $res -Status 400 -Message 'Invalid spicefield_type id.'
        return
    }
    if (-not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must be a JSON object: { "active": true|false }.'
        return
    }
    if (-not $body.ContainsKey('active')) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include "active" (true|false).'
        return
    }
    $raw = $body['active']
    # STRICT boolean parsing — accept only real JSON booleans. We deliberately
    # do NOT coerce strings/numbers, because the whole point of this endpoint
    # is to guarantee is_spawning_active is set to exactly TRUE or FALSE,
    # never NULL, never some ambiguous truthy value.
    $active = $null
    if ($raw -is [bool]) {
        $active = [bool]$raw
    } elseif ($raw -is [int] -or $raw -is [long]) {
        # Some JSON parsers map JSON true/false to 1/0 — accept only those.
        if ([int]$raw -eq 1) { $active = $true }
        elseif ([int]$raw -eq 0) { $active = $false }
    }
    if ($null -eq $active) {
        Write-DuneError -Response $res -Status 400 -Message '"active" must be a JSON boolean (true or false); null and other values are rejected.'
        return
    }

    try {
        Set-V6SpicefieldSpawning -Ip $ctx.ip -TypeId $typeId -Active $active

        # Read back the canonical row so the UI can refresh state without a
        # full list reload.
        $rows = Get-V6SpicefieldTypes -Ip $ctx.ip
        $row  = $rows | Where-Object { [int]$_.spicefield_type_id -eq $typeId } | Select-Object -First 1
        if (-not $row) {
            Write-DuneError -Response $res -Status 404 -Message "Spicefield type $typeId not found after update."
            return
        }
        Write-DuneJson -Response $res -Body @{
            ok  = $true
            row = @{
                spicefieldTypeId = [int]$row.spicefield_type_id
                mapName          = "$($row.map_name)"
                fieldType        = "$($row.field_type)"
                dimensionIndex   = [int]$row.dimension_index
                maxActive        = [int]$row.max_globally_active
                maxPrimed        = [int]$row.max_globally_primed
                currentActive    = [int]$row.current_globally_active
                currentPrimed    = [int]$row.current_globally_primed
                isSpawningActive = [bool]$row.is_spawning_active
                spawnWeight      = [double]$row.global_spawn_weight
            }
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Spicefield spawning toggle failed: $($_.Exception.Message)"
    }
}
