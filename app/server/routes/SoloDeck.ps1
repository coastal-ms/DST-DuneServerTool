Register-DuneRoute -Method GET -Path '/api/solo/deck' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    Write-DuneJson -Response $res -Body (Get-DuneSoloDeckStatus)
}

Register-DuneRoute -Method POST -Path '/api/solo/deck/settings/preview' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-deck' -Script { Invoke-DuneSoloDeckSettingsPreview }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/deck/settings/apply' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-deck' -Script {
        Invoke-DuneSoloDeckSettingsApply -Token ([string]$body.token) -Confirmed $body.confirmed -CloudConfirmed $body.cloudConfirmed
    }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/deck/pairing' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-deck' -Script { Get-DuneSoloDeckPairingInfo }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method GET -Path '/api/solo/deck/companion' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $res.Headers['Content-Disposition'] = 'attachment; filename="DST-Deck-Companion.sh"'
    Write-DuneFile -Response $res -Path (Join-Path (Get-DuneSoloDeckResourceRoot) 'DST-Deck-Companion.sh')
}

Register-DuneRoute -Method POST -Path '/api/solo/deck/mods/preview' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-deck' -Script { Invoke-DuneSoloDeckModsPreview }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/deck/mods/apply' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-deck' -Script {
        Invoke-DuneSoloDeckModsApply -Token ([string]$body.token) -Confirmed $body.confirmed
    }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
