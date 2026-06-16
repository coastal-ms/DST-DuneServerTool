# Gameplay API — World (Bases, Storage, Blueprints). Read-only views following
# the live/demo + `source` convention. Shared helpers Get-DuneQ /
# Test-DuneDemoRequested come from routes/Gameplay.ps1 (loaded first).

# ---------------------------------------------------------------------------
# GET /api/gameplay/bases  — base list (live -> demo).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/bases' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'; $bases = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneBasesLive -Ip $ctx.ip
                if ($live.ok) { $bases = $live.bases; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $bases) { $bases = Get-DuneBasesDemo }
        $out = @{ bases = @($bases); total = @($bases).Count; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Bases list failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/storage  — storage container list (live -> demo).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/storage' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'; $containers = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneStorageLive -Ip $ctx.ip
                if ($live.ok) { $containers = $live.containers; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $containers) { $containers = Get-DuneStorageDemo }
        $out = @{ containers = @($containers); total = @($containers).Count; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage list failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/storage/items?id=<containerId>  — container contents.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/storage/items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'id'), [ref]$cid)
        if ($cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'container id is required.'; return }

        $source = 'demo'; $items = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneStorageItemsLive -Ip $ctx.ip -ContainerId $cid
                if ($live.ok) { $items = $live.items; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $items) { $items = (Get-DuneStorageItemsDemo -ContainerId $cid).items }
        $out = @{ items = @($items); source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage items failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/blueprints  — blueprint list (live -> demo).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/blueprints' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'; $blueprints = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneBlueprintsLive -Ip $ctx.ip
                if ($live.ok) { $blueprints = $live.blueprints; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $blueprints) { $blueprints = Get-DuneBlueprintsDemo }
        $out = @{ blueprints = @($blueprints); total = @($blueprints).Count; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Blueprints list failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/blueprints/export?id=<blueprintId>  — portable JSON file
# (live -> demo). Frontend downloads the `blueprint` object as `filename`.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/blueprints/export' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $id = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'id'), [ref]$id)
        if ($id -le 0) { Write-DuneError -Response $res -Status 400 -Message 'blueprint id is required.'; return }

        $source = 'demo'; $bp = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneBlueprintExportLive -Ip $ctx.ip -BlueprintId $id
                if ($live.ok) { $bp = $live.blueprint; $source = 'live' } else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $bp) { $bp = Get-DuneBlueprintExportDemo -BlueprintId $id }
        $name = [string]$bp['name']
        $out = @{ blueprint = $bp; filename = (Get-DuneBlueprintFilename -Name $name -Id $id); source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Blueprint export failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# POST /api/gameplay/blueprints/import  { player_id, blueprint }
#   — recreate the blueprint in a player's backpack. Live DB required; the
#   player must be offline.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method POST -Path '/api/gameplay/blueprints/import' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $playerId = Get-DuneBodyInt -Body $body -Name 'player_id'
        $bp  = Get-DuneBodyValue -Body $body -Name 'blueprint'
        if ($null -eq $playerId -or $playerId -le 0) { Write-DuneError -Response $res -Status 400 -Message 'player_id is required.'; return }
        if ($null -eq $bp) { Write-DuneError -Response $res -Status 400 -Message 'blueprint is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Import-DuneBlueprintLive -Ip $ip -PlayerPawnId $playerId -Blueprint $bp }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Blueprint import failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/bases/export?id=<baseId>  — base recentered as a blueprint
# JSON file (live -> demo). Frontend downloads the `blueprint` object.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/bases/export' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $id = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'id'), [ref]$id)
        if ($id -le 0) { Write-DuneError -Response $res -Status 400 -Message 'base id is required.'; return }

        $source = 'demo'; $bp = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneBaseExportLive -Ip $ctx.ip -BaseId $id
                if ($live.ok) { $bp = $live.blueprint; $source = 'live' } else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $bp) { $bp = Get-DuneBaseExportDemo -BaseId $id }
        $out = @{ blueprint = $bp; filename = "base_$id.json"; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Base export failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Storage write actions. Live DB required (no demo writes). Items added/removed
# only become visible to other players after a server zone restart.
# ---------------------------------------------------------------------------

# POST /api/gameplay/storage/give-item  { container_id, template, qty, quality }
Register-DuneRoute -Method POST -Path '/api/gameplay/storage/give-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid  = Get-DuneBodyInt -Body $body -Name 'container_id'
        $tmpl = [string](Get-DuneBodyValue -Body $body -Name 'template')
        $qty  = Get-DuneBodyInt -Body $body -Name 'qty'
        $qual = Get-DuneBodyInt -Body $body -Name 'quality'
        if ($null -eq $qual) { $qual = 0L }
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'container_id is required.'; return }
        if (-not $tmpl) { Write-DuneError -Response $res -Status 400 -Message 'template is required.'; return }
        if ($null -eq $qty -or $qty -le 0) { $qty = 1L }
        $tv = Test-DuneValidGiveTemplate -TemplateId $tmpl
        if (-not $tv.ok) { Write-DuneError -Response $res -Status 400 -Message $tv.error; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneStorageGiveItem -Ip $ip -ContainerId $cid -Template $tmpl -Qty $qty -Quality $qual }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage give item failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/storage/give-items  { container_id, items: [{template,qty,quality}] }
Register-DuneRoute -Method POST -Path '/api/gameplay/storage/give-items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid   = Get-DuneBodyInt -Body $body -Name 'container_id'
        $items = Get-DuneBodyValue -Body $body -Name 'items'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'container_id is required.'; return }
        if ($null -eq $items -or @($items).Count -eq 0) { Write-DuneError -Response $res -Status 400 -Message 'items is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneStorageGiveItems -Ip $ip -ContainerId $cid -Items $items }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage give items failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/storage/delete-item  { item_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/storage/delete-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $iid = Get-DuneBodyInt -Body $body -Name 'item_id'
        if ($null -eq $iid -or $iid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'item_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneStorageDeleteItem -Ip $ip -ItemId $iid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage delete item failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/storage/set-item-stack  { item_id, stack_size }
# Per-item stack-quantity editor for container contents. stack_size is a plain
# bigint column, so this just rewrites it. The new value only appears in-game
# after a server zone (battlegroup) restart.
Register-DuneRoute -Method POST -Path '/api/gameplay/storage/set-item-stack' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $iid = Get-DuneBodyInt -Body $body -Name 'item_id'
        $ss  = Get-DuneBodyInt -Body $body -Name 'stack_size'
        if ($null -eq $iid -or $iid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'item_id is required.'; return }
        if ($null -eq $ss -or $ss -lt 1) { Write-DuneError -Response $res -Status 400 -Message 'stack_size must be at least 1.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneStorageSetItemStack -Ip $ip -ItemId $iid -StackSize $ss }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Storage set item stack failed: $($_.Exception.Message)"
    }
}
