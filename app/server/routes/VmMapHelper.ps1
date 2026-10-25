Register-DuneRoute -Method GET -Path '/api/v1/maps/vm-helper' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $state=Get-DuneVmMapState
        if ($state.enabled -and $state.phase -eq 'ready') { $state=Set-DuneVmMapCollection -Action 'status' }
        Write-DuneJson -Response $res -Body $state
    }
    catch { Write-DuneError -Response $res -Status 503 -Message 'VM map status is unavailable. Check the VM connection and retry.' }
}

Register-DuneRoute -Method POST -Path '/api/v1/maps/vm-helper' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-DuneVmMapState).enabled -and -not $body.resourcesAccepted) { throw 'Accept the Live Map resource requirements before installing the helper.' }
        Write-DuneJson -Response $res -Body (Start-DuneVmMapSetup)
    }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method DELETE -Path '/api/v1/maps/vm-helper' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Start-DuneVmMapSetup -Remove) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/v1/maps/vm-helper/control' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Set-DuneVmMapCollection -Action ([string]$body.action) -Preferences $body.preferences) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
