BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'GameplayWorld.ps1'
    function global:Invoke-DuneSqlQuery { throw 'Test must mock Invoke-DuneSqlQuery.' }
    function global:ConvertTo-DuneRowMaps { param($Result) return @($Result.rows) }
}

AfterAll {
    Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    Remove-Item Function:\global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
}

Describe 'Storage overview container coverage' -Tag 'Pure' {
    It 'selects placeables by real storage inventory instead of class-name text' {
        $script:DuneStorageListSql | Should -Match 'inv\.inventory_type = 4'
        $script:DuneStorageListSql | Should -Not -Match "building_type ILIKE"
    }

    It 'uses a friendly class name for the developer container' {
        Mock Invoke-DuneSqlQuery {
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

        Mock ConvertTo-DuneRowMaps {
            param($Result)
            return @($Result.rows)
        }

        $result = Get-DuneStorageLive -Ip '1.2.3.4'
        $result.ok | Should -BeTrue
        $result.containers.Count | Should -Be 1
        $result.containers[0].class | Should -Be 'Developer Storage Container'
        $result.containers[0].raw_class | Should -Be 'Developer_StorageContainer_Placeable'
    }

    It 'renames only a proven storage placeable and escapes the label' {
        $script:renameSql = ''
        $script:renameReadOnly = $true
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly)
            $script:renameSql = $Sql
            $script:renameReadOnly = $ReadOnly
            return @{ ok = $true; rows = @(@{ updated_count = '1' }) }
        }
        Mock ConvertTo-DuneRowMaps {
            param($Result)
            return @($Result.rows)
        }

        $result = Invoke-DuneStorageRename -Ip '1.2.3.4' -ContainerId 123 -Name "  Duke's Ore  "

        $result.ok | Should -BeTrue
        $result.name | Should -Be "Duke's Ore"
        $script:renameReadOnly | Should -BeFalse
        $script:renameSql | Should -Match 'FROM dune\.placeables'
        $script:renameSql | Should -Match 'inv\.inventory_type = 4'
        $script:renameSql | Should -Match "Duke''s Ore"
    }

    It 'rejects reserved storage names before querying the database' {
        Mock Invoke-DuneSqlQuery { throw 'Reserved names must fail before a query runs.' }

        (Invoke-DuneStorageRename -Ip '1.2.3.4' -ContainerId 123 -Name '##Internal').ok | Should -BeFalse
        (Invoke-DuneStorageRename -Ip '1.2.3.4' -ContainerId 123 -Name 'None').ok | Should -BeFalse
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }

    It 'guards partial storage stack changes with the quantity originally loaded' {
        $script:stackSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Sql)
            $script:stackSql = $Sql
            return @{ ok = $true; rows = @(@{ item_id = '42' }) }
        }

        $result = Invoke-DuneStorageSetItemStack -Ip '1.2.3.4' -ItemId 42 -StackSize 6 -ExpectedStackSize 10

        $result.ok | Should -BeTrue
        $script:stackSql | Should -Match 'SET stack_size = 6::bigint'
        $script:stackSql | Should -Match 'AND stack_size = 10::bigint'
    }

    It 'guards full player item deletion with the quantity originally loaded' {
        $script:deleteSql = ''
        Mock Invoke-DuneSqlQuery {
            param($Sql)
            $script:deleteSql = $Sql
            return @{ ok = $true; rows = @(@{ deleted = '' }) }
        }

        $result = Invoke-DunePlayerDeleteItem -Ip '1.2.3.4' -ItemId 43 -ExpectedStackSize 4

        $result.ok | Should -BeTrue
        $script:deleteSql | Should -Match 'FROM dune\.items'
        $script:deleteSql | Should -Match 'AND stack_size = 4::bigint'
        $script:deleteSql | Should -Match 'FOR UPDATE'
    }

    Describe 'Placed-base portable blueprint ids' -Tag 'Pure' {
        It 'emits matching one-based placeable and pentashield ids' {
            function global:Invoke-DuneSqlQuery {
                param($Ip, $Sql)
                if ($Sql -match 'FROM dune\.building_instances') {
                    return @{
                        ok = $true
                        rows = @(@{
                            building_type = 'Atreides_Outpost_Foundation'
                            transform = '0,0,0,0,0,0,1'
                            owner_entity_id = 42
                        })
                    }
                }
                return @{
                    ok = $true
                    rows = @(@{
                        building_type = 'Choam_PentashieldSurfaceHorizontal_Placeable'
                        location = '(0,0,256)'
                        rotation = '(0,0,0,1)'
                        properties = '{"Choam_PentashieldSurfaceHorizontal_C":{"m_Scale":[10,20,30]}}'
                    })
                }
            }
            function global:ConvertTo-DuneRowMaps {
                param($Result)
                return @($Result.rows)
            }

            try {
                $result = Get-DuneBaseExportLive -Ip '1.2.3.4' -BaseId 123

                $result.ok | Should -BeTrue
                @($result.blueprint.placeables).Count | Should -Be 1
                @($result.blueprint.pentashields).Count | Should -Be 1
                $result.blueprint.placeables[0].placeable_id | Should -Be 1
                $result.blueprint.pentashields[0].placeable_id | Should -Be 1
            } finally {
                Remove-Item Function:\global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
                Remove-Item Function:\global:ConvertTo-DuneRowMaps -ErrorAction SilentlyContinue
            }
        }
    }
}
