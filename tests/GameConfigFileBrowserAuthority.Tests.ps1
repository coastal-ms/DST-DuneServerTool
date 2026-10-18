BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'RetailServerSettings.ps1'
    Import-DstLib 'GameConfig.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app/server/lib/Maps.ps1')
    function global:Invoke-V6Ssh { param($Ip,$Cmd,$StdinData,$TimeoutSec) }
    function global:Invoke-DuneCommandExternal { param($Name) }
    function global:Set-V6ConsoleVariableOverrides { param($Ip,$Names,$Values,$ManagedNames) }
}

Describe 'File Browser manual INIs survive reload and battlegroup restart' {
    BeforeEach {
        $script:liveEngine = "[ConsoleVariables]`nVehicle.MaxVehiclesPerPlayer=20`nDune.DisableShieldOnShooting=0`n"
        $script:liveGame = "[/Script/DuneSandbox.DuneGameMode]`n; manual comment`nm_PlayerStartingWater=250`n"
        Mock Resolve-DuneRetailServerSettingsTarget {
            @{ available=$true;namespace='active-bg';persistentVolumeClaim='active-saved';pod='active-filebrowser' }
        }
        Mock Get-DuneRetailStartupSyncPreference { @{enabled=$true;injectionsApplied=$true} }
        Mock Invoke-DuneCommandExternal { @{ok=$true} }
        Mock Set-V6ConsoleVariableOverrides { @{Success=$true} }
        Mock Invoke-V6Ssh {
            param($Ip,$Cmd,$StdinData,$TimeoutSec)
            if ($Cmd -match 'kubectl get pv ') { return '/var/lib/rancher/k3s/storage/active-volume' }
            if ($Cmd -match 'echo __DST_USER_INIS__') { return '__DST_USER_INIS__' }
            if ($Cmd -eq "sudo cat '/var/lib/rancher/k3s/storage/active-volume/Saved/UserSettings/UserEngine.ini' 2>/dev/null") { return $script:liveEngine }
            if ($Cmd -eq "sudo cat '/var/lib/rancher/k3s/storage/active-volume/Saved/UserSettings/UserGame.ini' 2>/dev/null") { return $script:liveGame }
            throw "Unexpected operation during read/restart: $Cmd"
        }
    }

    It 'rereads the File Browser file and reflects a subsequent deletion exactly' {
        $first = Get-DuneGameConfig -Ip '192.0.2.10'
        $first.source | Should -Be 'live'
        $first.engine.effectiveByKey['Vehicle.MaxVehiclesPerPlayer'] | Should -Be '20'
        $script:liveEngine = "[ConsoleVariables]`n; user removed the vehicle override and empty assignment`nDune.DisableShieldOnShooting=0`n"
        $second = Get-DuneGameConfig -Ip '192.0.2.10'
        $second.engine.raw | Should -Be $script:liveEngine
        $second.engine.effectiveByKey.ContainsKey('Vehicle.MaxVehiclesPerPlayer') | Should -BeFalse
        $second.engine.effectiveByKey.ContainsKey('SafeZone.EnableScale') | Should -BeFalse
        $second.engine.effectiveByKey['Dune.DisableShieldOnShooting'] | Should -Be '0'
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'setup/config|tee|kubectl cp|install |mv ' }
    }

    It 'restarts using current files without restoring deleted keys or blank lines from setup' {
        $script:liveEngine = "[ConsoleVariables]`nDune.DisableShieldOnShooting=0`n"
        $before = $script:liveEngine
        $result = Invoke-DuneBattlegroupRestart -Ip '192.0.2.10'
        $result.ok | Should -BeTrue
        $result.iniDeploy.skipped | Should -BeTrue
        $script:liveEngine | Should -Be $before
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'setup/config|tee|kubectl cp|install |mv ' }
        Should -Invoke Set-V6ConsoleVariableOverrides -Times 1 -ParameterFilter {
            -not $Values.ContainsKey('Vehicle.MaxVehiclesPerPlayer') -and
            -not $Values.ContainsKey('SafeZone.EnableScale') -and
            $Values['Dune.DisableShieldOnShooting'] -eq '0'
        }
        Should -Invoke Invoke-DuneCommandExternal -Times 1 -ParameterFilter { $Name -eq 'restart' }
    }

    It 'refuses an unverified volume rather than falling back to old installed defaults' {
        Mock Invoke-V6Ssh { '/some/other/volume' }
        { Get-DuneGameConfig -Ip '192.0.2.10' } | Should -Throw '*No setup INIs were substituted*'
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'sudo cat|kubectl cp' }
    }
}


Describe 'Installer does not deploy user gameplay settings' {
    It 'ships application files without overwrite targets for player or server INIs' {
        $installer = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app/installer/DuneServer.iss') -Raw
        $installer | Should -Not -Match '(?im)^Source:.*(?:UserGame\.ini|UserEngine\.ini|ServerCustomSettings\.ini|Game\.ini|Engine\.ini)'
        $deletes = [regex]::Match($installer, '(?s)\[InstallDelete\](.*?)\[Icons\]').Groups[1].Value
        $deletes | Should -Not -Match '(?i)DuneSandbox|UserSettings|\.ini|userappdata|localappdata'
        $installer | Should -Match 'if not SkipConfigPages then\s+WriteDuneConfig\(\)'
    }
}
