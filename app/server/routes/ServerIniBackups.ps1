Register-DuneRoute -Method GET -Path '/api/gameconfig/ini-backups' -Handler {
    param($req, $res, $routeParams, $body)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) { Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message; return }
    try { Write-DuneJson -Response $res -Body (Get-DuneServerIniBackups -Ip $ctx.ip) }
    catch { Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message }
}

function Invoke-DuneServerIniBackupRoute {
        param($res, $body, [string]$operation)
        $ctx = Get-DuneGameConfigContext
        if (-not $ctx.ok) { Write-DuneError -Response $res -Status $ctx.status -Message $ctx.message; return }
        try {
            if ($body -isnot [hashtable] -or $body.files -isnot [array]) { throw 'Select INI backups first.' }
            $result = Invoke-WithDuneLock -Name 'server-ini-backups' -Script {
                if ($operation -eq 'download') { Export-DuneServerIniBackups -Ip $ctx.ip -Files $body.files }
                else { Remove-DuneServerIniBackups -Ip $ctx.ip -Files $body.files }
            }
            Write-DuneJson -Response $res -Body $result
        } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/gameconfig/ini-backups/download' -Handler {
    param($req, $res, $routeParams, $body)
    Invoke-DuneServerIniBackupRoute -res $res -body $body -operation download
}

Register-DuneRoute -Method POST -Path '/api/gameconfig/ini-backups/delete' -Handler {
    param($req, $res, $routeParams, $body)
    Invoke-DuneServerIniBackupRoute -res $res -body $body -operation delete
}
