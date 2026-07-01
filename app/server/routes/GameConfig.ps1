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
# GET /api/gameconfig/defaults — full settings catalog from the live image.
# Reads DefaultGame.ini + DefaultEngine.ini out of a running game-server pod
# (cached per process), merges with the current User*.ini overrides, and
# returns every section as { name, file, count, overriddenCount, keys[] }.
# Pass ?refresh=1 to force a re-read of the pod files (e.g. after a game patch).
# 503 when VM not available; 500 on read failure.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/defaults' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $force = $false
        try {
            $v = $req.QueryString['refresh']
            if ($v -and ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes')) { $force = $true }
        } catch {}
        $cat = Get-DuneGameConfigCatalog -Ip $ctx.ip -ForceDefaults:$force
        Write-DuneJson -Response $res -Body @{
            available = $true
            cached    = $cat.cached
            source    = $cat.source
            sections  = $cat.sections
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Defaults catalog load failed: $($_.Exception.Message)"
    }
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
# absorption); any pre-existing the reference implementation block is migrated. Returns the
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
            $rm = (Test-DuneGameConfigValueIsDefault -Key $key -Value "$($u.value)")
            $structured.Add(@{ file = $file; section = $sec; key = $key; value = "$($u.value)"; remove = $rm })
        }
    } else {
        # Schema-keyed object form: resolve section/file from the schema.
        $keys = if ($updates -is [hashtable]) { $updates.Keys } else { $updates.PSObject.Properties.Name }
        foreach ($k in $keys) {
            if (-not $schemaMap.ContainsKey($k)) { continue }
            $v = if ($updates -is [hashtable]) { $updates[$k] } else { $updates.$k }
            $rm = (Test-DuneGameConfigValueIsDefault -Key $k -Value "$v")
            $structured.Add(@{ file = $schemaMap[$k].file; section = $schemaMap[$k].section; key = $k; value = "$v"; remove = $rm })
        }
    }

    if ($structured.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'No recognized keys in updates.'
        return
    }

    try {
        Save-DuneGameConfig -Ip $ctx.ip -Updates $structured.ToArray()
        $cfg = Get-DuneGameConfig -Ip $ctx.ip
        $clientApply = Get-DuneGameConfigClientApplyNotice -Updates $structured.ToArray()
        Write-DuneJson -Response $res -Body @{
            ok          = $true
            applied     = $structured.Count
            source      = $cfg.source
            game        = $cfg.game
            engine      = $cfg.engine
            clientApply = $clientApply
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config save failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST /api/gameconfig/backup — snapshot the live INI files before editing.
# Copies each live file to "<path>.dstbak-<timestamp>" on the BG VM (read-only
# copy; no settings are changed). Returns the backup paths so the user has a
# restore point. 503 when VM not available.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameconfig/backup' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $r = Backup-DuneGameConfig -Ip $ctx.ip
        $allOk = (@($r.files | Where-Object { -not $_.ok }).Count -eq 0)
        Write-DuneJson -Response $res -Body @{
            ok        = $allOk
            timestamp = $r.timestamp
            source    = $r.source
            files     = $r.files
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config backup failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# GET /api/gameconfig/backups — list existing DST backups for the live INI files.
# Returns the most-recent ".dstbak-<ts>" snapshots next to UserGame/UserEngine.ini
# so the user can locate a restore point. 503 when VM not available.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/backups' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    try {
        $r = Get-DuneGameConfigBackups -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            available = $true
            source    = $r.source
            backups   = $r.backups
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config backup list failed: $($_.Exception.Message)"
    }
}

# POST /api/gameconfig/backups/delete — delete selected DST backup files.
# Body: { paths: ["<full path>.dstbak-<ts>", ...] }. Paths are validated
# server-side to the .dstbak pattern next to the live INI files. 503 w/o VM.
Register-DuneRoute -Method POST -Path '/api/gameconfig/backups/delete' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    if ($body -is [hashtable]) {
        $raw = $body['paths']
        if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
            foreach ($p in $raw) { $s = "$p".Trim(); if ($s) { $paths.Add($s) } }
        }
    }
    if ($paths.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'No backup paths supplied.'
        return
    }
    try {
        $r = Remove-DuneGameConfigBackups -Ip $ctx.ip -Paths $paths.ToArray()
        Write-DuneJson -Response $res -Body @{
            ok      = $true
            deleted = $r.deleted
            results = $r.results
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Game config backup delete failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# LOCAL CLIENT CONFIG endpoints. These run on the admin's own machine (no SSH /
# no VM context needed) and operate on the player's client Game.ini.
#
# GET  /api/gameconfig/client      — read the local client config + folder info.
# PUT  /api/gameconfig/client/dir  — persist the client-config FOLDER. { dir }
# PUT  /api/gameconfig/client/apply— upsert ClientApply keys into the local file.
#                                     { updates: [ { key, value }, ... ], dir? }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/client' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneGameConfigClient)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Client config read failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameconfig/client/dir' -Handler {
    param($req, $res, $routeParams, $body)
    $dir = ''
    if ($body -is [hashtable] -and $body.Contains('dir')) { $dir = "$($body['dir'])".Trim() }
    if (-not $dir) {
        Write-DuneError -Response $res -Status 400 -Message 'Missing dir.'
        return
    }
    $resolved = [Environment]::ExpandEnvironmentVariables($dir)
    if (-not (Test-Path -LiteralPath $resolved)) {
        Write-DuneError -Response $res -Status 400 -Message "Folder does not exist: $resolved"
        return
    }
    try {
        $null = Invoke-WithDuneLock -Name 'config' -Script { Save-DuneConfig -Config @{ ClientConfigPath = $dir } }
        Write-DuneJson -Response $res -Body (Get-DuneGameConfigClient)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Saving client config folder failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameconfig/client/apply' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not $body -or -not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'
        return
    }
    $dir     = if ($body.Contains('dir')) { "$($body['dir'])".Trim() } else { '' }
    $updates = New-Object 'System.Collections.Generic.List[object]'
    $raw = $body['updates']
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string]) -and -not ($raw -is [hashtable])) {
        foreach ($u in $raw) {
            $k = if ($u -is [hashtable]) { "$($u['key'])" } else { "$($u.key)" }
            $v = if ($u -is [hashtable]) { "$($u['value'])" } else { "$($u.value)" }
            if ($k) { $updates.Add(@{ key = $k; value = $v }) }
        }
    }
    if ($updates.Count -eq 0) {
        Write-DuneError -Response $res -Status 400 -Message 'No updates supplied.'
        return
    }
    try {
        # Seed-from-defaults needs DefaultGame.ini (a live pod read); only pay for
        # it when a Landsraad-style struct member is actually being applied, and
        # tolerate failure so non-struct client edits still apply offline.
        $defaultsRaw = ''
        if (Test-DuneUpdatesHaveStructMember -Updates $updates.ToArray()) {
            try {
                $ctx = Get-DuneGameConfigContext
                if ($ctx.ok) { $defaultsRaw = "$((Get-DuneGameConfigDefaults -Ip $ctx.ip).game)" }
            } catch { $defaultsRaw = '' }
        }
        $r = Save-DuneGameConfigClient -Updates $updates.ToArray() -Dir $dir -DefaultsRaw $defaultsRaw
        $client = Get-DuneGameConfigClient -Dir $dir
        Write-DuneJson -Response $res -Body @{
            ok      = $true
            path    = $r.path
            backup  = $r.backup
            created = $r.created
            applied = $r.applied
            items   = $r.items
            client  = $client
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Applying to client config failed: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# POST /api/gameconfig/client/open — open the local client Game.ini in Notepad
# on this PC (DST runs locally). Body (optional): { dir }
# -----------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameconfig/client/open' -Handler {
    param($req, $res, $routeParams, $body)
    $dir = ''
    if ($body -is [hashtable] -and $body.Contains('dir')) { $dir = "$($body['dir'])".Trim() }
    try {
        $resolvedDir = Resolve-DuneGameConfigClientDir -Dir $dir
        if (-not (Test-Path -LiteralPath $resolvedDir)) {
            Write-DuneError -Response $res -Status 400 -Message "Client config folder not found: $resolvedDir"
            return
        }
        $path = Get-DuneGameConfigClientFilePath -Dir $dir
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$path`""
        Write-DuneJson -Response $res -Body @{ ok = $true; path = $path }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Opening client config failed: $($_.Exception.Message)"
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

# -----------------------------------------------------------------------------
# Land-claim (staking unit) extension timer.
# GET /api/gameconfig/landclaim-timer  — current server + client state.
#   { server:{available,enabled,seconds,formattedOk,...}, client:{exists,enabled,seconds,...} }
# PUT /api/gameconfig/landclaim-timer  — { enabled: bool, seconds: number }
#   Writes both the server UserGame.ini and the local client Game.ini.
# -----------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameconfig/landclaim-timer' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneGameConfigContext
        if ($ctx.ok) {
            Write-DuneJson -Response $res -Body (Get-DuneLandclaimTimer -Ip $ctx.ip)
        } else {
            # VM unavailable: still surface the local client Game.ini state.
            $client = Get-DuneGameConfigClient
            $cst    = Get-DuneLandclaimTimerState -Raw $client.raw
            Write-DuneJson -Response $res -Body @{
                server = @{ available = $false; enabled = $false; seconds = ''; formattedOk = $false; reason = $ctx.message }
                client = @{ exists = [bool]$client.exists; dirExists = [bool]$client.dirExists; path = $client.path; dir = $client.dir; enabled = $cst.enabled; seconds = $cst.seconds; formattedOk = $cst.formattedOk }
                clientBlock = (Get-DuneLandclaimClientBlock -Seconds ($(if ($cst.enabled) { $cst.seconds } else { '' })))
            }
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Land-claim timer read failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method PUT -Path '/api/gameconfig/landclaim-timer' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) {
        Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message
        return
    }
    if (-not (Test-DunePlayerGuard -Req $req -Res $res -Ip $ctx.ip)) { return }
    if (-not $body -or -not ($body -is [hashtable])) {
        Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'
        return
    }

    $enabled = $false
    if ($body.Contains('enabled')) { $enabled = [bool]$body['enabled'] }

    $seconds = ''
    if ($enabled) {
        $secRaw = if ($body.Contains('seconds')) { "$($body['seconds'])".Trim() } else { '' }
        $parsed = 0.0
        if (-not [double]::TryParse($secRaw, [ref]$parsed) -or $parsed -le 0) {
            Write-DuneError -Response $res -Status 400 -Message 'Enter a positive number of seconds for the land-claim timer.'
            return
        }
        $seconds = $secRaw
    }

    try {
        $r      = Set-DuneLandclaimTimer -Ip $ctx.ip -Enabled $enabled -Seconds $seconds
        $state  = Get-DuneLandclaimTimer -Ip $ctx.ip
        Write-DuneJson -Response $res -Body @{
            ok          = $true
            enabled     = $enabled
            seconds     = $seconds
            result      = $r
            server      = $state.server
            client      = $state.client
            clientBlock = $state.clientBlock
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Land-claim timer save failed: $($_.Exception.Message)"
    }
}
