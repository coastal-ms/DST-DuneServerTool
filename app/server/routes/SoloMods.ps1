Register-DuneRoute -Method GET -Path '/api/solo/mods' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Get-DuneSoloMods) } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
Register-DuneRoute -Method POST -Path '/api/solo/mods/import' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script {
            if ($null -ne $body.base64 -or $null -ne $body.filename) {
                if ($body.path) { throw 'Choose one ZIP import source.' }
                Import-DuneSoloModUpload -Filename ([string]$body.filename) -Base64 ([string]$body.base64)
            } else { Import-DuneSoloMod ([string]$body.path) }
        }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method GET -Path '/api/solo/mods/regis-tanks/status' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    Write-DuneJson -Response $res -Body (Get-DuneSoloTankStatus)
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/regis-tanks' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script {
            if ($body -is [hashtable] -and $body.ContainsKey('preset')) { Grant-DuneSoloRegisTank -Preset ([string]$body.preset) }
            else { Install-DuneRegisTanksMod }
        }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/regis-tanks/enable' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Invoke-WithDuneLock -Name 'solo-mods' -Script { Enable-DuneSoloRegisTanks }) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
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
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Open-DuneSoloModsFolder -Desktop:($body.desktop -eq $true) }
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

Register-DuneRoute -Method POST -Path '/api/solo/mods/delete' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { Remove-DuneSoloMod ([string]$body.folder) }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}

Register-DuneRoute -Method POST -Path '/api/solo/mods/shortcut' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try {
        $result=Invoke-WithDuneLock -Name 'solo-mods' -Script { New-DuneSoloModShortcut }
        Write-DuneJson -Response $res -Body $result
    } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
Register-DuneRoute -Method GET -Path '/api/solo/mods/log' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Get-DuneSoloRuntimeLog) }
    catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
