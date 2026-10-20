BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RegisTanks.ps1'
    Import-DstLib 'Gameplay.ps1'
    function global:Resolve-DuneRetailServerSettingsTarget { param($Ip) }
    function global:Invoke-V6Ssh { param($Ip,$Cmd,$TimeoutSec) }
    function global:Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) }
    function global:Invoke-DuneVehicleSpawnLive { param($Ip,$ActorId,$VehicleId,$ActorClass,$TemplateName,$Persistent) }
    $script:TankBinary = '/home/dune/server/DuneSandbox/Binaries/Linux/DuneSandboxServer-Linux-Shipping'
    $script:TankOverlay = '/home/dune/server/DuneSandbox/Content/Paks/pakchunk999-DSTRegisTank-2147284-LinuxServer_P'
}
Describe 'Native Regis Tank controls' {
    BeforeEach {
        Mock Resolve-DuneRetailServerSettingsTarget { @{available=$true;namespace='test-bg'} }
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@('map');rows=@(,@('HaggaBasin'))} }
        Mock Invoke-V6Ssh {
            if ($Cmd -like '*get pods*') { '{"items":[{"metadata":{"name":"test-sg-survival-1-pod-2"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' }
            else { @("240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126  $script:TankBinary", "75e7144577253917f6da7312ef5e585b12fb728226a22b0938323751a6b555cd  $script:TankOverlay.pak", "13011a68170df5a9320782691768b0b0bd568610bc682ec1979e979de534c01e  $script:TankOverlay.ucas", "12781c923dcace79204bfecaf0ff4ea49c41ec6a07e68fe81fd3feb96767ced5  $script:TankOverlay.utoc") }
        }
    }
    It 'enables grants only when the running executable and every overlay match' {
        (Get-DuneRegisTankSupport -Ip test -ActorId 544).enabled | Should -BeTrue
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter { $ReadOnly -and $Sql -match "ps.player_pawn_id=544::bigint" -and $Sql -match "online_status::text='Online'" }
    }
    It 'blocks altered binaries, missing assets and repeated hash lines' {
        Mock Invoke-V6Ssh { @("240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126  $script:TankBinary", "240b4bb378a93b70134fa685fc467bc2ae94fd40d81da2feea0f987758bc9126  $script:TankBinary") } -ParameterFilter { $Cmd -like '*sha256sum*' }
        (Get-DuneRegisTankSupport -Ip test -ActorId 544).enabled | Should -BeFalse
    }
    It 'recognizes the current patched executable only with the complete unchanged overlay' {
        Mock Invoke-V6Ssh {
            @("3e8966850e911826f4e5339dea5b3830a71e037acc9b0ed400bc9f0e21e6e318  $script:TankBinary", "75e7144577253917f6da7312ef5e585b12fb728226a22b0938323751a6b555cd  $script:TankOverlay.pak", "13011a68170df5a9320782691768b0b0bd568610bc682ec1979e979de534c01e  $script:TankOverlay.ucas", "12781c923dcace79204bfecaf0ff4ea49c41ec6a07e68fe81fd3feb96767ced5  $script:TankOverlay.utoc")
        } -ParameterFilter { $Cmd -like '*sha256sum*' }
        $support=Get-DuneRegisTankSupport -Ip test -ActorId 544
        $support.enabled | Should -BeTrue
        $support.build | Should -Be '2156652'
    }
    It 'does not probe or grant on a different player map' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@('map');rows=@(,@('DeepDesert'))} }
        (Get-DuneRegisTankSupport -Ip test -ActorId 544).enabled | Should -BeFalse
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'blocks offline players before compatibility probing' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@('map');rows=@()} }
        (Get-DuneRegisTankSupport -Ip test -ActorId 544).enabled | Should -BeFalse
        Should -Invoke Invoke-V6Ssh -Times 0
    }
    It 'passes only exact supported variants through the persistent owned-vehicle path' {
        Mock Invoke-DuneVehicleSpawnLive { @{ok=$true} }
        Invoke-DuneRegisTankGrant -Ip test -ActorId 544 -TemplateName T6_CombatDart | Out-Null
        Should -Invoke Invoke-DuneVehicleSpawnLive -Times 1 -ParameterFilter { $ActorId -eq 544 -and $VehicleId -eq 'Tank' -and $TemplateName -eq 'T6_CombatDart' -and $Persistent }
        { Invoke-DuneRegisTankGrant -Ip test -ActorId 544 -TemplateName T6_Unsupported } | Should -Throw '*variant*'
        { Invoke-DuneRegisTankGrant -Ip test -ActorId 0 -TemplateName T6_CombatFire } | Should -Throw '*online*'
    }
}
