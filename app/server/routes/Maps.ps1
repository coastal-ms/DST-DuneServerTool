# Routes for on-demand map control (currently DeepDesert).

# Static route — clears drifted partitions so on-demand maps launch again.
# Registered separately from /api/maps/{key} (it's a POST so there's no
# collision with the GET param route).
Register-DuneRoute -Method POST -Path '/api/maps/fix-partitions' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Invoke-DuneFixOnDemandPartitions }
        if (-not $result.ok -and $result.status) {
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/maps/{key}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state = Get-DuneOnDemandMapState -Key $routeParams.key
        if (-not $state.ok) {
            Write-DuneError -Response $res -Status $state.status -Message $state.message
            return
        }
        Write-DuneJson -Response $res -Body $state
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/maps/{key}/start' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Start-DuneOnDemandMap -Key $routeParams.key }
        if (-not $result.ok -and $result.status) {
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/maps/{key}/stop' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        # ?force=true bypasses the "players online" guard
        $force = $false
        try {
            $q = $req.Url.Query
            if ($q -and $q -match '(?:^|[?&])force=(true|1|yes)(?:&|$)') { $force = $true }
        } catch {}
        $result = Invoke-WithDuneLock -Name 'ondemand-maps' -Script { Stop-DuneOnDemandMap -Key $routeParams.key -Force:$force }
        if (-not $result.ok -and $result.status) {
            # 409 = players online, needs confirmation. Return the body so
            # the frontend can show the count and re-POST with ?force=true.
            if ($result.status -eq 409) {
                $res.StatusCode = 409
                Write-DuneJson -Response $res -Body $result
                return
            }
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
