# PlayersAdmin.ps1 — v11.5.9 player admin routes ported from dune-admin §2 + §7.
# Currency / progression writes + returning-player-award + delete-account.
# Uses Invoke-DunePlayerWriteRoute + Get-DuneBodyInt/Value from routes/GameplayPlayers.ps1.

# POST /api/gameplay/players/give-scrip  { actor_id, delta, currency_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-scrip' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        $cid = Get-DuneBodyInt -Body $body -Name 'currency_id'
        if ($null -eq $cid) { $cid = 0L }
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveScrip -Ip $ip -ActorId $aid -Delta $delta -CurrencyIdOverride ([int]$cid) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Give scrip failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/give-faction-rep  { actor_id, faction_id, delta }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-faction-rep' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $fid = Get-DuneBodyInt -Body $body -Name 'faction_id'
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        if ($null -eq $fid -or $fid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'faction_id is required (1=Atreides, 2=Harkonnen, 4=Smuggler).'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveFactionRep -Ip $ip -ActorId $aid -FactionId ([int]$fid) -Delta ([int]$delta) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Give faction rep failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/set-faction-tier  { actor_id, faction_id, tier }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-faction-tier' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $fid = Get-DuneBodyInt -Body $body -Name 'faction_id'
        $tier = Get-DuneBodyInt -Body $body -Name 'tier'
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        if ($null -eq $fid -or $fid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'faction_id is required.'; return }
        if ($null -eq $tier) { Write-DuneError -Response $res -Status 400 -Message 'tier (0..20) is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSetFactionTier -Ip $ip -ActorId $aid -FactionId ([int]$fid) -Tier ([int]$tier) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set faction tier failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/award-char-xp  { pawn_id, delta }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/award-char-xp' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerAwardCharXp -Ip $ip -PawnId $pawn -XpDelta $delta }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Award char XP failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/award-intel  { actor_id?, pawn_id?, delta }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/award-intel' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $delta = Get-DuneBodyInt -Body $body -Name 'delta'
        if ($null -eq $aid) { $aid = 0L }
        if ($null -eq $pawn) { $pawn = 0L }
        if ($aid -le 0 -and $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id or pawn_id is required.'; return }
        if ($null -eq $delta) { Write-DuneError -Response $res -Status 400 -Message 'delta must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerAwardIntel -Ip $ip -ActorId $aid -PawnId $pawn -IntelDelta ([int]$delta) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Award intel failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/char-xp?actor_id=<id>
Register-DuneRoute -Method GET -Path '/api/gameplay/players/char-xp' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'actor_id'), [ref]$aid)
        if ($aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        Invoke-DunePlayerReadRoute -Response $res -Request $req `
            -LiveBlock { param($ip) Invoke-DunePlayerGetCharXp -Ip $ip -ActorId $aid } `
            -DemoBlock { @{ ok = $true; actor_id = $aid; xp = 0; level = 0; skill_points_spent = 0; skill_points_total = 0 } } `
            -PayloadKey 'char_xp'
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Get char XP failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/returning-player-award  { account_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/returning-player-award' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGrantReturningAward -Ip $ip -AccountId $aid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant returning award failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/dismiss-returning-player-award  { account_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/dismiss-returning-player-award' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerDismissReturningAward -Ip $ip -AccountId $aid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Dismiss returning award failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/delete-account  { account_id, confirm }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/delete-account' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'account_id'
        $confirm = [string](Get-DuneBodyValue -Body $body -Name 'confirm')
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if ($confirm -ne 'DELETE') { Write-DuneError -Response $res -Status 400 -Message 'confirm must equal "DELETE" to authorize this destructive action.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerDeleteAccount -Ip $ip -AccountId $aid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Delete account failed: $($_.Exception.Message)"
    }
}
