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
    $script:resolvedPawn  = 200
    $script:lastWriteSql  = $null
    $script:writeCount    = 0
    $script:writes        = @()
    $script:lastLevelReadSql = $null

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        if ($Sql -match 'online_status') {
            if ($null -eq $script:onlineStatus) { return @{ ok = $true; maps = @() } }
            return @{ ok = $true; maps = @(@{ status = $script:onlineStatus }) }
        }
        if ($ReadOnly -and $Sql -match 'AS pid') {
            return @{ ok = $true; maps = @(@{ pid = $script:resolvedPawn }) }
        }
        if ($ReadOnly -and $Sql -match 'FLevelComponent' -and $Sql -match 'AS entity_id') {
            $script:lastLevelReadSql = $Sql
            return @{ ok = $true; maps = @(@{ entity_id = '555'; xp_text = '1000'; sp_unspent_text = '0'; sp_total_text = '0' }) }
        }
        if ($ReadOnly -and $Sql -match 'KeystonePlayerComponent') {
            return @{ ok = $true; maps = @(@{ ids = '[]' }) }
        }
        if ($ReadOnly -and $Sql -match 'm_TechKnowledgePoints') {
            return @{ ok = $true; maps = @(@{ intel = $script:curIntel }) }
        }
        # write path
        $script:lastWriteSql = $Sql
        $script:writeCount   = $script:writeCount + 1
        $script:writes       = @($script:writes) + $Sql
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
        $script:resolvedPawn = 200
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

    It 'writes to the PAWN actor for an OFFLINE player and returns the new intel total' {
        $script:onlineStatus = 'Offline'
        $script:curIntel     = 250
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 500
        $r.ok | Should -BeTrue
        $r.intel | Should -Be 750
        $r.message | Should -Match 'Set Intel to 750'
        $script:writeCount | Should -Be 1
        $script:lastWriteSql | Should -Match '750'
        # Intel lives on the pawn (200), NOT the controller (100).
        $script:lastWriteSql | Should -Match '\b200\b'
        $script:lastWriteSql | Should -Not -Match '\b100\b'
    }

    It 'resolves the pawn from the controller when only the controller id is known and writes to the pawn' {
        $script:onlineStatus = 'Offline'
        $script:resolvedPawn = 200
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 0 -IntelDelta 10
        $r.ok | Should -BeTrue
        $script:writeCount | Should -Be 1
        $script:lastWriteSql | Should -Match '\b200\b'
        $script:lastWriteSql | Should -Not -Match '\b100\b'
    }

    It 'clamps the new intel total to the spendable cap (2779)' {
        $script:curIntel = 2700
        $r = Invoke-DunePlayerAwardIntel -Ip 'x' -ActorId 100 -PawnId 200 -IntelDelta 500
        $r.ok | Should -BeTrue
        $r.intel | Should -Be 2779
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

Describe 'Invoke-DunePlayerAwardCharXp offline actor targeting' -Tag 'PlayersAdmin' {
    BeforeEach {
        $script:onlineStatus     = 'Offline'
        $script:curIntel         = 0
        $script:resolvedPawn     = 200
        $script:lastWriteSql     = $null
        $script:lastLevelReadSql = $null
        $script:writeCount       = 0
        $script:writes           = @()
    }

    It 'rejects an ONLINE player and never writes' {
        $script:onlineStatus = 'Online'
        $r = Invoke-DunePlayerAwardCharXp -Ip 'x' -PawnId 200 -XpDelta 5000
        $r.ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }

    It 'reads the FLevelComponent from the PAWN (not the controller)' {
        $r = Invoke-DunePlayerAwardCharXp -Ip 'x' -PawnId 200 -XpDelta 5000
        $r.ok | Should -BeTrue
        # FLevelComponent is keyed on the pawn actor id (200), per the reference tool.
        $script:lastLevelReadSql | Should -Match '\b200\b'
    }

    It 'writes the FLevelComponent update keyed on the resolved entity_id' {
        $r = Invoke-DunePlayerAwardCharXp -Ip 'x' -PawnId 200 -XpDelta 5000
        $r.ok | Should -BeTrue
        ($script:writes -join ' ') | Should -Match 'FLevelComponent'
        ($script:writes -join ' ') | Should -Match '\b555\b'
    }

    It 'writes the intel cascade to the PAWN actor, not the controller' {
        $r = Invoke-DunePlayerAwardCharXp -Ip 'x' -PawnId 200 -XpDelta 5000
        $r.ok | Should -BeTrue
        $intelWrite = $script:writes | Where-Object { $_ -match 'TechKnowledgePlayerComponent' } | Select-Object -First 1
        $intelWrite | Should -Not -BeNullOrEmpty
        $intelWrite | Should -Match 'id = 200::bigint'
    }

    It 'requires a pawn id' {
        $r = Invoke-DunePlayerAwardCharXp -Ip 'x' -PawnId 0 -XpDelta 5000
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'required'
        $script:writeCount | Should -Be 0
    }
}
