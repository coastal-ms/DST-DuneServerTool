BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'GameConfig.ps1'
    Import-DstLib 'Landsraad.ps1'
    $script:Section = '/Script/DuneSandbox.LandsraadSettings'
    # Exact relevant declarations from the 2156652 packaged DefaultGame.ini.
    $script:PatchDefaults = "[$script:Section]`nDedicatedServerData=(m_TaskGoalAmount=70000,LandsraadMinimumTermDurationInSeconds=172800,m_LandsraadVotingPeriodDurationInSec=118500)`nListenServerData=(m_TaskGoalAmount=100,LandsraadMinimumTermDurationInSeconds=7200)`n"
}

Describe '1.5.15.0 Landsraad settings compatibility' {
    It 'exposes the declared dedicated minimum instead of the removed fixed cycle field' {
        $field = @($script:DuneGameConfigSchema | Where-Object Key -eq 'LandsraadMinimumTermDurationInSeconds')
        $field.Count | Should -Be 1
        $field[0].StructKey | Should -Be 'DedicatedServerData'
        $field[0].Section | Should -Be $script:Section
        $field[0].Default | Should -Be '172800'
        $field[0].Label | Should -Match 'Minimum'
        @($script:DuneGameConfigSchema.Key) | Should -Not -Contain 'm_LandsraadCycleDurationInSeconds'
        @($script:DuneLandsraadIniKeys.Key) | Should -Contain 'LandsraadMinimumTermDurationInSeconds'
        @($script:DuneLandsraadIniKeys.Key) | Should -Not -Contain 'm_LandsraadCycleDurationInSeconds'
    }

    It 'writes the dedicated member without copying the distinct Solo minimum or legacy cycle' {
        $raw = "[$script:Section]`nDedicatedServerData=(m_TaskGoalAmount=321,m_LandsraadCycleDurationInSeconds=604800,LandsraadMinimumTermDurationInSeconds=9000,m_TermStartedMessage=(Name=`"Custom, retained`"))`nListenServerData=(LandsraadMinimumTermDurationInSeconds=7200)`n"
        $updates = @(Convert-DuneStructUpdates -Raw $raw -DefaultsRaw $script:PatchDefaults -Updates @(
            @{file='game';section=$script:Section;key='LandsraadMinimumTermDurationInSeconds';value='18000'}
        ))
        $updates.Count | Should -Be 1
        $updates[0].key | Should -Be 'DedicatedServerData'
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $doc = ConvertFrom-DuneIniDoc -Raw $out
        $box = Get-DuneStructBlobFromDoc -Doc $doc -Section $script:Section -StructKey 'DedicatedServerData'
        $box | Should -Match 'LandsraadMinimumTermDurationInSeconds=18000'
        $box | Should -Match 'm_LandsraadCycleDurationInSeconds=604800'
        $box | Should -Match 'm_TaskGoalAmount=321'
        $box | Should -Match 'Name="Custom, retained"'
        (Get-DuneStructBlobFromDoc -Doc $doc -Section $script:Section -StructKey 'ListenServerData') | Should -Be '(LandsraadMinimumTermDurationInSeconds=7200)'
    }

    It 'does not infer a minimum duration from an existing legacy cycle' {
        $raw = "[$script:Section]`nDedicatedServerData=(m_TaskGoalAmount=321,m_LandsraadCycleDurationInSeconds=99)`n"
        $values = Get-DuneIniEffectiveByKey -Raw $raw
        $values.ContainsKey('LandsraadMinimumTermDurationInSeconds') | Should -BeFalse
        $values.m_LandsraadCycleDurationInSeconds | Should -Be '99'
    }

    It 'keeps removed raw controls out of the current catalog without scrubbing saved overrides' {
        $script:DuneAdvancedCvarCatalogCache = $null
        $script:DuneAdvancedCvarKeyMapCache = $null
        $catalog = @(Get-DuneAdvancedCvarCatalog)
        @($catalog.key) | Should -Not -Contain 'Settings.AmbientOcclusion.Enabled'
        @($catalog.key) | Should -Not -Contain 'tb.EnableAsyncLoadCancelling'
        $raw = "[ConsoleVariables]`nSettings.AmbientOcclusion.Enabled=True`nUnrelated.Manual=0`n"
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @(
            @{file='engine';section='ConsoleVariables';key='Dune.GlobalMiningOutputMultiplier';value='0.5'}
        ) -QuotedKeys @{}
        $out | Should -Match 'Settings.AmbientOcclusion.Enabled=True'
        $out | Should -Match 'Unrelated.Manual=0'
    }
}
