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
