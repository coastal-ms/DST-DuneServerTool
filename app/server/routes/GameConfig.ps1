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
# Body: { updates: { "<key>": "<value>", ... } }
# We figure out which file each key belongs to from the schema; unknown keys
# are silently dropped (defends against client bugs / stale schemas).
# Returns the freshly-fetched config so the client can refresh its state.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method PUT -Path '/api/gameconfig' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }

    # Parse updates from body
    $updates = $null
    if ($body -is [hashtable] -and $body.ContainsKey('updates')) { $updates = $body.updates }
    elseif ($body.updates) { $updates = $body.updates }
    if (-not $updates) {
        Write-DuneError -Response $res -Status 400 -Message 'Body must include an "updates" object.'
        return
    }

    $keyFile = Get-DuneGameConfigKeyFileMap
    $gameUpdates   = @{}
    $engineUpdates = @{}
    $keys = if ($updates -is [hashtable]) { $updates.Keys } else { $updates.PSObject.Properties.Name }
    foreach ($k in $keys) {
        if (-not $keyFile.ContainsKey($k)) { continue }
        $v = if ($updates -is [hashtable]) { $updates[$k] } else { $updates.$k }
        switch ($keyFile[$k]) {
            'game'   { $gameUpdates[$k]   = $v }
            'engine' { $engineUpdates[$k] = $v }
        }
    }

    if ($gameUpdates.Count -eq 0 -and $engineUpdates.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'No recognized keys in updates.'
        return
    }

    try {
        Save-DuneGameConfig -Ip $ctx.ip -GameUpdates $gameUpdates -EngineUpdates $engineUpdates
        # Return freshly-fetched config so the client can sync its state.
        $cfg = Get-DuneGameConfig -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            ok        = $true
            applied   = @{ game = $gameUpdates.Count; engine = $engineUpdates.Count }
            source    = $cfg.source
            game      = $cfg.game
            engine    = $cfg.engine
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
