BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
}
Describe 'Character inventory and bank separation' {
    It 'keeps bank rows out of the character item editor before pagination' {
        Mock Invoke-DuneSqlQuery { @{ok=$true;columns=@();rows=@()} }
        $result=Get-DunePlayerDetailLive -Ip fixture -PawnId 7 -ControllerId 5 -InventoryOffset 0
        $result.ok | Should -BeTrue
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -Exactly -ParameterFilter {
            $ReadOnly -and $Sql -match 'WHERE inv.actor_id = 7::bigint' -and
            $Sql -match 'inv.inventory_type IS DISTINCT FROM 30' -and $Sql -match 'LIMIT 29 OFFSET 0'
        }
    }
}
