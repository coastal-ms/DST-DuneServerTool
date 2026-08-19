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
    if ($state.PSObject.Properties['researchRecoveryRequired'] -and [bool]$state.researchRecoveryRequired) {
        Write-DuneError -Response $res -Status 409 -Message 'Research recovery is unresolved. Use Roll back research recovery instead.'
        return
    }
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

Register-DuneRoute -Method GET -Path '/api/db/world-restart/research-audit' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneWorldRestartResearchAudit)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "World Restart research audit failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method POST -Path '/api/db/world-restart/research-recover' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = if ($body -is [hashtable]) { [string]$body.confirm } elseif ($body) { [string]$body.confirm } else { '' }
        if ($confirm -cne 'RESET RESEARCH') {
            Write-DuneError -Response $res -Status 400 -Message 'Type RESET RESEARCH exactly to continue.'
            return
        }

        $characterName = if ($body -is [hashtable]) { [string]$body.characterName } elseif ($body) { [string]$body.characterName } else { '' }
        $funcomId = if ($body -is [hashtable]) { [string]$body.funcomId } elseif ($body) { [string]$body.funcomId } else { '' }
        $itemKeys = @()
        if ($body -is [hashtable] -and $body.ContainsKey('itemKeys')) {
            $itemKeys = @($body.itemKeys | ForEach-Object { [string]$_ })
        } elseif ($body -and $body.PSObject.Properties['itemKeys']) {
            $itemKeys = @($body.itemKeys | ForEach-Object { [string]$_ })
        }
        if (-not $characterName -or -not $funcomId -or $itemKeys.Count -eq 0) {
            Write-DuneError -Response $res -Status 400 -Message 'characterName, funcomId, and itemKeys are required.'
            return
        }
        $result = Invoke-WithDuneLock -Name $script:DuneWorldRestartLockName -TimeoutSec 5 -Script {
            Invoke-DuneWorldRestartResearchRecovery -CharacterName $characterName -FuncomId $funcomId -ItemKeys $itemKeys
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/db/world-restart/research-rollback' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $confirm = if ($body -is [hashtable]) { [string]$body.confirm } elseif ($body) { [string]$body.confirm } else { '' }
        if ($confirm -cne $script:DuneWorldRestartResearchRollbackConfirm) {
            Write-DuneError -Response $res -Status 400 -Message "Type $script:DuneWorldRestartResearchRollbackConfirm exactly to continue."
            return
        }
        $result = Invoke-WithDuneLock -Name $script:DuneWorldRestartLockName -TimeoutSec 5 -Script {
            Invoke-DuneWorldRestartResearchRollback
        }
        Write-DuneJson -Response $res -Body $result
    } catch {
        Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message
    }
}
