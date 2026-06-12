# Coriolis Admin routes — v11.5.7
#
# Endpoints for inspecting and setting Coriolis storm seeds. Mounted under
# /api/gameplay/coriolis/* so it lives next to the existing Gameplay admin
# surface (no separate admin tab needed).

# GET /api/gameplay/coriolis/seeds  → current seeds
Register-DuneRoute -Method GET -Path '/api/gameplay/coriolis/seeds' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $source = 'demo'; $payload = $null; $liveError = $null
        if (-not (Test-DuneDemoRequested $req)) {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Get-DuneCoriolisSeedsLive -Ip $ctx.ip
                if ($live.ok) { $payload = $live; $source = if ($live.unsupported) { 'demo' } else { 'live' } }
                else { $liveError = $live.error }
            } else { $liveError = $ctx.message }
        }
        if (-not $payload) { $payload = Get-DuneCoriolisSeedsDemo }
        $out = @{
            ok         = $true
            source     = $source
            farm_seed  = $payload.farm_seed
            maps       = $payload.maps
            partitions = $payload.partitions
        }
        if ($liveError) { $out['liveError'] = $liveError }
        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Coriolis seeds failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/coriolis/set-farm-seed  { seed }
Register-DuneRoute -Method POST -Path '/api/gameplay/coriolis/set-farm-seed' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $seed = Get-DuneBodyInt -Body $body -Name 'seed'
        if ($null -eq $seed -or $seed -lt 0) { Write-DuneError -Response $res -Status 400 -Message 'seed (non-negative integer) is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip) Invoke-DuneCoriolisSetFarmSeed -Ip $ip -Seed ([int]$seed)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set farm seed failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/coriolis/set-map-seed  { map, seed }
Register-DuneRoute -Method POST -Path '/api/gameplay/coriolis/set-map-seed' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $map = ''
        if ($body -and $body.PSObject.Properties['map']) { $map = [string]$body.map }
        $seed = Get-DuneBodyInt -Body $body -Name 'seed'
        if (-not $map) { Write-DuneError -Response $res -Status 400 -Message 'map (string) is required.'; return }
        if ($null -eq $seed -or $seed -lt 0) { Write-DuneError -Response $res -Status 400 -Message 'seed (non-negative integer) is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip) Invoke-DuneCoriolisSetMapSeed -Ip $ip -Map $map -Seed ([int]$seed)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set map seed failed: $($_.Exception.Message)"
    }
}

# POST /api/gameplay/coriolis/set-partition-seed  { partition_id, seed }
Register-DuneRoute -Method POST -Path '/api/gameplay/coriolis/set-partition-seed' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $pid = Get-DuneBodyInt -Body $body -Name 'partition_id'
        $seed = Get-DuneBodyInt -Body $body -Name 'seed'
        if ($null -eq $pid -or $pid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'partition_id (positive integer) is required.'; return }
        if ($null -eq $seed -or $seed -lt 0) { Write-DuneError -Response $res -Status 400 -Message 'seed (non-negative integer) is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action {
            param($ip) Invoke-DuneCoriolisSetPartitionSeed -Ip $ip -PartitionId ([long]$pid) -Seed ([int]$seed)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Set partition seed failed: $($_.Exception.Message)"
    }
}
