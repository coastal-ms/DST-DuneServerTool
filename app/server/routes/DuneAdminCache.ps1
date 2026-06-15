# dune-admin VM cache -- list + clear endpoints.
# See app/server/lib/DuneAdminCache.ps1 for the why.

Register-DuneRoute -Method GET -Path '/api/dune-admin-cache' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DuneAdminVmCacheStatus
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/dune-admin-cache/clear' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Clear-DuneAdminVmCache
        if (-not $r.ok -and $r.status) {
            Write-DuneError -Response $res -Status $r.status -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
