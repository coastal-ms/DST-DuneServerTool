BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . "$(Get-DstRepoRoot)\app\lib\Db-Postgres.ps1"
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersAdmin.ps1'
    Import-DstLib 'PlayersRead.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
}
Describe 'Player Scrip balances' {
    BeforeEach {
        Mock Test-V6LegacySolarisFunctionAvailable { $false }
        Mock Get-V6SolarisSqlExpression { "'Solaris'::dune.virtualwallettype" }
        Mock Get-V6HouseCreditSqlExpression { "'HouseCredit'::dune.virtualwallettype" }
        Mock Invoke-DuneSqlQuery {
            if ($Sql -match 'AS pawn_id') {
                return @{ok=$true;columns=@('pawn_id','controller_id','solaris','total_currency');rows=@(,@('7','5','997000','2097000'))}
            }
            if ($Sql -match 'AS bal;') {
                return @{ok=$true;columns=@('bal');rows=@(,@('1100000'))}
            }
            return @{ok=$true;columns=@();rows=@()}
        }
    }
    It 'reads the current enum currency and keeps the selected controller' {
        $r=Get-DunePlayerStatsLive -Ip fixture -PawnId 7
        $r.stats.scrip | Should -Be 1100000
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter {
            $ReadOnly -and $Sql -match 'AS bal;' -and $Sql -match "currency_id = 'HouseCredit'::dune.virtualwallettype" -and $Sql -match 'player_controller_id = 5::bigint'
        }
    }
    It 'preserves legacy numeric currency resolution' {
        Mock Test-V6LegacySolarisFunctionAvailable { $true }
        Mock Resolve-DuneScripCurrencyId { 3 }
        Get-DuneScripCurrencySqlExpression -Ip fixture | Should -Be '3::smallint'
    }
    It 'distinguishes an unavailable read from a zero balance' {
        Mock Invoke-DuneSqlQuery { @{ok=$false;error='Connection lost'} } -ParameterFilter { $Sql -match 'AS bal;' }
        $r=Get-DunePlayerStatsLive -Ip fixture -PawnId 7
        $r.stats.scrip | Should -BeNullOrEmpty
    }
    It 'uses the enum currency in faction balance reads too' {
        $r=Get-DunePlayerFactionsLive -Ip fixture
        $r.ok | Should -BeTrue
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter {
            $ReadOnly -and $Sql -match "vcb.currency_id = 'HouseCredit'::dune.virtualwallettype"
        }
    }
}
