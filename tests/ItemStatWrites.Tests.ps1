BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    function Test-DunePlayerOffline { param($Ip,$PawnId,[switch]$RequireVerifiedStatus) @{ok=$true} }
    function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec,[switch]$Bulk) }
}
Describe 'Explicit missing-component item writes' {
    BeforeEach {
        $script:captured=''
        Mock Invoke-DuneSqlQuery {
            $script:captured=$Sql
            @{ok=$true;columns=@('item_id','before_ammo','after_ammo','refilled');rows=@(,@('5','0','12','1'))}
        }
    }
    It 'streams the ammo update and only seeds a known missing weapon component' {
        $r=Invoke-DunePlayerSetWeaponAmmo -Ip '192.0.2.1' -PawnId 42 -ItemId 5 -Ammo 12 -ExpectedAmmo 0
        $r.ok | Should -BeTrue
        $script:captured | Should -Match '"smugshot5"'
        $script:captured | Should -Match "NOT \(i.stats \? 'FWeaponItemStats'\)"
        $script:captured | Should -Match 'inv.actor_id = 42::bigint'
        $script:captured | Should -Match 't.before_ammo::bigint = 0::bigint'
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter { $Bulk -and -not $ReadOnly }
    }
    It 'seeds an empty known water container without converting other fluids' {
        $r=Invoke-DunePlayerSetItemWater -Ip '192.0.2.1' -ItemId 5 -Amount 10000
        $r.ok | Should -BeTrue
        $script:captured | Should -Match '"decajon"'
        $script:captured | Should -Match "FillableType' = 'None'"
        $script:captured | Should -Match 'WHERE i.id = 5::bigint'
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter { $Bulk -and -not $ReadOnly }
    }
    It 'uses saved or table capacity for bulk refill within the selected player inventories' {
        $r=Invoke-DunePlayerFillWater -Ip '192.0.2.1' -PawnId 42
        $r.ok | Should -BeTrue
        $script:captured | Should -Match 'inv.actor_id = 42::bigint'
        $script:captured | Should -Match 'AS capacity'
        $script:captured | Should -Match "IN \('Water','None'\)"
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter { $Bulk -and -not $ReadOnly }
    }
}
