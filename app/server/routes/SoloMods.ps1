Register-DuneRoute -Method GET -Path '/api/solo/mods' -LocalOnly -Handler {
    param($req,$res,$routeParams,$body)
    try { Write-DuneJson -Response $res -Body (Get-DuneSoloMods) } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
}
foreach($action in @('import','selection','runtime','launch','restore','open')){
    $handler=[scriptblock]::Create(@'
        param($req,$res,$routeParams,$body)
        try {
            $result=Invoke-WithDuneLock -Name 'solo-mods' -Script {
                switch('ACTION'){
                    'import' { Import-DuneSoloMod ([string]$body.path) }
                    'selection' { Set-DuneSoloModSelection $body }
                    'runtime' { Install-DuneSoloModRuntime }
                    'launch' { Start-DuneSoloModGame ([bool]$body.withMods) }
                    'restore' { Restore-DuneSoloModSession }
                    'open' { New-Item -ItemType Directory -Path $script:DuneSoloModsRoot -Force | Out-Null; Start-Process explorer.exe -ArgumentList ('"'+$script:DuneSoloModsRoot+'"'); @{ok=$true} }
                }
            }
            Write-DuneJson -Response $res -Body $result
        } catch { Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message }
'@.Replace('ACTION',$action))
    Register-DuneRoute -Method POST -Path "/api/solo/mods/$action" -LocalOnly -Handler $handler
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
