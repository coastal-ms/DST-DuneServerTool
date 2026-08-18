# Reversible same-battlegroup World Restart endpoints.

Register-DuneRoute -Method GET -Path '/api/db/world-restart/status' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body (Get-DuneWorldRestartStatus)
}

Register-DuneRoute -Method POST -Path '/api/db/world-restart' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $confirm = if ($body -is [hashtable]) { [string]$body.confirm } elseif ($body) { [string]$body.confirm } else { '' }
    if ($confirm -cne $script:DuneWorldRestartConfirm) {
        Write-DuneError -Response $res -Status 400 -Message "Type $script:DuneWorldRestartConfirm exactly to continue."
        return
    }
    $result = Start-DuneWorldRestartWorker -Operation restart -ServerDir $script:DuneServerDir
    if (-not $result.ok) {
        Write-DuneError -Response $res -Status 409 -Message $result.error
        return
    }
    Write-DuneJson -Response $res -Status 202 -Body $result
}

Register-DuneRoute -Method POST -Path '/api/db/world-restart/rollback' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $confirm = if ($body -is [hashtable]) { [string]$body.confirm } elseif ($body) { [string]$body.confirm } else { '' }
    if ($confirm -cne $script:DuneWorldRollbackConfirm) {
        Write-DuneError -Response $res -Status 400 -Message "Type $script:DuneWorldRollbackConfirm exactly to continue."
        return
    }
    $state = Get-DuneWorldRestartStatus
    if (-not $state.rollbackAvailable -or -not $state.backupPath) {
        Write-DuneError -Response $res -Status 409 -Message 'No verified World Restart rollback backup is available.'
        return
    }
    $result = Start-DuneWorldRestartWorker -Operation rollback -ServerDir $script:DuneServerDir
    if (-not $result.ok) {
        Write-DuneError -Response $res -Status 409 -Message $result.error
        return
    }
    Write-DuneJson -Response $res -Status 202 -Body $result
}
