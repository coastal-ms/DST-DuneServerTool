# Vehicle fleet and safe deletion queue.

Register-DuneRoute -Method GET -Path '/api/gameplay/vehicles' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Get-DuneVehicleFleetLive -Ip $ctx.ip
        if (-not $result.ok) { Write-DuneError -Response $res -Status 503 -Message $result.error; return }
        Write-DuneJson -Response $res -Body @{ vehicles = @($result.vehicles); total = $result.total; source = 'live' }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicle fleet failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/gameplay/vehicles/deletions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneVehicleDeletionQueue)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Vehicle deletion queue failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/deletions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $vehicleId = Get-DuneBodyInt -Body $body -Name 'vehicle_id'
        $confirm = [string](Get-DuneBodyValue -Body $body -Name 'confirm')
        if ($null -eq $vehicleId -or $vehicleId -le 0) { Write-DuneError -Response $res -Status 400 -Message 'vehicle_id is required.'; return }
        if ($confirm -cne "DELETE $vehicleId") { Write-DuneError -Response $res -Status 400 -Message "Type DELETE $vehicleId exactly to queue this removal."; return }

        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $fleet = Get-DuneVehicleFleetLive -Ip $ctx.ip
        if (-not $fleet.ok) { Write-DuneError -Response $res -Status 503 -Message $fleet.error; return }
        $vehicle = @($fleet.vehicles | Where-Object { [int64]$_.id -eq [int64]$vehicleId } | Select-Object -First 1)
        if ($vehicle.Count -eq 0) { Write-DuneError -Response $res -Status 404 -Message "Vehicle $vehicleId was not found."; return }
        $v = $vehicle[0]
        $result = Invoke-WithDuneLock -Name 'vehicle-deletion' -TimeoutSec 5 -Script {
            Add-DuneVehicleDeletion -VehicleId $vehicleId -VehicleClass $v.class -VehicleName $v.vehicle_name -Map $v.map -Owners $v.owners -ActorState $v.actor_state
        }
        if (-not $result.ok) { Write-DuneError -Response $res -Status 500 -Message $result.error; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Queue vehicle deletion failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method DELETE -Path '/api/gameplay/vehicles/deletions/{id}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $entryId = [string]$routeParams.id
        $result = Invoke-WithDuneLock -Name 'vehicle-deletion' -TimeoutSec 5 -Script {
            Remove-DuneVehicleDeletion -EntryId $entryId
        }
        if (-not $result.ok) { Write-DuneError -Response $res -Status 404 -Message $result.error; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Cancel vehicle deletion failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/deletions/process' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = [string](Get-DuneBodyValue -Body $body -Name 'confirm')
        if ($confirm -cne 'RESTART AND DELETE') {
            Write-DuneError -Response $res -Status 400 -Message 'Type RESTART AND DELETE exactly to open the safe deletion window.'
            return
        }
        if (-not (Test-DuneDisruptiveActionGuard -Req $req -Res $res -Action 'opening the vehicle deletion restart window')) { return }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status 503 -Message $ctx.message; return }
        $result = Invoke-WithDuneLock -Name 'vehicle-deletion' -TimeoutSec 5 -Script {
            Invoke-DuneVehicleDeletionWindow -Ip $ctx.ip
        }
        if (-not $result.ok) { Write-DuneJson -Response $res -Status 503 -Body $result; return }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Process vehicle deletions failed: $($_.Exception.Message)"
    }
}
