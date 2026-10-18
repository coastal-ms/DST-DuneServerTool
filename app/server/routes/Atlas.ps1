Register-DuneRoute -Method POST -Path '/api/v1/maps/atlas/session' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $session = Get-DuneAtlasSession
        # The collector key and loopback address stay on the host. Normal DST
        # authentication protects this same-origin view locally and remotely.
        $result = @{ available=[bool]$session.available }
        if ($session.available) { $result.url='/api/v1/maps/atlas/view'; $result.mode=$session.mode }
        else { $result.reasonCode=$session.reasonCode }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneJson -Response $res -Body @{ available=$false; reasonCode='startup-unavailable' }
    }
}

Register-DuneRoute -Method GET -Path '/api/v1/maps/atlas/view' -Handler {
    param($req, $res, $routeParams, $body)
    Invoke-DuneAtlasProxy -Request $req -Response $res -Path '/' -Method GET
}

Register-DuneRoute -Method GET -Path '/api/v1/maps/atlas/resource' -Handler {
    param($req, $res, $routeParams, $body)
    Invoke-DuneAtlasProxy -Request $req -Response $res -Path ([string]$req.QueryString['path']) -Method GET
}

Register-DuneRoute -Method POST -Path '/api/v1/maps/atlas/resource' -Handler {
    param($req, $res, $routeParams, $body)
    Invoke-DuneAtlasProxy -Request $req -Response $res -Path ([string]$req.QueryString['path']) -Method POST -Body $body
}
