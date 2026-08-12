BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'
}

Describe 'Storage overview container coverage' -Tag 'Pure' {
    It 'selects placeables by real storage inventory instead of class-name text' {
        $script:DuneStorageListSql | Should -Match 'inv\.inventory_type = 4'
        $script:DuneStorageListSql | Should -Not -Match "building_type ILIKE"
    }

    It 'uses a friendly class name for the developer container' {
        function global:Invoke-DuneSqlQuery {
            return @{
                ok = $true
                rows = @(
                    @{
                        id = 123
                        name = ''
                        class = 'Developer_StorageContainer_Placeable'
                        map = 'Hagga Basin'
                        item_count = 0
                        item_templates = ''
                        owner_name = 'Tester'
                    }
                )
            }
        }

        function global:ConvertTo-DuneRowMaps {
            param($Result)
            return @($Result.rows)
        }

        try {
            $result = Get-DuneStorageLive -Ip '1.2.3.4'
            $result.ok | Should -BeTrue
            $result.containers.Count | Should -Be 1
            $result.containers[0].class | Should -Be 'Developer Storage Container'
            $result.containers[0].raw_class | Should -Be 'Developer_StorageContainer_Placeable'
        } finally {
            Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
            Remove-Item Function:\global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
        }
    }
}
