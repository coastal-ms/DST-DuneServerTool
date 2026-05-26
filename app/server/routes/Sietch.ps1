# Sietches API — list, add, remove the last shard.
# Add/Remove patch the K8s BG CRD via SSH; restart the battlegroup to apply.

Register-DuneRoute -Method GET -Path '/api/sietches' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneSietchOverview
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/sietches' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Add-DuneSietch
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method DELETE -Path '/api/sietches/last' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Remove-DuneLastSietch
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
