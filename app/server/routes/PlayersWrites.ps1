# PlayersWrites.ps1 — v11.5.9 player write routes ported from the reference implementation.
# Wires Phase C/D/E/F endpoints onto the HTTP server. All routes use
# Invoke-DunePlayerWriteRoute + Get-DuneBodyInt/Value from routes/GameplayPlayers.ps1.

# ---------------------------------------------------------------------------
# §3 — Items / inventory
# ---------------------------------------------------------------------------

# POST /api/gameplay/players/give-items  { pawn_id, items:[{template,qty,quality}], allow_overflow? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pawn = Get-DuneBodyInt -Body $body -Name 'pawn_id'
        $items = Get-DuneBodyValue -Body $body -Name 'items'
        $fls = [string](Get-DuneBodyValue -Body $body -Name 'fls_id')
        # Drop-to-ground (overflow) defaults ON so a full inventory never silently
        # swallows kit parts; pass allow_overflow=false explicitly to opt out.
        $ovRaw = Get-DuneBodyValue -Body $body -Name 'allow_overflow'
        $overflow = if ($null -eq $ovRaw) { $true } else { [bool]$ovRaw }
        if ($null -eq $pawn -or $pawn -le 0) { Write-DuneError -Response $res -Status 400 -Message 'pawn_id is required.'; return }
        if ($null -eq $items) { Write-DuneError -Response $res -Status 400 -Message 'items[] is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveItemsBulk -Ip $ip -PawnId $pawn -Items $items -FlsId $fls -AllowOverflow $overflow }
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

# GET /api/gameplay/players/teleport-destinations  (named maps/hubs for the UI)
Register-DuneRoute -Method GET -Path '/api/gameplay/players/teleport-destinations' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $dests = Get-DuneTeleportDestinations
        Write-DuneJson -Response $res -Body @{ destinations = @($dests); total = @($dests).Count; source = 'catalog' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Teleport destinations failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/teleport-to-location  { account_id, destination }
# Offline-only: writes the player's partition + location (RAM-authoritative while
# connected). Moves the player to a named map/hub from the destination catalog.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/teleport-to-location' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $dest = [string](Get-DuneBodyValue -Body $body -Name 'destination')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $dest) { Write-DuneError -Response $res -Status 400 -Message 'destination is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to teleport to a location. $($off.reason)" }
            }
            Invoke-DunePlayerTeleportToLocation -Ip $ip -AccountId $acc -Destination $dest
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Teleport to location failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/set-respawn  { account_id, destination }
# Offline-only: adds a respawn point at a named destination (non-destructive -
# the player's existing respawn points are preserved).
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-respawn' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $dest = [string](Get-DuneBodyValue -Body $body -Name 'destination')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $dest) { Write-DuneError -Response $res -Status 400 -Message 'destination is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to set a respawn point. $($off.reason)" }
            }
            Invoke-DunePlayerSetRespawn -Ip $ip -AccountId $acc -Destination $dest
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set respawn failed: $($_.Exception.Message)"
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

# POST /api/gameplay/players/faction/reset  { account_id, faction, deep? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/faction/reset' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $fac = [string](Get-DuneBodyValue -Body $body -Name 'faction')
        $deepRaw = Get-DuneBodyValue -Body $body -Name 'deep'
        $deep = [bool]$deepRaw
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $fac) { Write-DuneError -Response $res -Status 400 -Message 'faction is required (atreides|harkonnen|both).'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) { return @{ ok = $false; error = "Player must be offline to reset faction. $($off.reason)" } }
            Invoke-DunePlayerResetFaction -Ip $ip -AccountId $acc -Faction $fac -Deep $deep
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset faction failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/fresh-start/snapshot  { account_id }
# Capture the character's building sets/pieces + cosmetics to the snapshot store
# (keyed by name). Run BEFORE the player deletes their character in-game.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/fresh-start/snapshot' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSnapshotBuilds -Ip $ip -AccountId $acc }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Snapshot builds failed: $($_.Exception.Message)"
    }
}

# GET /api/gameplay/players/fresh-start/snapshots  -> saved snapshot metadata
Register-DuneRoute -Method GET -Path '/api/gameplay/players/fresh-start/snapshots' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $list = Get-DuneFreshStartSnapshotList
        Write-DuneJson -Response $res -Body @{ ok = $true; snapshots = @($list) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "List snapshots failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/fresh-start/restore  { name }
# Grant a saved snapshot's building sets + cosmetics onto the current live
# character with that name (the recreated one). Offline-only (checked in-helper).
Register-DuneRoute -Method POST -Path '/api/gameplay/players/fresh-start/restore' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $name = [string](Get-DuneBodyValue -Body $body -Name 'name')
        if (-not $name) { Write-DuneError -Response $res -Status 400 -Message 'name is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRestoreBuilds -Ip $ip -Name $name -SkipNpe $false }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Restore builds failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/fresh-start/restore-skip-npe  { name }
# Same as /fresh-start/restore but ALSO marks the tutorial as completed on the
# restored character (Fresh Start + No NPE variant). Offline-only.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/fresh-start/restore-skip-npe' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $name = [string](Get-DuneBodyValue -Body $body -Name 'name')
        if (-not $name) { Write-DuneError -Response $res -Status 400 -Message 'name is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerRestoreBuilds -Ip $ip -Name $name -SkipNpe $true }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Restore builds (+ skip NPE) failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/progression/apply-preset  { account_id, preset_id }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/progression/apply-preset' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        # NOTE: do NOT name this $pid — $PID is a PowerShell read-only automatic
        # variable (and AllScope), so $pid = ... throws "Cannot overwrite variable
        # PID because it is read-only or constant." See issue: Apply preset failed.
        $presetId = [string](Get-DuneBodyValue -Body $body -Name 'preset_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $presetId) { Write-DuneError -Response $res -Status 400 -Message 'preset_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            # Offline-only: completing journey nodes writes journey_story_node rows,
            # the pawn TechKnowledge recipe blob, and reward tags - all RAM-authoritative
            # while the player is connected, so an online edit is overwritten on logout.
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to apply a progression preset. $($off.reason)" }
            }
            Invoke-DunePlayerApplyProgressionPreset -Ip $ip -AccountId $acc -PresetId $presetId
        }
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
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            # Offline-only: same RAM-authoritative journey/TechKnowledge writes as the
            # preset path - an online edit is overwritten when the player logs out.
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to complete a journey node. $($off.reason)" }
            }
            Invoke-DunePlayerCompleteJourneyNode -Ip $ip -AccountId $acc -NodeId $node
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Complete journey failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/journey/reset  { account_id, node_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/journey/reset' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $node = [string](Get-DuneBodyValue -Body $body -Name 'node_id')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            if ($node) { Invoke-DunePlayerResetJourneyNode -Ip $ip -AccountId $acc -NodeId $node }
            else { Invoke-DunePlayerResetJourneyNodes -Ip $ip -AccountId $acc }
        }
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

# POST /api/gameplay/players/unlock-trainer  { account_id, job }
# Offline-only: skill grants write to the character's FLevelComponent in Postgres,
# but the map pod holds the authoritative copy in RAM while the player is online.
# If they're online when we write, the pod flushes its RAM state on logout and
# overwrites our grants. Same class of issue as Fill Base Water (#221).
Register-DuneRoute -Method POST -Path '/api/gameplay/players/unlock-trainer' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to unlock trainers. $($off.reason)" }
            }
            Invoke-DunePlayerUnlockTrainer -Ip $ip -AccountId $acc -Job $job
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Unlock trainer failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/unlock-main-quest  { account_id, quest }
# Offline-only: same FLevelComponent RAM-authority issue as unlock-trainer.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/unlock-main-quest' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $quest = [string](Get-DuneBodyValue -Body $body -Name 'quest')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $quest) { Write-DuneError -Response $res -Status 400 -Message 'quest is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to unlock main quests. $($off.reason)" }
            }
            Invoke-DunePlayerUnlockMainQuest -Ip $ip -AccountId $acc -Quest $quest
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Unlock main quest failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/grant-job-skills  { account_id, job }
# Offline-only: same FLevelComponent RAM-authority issue as unlock-trainer.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-job-skills' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to grant job skills. $($off.reason)" }
            }
            Invoke-DunePlayerGrantJobSkills -Ip $ip -AccountId $acc -Job $job
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant job skills failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/reset-job-skills  { account_id, job }
# Offline-only: same FLevelComponent RAM-authority issue as unlock-trainer.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-job-skills' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to reset job skills. $($off.reason)" }
            }
            Invoke-DunePlayerResetJobSkills -Ip $ip -AccountId $acc -Job $job
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Reset job skills failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/set-starter-class  { account_id, job }
# Offline-only: same FLevelComponent RAM-authority issue as unlock-trainer.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-starter-class' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        $job = [string](Get-DuneBodyValue -Body $body -Name 'job')
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        if (-not $job) { Write-DuneError -Response $res -Status 400 -Message 'job is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) {
                return @{ ok = $false; error = "Player must be offline to set starter class. $($off.reason)" }
            }
            Invoke-DunePlayerSetStarterClass -Ip $ip -AccountId $acc -Job $job
        }
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

# POST /api/gameplay/players/grant-all-skills  { account_id }
# Grants every skill in the bundled catalog on the character. Offline-only.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-all-skills' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) { return @{ ok = $false; error = "Player must be offline to grant skills. $($off.reason)" } }
            Invoke-DunePlayerGrantAllSkills -Ip $ip -AccountId $acc
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant all skills failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/players/grant-all-tech  { account_id }
# Marks every buildable patent + crafting recipe + starter group in the bundled
# catalog as Purchased on the character's Intel terminal. Offline-only.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-all-tech' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acc = Get-DuneBodyInt -Body $body -Name 'account_id'
        if ($null -eq $acc -or $acc -le 0) { Write-DuneError -Response $res -Status 400 -Message 'account_id is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip)
            $off = Test-DunePlayerOfflineByAccount -Ip $ip -AccountId $acc
            if (-not $off.ok) { return @{ ok = $false; error = "Player must be offline to grant tech recipes. $($off.reason)" } }
            Invoke-DunePlayerGrantAllTech -Ip $ip -AccountId $acc
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Grant all tech recipes failed: $($_.Exception.Message)"
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
# Mirrors the reference implementation cmdUpdatePlayerTags (calls dune.update_player_tags proc
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