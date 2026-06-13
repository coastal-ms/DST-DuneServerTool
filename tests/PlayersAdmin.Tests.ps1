# Tests the online-gate + jsonb hardening on Invoke-DunePlayerAwardIntel
# (PlayersAdmin.ps1). The real gate logic runs end-to-end against a stubbed
# Invoke-DuneSqlQuery that serves online_status / intel rows and captures the
# write SQL, so we exercise Test-DunePlayerOffline(ByController) for real.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    # Drive the gate via a fake DB. $script:onlineStatus = $null => no
    # player_state row (treated offline). Capture the write SQL + count.
    $script:onlineStatus = 'Offline'
    $script:curIntel      = 0
    $script:lastWriteSql  = $null
    $script:writeCount    = 0

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        if ($Sql -match 'online_status') {
            if ($null -eq $script:onlineStatus) { return @{ ok = $true; maps = @() } }
            return @{ ok = $true; maps = @(@{ status = $script:onlineStatus }) }
        }
        if ($ReadOnly -and $Sql -match 'm_TechKnowledgePoints') {
            return @{ ok = $true; maps = @(@{ intel = $script:curIntel }) }
        }
        # write path
        $script:lastWriteSql = $Sql
        $script:writeCount   = $script:writeCount + 1
        return @{ ok = $true; maps = @(); message = 'UPDATE 1' }
    }
    function global:ConvertTo-DuneRowMaps {
        param($Result)
        $m = if ($Result -and $Result.maps) { $Result.maps } else { @() }
        return ,@($m)
    }
    function global:ConvertTo-DuneInt {
        param($Value)
        if ($null -eq $Value) { return 0 }
        return [int]$Value
    }

    Import-DstLib 'PlayersAdmin.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery   -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt     -ErrorAction SilentlyContinue
}

Describe 'Invoke-DunePlayerAwardIntel online gate' -Tag 'PlayersAdmin' {
    BeforeEach {
        $script:onlineStatus = 'Offline'
        $script:curIntel     = 0
        $script:lastWriteSql = $null
        $script:writeCount   = 0
    }

    It 'rejects an ONLINE player (pawn id known) and never writes' {
        $script:onlineStatus = 'Online'
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 1000
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Online'
        $r.error | Should -Match 'log out first'
        $script:writeCount | Should -Be 0
    }

    It 'rejects an ONLINE player when only the controller id is known (pawn=0)' {
        $script:onlineStatus = 'Online'
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 0 -IntelDelta 1000
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Online'
        $script:writeCount | Should -Be 0
    }

    It 'writes for an OFFLINE player and returns the new intel total' {
        $script:onlineStatus = 'Offline'
        $script:curIntel     = 250
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 500
        $r.ok | Should -BeTrue
        $r.intel | Should -Be 750
        $r.message | Should -Match 'Set Intel to 750'
        $script:writeCount | Should -Be 1
        $script:lastWriteSql | Should -Match '750'
        $script:lastWriteSql | Should -Match '\b100\b'
    }

    It 'floors a negative result at 0' {
        $script:curIntel = 100
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta -500
        $r.ok | Should -BeTrue
        $r.intel | Should -Be 0
        $r.message | Should -Match 'Set Intel to 0'
    }

    It 'treats a missing player_state row as offline and writes' {
        $script:onlineStatus = $null
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 10
        $r.ok | Should -BeTrue
        $script:writeCount | Should -Be 1
    }

    It 'requires a controller or pawn id' {
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 0 -PawnId 0 -IntelDelta 10
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'required'
        $script:writeCount | Should -Be 0
    }

    It 'builds the TechKnowledgePlayerComponent parent so a missing component is created' {
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 10
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match 'TechKnowledgePlayerComponent'
        $script:lastWriteSql | Should -Match 'jsonb_build_object'
        $script:lastWriteSql | Should -Match 'COALESCE'
    }
}
