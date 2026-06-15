# Gameplay API — Players. Read views (list + detail) follow the live/demo +
# `source` convention; write actions require a live DB (no demo writes) and
# mirror the reference implementation's stored procedures. Shared helpers Get-DuneQ /
# Test-DuneDemoRequested come from routes/Gameplay.ps1 (loaded first).

# Read a scalar field from a parsed JSON body (hashtable or PSObject).
function Get-DuneBodyValue {
    param($Body, [string]$Name)
    if ($null -eq $Body) { return $null }
    if ($Body -is [System.Collections.IDictionary]) {
        if ($Body.Contains($Name)) { return $Body[$Name] }
        return $null
    }
    if ($Body.PSObject.Properties[$Name]) { return $Body.$Name }
    return $null
}

function Get-DuneBodyInt {
    param($Body, [string]$Name)
    $v = Get-DuneBodyValue -Body $Body -Name $Name
    $n = 0L
    if ([Int64]::TryParse([string]$v, [ref]$n)) { return $n }
    return $null
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/players  — full character list (live -> demo).
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/players' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'
        $players = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DunePlayersLive -Ip $ctx.ip
                if ($live.ok) { $players = $live.players; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $players) { $players = Get-DunePlayersDemo }
        $out = @{ players = @($players); total = @($players).Count; source = $source }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Players list failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# GET /api/gameplay/players/detail?pawn=<id>&controller=<id>
#   — inventory + specs + currency for one player.
# ---------------------------------------------------------------------------
Register-DuneRoute -Method GET -Path '/api/gameplay/players/detail' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = 0L; $controller = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'pawn'), [ref]$pawn)
        [void][Int64]::TryParse((Get-DuneQ $req 'controller'), [ref]$controller)
        if ($pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn id is required.'; return }

        $source = 'demo'
        $detail = $null
        $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DunePlayerDetailLive -Ip $ctx.ip -PawnId $pawn -ControllerId $controller
                if ($live.ok) { $detail = $live; $source = 'live' }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if ($null -eq $detail) { $detail = Get-DunePlayerDetailDemo -PawnId $pawn }
        $out = @{
            inventory = @($detail.inventory)
            specs     = @($detail.specs)
            currency  = @($detail.currency)
            source    = $source
        }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player detail failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Write actions. All require a live DB; they never touch demo data.
# ---------------------------------------------------------------------------
function Invoke-DunePlayerWriteRoute {
    param($Response, [scriptblock]$Action)
    $ctx = Get-DuneDbContext
    if (-not $ctx.ok) { Write-DuneError -Response $Response -Status 503 -Message $ctx.message; return }
    $result = & $Action $ctx.ip
    if (-not $result.ok) { Write-DuneError -Response $Response -Status 503 -Message $result.error; return }
    Write-DuneJson -Response $Response -Body @{ ok = $true; message = $result.message; result = $result }
}

# POST /api/gameplay/players/give-solari  { controller_id, amount }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-solari' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        $amt = Get-DuneBodyInt -Body $body -Name 'amount'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        if ($null -eq $amt) { Write-DuneError -Response $res -Status 400 -Message 'amount must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveSolari -Ip $ip -ControllerId $cid -Amount $amt }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Give solari failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/give-item  { pawn_id, template, qty, quality, fls_id? }
# v12.0.3 — Auto-routes between online (RMQ ServerCommand, instant) and offline
# (SQL backpack insert, requires relog for online) based on player state.
# - Online + quality<=0     → RMQ live (instant in-game)
# - Online + quality>0      → SQL (preserves quality; player must relog)
# - Offline                 → SQL (will appear on next login)
# Response includes 'path' = 'rmq' | 'sql'. Use /give-item-live for explicit RMQ override.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $tmpl = [string](Get-DuneBodyValue -Body $body -Name 'template')
        $qty  = Get-DuneBodyInt -Body $body -Name 'qty'
        $qual = Get-DuneBodyInt -Body $body -Name 'quality'
        $fls  = [string](Get-DuneBodyValue -Body $body -Name 'fls_id')
        if ($null -eq $qual) { $qual = 0L }
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if (-not $tmpl) { Write-DuneError -Response $res -Status 400 -Message 'template is required.'; return }
        if ($null -eq $qty -or $qty -le 0) { Write-DuneError -Response $res -Status 400 -Message 'qty must be a positive integer.'; return }

        $tv = Test-DuneValidGiveTemplate -TemplateId $tmpl
        if (-not $tv.ok) { Write-DuneError -Response $res -Status 400 -Message $tv.error; return }

        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOffline -Ip $ip -PawnId $pawn
            $isOnline = -not $off.ok
            # Online + default quality → RMQ live (instant, no relog)
            if ($isOnline -and $qual -le 0) {
                $r = Invoke-DunePlayerGiveItemLive -Ip $ip -ActorId $pawn -FlsId $fls -Template $tmpl -Quantity ([int]$qty) -Durability 1.0
                if ($r.ok -and -not $r.path) { $r['path'] = 'rmq' }
                return $r
            }
            # Otherwise SQL (offline, OR online with custom quality)
            $r = Invoke-DunePlayerGiveItem -Ip $ip -PawnId $pawn -Template $tmpl -Qty $qty -Quality $qual
            if ($r.ok) {
                $r['path'] = 'sql'
                if ($isOnline) {
                    $r['message'] = "$($r.message) Player is online — they must relog to see the item (quality $qual cannot be delivered live)."
                }
            }
            return $r
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Give item failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/rename  { account_id, name }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/rename' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'account_id'
        $name = [string](Get-DuneBodyValue -Body $body -Name 'name')
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $name -or -not $name.Trim()) { Write-DuneError -Response $res -Status 400 -Message 'name is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRename -Ip $ip -AccountId $aid -Name $name }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Rename failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/award-xp  { controller_id, track_type, delta }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/award-xp' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        $track = [string](Get-DuneBodyValue -Body $body -Name 'track_type')
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        if (-not $track) { Write-DuneError -Response $res -Status 400 -Message 'track_type is required.'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerAwardXp -Ip $ip -ControllerId $cid -TrackType $track -Delta ([int]$delta) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Award XP failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/delete-item  { item_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/delete-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $iid = Get-DuneBodyInt -Body $body -Name 'item_id'
        if ($null -eq $iid -or $iid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'item_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerDeleteItem -Ip $ip -ItemId $iid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Delete item failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/repair-item  { item_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/repair-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $iid = Get-DuneBodyInt -Body $body -Name 'item_id'
        if ($null -eq $iid -or $iid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'item_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRepairItem -Ip $ip -ItemId $iid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Repair item failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/set-item-durability  { item_id, max, current, decayed }
# Per-item durability editor: writes the three FItemStackAndDurabilityStats
# fields verbatim. Lets the operator override the GREATEST/catalog guess when
# it's wrong. Items without the durability block are left untouched (no-op).
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-item-durability' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $iid = Get-DuneBodyInt -Body $body -Name 'item_id'
        if ($null -eq $iid -or $iid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'item_id is required.'; return }
        $mv = Get-DuneBodyValue -Body $body -Name 'max'
        $cv = Get-DuneBodyValue -Body $body -Name 'current'
        $dv = Get-DuneBodyValue -Body $body -Name 'decayed'
        if ($null -eq $mv -or $null -eq $cv -or $null -eq $dv) {
            Write-DuneError -Response $res -Status 400 -Message 'max, current, and decayed are required.'; return
        }
        $mxd = 0.0; $crd = 0.0; $dcd = 0.0
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        if (-not [double]::TryParse([string]$mv, [System.Globalization.NumberStyles]::Float, $ci, [ref]$mxd)) {
            Write-DuneError -Response $res -Status 400 -Message 'max must be a number.'; return
        }
        if (-not [double]::TryParse([string]$cv, [System.Globalization.NumberStyles]::Float, $ci, [ref]$crd)) {
            Write-DuneError -Response $res -Status 400 -Message 'current must be a number.'; return
        }
        if (-not [double]::TryParse([string]$dv, [System.Globalization.NumberStyles]::Float, $ci, [ref]$dcd)) {
            Write-DuneError -Response $res -Status 400 -Message 'decayed must be a number.'; return
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip)
            Invoke-DunePlayerSetItemDurability -Ip $ip -ItemId $iid -Max $mxd -Current $crd -Decayed $dcd
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set item durability failed: $($_.Exception.Message)"
    }
}

# ===========================================================================
# v11.5.6 — extended player surface routes.
# ===========================================================================

# Helper: run a read with live/demo fallback. $LiveBlock returns @{ok,...},
# $DemoBlock returns the payload directly. Both shapes get wrapped with
# `source` + optional `liveError`.
function Invoke-DunePlayerReadRoute {
    param($Response, $Request, [scriptblock]$LiveBlock, [scriptblock]$DemoBlock, [string]$PayloadKey)
    $source = 'demo'
    $payload = $null
    $liveError = $null
    if (-not (Test-DuneDemoRequested $Request)) {
        $ctx = Get-DuneDbContext
        if ($ctx.ok) {
            $live = & $LiveBlock $ctx.ip
            if ($live -and $live.ok) {
                $payload = $live
                $source = 'live'
            } else { $liveError = if ($live) { $live.error } else { 'no result' } }
        } else { $liveError = $ctx.message }
    }
    if ($null -eq $payload) {
        $demo = & $DemoBlock
        if ($demo -is [System.Collections.IDictionary] -and $demo.Contains('ok')) {
            $payload = $demo
        } else {
            $payload = @{ ok = $true; $PayloadKey = $demo }
        }
    }
    $out = @{}
    foreach ($k in $payload.Keys) { if ($k -ne 'ok' -and $k -ne 'error') { $out[$k] = $payload[$k] } }
    $out['source'] = $source
    if ($liveError) { $out['liveError'] = $liveError }
    Write-DuneJson -Response $Response -Body $out
}

# GET /api/gameplay/players/summary — server-wide dashboard.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/summary' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerSummaryLive -Ip $ip } `
            -DemoBlock { Get-DunePlayerSummaryDemo } `
            -PayloadKey 'summary'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player summary failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/{pawn}/stats — per-player snapshot.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/stats' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'pawn'), [ref]$pawn)
        if ($pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerStatsLive -Ip $ip -PawnId $pawn } `
            -DemoBlock { @{ ok = $true; stats = (Get-DunePlayerStatsDemo -PawnId $pawn) } } `
            -PayloadKey 'stats'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player stats failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/specs?pawn=&controller= — tracks + keystones.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/specs' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = 0L; $controller = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'pawn'),       [ref]$pawn)
        [void][Int64]::TryParse((Get-DuneQ $req 'controller'), [ref]$controller)
        if ($pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerSpecsFullLive -Ip $ip -PawnId $pawn -ControllerId $controller } `
            -DemoBlock { Get-DunePlayerSpecsFullDemo } `
            -PayloadKey 'specs'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player specs failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/grant-max-spec  { controller_id, track_type }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-max-spec' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid   = Get-DuneBodyInt -Body $body -Name 'controller_id'
        $track = [string](Get-DuneBodyValue -Body $body -Name 'track_type')
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        if (-not $track) { Write-DuneError -Response $res -Status 400 -Message 'track_type is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGrantMaxSpec -Ip $ip -ControllerId $cid -TrackType $track }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant max spec failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/reset-spec  { controller_id, track_type }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-spec' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid   = Get-DuneBodyInt -Body $body -Name 'controller_id'
        $track = [string](Get-DuneBodyValue -Body $body -Name 'track_type')
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        if (-not $track) { Write-DuneError -Response $res -Status 400 -Message 'track_type is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetSpec -Ip $ip -ControllerId $cid -TrackType $track }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset spec failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/reset-all-specs  { controller_id } — tracks + keystones.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-all-specs' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetAllSpecs -Ip $ip -ControllerId $cid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset all specs failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/grant-all-keystones  { controller_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-all-keystones' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGrantAllKeystones -Ip $ip -ControllerId $cid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant all keystones failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/reset-all-keystones  { controller_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-all-keystones' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetAllKeystones -Ip $ip -ControllerId $cid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset all keystones failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/tags?account=  — tag list for one account.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/tags' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'account'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerTagsLive -Ip $ip -AccountId $aid } `
            -DemoBlock { @{ ok = $true; tags = (Get-DunePlayerTagsDemo) } } `
            -PayloadKey 'tags'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player tags failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/tags  { account_id, tags: string[] }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/tags' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        $raw = Get-DuneBodyValue -Body $body -Name 'tags'
        $tags = @()
        if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
            foreach ($t in $raw) { $tags += ([string]$t) }
        }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSetTags -Ip $ip -AccountId $aid -Tags $tags }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set player tags failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/events?account=&limit=  — history.
Register-DuneRoute -Method GET -Path '/api/gameplay/players/events' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L; $limit = 100
        [void][Int64]::TryParse((Get-DuneQ $req 'account'), [ref]$aid)
        [void][Int32]::TryParse((Get-DuneQ $req 'limit'),   [ref]$limit)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Get-DunePlayerEventsLive -Ip $ip -AccountId $aid -Limit $limit } `
            -DemoBlock { @{ ok = $true; events = (Get-DunePlayerEventsDemo) } } `
            -PayloadKey 'events'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Player events failed: $($_.Exception.Message)"
    }
}


# v11.5.7+v11.5.9 — POST /api/gameplay/players/fill-water  { pawn_id|actor_id|fls_id, water_amount? }
# Online players: RMQ UpdateAllWaterFillables (live, via mq-game broker).
# Offline players: SQL UPDATE of FFillableItemStats CurrentAmount = MaxAmount.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/fill-water' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        if (-not $pawn) { $pawn = Get-DuneBodyInt -Body $body -Name 'actor_id' }
        if (-not $pawn) { $pawn = Get-DuneBodyInt -Body $body -Name 'id' }
        $fls  = [string](Get-DuneBodyValue -Body $body -Name 'fls_id')
        if ((-not $pawn -or $pawn -le 0) -and [string]::IsNullOrWhiteSpace($fls)) {
            Write-DuneError -Response $res -Status 400 -Message 'pawn_id (actor id) or fls_id is required.'
            return
        }
        $amt = Get-DuneBodyInt -Body $body -Name 'water_amount'
        if ($null -eq $amt -or $amt -le 0) { $amt = 1000000 }

        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            # Online path when fls_id supplied or pawn online.
            if (-not [string]::IsNullOrWhiteSpace($fls)) {
                return Invoke-DunePlayerFillWaterLive -Ip $ip -FlsId $fls -WaterAmount ([int]$amt)
            }
            $off = Test-DunePlayerOffline -Ip $ip -PawnId $pawn
            if (-not $off.ok) {
                return Invoke-DunePlayerFillWaterLive -Ip $ip -ActorId $pawn -WaterAmount ([int]$amt)
            }
            # Offline: existing SQL refill (per-item MaxAmount).
            Invoke-DunePlayerFillWater -Ip $ip -PawnId $pawn
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Fill water failed: $($_.Exception.Message)"
    }
}

# v12.1.2: Fill Base Water route removed - see CHANGELOG. Stub kept above to
# return 410 Gone for any cached UI references; safe to delete once UIs roll.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/fill-base-water-removed-in-v12.1.2' -Handler {
    param($req, $res, $routeParams, $body)
    # Fill Base Water was investigated in v12.1.2 and removed - see CHANGELOG.
    # The pod holds cistern water in RAM and overwrites our DB writes on its
    # periodic save, so neither the RMQ ServerCommand path nor a direct DB
    # write can move the in-game value while the map pod is running.
    Write-DuneError -Response $res -Status 410 -Message 'Fill Base Water was removed in v12.1.2 - cistern water is owned by the live pod and overwrites DB writes. See CHANGELOG for details.'
}
