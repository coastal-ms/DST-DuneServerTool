Register-DuneRoute -Method GET -Path '/api/solo/mods' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Get-DuneSoloMods) } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
Register-DuneRoute -Method POST -Path '/api/solo/mods/import' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Import-DuneSoloMod ([string]$body.path) }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/selection' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Set-DuneSoloModSelection $body }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/runtime' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Install-DuneSoloModRuntime }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/launch' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Start-DuneSoloModGame ([bool]$body.withMods) }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/restore' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Restore-DuneSoloModSession }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/open' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { New-Item -ItemType Directory -Path $script:DuneSoloModsRoot -Force | Out-Null; Start-Process explorer.exe -ArgumentList ('"'+$script:DuneSoloModsRoot+'"'); @{ok=$true} }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method GET -Path '/api/game/launch-preferences' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    Write-DuneJson -Response $res -Body (Get-DuneGameLaunchPreferences)
}
Register-DuneRoute -Method POST -Path '/api/game/launch-preferences' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'game-launch-preferences' -Script { Set-DuneGameLaunchPreferences $body }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
