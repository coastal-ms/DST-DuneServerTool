$playerTeleportHandler = {
        param($req, $res, $routeParams, $body)
        try {
            $account = if ($req.HttpMethod -eq 'GET') { Get-DuneQ $req 'account_id' } else { Get-DuneBodyValue $body 'account_id' }
            $id=0L
            if (-not [long]::TryParse([string]$account,[ref]$id) -or $id -le 0) { throw 'Select a player.' }
            $principal=$routeParams.requestPrincipal
            if ($principal.type -eq 'linked-player' -and [string]$id -cne [string]$principal.linkedCharacter.id) { throw 'Select your linked character.' }
            if ($req.HttpMethod -ne 'GET') {
                if (-not ($body -is [hashtable])) { throw 'A JSON object is required.' }
                foreach($key in $body.Keys){if($key -notin @('account_id','action','name','id','scope')){throw 'Unsupported teleport field.'}}
            }
            $ctx=Get-DuneDbContext
            if(-not $ctx.ok){throw 'The game database is unavailable.'}
            $target=Get-DunePlayerTeleportTarget -Ip $ctx.ip -AccountId $id
            if($req.HttpMethod -eq 'GET') { $result=Get-DunePlayerTeleportView -Target $target }
            elseif($req.HttpMethod -eq 'DELETE') { $result=Remove-DunePlayerTeleport -Target $target -Id ([string]$body.id) }
            elseif($body.action -eq 'capture') { $result=Start-DunePlayerTeleportCapture -Ip $ctx.ip -Target $target -Name ([string]$body.name) }
            elseif($body.action -eq 'teleport') {
                if($body.scope -notin @('shared','private')){throw 'Choose a shared or private location.'}
                $result=Invoke-DunePlayerTeleport -Ip $ctx.ip -Target $target -Id ([string]$body.id) -Scope $body.scope
            } else { throw 'Unknown teleport action.' }
            Write-DuneJson -Response $res -Body $result
        } catch { Write-DuneError -Response $res -Status 409 -Message $_.Exception.Message }
}
Register-DuneRoute -Method GET -Path '/api/player-portal/teleports' -Handler $playerTeleportHandler
Register-DuneRoute -Method POST -Path '/api/player-portal/teleports' -Handler $playerTeleportHandler
Register-DuneRoute -Method DELETE -Path '/api/player-portal/teleports' -Handler $playerTeleportHandler
