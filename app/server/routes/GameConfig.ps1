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
