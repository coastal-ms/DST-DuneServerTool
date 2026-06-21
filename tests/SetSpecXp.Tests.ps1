# Tests the offline specialization-XP set (the editable XP field on
# Players -> Specs): Invoke-DunePlayerSetSpecXp in lib/GameplayPlayers.ps1.
#
# Behavior: write an ABSOLUTE xp value for one track (the admin types the exact
# value they want), clamped 0..44182, routing through
# dune.set_specialization_xp_and_level (writes BOTH xp_amount and level). Level is
# the linear 0..max -> 0..100 scale of the typed value (admin intent wins, so it
# can lower a level too). The game treats specialization_tracks as authoritative on
# login, so the value reflects in-game after a full re-login. There is no
# read-before-write: the UI already shows the current value, so the set is a single
# authoritative proc call (no add math, no read/write race).

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    $script:lastWriteSql  = $null
    $script:lastSelectSql = $null
    $script:writeCount    = 0

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        if ($ReadOnly) {
            $script:lastSelectSql = $Sql
            return @{ ok = $true; maps = @() }
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

Describe 'Invoke-DunePlayerSetSpecXp (offline spec XP set)' -Tag 'Players' {
    BeforeEach {
        $script:lastWriteSql  = $null
        $script:lastSelectSql = $null
        $script:writeCount    = 0
    }

    It 'routes through the stored proc and never does a raw xp_amount-only UPDATE' {
        $r = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Xp 5000
        $r.ok | Should -BeTrue

        $script:lastWriteSql | Should -Match 'dune\.set_specialization_xp_and_level'
        $script:lastWriteSql | Should -Not -Match 'UPDATE\s+dune\.specialization_tracks'
        # absolute value, on the right track + controller
        $script:lastWriteSql | Should -Match '5000::integer'
        $script:lastWriteSql | Should -Match "'Combat'::dune\.specializationtracktype"
        $script:lastWriteSql | Should -Match '555::bigint'
    }

    It 'writes the typed value verbatim (does not add to anything)' {
        $r = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Gathering' -Xp 12345
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '12345::integer'
    }

    It 'does not read the track before writing (set is authoritative, single call)' {
        $null = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 777 -TrackType 'Combat' -Xp 100
        $script:lastSelectSql | Should -BeNullOrEmpty
        $script:writeCount | Should -Be 1
    }

    It 'caps XP at the track maximum (44182) and writes the max level' {
        $r = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Xp 999999
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '44182::integer'
        $script:lastWriteSql | Should -Match '100::real'   # capped level
    }

    It 'clamps a negative value to zero XP and zero level' {
        $r = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Combat' -Xp -5000
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Match '0::integer'
        $script:lastWriteSql | Should -Match '0::real'
    }

    It 'returns a message reporting the value that was set' {
        $r = Invoke-DunePlayerSetSpecXp -Ip '1.2.3.4' -ControllerId 555 -TrackType 'Crafting' -Xp 5000
        $r.message | Should -Match 'Set'
        $r.message | Should -Match '5000'
    }
}
