BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    function Invoke-DuneSqlQuery { param($Ip,$Sql,$ReadOnly,$MaxRows,$TimeoutSec) }
}
Describe 'Missing item stat components' {
    It 'exposes empty ammo and refill controls only for known item types without writing' {
        Mock Invoke-DuneSqlQuery {
            if($Sql -match 'FROM dune.items') {
                return @{ok=$true;columns=@('id','template_id','current_ammo','water_amount','water_type','weapon_stats_missing','water_stats_missing');rows=@(
                    @('1','SmugShot5','N/A','N/A','','t','t'),
                    @('2','Decajon','N/A','N/A','','t','t'),
                    @('3','CopperBar','N/A','N/A','','t','t'),
                    @('4','SmugShot5','17','N/A','','f','t'),
                    @('5','Decajon','N/A','3','None','t','f')
                )}
            }
            return @{ok=$true;columns=@();rows=@()}
        }
        $result=Get-DunePlayerDetailLive -Ip '192.0.2.1' -PawnId 42 -ControllerId 43
        $result.ok | Should -BeTrue
        $result.inventory[0].current_ammo | Should -Be '0'
        $result.inventory[1].water_amount | Should -Be '0'
        $result.inventory[1].water_type | Should -Be 'Water'
        $result.inventory[1].water_capacity | Should -Be 10000
        $result.inventory[2].current_ammo | Should -Be 'N/A'
        $result.inventory[2].water_amount | Should -Be 'N/A'
        $result.inventory[3].current_ammo | Should -Be '17'
        $result.inventory[4].water_type | Should -Be 'Water'
        $result.inventory[4].water_amount | Should -Be '3'
        Should -Invoke Invoke-DuneSqlQuery -Times 3 -Exactly -ParameterFilter { $ReadOnly -eq $true }
    }
}
