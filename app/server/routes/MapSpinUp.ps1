# Routes for Map SpinUp — per-map MinServers floor in the director.ini.

Register-DuneRoute -Method GET -Path '/api/map-spinup' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneSpinUpMaps
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/map-spinup/{map}' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $enabled = $false
        if ($body -is [hashtable] -and $body.ContainsKey('enabled')) { $enabled = [bool]$body['enabled'] }
        elseif ($null -ne $body -and $null -ne $body.enabled)        { $enabled = [bool]$body.enabled }

        $r = Invoke-WithDuneLock -Name 'director-ini' -Script { Set-DuneSpinUpMap -Map $routeParams.map -Enabled:$enabled }
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
