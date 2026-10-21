BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayBot.ps1'
    Import-DstLib 'Atlas.ps1'
    function global:Invoke-WithDuneLock { param($Name, $Script) & $Script }
    function global:Get-DuneDbContext { throw 'Test must mock the database context' }
    function global:Invoke-DuneSqlQuery { param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec) throw 'Test must mock SQL' }
}

Describe 'Independent market bot work' {
    BeforeEach {
        $script:statePath = Join-Path $TestDrive 'bot-state.json'
        Mock Get-DuneBotStatePath { $script:statePath }
        Mock Read-DuneBotConfig { @{ enabled=$true; maintain_balance=$false; max_buys_per_tick=25; disabled_items=@(); die_size=12; die_target=1; over_market_guard=$true; over_market_baseline=100 } }
        Mock Get-DuneDbContext { @{ ok=$true; ip='test' } }
        Mock Get-DuneBotIdentity { @{ ok=$true; ownerId=1; exchangeId=2 } }
        Mock Invoke-DuneSqlQuery { @{ ok=$true; columns=@('id'); rows=@() } } -ParameterFilter { $ReadOnly }
        Mock Get-DuneBotOrderExpiry { 999999999L }
        Mock Read-DuneBotMaskCache { throw 'Empty market must not build the catalog' }
        Mock Get-DuneBotVendorSnapshot { throw 'Empty market must not read vendors' }
        $script:listTime = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
        Save-DuneBotState @{ last_list_tick=$script:listTime; last_mask_refresh='2026-10-20T00:00:00Z'; last_list_result=@{inserted=7}; relist_pending=$true; seed_progress=@{running=$true}; error_count=3 }
    }
    It 'preserves listing cadence and pending work across repeated buy ticks' {
        1..3 | ForEach-Object { (Invoke-DuneBotBuyTick).ok | Should -BeTrue }
        $state = Read-DuneBotState
        (ConvertTo-DuneBotUtcInstant $state.last_list_tick).ToString('o') | Should -Be ([DateTime]::Parse($script:listTime).ToUniversalTime().ToString('o'))
        $state.last_mask_refresh | Should -Not -BeNullOrEmpty
        $state.last_list_result.inserted | Should -Be 7
        $state.relist_pending | Should -BeTrue
        $state.seed_progress.running | Should -BeTrue
        $state.error_count | Should -Be 3
        $state.last_buy_tick | Should -Not -BeNullOrEmpty
        $state.last_result.candidates | Should -Be 0
        Should -Invoke Read-DuneBotMaskCache -Times 0 -Exactly
        Should -Invoke Get-DuneBotVendorSnapshot -Times 0 -Exactly
        Should -Invoke Invoke-DuneSqlQuery -Times 3 -Exactly -ParameterFilter { $ReadOnly }
    }
    It 'still builds price guards when candidate orders exist' {
        Mock Invoke-DuneSqlQuery { @{ ok=$true; columns=@('id','template_id'); rows=@(,@(1,'knife')) } } -ParameterFilter { $ReadOnly }
        Mock Read-DuneBotMaskCache { @{} }
        Mock Get-DuneBotVendorSnapshot { @{ok=$true; snapshot=@{}} }
        Mock Resolve-DuneBotListingCandidates { return ,@() }
        Mock Get-Random { 2 }
        (Invoke-DuneBotBuyTick).candidates | Should -Be 1
        Should -Invoke Read-DuneBotMaskCache -Times 1 -Exactly
        Should -Invoke Get-DuneBotVendorSnapshot -Times 1 -Exactly
    }
}

Describe 'Database row projection' {
    It 'preserves row ordering, nested values, missing cells and array shape' {
        $rows = @(@(1, @('a','b')), @(2))
        $maps = ConvertTo-DuneRowMaps @{ok=$true; columns=@('id','value'); rows=$rows}
        $maps | Should -HaveCount 2
        $maps[0].id | Should -Be 1
        $maps[0].value | Should -HaveCount 2
        $maps[1].value | Should -BeNullOrEmpty
        (ConvertTo-DuneRowMaps @{ok=$true; columns=@('id'); rows=@(,@(9))}).GetType().Name | Should -Be 'Object[]'
        (ConvertTo-DuneRowMaps @{ok=$false}).Count | Should -Be 0
    }
}

Describe 'Verified map host reuse' {
    BeforeEach {
        $script:AppDir='fixture'
        $script:created=[DateTime]::UtcNow.AddMinutes(-1)
        $script:DuneAtlasSessionCache=@{appDir='fixture'; expires=[DateTime]::MinValue; session=@{available=$true; url='private'; processId=123; creationTicks=$script:created.Ticks.ToString()}}
        Mock Start-DuneAtlasSession { @{available=$true; url='restarted'} }
        Mock Get-CimInstance { [pscustomobject]@{CreationDate=$script:created} }
    }
    It 'checks the running identity instead of staging the package again' {
        (Get-DuneAtlasSession).url | Should -Be 'private'
        Should -Invoke Start-DuneAtlasSession -Times 0 -Exactly
        (Get-DuneAtlasSession).url | Should -Be 'private'
        Should -Invoke Get-CimInstance -Times 1 -Exactly
    }
    It 'verifies startup again when a PID has been reused' {
        Mock Get-CimInstance { [pscustomobject]@{CreationDate=[DateTime]::UtcNow} }
        (Get-DuneAtlasSession).url | Should -Be 'restarted'
        Should -Invoke Start-DuneAtlasSession -Times 1 -Exactly
    }
    It 'verifies startup again after the host exits or the application changes' {
        Mock Get-CimInstance { $null }
        (Get-DuneAtlasSession).url | Should -Be 'restarted'
        $script:AppDir='other'
        (Get-DuneAtlasSession).url | Should -Be 'restarted'
        Should -Invoke Start-DuneAtlasSession -Times 2 -Exactly
    }
    AfterEach { $script:DuneAtlasSessionCache=$null }
}
