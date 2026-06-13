# PlayersWrites.ps1 — v11.5.9 player write routes ported from dune-admin.
# Wires Phase C/D/E/F endpoints onto the HTTP server. All routes use
# Invoke-DunePlayerWriteRoute + Get-DuneBodyInt/Value from routes/GameplayPlayers.ps1.

# ---------------------------------------------------------------------------
# §3 — Items / inventory
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/give-items  { pawn_id, items:[{template,qty,quality}] }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $items = Get-DuneBodyValue -Body $body -Name 'items'
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if ($null -eq $items) { Write-DuneError -Response $res -Status 400 -Message 'items[] is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveItemsBulk -Ip $ip -PawnId $pawn -Items $items }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Give items failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/repair-gear  { pawn_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/repair-gear' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRepairGear -Ip $ip -PawnId $pawn }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Repair gear failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/restore-destroyed  { pawn_id }
# Sister of repair-gear that targets items where CurrentDurability is 0 or NULL
# (Chopper's "completely dead" case). Same gear-slot scope. Re-seeds durability
# stats; also grafts the FItemStackAndDurabilityStats block when missing.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/restore-destroyed' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRestoreDestroyedGear -Ip $ip -PawnId $pawn }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Restore destroyed failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# §4 — Vehicles
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/repair-vehicle  { vehicle_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/repair-vehicle' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vid = Get-DuneBodyInt -Body $body -Name 'vehicle_id'
        if ($null -eq $vid -or $vid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'vehicle_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneVehicleRepair -Ip $ip -VehicleId $vid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Repair vehicle failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/refuel-vehicle  { vehicle_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/refuel-vehicle' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vid = Get-DuneBodyInt -Body $body -Name 'vehicle_id'
        if ($null -eq $vid -or $vid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'vehicle_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneVehicleRefuel -Ip $ip -VehicleId $vid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Refuel vehicle failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# §5 — Teleport (offline path; online path deferred to RMQ phase)
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/teleport-to-player  { source_pawn_id, target_pawn_id, partition_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/teleport-to-player' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $src = Get-DuneBodyInt -Body $body -Name 'source_pawn_id'
        $tgt = Get-DuneBodyInt -Body $body -Name 'target_pawn_id'
        $partN = Get-DuneBodyInt -Body $body -Name 'partition_id'
        if ($null -eq $src -or $src -le 0) { Write-DuneError -Response $res -Status 400 -Message 'source_pawn_id is required.'; return }
        if ($null -eq $tgt -or $tgt -le 0) { Write-DuneError -Response $res -Status 400 -Message 'target_pawn_id is required.'; return }
        $partition = if ($null -eq $partN) { $null } else { [Nullable[long]]([long]$partN) }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerTeleportToPlayer -Ip $ip -SourcePawnId $src -TargetPawnId $tgt -PartitionId $partition }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Teleport failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# §6 — Progression / journey / contracts / jobs / codex / tutorials
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/progression-unlock  { actor_id, faction, preset }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/progression-unlock' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $fac = [string](Get-DuneBodyValue -Body $body -Name 'faction')
        $pre = [string](Get-DuneBodyValue -Body $body -Name 'preset')
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        if (-not $fac) { Write-DuneError -Response $res -Status 400 -Message 'faction is required (atreides|harkonnen).'; return }
        if (-not $pre) { Write-DuneError -Response $res -Status 400 -Message 'preset is required (ch3_start|rank19_eligible).'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerProgressionUnlock -Ip $ip -ActorId $aid -Faction $fac -Preset $pre }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Progression unlock failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/progression-reverse  { actor_id, faction, preset }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/progression-reverse' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $aid = Get-DuneBodyInt -Body $body -Name 'actor_id'
        $fac = [string](Get-DuneBodyValue -Body $body -Name 'faction')
        $pre = [string](Get-DuneBodyValue -Body $body -Name 'preset')
        if ($null -eq $aid -or $aid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'actor_id is required.'; return }
        if (-not $fac) { Write-DuneError -Response $res -Status 400 -Message 'faction is required.'; return }
        if (-not $pre) { Write-DuneError -Response $res -Status 400 -Message 'preset is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerProgressionReverse -Ip $ip -ActorId $aid -Faction $fac -Preset $pre }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Progression reverse failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/progression/apply-preset  { account_id, preset_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/progression/apply-preset' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $pid = [string](Get-DuneBodyValue -Body $body -Name 'preset_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $pid) { Write-DuneError -Response $res -Status 400 -Message 'preset_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerApplyProgressionPreset -Ip $ip -AccountId $acc -PresetId $pid }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Apply preset failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/journey/complete  { account_id, node_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/journey/complete' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $node = [string](Get-DuneBodyValue -Body $body -Name 'node_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $node) { Write-DuneError -Response $res -Status 400 -Message 'node_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerCompleteJourneyNode -Ip $ip -AccountId $acc -NodeId $node }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Complete journey failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/journey/reset  { account_id, node_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/journey/reset' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $node = [string](Get-DuneBodyValue -Body $body -Name 'node_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $node) { Write-DuneError -Response $res -Status 400 -Message 'node_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetJourneyNode -Ip $ip -AccountId $acc -NodeId $node }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset journey failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/journey/wipe  { account_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/journey/wipe' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerWipeJourneyNodes -Ip $ip -AccountId $acc }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Wipe journey failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/contract/complete  { account_id, contract_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/contract/complete' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $cid = [string](Get-DuneBodyValue -Body $body -Name 'contract_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $cid) { Write-DuneError -Response $res -Status 400 -Message 'contract_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerCompleteContracts -Ip $ip -AccountId $acc -ContractIds @($cid) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Complete contract failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/contracts/complete  { account_id, contract_ids:[..] }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/contracts/complete' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $ids = Get-DuneBodyValue -Body $body -Name 'contract_ids'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $ids -or @($ids).Count -eq 0) { Write-DuneError -Response $res -Status 400 -Message 'contract_ids[] is required.'; return }
        $arr = @($ids | ForEach-Object { [string]$_ })
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerCompleteContracts -Ip $ip -AccountId $acc -ContractIds $arr }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Complete contracts failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/contracts/reverse  { account_id, contract_ids:[..] }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/contracts/reverse' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $ids = Get-DuneBodyValue -Body $body -Name 'contract_ids'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $ids -or @($ids).Count -eq 0) { Write-DuneError -Response $res -Status 400 -Message 'contract_ids[] is required.'; return }
        $arr = @($ids | ForEach-Object { [string]$_ })
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerReverseContracts -Ip $ip -AccountId $acc -ContractIds $arr }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reverse contracts failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/grant-job-skills  { account_id, job }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-job-skills' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGrantJobSkills -Ip $ip -AccountId $acc -Job $job }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant job skills failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/reset-job-skills  { account_id, job }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-job-skills' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetJobSkills -Ip $ip -AccountId $acc -Job $job }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset job skills failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/set-starter-class  { account_id, job }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-starter-class' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSetStarterClass -Ip $ip -AccountId $acc -Job $job }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set starter class failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/delete-tutorials  { account_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/delete-tutorials' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerDeleteTutorials -Ip $ip -AccountId $acc }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Delete tutorials failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/wipe-codex  { account_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/wipe-codex' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerWipeCodex -Ip $ip -AccountId $acc }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Wipe codex failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# §10 — Storage owner debug (read-only)
# ---------------------------------------------------------------------------

# GET /api/gameplay/storage/owner-debug?id=<placeable_id>
Register-DuneRoute -Method GET -Path '/api/gameplay/storage/owner-debug' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $idStr = Get-DuneQ $req 'id'
        $id = 0L
        [void][Int64]::TryParse($idStr, [ref]$id)
        if ($id -le 0) { Write-DuneError -Response $res -Status 400 -Message 'id (placeable id) is required.'; return }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $r = Get-DuneStorageOwnerDebug -Ip $ctx.ip -PlaceableId $id
        if (-not $r.ok) { Write-DuneError -Response $res -Status 503 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true; placeable_id = $id; debug = $r.result; source = 'live' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Owner debug failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# §7 refine — Account/identity: update-tags (add+remove delta)
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/update-tags  { account_id, add?[], remove?[] }
# Mirrors dune-admin cmdUpdatePlayerTags (calls dune.update_player_tags proc
# so server-side triggers fire). Separate from POST /tags (overwrite model)
# which is kept for back-compat.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/update-tags' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acct = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acct -or $acct -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        $add  = @(Get-DuneBodyValue -Body $body -Name 'add')
        $rem  = @(Get-DuneBodyValue -Body $body -Name 'remove')
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip) Invoke-DunePlayerUpdateTags -Ip $ip -AccountId ([long]$acct) -Add $add -Remove $rem
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Update tags failed: $($_.Exception.Message)"
    }
}