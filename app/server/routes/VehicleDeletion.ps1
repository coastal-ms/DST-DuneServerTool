# Vehicle fleet and safe deletion queue.

Register-DuneRoute -Method GET -Path '/api/gameplay/vehicles' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $player = Resolve-DuneInventoryPlayerId -HasPlayerId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'player_id') -Value (Get-DuneQ $req 'player_id')
        if (-not $player.ok) { Write-DuneError -Response $res -Status 400 -Message $player.error; return }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Get-DuneVehicleFleetLive -Ip $ctx.ip -PlayerId ([long]$player.playerId)
        if (-not $result.ok) { Write-DuneError -Response $res -Status 503 -Message $result.error; return }
        Write-DuneJson -Response $res -Body @{
            vehicles = @($result.vehicles); total = $result.total; source = 'live'
            observed_at = $result.observed_at; stale_after_seconds = $result.stale_after_seconds
            database_scope = $result.database_scope
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicle fleet failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/gameplay/vehicles/{id}/integrity' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vehicleId = 0L
        if (-not [long]::TryParse([string]$routeParams.id, [ref]$vehicleId) -or $vehicleId -le 0 -or $vehicleId -gt 9007199254740991) {
            Write-DuneError -Response $res -Status 400 -Message 'A valid vehicle id is required.'; return
        }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Get-DuneVehicleIntegrityLive -Ip $ctx.ip -VehicleId $vehicleId
        if (-not $result.ok) { Write-DuneError -Response $res -Status 503 -Message $result.error; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicle integrity failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/names' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $changes = @((Get-DuneBodyValue -Body $body -Name 'changes'))
        $databaseScope = [string](Get-DuneBodyValue -Body $body -Name 'database_scope')
        if ($changes.Count -lt 1 -or $changes.Count -gt 100) {
            Write-DuneError -Response $res -Status 400 -Message 'Change between 1 and 100 vehicle names at once.'; return
        }
        if ($databaseScope -cnotmatch '^[a-f0-9]{64}$') {
            Write-DuneError -Response $res -Status 400 -Message 'Refresh the fleet before saving vehicle names.'; return
        }
        if (-not (Test-DuneDisruptiveActionGuard -Req $req -Res $res -Action 'saving vehicle names and restarting the battlegroup')) { return }

        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Invoke-WithDuneLock -Name 'vehicle-lifecycle' -TimeoutSec 5 -Script {
            Invoke-DuneVehicleRenameBatch -Ip $ctx.ip -Changes $changes -DatabaseScope $databaseScope
        }
        if (-not $result.ok) {
            $status = if ($result.status) { [int]$result.status } else { 409 }
            Write-DuneJson -Response $res -Status $status -Body $result
            return
        }
        Write-DuneJson -Response $res -Status 202 -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Save vehicle names failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/delete' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not [bool](Get-DuneBodyValue -Body $body -Name 'confirmed')) {
            Write-DuneError -Response $res -Status 400 -Message 'Confirmation is required before deleting vehicles.'; return
        }
        $vehicleIds = @()
        foreach ($rawId in @((Get-DuneBodyValue -Body $body -Name 'vehicle_ids'))) {
            $vehicleId = 0L
            if (-not [long]::TryParse([string]$rawId, [ref]$vehicleId) -or $vehicleId -le 0 -or $vehicleId -gt 9007199254740991) {
                Write-DuneError -Response $res -Status 400 -Message 'Every vehicle id must be a positive integer.'; return
            }
            if ($vehicleId -notin $vehicleIds) { $vehicleIds += $vehicleId }
        }
        if ($vehicleIds.Count -eq 0 -or $vehicleIds.Count -gt 100) {
            Write-DuneError -Response $res -Status 400 -Message 'Select between 1 and 100 vehicles.'; return
        }
        if (-not (Test-DuneDisruptiveActionGuard -Req $req -Res $res -Action 'deleting vehicles with one protected backup and battlegroup restart')) { return }

        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $fleet = Get-DuneVehicleFleetLive -Ip $ctx.ip
        if (-not $fleet.ok) { Write-DuneError -Response $res -Status 503 -Message $fleet.error; return }
        $selected = @($fleet.vehicles | Where-Object { [int64]$_.id -in $vehicleIds })
        if ($selected.Count -ne $vehicleIds.Count) {
            Write-DuneError -Response $res -Status 404 -Message 'One or more selected vehicles were not found. Refresh and select them again.'; return
        }
        $blocked = @($selected | Where-Object deletion_blocked_reason | Select-Object -First 1)
        if ($blocked.Count) { Write-DuneError -Response $res -Status 409 -Message ([string]$blocked[0].deletion_blocked_reason); return }

        $result = Invoke-WithDuneLock -Name 'vehicle-lifecycle' -TimeoutSec 5 -Script {
            $existing = Get-DuneVehicleDeletionQueue
            if ($existing.running) { return @{ ok = $false; error = 'A vehicle deletion is already running.' } }
            foreach ($entry in @($existing.entries)) {
                [void](Remove-DuneVehicleDeletion -EntryId ([string]$entry.id))
            }
            $queuedIds = @()
            foreach ($v in $selected) {
                $queued = Add-DuneVehicleDeletion -VehicleId $v.id -VehicleClass $v.class -VehicleName $v.vehicle_name -Map $v.map -Owners $v.owners -ActorState $v.actor_state -TargetRevision $v.target_revision -ModuleCount $v.module_count -CargoStackCount $v.cargo_stack_count -DatabaseScope $fleet.database_scope
                if (-not $queued.ok) { return $queued }
                $queuedIds += [string]$queued.entry.id
            }
            $current = Get-DuneVehicleDeletionQueue
            $processed = Invoke-DuneVehicleDeletionWindow -Ip $ctx.ip -QueueRevision $current.revision
            if (-not $processed.ok) {
                foreach ($entryId in $queuedIds) { [void](Remove-DuneVehicleDeletion -EntryId $entryId) }
            }
            return $processed
        }
        if (-not $result.ok) { Write-DuneJson -Response $res -Status 503 -Body $result; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Delete vehicles failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/gameplay/vehicles/deletions' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneVehicleDeletionQueue)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicle deletion queue failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/deletions' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vehicleId = Get-DuneBodyInt -Body $body -Name 'vehicle_id'
        $confirm = [string](Get-DuneBodyValue -Body $body -Name 'confirm')
        if ($null -eq $vehicleId -or $vehicleId -le 0) { Write-DuneError -Response $res -Status 400 -Message 'vehicle_id is required.'; return }
        if ($confirm -cne "DELETE $vehicleId") { Write-DuneError -Response $res -Status 400 -Message "Type DELETE $vehicleId exactly to queue this removal."; return }
        $revision = [string](Get-DuneBodyValue -Body $body -Name 'target_revision')
        if ($revision -cnotmatch '^[a-f0-9]{32}$') { Write-DuneError -Response $res -Status 400 -Message 'Refresh the fleet and confirm the exact target snapshot.'; return }

        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $fleet = Get-DuneVehicleFleetLive -Ip $ctx.ip -VehicleId $vehicleId
        if (-not $fleet.ok) { Write-DuneError -Response $res -Status 503 -Message $fleet.error; return }
        $vehicle = @($fleet.vehicles | Where-Object { [int64]$_.id -eq [int64]$vehicleId } | Select-Object -First 1)
        if ($vehicle.Count -eq 0) { Write-DuneError -Response $res -Status 404 -Message "Vehicle $vehicleId was not found."; return }
        $v = $vehicle[0]
        if ($v.target_revision -cne $revision -or $v.deletion_blocked_reason) {
            Write-DuneError -Response $res -Status 409 -Message "Vehicle changed or cannot be removed. Refresh and review it. $($v.deletion_blocked_reason)"; return
        }
        $result = Invoke-WithDuneLock -Name 'vehicle-lifecycle' -TimeoutSec 5 -Script {
            Add-DuneVehicleDeletion -VehicleId $vehicleId -VehicleClass $v.class -VehicleName $v.vehicle_name -Map $v.map -Owners $v.owners -ActorState $v.actor_state -TargetRevision $revision -ModuleCount $v.module_count -CargoStackCount $v.cargo_stack_count -DatabaseScope $fleet.database_scope
        }
        if (-not $result.ok) { Write-DuneError -Response $res -Status 500 -Message $result.error; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Queue vehicle deletion failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/gameplay/vehicles/deletions/{id}' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $entryId = [string]$routeParams.id
        $result = Invoke-WithDuneLock -Name 'vehicle-lifecycle' -TimeoutSec 5 -Script {
            Remove-DuneVehicleDeletion -EntryId $entryId
        }
        if (-not $result.ok) { Write-DuneError -Response $res -Status 404 -Message $result.error; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Cancel vehicle deletion failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/deletions/process' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneBodyValue -Body $body -Name 'confirm')
        if ($confirm -cne 'RESTART AND DELETE') {
            Write-DuneError -Response $res -Status 400 -Message 'Type RESTART AND DELETE exactly to open the safe deletion window.'
            return
        }
        $queueRevision = [string](Get-DuneBodyValue -Body $body -Name 'queue_revision')
        if ($queueRevision -cnotmatch '^[a-f0-9]{64}$') {
            Write-DuneError -Response $res -Status 400 -Message 'Refresh the queue and confirm its exact current target list.'; return
        }
        if (-not (Test-DuneDisruptiveActionGuard -Req $req -Res $res -Action 'opening the vehicle deletion restart window')) { return }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Invoke-WithDuneLock -Name 'vehicle-lifecycle' -TimeoutSec 5 -Script {
            Invoke-DuneVehicleDeletionWindow -Ip $ctx.ip -QueueRevision $queueRevision
        }
        if (-not $result.ok) { Write-DuneJson -Response $res -Status 503 -Body $result; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Process vehicle deletions failed: $($_.Exception.Message)"
    }
}
