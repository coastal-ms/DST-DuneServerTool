BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRead.ps1'
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'SoloCosmetics.ps1'
}

Describe 'Solo bulk unlock grants' {
    BeforeEach {
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Assert-DuneSoloGameClosed {}
        Mock Get-DuneSoloStatus { @{ inspection=@{ cosmetics=@{available=$true;unlocked=@('Saved');customizations=@();pending=@('Held')};inventories=@(@{kind='backpack';key='inventory:10'}) } } }
        Mock Get-DuneBuildingSetGrantCatalog { @(@{template='Saved'},@{template='Held'},@{template='Missing'}) }
        Mock Invoke-DuneSoloGiveItems { [pscustomobject]@{ok=$true;safetyBackup='verified-backup.db'} }
    }
    It 'skips saved and held templates and submits only missing curated entries' {
        $result = Invoke-DuneSoloGrantUnlocks -Kind building-sets
        $result.submitted | Should -Be 1
        $result.skipped | Should -Be 2
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 1 -ParameterFilter {
            $Destination -eq 'inventory:10' -and $Items.Count -eq 1 -and $Items[0].templateId -eq 'Missing' -and $Confirm -eq 'GIVE SOLO ITEMS'
        }
    }
    It 'does not create a grant when all tokens are already held or saved' {
        Mock Get-DuneBuildingSetGrantCatalog { @(@{template='Saved'},@{template='Held'}) }
        (Invoke-DuneSoloGrantUnlocks -Kind building-sets).submitted | Should -Be 0
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 0
    }
    It 'fails closed when ownership cannot be verified' {
        Mock Get-DuneSoloStatus { @{inspection=@{cosmetics=@{available=$false}}} }
        { Invoke-DuneSoloGrantUnlocks -Kind building-sets } | Should -Throw '*ownership*'
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 0
    }
    It 'refuses grants when the game is running' {
        Mock Assert-DuneSoloGameClosed { throw 'Game is still running.' }
        { Invoke-DuneSoloGrantUnlocks -Kind building-sets } | Should -Throw '*still running*'
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 0
    }
    It 'refuses unknown grant categories' {
        { Invoke-DuneSoloGrantUnlocks -Kind arbitrary } | Should -Throw
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 0
    }
    It 'batches missing tokens into available slots and reports the remainder' {
        Mock Get-DuneSoloStatus { @{ inspection=@{ cosmetics=@{available=$true;unlocked=@();customizations=@();pending=@()};inventories=@(@{kind='backpack';key='inventory:10';maxItemCount=3;itemRows=2}) } } }
        $result = Invoke-DuneSoloGrantUnlocks -Kind building-sets
        $result.submitted | Should -Be 1
        $result.remaining | Should -Be 2
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 1 -ParameterFilter { $Items.Count -eq 1 }
    }
    It 'refuses a full backpack without changing the save' {
        Mock Get-DuneSoloStatus { @{ inspection=@{ cosmetics=@{available=$true;unlocked=@();customizations=@();pending=@()};inventories=@(@{kind='backpack';key='inventory:10';maxItemCount=3;itemRows=3}) } } }
        { Invoke-DuneSoloGrantUnlocks -Kind building-sets } | Should -Throw '*backpack is full*'
        Should -Invoke Invoke-DuneSoloGiveItems -Exactly 0
    }
}
