BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'GameConfig.ps1'
    Import-DstLib 'Landsraad.ps1'
    function Invoke-V6Ssh { param($Ip, $Cmd) throw 'Unexpected unmocked SSH call.' }
    $script:Section = '/Script/DuneSandbox.LandsraadSettings'
    $script:CurrentDefaults = "[$script:Section]`n" + 'DedicatedServerData=(m_TaskGoalAmount=70000,m_LandsraadContractsAbandonCooldownSeconds=3600,m_NumberOfWeeksTermRetention=4,m_TermStartedMessage=(Name="Default"),m_BoardLayouts=((Houses=2)),m_ExtraNewMember=True)' + "`nListenServerData=(m_TaskGoalAmount=500)`n"
    $script:Edit = @{file='game';section=$script:Section;key='m_LandsraadContractsAbandonCooldownSeconds';value='5'}
}

Describe 'Landsraad current and legacy server structs' {
    It 'heals a current stub while preserving customized nested members' {
        $raw = "[$script:Section]`n" + 'DedicatedServerData=(m_TaskGoalAmount=12000,m_TermStartedMessage=(Name="Custom, with commas"))'
        $updates = @(Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit) -DefaultsRaw $script:CurrentDefaults)
        $updates[0].value | Should -Match 'm_TaskGoalAmount=12000'
        $updates[0].value | Should -Match 'm_TermStartedMessage=\(Name="Custom, with commas"\)'
        $updates[0].value | Should -Match 'm_BoardLayouts=\(\(Houses=2\)\)'
        $updates[0].value | Should -Match 'm_ExtraNewMember=True'
    }
    It 'seeds a complete current box from game defaults' {
        $updates = @(Convert-DuneStructUpdates -Raw '' -Updates @($script:Edit) -DefaultsRaw $script:CurrentDefaults)
        $updates.Count | Should -Be 1
        $updates[0].key | Should -Be 'DedicatedServerData'
        $updates[0].value | Should -Match 'm_LandsraadContractsAbandonCooldownSeconds=5'
        $updates[0].value | Should -Match 'm_BoardLayouts=\(\(Houses=2\)\)'
        $updates[0].value | Should -Match 'm_ExtraNewMember=True'
        $updates[0].value | Should -Not -Match 'm_TaskGoalAmount=500[,)]'
    }
    It 'preserves legacy nested customizations and the original legacy box' {
        $raw = "[$script:Section]`n" + 'Data=(m_TaskGoalAmount=12000,m_TermStartedMessage=(Name="Custom, message"),m_BoardLayouts=((Houses=9)),m_UnknownCustom=(Nested=(Value=7)))' + "`nListenServerData=(m_TaskGoalAmount=500)`n"
        $updates = @(Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit) -DefaultsRaw $script:CurrentDefaults)
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $doc = ConvertFrom-DuneIniDoc -Raw $out
        $box = Get-DuneStructBlobFromDoc -Doc $doc -Section $script:Section -StructKey 'DedicatedServerData'
        $box | Should -Match 'm_TaskGoalAmount=12000'
        $box | Should -Match 'm_TermStartedMessage=\(Name="Custom, message"\)'
        $box | Should -Match 'm_BoardLayouts=\(\(Houses=9\)\)'
        $box | Should -Match 'm_UnknownCustom=\(Nested=\(Value=7\)\)'
        $box | Should -Match 'm_ExtraNewMember=True'
        (Get-DuneStructBlobFromDoc -Doc $doc -Section $script:Section -StructKey 'Data') | Should -Match 'm_TaskGoalAmount=12000'
        (Get-DuneStructBlobFromDoc -Doc $doc -Section $script:Section -StructKey 'ListenServerData') | Should -Be '(m_TaskGoalAmount=500)'
    }
    It 'prefers the current box when both formats are present' {
        $raw = "[$script:Section]`nData=(m_TaskGoalAmount=111)`nDedicatedServerData=(m_TaskGoalAmount=222)`n"
        (Get-DuneIniEffectiveByKey -Raw $raw).m_TaskGoalAmount | Should -Be '222'
        $updates = @(Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit) -DefaultsRaw $script:CurrentDefaults)
        $updates[0].key | Should -Be 'DedicatedServerData'
        $updates[0].value | Should -Match 'm_TaskGoalAmount=222'
    }
    It 'uses legacy defaults on an older installed game' {
        $raw = "[$script:Section]`nData=(m_TaskGoalAmount=111)`nDedicatedServerData=(m_TaskGoalAmount=222)`n"
        $defaults = "[$script:Section]`nData=(m_TaskGoalAmount=70000)`n"
        $updates = @(Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit) -DefaultsRaw $defaults)
        $updates[0].key | Should -Be 'Data'
        $updates[0].value | Should -Match 'm_TaskGoalAmount=111'
    }
    It 'retains existing legacy format when defaults are unavailable' {
        $raw = "[$script:Section]`nData=(m_TaskGoalAmount=111)`n"
        $updates = @(Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit))
        $updates[0].key | Should -Be 'Data'
        (Get-DuneIniEffectiveByKey -Raw $raw).m_TaskGoalAmount | Should -Be '111'
    }
    It 'fails closed for a malformed legacy box during migration' {
        $raw = "[$script:Section]`nData=(m_TermStartedMessage=(Name=Broken)`n"
        { Convert-DuneStructUpdates -Raw $raw -Updates @($script:Edit) -DefaultsRaw $script:CurrentDefaults } | Should -Throw '*Malformed Landsraad*'
    }
    It 'reads the current box in the Gameplay Admin summary' {
        Mock Resolve-DuneGameConfigPaths { @{game='/config/UserGame.ini'} }
        Mock Invoke-V6Ssh { "[/Script/Other]`nData=(m_TaskGoalAmount=999)`n[/Script/DuneSandbox.LandsraadSettings]`nData=(m_TaskGoalAmount=111)`nDedicatedServerData=(m_TaskGoalAmount=222)`n" }
        $result = Get-DuneLandsraadIniSettings -Ip 'fixture'
        $result.ok | Should -BeTrue
        ($result.settings | Where-Object key -eq 'm_TaskGoalAmount').value | Should -Be '222'
    }
}
