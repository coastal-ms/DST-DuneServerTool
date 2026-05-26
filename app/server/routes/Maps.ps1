# Routes for on-demand map control (currently DeepDesert).

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
        $result = Start-DuneOnDemandMap -Key $routeParams.key
        if (-not $result.ok -and $result.status) {
            Write-DuneError -Response $res -Status $result.status -Message $result.message
            return
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
