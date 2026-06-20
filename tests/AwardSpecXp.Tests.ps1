# Tests the offline specialization-XP grant (the "+5000 XP" button on
# Players -> Specs): Invoke-DunePlayerAwardXp in lib/GameplayPlayers.ps1.
#
# Behavior: ADD the delta to the stored track, seeding the row from 0 when none
# exists (insert-at-delta), routing through dune.set_specialization_xp_and_level
# (writes BOTH xp_amount and level). The game treats specialization_tracks as
# authoritative on login, so the value reflects in-game after a full re-login.
# Caps XP at the max, recomputes level on the 0..max -> 0..100 scale, and never
# demotes a level already earned in-game. The UI gates the button behind a
# confirm warning because seeding from 0 sets (not adds to) any hidden in-save
# progress that was never persisted to this table.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    $script:curRow       = $null
    $script:lastWriteSql = $null
    $script:lastSelectSql = $null
    $script:writeCount   = 0

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        if ($ReadOnly -and $Sql -match 'SELECT xp_amount, level') {
            $script:lastSelectSql = $Sql
            if ($null -eq $script:curRow) { return @{ ok = $true; maps = @() } }
            return @{ ok = $true; maps = @(@{ xp_amount = $script:curRow.xp; level = $script:curRow.level }) }
        }
        $script:lastWriteSql = $Sql
        $script:writeCount   = $script:writeCount + 1
        return @{ ok = $true; maps = @(); message = 'SELECT 1' }
    }
    function global:ConvertTo-DuneRowMaps {
        param($Result)
        if ($Result -and $Result.maps) { return $Result.maps }
        return @()
    }
    function global:ConvertTo-DuneInt {
        param($Value)
        if ($null -eq $Value) { return 0 }
        return [int]$Value
    }

    Import-DstLib 'GameplayPlayers.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery   -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt     -ErrorAction SilentlyContinue
}

Describe 'Invoke-DunePlayerAwardXp (offline spec XP grant)' -Tag 'Players' {
    BeforeEach {
        $script:curRow        = $null
        $script:lastWriteSql  = $null
        $script:lastSelectSql = $null
        $script:writeCount    = 0
    }

    It 'routes through the stored proc and never does a raw xp_amount-only UPDATE' {
        $script:curRow = @{ xp = 10000; level = 22.6 }
        $r = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Delta 5000
        $r.ok | Should -BeTrue

        $script:lastWriteSql | Should -Match 'dune\.set_specialization_xp_and_level'
        $script:lastWriteSql | Should -Not -Match 'UPDATE\s+dune\.specialization_tracks'
        # current + delta, applied to the same track
        $script:lastWriteSql | Should -Match '15000::integer'
        $script:lastWriteSql | Should -Match "'Combat'::dune\.specializationtracktype"
    }

    It 'caps XP at the track maximum (44182)' {
        $script:curRow = @{ xp = 43000; level = 97.3 }
        $r = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Delta 5000
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '44182::integer'
        $script:lastWriteSql | Should -Match '100::real'   # capped level
    }

    It 'never demotes a level already earned in-game' {
        # Player leveled past the linear scale: 1000 XP but level 90 in-game.
        $script:curRow = @{ xp = 1000; level = 90 }
        $r = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Gathering' -Delta 5000
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '6000::integer'
        $script:lastWriteSql | Should -Match '90::real'    # level preserved, not lowered
    }

    It 'seeds the track via the stored proc when none exists yet (insert-at-delta)' {
        $script:curRow = $null
        $r = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Crafting' -Delta 5000
        $r.ok | Should -BeTrue
        $r.message | Should -Match 'Created'
        $script:lastWriteSql | Should -Match 'dune\.set_specialization_xp_and_level'
        $script:lastWriteSql | Should -Match '5000::integer'
    }

    It 'reads the current track before writing (so it can recompute level)' {
        $script:curRow = @{ xp = 10000; level = 22.6 }
        $null = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 777 -TrackType 'Combat' -Delta 100
        $script:lastSelectSql | Should -Match 'SELECT xp_amount, level'
        $script:lastSelectSql | Should -Match 'player_id = 777'
    }

    It 'clamps a negative delta at zero XP' {
        $script:curRow = @{ xp = 1000; level = 2.3 }
        $r = Invoke-DunePlayerAwardXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Delta -5000
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '0::integer'
    }
}
