# Gameplay API — Players. Read views (list + detail) follow the live/demo +
# `source` convention; write actions require a live DB (no demo writes) and
# mirror dune-admin's stored procedures. Shared helpers Get-DuneQ /
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

# POST /api/gameplay/players/give-item  { pawn_id, template, qty, quality }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-item' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $tmpl = [string](Get-DuneBodyValue -Body $body -Name 'template')
        $qty  = Get-DuneBodyInt -Body $body -Name 'qty'
        $qual = Get-DuneBodyInt -Body $body -Name 'quality'
        if ($null -eq $qual) { $qual = 0L }
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if (-not $tmpl) { Write-DuneError -Response $res -Status 400 -Message 'template is required.'; return }
        if ($null -eq $qty -or $qty -le 0) { Write-DuneError -Response $res -Status 400 -Message 'qty must be a positive integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveItem -Ip $ip -PawnId $pawn -Template $tmpl -Qty $qty -Quality $qual }
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

# POST /api/gameplay/players/award-xp  { pawn_id, track_type, delta }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/award-xp' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $track = [string](Get-DuneBodyValue -Body $body -Name 'track_type')
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if (-not $track) { Write-DuneError -Response $res -Status 400 -Message 'track_type is required.'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerAwardXp -Ip $ip -PawnId $pawn -TrackType $track -Delta ([int]$delta) }
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
