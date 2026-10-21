BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'PlatformCache.ps1'
    Import-DstLib 'PublicIp.ps1'
    Import-DstLib 'MapPlatform.ps1'
    function global:Get-DuneDbContext { @{ ok=$true; ip='fixture' } }
    function global:Invoke-DuneSqlRaw { param($Ip,$Sql,[switch]$Csv,$TimeoutSec) }
    function global:Test-DunePsqlError { param($Output) $false }
}
Describe 'Demand-driven widget status' {
    BeforeEach {
        $script:DuneApiLockTable = [hashtable]::Synchronized(@{})
        Mock Invoke-DuneSqlRaw { "map,ready,alive,is_current`nDeepDesert_1,t,t,t`nSurvival_1,t,f,t" }
    }
    It 'coalesces narrow reads and preserves the P34 alive distinction' {
        $a = Get-DuneWidgetStatus
        $b = Get-DuneWidgetStatus
        $a.maps.Count | Should -Be 2
        $a.maps[1].ready | Should -BeTrue
        $a.maps[1].alive | Should -BeFalse
        $b.observedAt | Should -Be $a.observedAt
        Should -Invoke Invoke-DuneSqlRaw -Times 1 -Exactly -ParameterFilter { $Sql -eq 'SELECT map, ready, alive, server_id IN (SELECT * FROM dune.active_server_ids) AS is_current FROM dune.farm_state ORDER BY map;' }
    }
    It 'ignores retired duplicates and old on-demand maps' {
        Mock Invoke-DuneSqlRaw { "map,ready,alive,is_current`nDeepDesert_1,f,f,f`nDeepDesert_1,t,t,t`nSH_Arrakeen,f,f,f`nOvermap,t,t,t`nSurvival_1,t,t,t" }
        $result = Get-DuneWidgetStatus
        $result.maps.Count | Should -Be 3
        @($result.maps | Where-Object map -eq DeepDesert_1).Count | Should -Be 1
        @($result.maps | Where-Object { -not $_.ready -or -not $_.alive }).Count | Should -Be 0
    }
    It 'retains a core-map outage without trusting its retired ready row' {
        Mock Invoke-DuneSqlRaw { "map,ready,alive,is_current`nDeepDesert_1,t,t,f`nSurvival_1,t,t,t" }
        $map = (Get-DuneWidgetStatus).maps | Where-Object map -eq DeepDesert_1
        $map.ready | Should -BeFalse
        $map.alive | Should -BeFalse
    }
    It 'does not combine stale readiness with current liveness or hide an active instance' {
        Mock Invoke-DuneSqlRaw { "map,ready,alive,is_current`nDeepDesert_1,t,f,f`nDeepDesert_1,f,t,t`nSH_Arrakeen,f,t,t" }
        $result = Get-DuneWidgetStatus
        $map = $result.maps | Where-Object map -eq DeepDesert_1
        $map.ready | Should -BeFalse
        $map.alive | Should -BeTrue
        @($result.maps | Where-Object map -eq SH_Arrakeen).Count | Should -Be 1
    }
    It 'returns an empty map list without inventing readiness' {
        Mock Invoke-DuneSqlRaw { 'map,ready,alive,is_current' }
        @( (Get-DuneWidgetStatus).maps ).Count | Should -Be 0
    }
    It 'does not return cached ready data after a failed fresh read' {
        Mock Invoke-DuneSqlRaw { throw 'offline' }
        { Get-DuneWidgetStatus } | Should -Throw '*offline*'
    }
    It 'does no map source work without a viewer and resumes for a live viewer' {
        Mock Invoke-DuneMapsPlatformRefresh {}
        Mock Set-DuneMapsSourceNextDue {}
        $cancel = [Threading.CancellationTokenSource]::new()
        try {
            $null = Invoke-DuneMapsPlatformRefreshLoop -CancellationToken $cancel.Token -InitialDelaySec 0 -NextDelay { $cancel.Cancel(); 0.01 }.GetNewClosure()
            Should -Invoke Invoke-DuneMapsPlatformRefresh -Times 0 -Exactly
        } finally { $cancel.Dispose() }
        (Get-DunePlatformCoordinationTable)['maps:viewer-until'] = [DateTime]::UtcNow.AddMinutes(2)
        $cancel = [Threading.CancellationTokenSource]::new()
        try {
            $null = Invoke-DuneMapsPlatformRefreshLoop -CancellationToken $cancel.Token -InitialDelaySec 0 -NextDelay { $cancel.Cancel(); 0.01 }.GetNewClosure()
            Should -Invoke Invoke-DuneMapsPlatformRefresh -Times 1 -Exactly
        } finally { $cancel.Dispose() }
    }
}
