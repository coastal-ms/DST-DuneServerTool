# Pods.ps1 - Routes for the Pods page.
#
# GET /api/pods                          - all pods across namespaces
# GET /api/pods/events?namespace=&name=  - events + describe tail for one pod
#
# VM-gated inside the lib helpers (Get-DuneBackupContext). Read-only cluster
# inspection.

Register-DuneRoute -Method GET -Path '/api/pods' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Get-DunePodsList
        if (-not $r.ok) {
            Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Pod list failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/pods/events' -Handler {
    param($req, $res, $routeParams, $body)
    $ns = ''
    $name = ''
    try {
        if ($req -and $req.QueryString) {
            if ($req.QueryString['namespace']) { $ns   = [string]$req.QueryString['namespace'] }
            if ($req.QueryString['name'])      { $name = [string]$req.QueryString['name'] }
        }

        Register-DuneRoute -Method POST -Path '/api/pods/prune-terminal-director' -Handler {
            param($req, $res, $routeParams, $body)
            try {
                $r = Invoke-WithDuneLock -Name 'prune-terminal-director-pods' -Script {
                    Remove-DuneTerminalDirectorPods
                }
                if (-not $r.ok) {
                    Write-DuneError -Response $res -Status $(if ($r.status) { [int]$r.status } else { 502 }) -Message $r.message
                    return
                }
                Write-DuneJson -Response $res -Body $r
            } catch {
                Write-DuneError -Response $res -Status 502 -Message "Director pod cleanup failed: $($_.Exception.Message)"
            }
        }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($ns) -or [string]::IsNullOrWhiteSpace($name)) {
        Write-DuneError -Response $res -Status 400 -Message 'Both "namespace" and "name" query parameters are required.'
        return
    }
    try {
        $r = Get-DunePodEvents -Namespace $ns -Name $name
        if (-not $r.ok) {
            Write-DuneError -Response $res -Status ([int]$r.status) -Message $r.message
            return
        }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 502 -Message "Pod events failed: $($_.Exception.Message)"
    }
}
