# PlayersRead.ps1 — v11.5.9 read routes ported from the reference implementation §1.
# Each route uses Invoke-DunePlayerReadRoute (live + demo fallback) so demo
# requests still get a usable empty / stub payload.

# GET /api/gameplay/players/online
Register-DuneRoute -Method GET -Path '/api/gameplay/players/online' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayersOnlineLive -Ip $ip } `
            -DemoBlock { @{ ok = $true; players = @(); total = 0 } } `
            -PayloadKey 'players'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Online players failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/factions
Register-DuneRoute -Method GET -Path '/api/gameplay/players/factions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerFactionsLive -Ip $ip } `
            -DemoBlock { @{ ok = $true; factions = @(); scrip_currency_id = -1 } } `
            -PayloadKey 'factions'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Factions failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/specs
Register-DuneRoute -Method GET -Path '/api/gameplay/players/specs' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerSpecsLive -Ip $ip } `
            -DemoBlock { @{ ok = $true; specs = @() } } `
            -PayloadKey 'specs'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Specs failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/journey?account_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/journey' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'account_id'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerJourneyLive -Ip $ip -AccountId $aid } `
            -DemoBlock { @{ ok = $true; nodes = @(); total = 0 } } `
            -PayloadKey 'nodes'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Journey failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/export?account_id=<id>  — returns JSON envelope
#   { export_json: "<character JSON>", account_id, funcom_id }
Register-DuneRoute -Method GET -Path '/api/gameplay/players/export' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'account_id'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerExportLive -Ip $ip -AccountId $aid } `
            -DemoBlock { @{ ok = $true; export_json = '{}'; account_id = $aid; funcom_id = '' } } `
            -PayloadKey 'export'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Export failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/keystones?player_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/keystones' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        # $playerId, not $pid — $PID is a read-only automatic variable.
        $playerId = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'player_id'), [ref]$playerId)
        if ($playerId -le 0) { Write-DuneError -Response $res -Status 400 -Message 'player_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerKeystonesLive -Ip $ip -PlayerId $playerId } `
            -DemoBlock { @{ ok = $true; keystones = @(); total = 0 } } `
            -PayloadKey 'keystones'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Keystones failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/vehicles?controller_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/vehicles' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'controller_id'), [ref]$cid)
        if ($cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerVehiclesLive -Ip $ip -ControllerId $cid } `
            -DemoBlock { @{ ok = $true; vehicles = @(); total = 0 } } `
            -PayloadKey 'vehicles'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicles failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/dungeons?player_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/dungeons' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        # $playerId, not $pid — $PID is a read-only automatic variable.
        $playerId = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'player_id'), [ref]$playerId)
        if ($playerId -le 0) { Write-DuneError -Response $res -Status 400 -Message 'player_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerDungeonsLive -Ip $ip -PlayerId $playerId } `
            -DemoBlock { @{ ok = $true; dungeons = @(); total = 0 } } `
            -PayloadKey 'dungeons'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Dungeons failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/player-ids?actor_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/player-ids' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'actor_id'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerIdsLive -Ip $ip -ActorId $aid } `
            -DemoBlock { @{ ok = $true; actor_id = $aid; display_name = ''; hex_id = ''; account_id = 0 } } `
            -PayloadKey 'player_ids'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player IDs failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/partitions  (teleport location catalog)
Register-DuneRoute -Method GET -Path '/api/gameplay/players/partitions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DunePartitionsCatalog
        Write-DuneJson -Response $res -Body @{
            partitions = $payload.partitions
            total      = $payload.total
            source     = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Partitions failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/trainers  (skill-trainer quest line catalog)
Register-DuneRoute -Method GET -Path '/api/gameplay/players/trainers' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DuneTrainerCatalog
        Write-DuneJson -Response $res -Body @{
            trainers = $payload.trainers
            total    = $payload.total
            source   = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Trainers failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/trainer-status?account_id=<id>
#   Per-character skill-tree ownership for the Unlock Trainers UI.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/trainer-status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'account_id'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerTrainerStatusLive -Ip $ip -AccountId $aid } `
            -DemoBlock { @{ ok = $true; account_id = $aid; has_pawn = $false; jobs = @(); total = 0 } } `
            -PayloadKey 'jobs'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Trainer status failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/main-quests  (main-quest story line catalog)
Register-DuneRoute -Method GET -Path '/api/gameplay/players/main-quests' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DuneMainQuestCatalog
        Write-DuneJson -Response $res -Body @{
            main_quests = $payload.main_quests
            total       = $payload.total
            source      = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Main quests failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/tags/catalog  (known gameplay tag universe for the Tags editor typeahead)
Register-DuneRoute -Method GET -Path '/api/gameplay/tags/catalog' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DuneTagCatalog
        Write-DuneJson -Response $res -Body @{
            tags   = $payload.tags
            total  = $payload.total
            source = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Tag catalog failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/contracts  (contract tag catalog)
Register-DuneRoute -Method GET -Path '/api/gameplay/contracts' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DuneContractCatalog
        Write-DuneJson -Response $res -Body @{
            contracts = $payload.contracts
            total     = $payload.total
            source    = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Contracts failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/progression/presets  (progression preset bundles)
Register-DuneRoute -Method GET -Path '/api/gameplay/progression/presets' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $payload = Get-DuneProgressionPresetsCatalog
        Write-DuneJson -Response $res -Body @{
            presets = $payload.presets
            total   = $payload.total
            source  = 'catalog'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Progression presets failed: $($_.Exception.Message)"
    }
}
