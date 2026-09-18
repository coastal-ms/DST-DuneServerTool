BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"

    function global:ConvertTo-DuneSqlString { param([string]$Value) return $Value.Replace("'", "''") }
    function global:ConvertTo-DuneInt { param($Value) return [long]$Value }
    function global:Test-DuneTruthy { param($Value) return [bool]$Value }
    function global:Invoke-DuneSqlQuery { throw 'Test must mock Invoke-DuneSqlQuery.' }
    function global:ConvertTo-DuneRowMaps { param($Result) return @($Result.rows) }
    function global:Invoke-DuneSqlRawStdin { throw 'Test must mock Invoke-DuneSqlRawStdin.' }
    function global:Test-DunePsqlError { return $false }
    function global:Get-DunePsqlErrorMessage { return 'unexpected psql error' }

    Import-DstLib 'GameplayWorld.ps1'
}

Describe 'Portable Self-Hosted blueprint compatibility' {
    It 'normalizes zero-based IDs and remaps pentashields before generating SQL' {
        $global:CapturedBlueprintSql = ''
        Mock Invoke-DuneSqlQuery { @{ ok = $true; rows = @() } }
        Mock Invoke-DuneSqlRawStdin {
            param($Ip, $Sql, $TimeoutSec)
            $global:CapturedBlueprintSql = $Sql
            return 'NOTICE: DST_BP_RESULT bp=40 item=50'
        }

        $result = Import-DuneBlueprintLive -Ip 'test' -PlayerPawnId 7 -Blueprint @{
            name = 'Zero based'
            instances = @(
                @{ instance_id = 0; building_type = 'Foundation'; x = 0; y = 0; z = 0; rotation = 0 }
                @{ instance_id = 2; building_type = 'Wall'; x = 1; y = 2; z = 3; rotation = 90 }
            )
            placeables = @(
                @{ placeable_id = 0; building_type = 'Shield'; x = 1; y = 2; z = 3; rx = 12; ry = 45; rz = 67 }
                @{ placeable_id = 1; building_type = 'Storage'; x = 4; y = 5; z = 6; rx = 1; ry = 2; rz = 3 }
            )
            pentashields = @(
                @{ placeable_id = 0; scale = @(10, 20, 30) }
            )
        }
        $result.ok | Should -BeTrue
        $global:CapturedBlueprintSql | Should -Match "\(v_bp, 1, 'Foundation'"
        $global:CapturedBlueprintSql | Should -Match "\(v_bp, 3, 'Wall'"
        $global:CapturedBlueprintSql | Should -Match "\(v_bp, 1, 'Shield', '\{1,2,3,45,12,67\}'::real\[\]"
        $global:CapturedBlueprintSql | Should -Match "\(v_bp, 1, ARRAY\[10,20,30\]::smallint\[\]\)"
        Remove-Variable CapturedBlueprintSql -Scope Global
    }

    It 'keeps one-based IDs unchanged and allocates mixed omissions collision-free' {
        $oneBased = Resolve-DuneBlueprintIds -Rows @(
            @{ instance_id = 1 },
            @{ instance_id = 4 }
        ) -Property 'instance_id' -Label 'instance'
        $mixed = Resolve-DuneBlueprintIds -Rows @(
            @{ placeable_id = 2 },
            @{},
            @{ placeable_id = 4 },
            @{}
        ) -Property 'placeable_id' -Label 'placeable'

        @($oneBased.ids) | Should -Be @(1, 4)
        @($mixed.ids) | Should -Be @(2, 1, 4, 3)
    }

    It 'rejects invalid and duplicate source IDs before any write' {
        Mock Invoke-DuneSqlQuery { @{ ok = $true; rows = @() } }
        Mock Invoke-DuneSqlRawStdin { throw 'write must not run' }

        foreach ($badId in @(-1, 1.5, 'not-an-id')) {
            $result = Import-DuneBlueprintLive -Ip 'test' -PlayerPawnId 7 -Blueprint @{
                instances = @(
                    @{ instance_id = $badId; building_type = 'Wall'; x = 0; y = 0; z = 0; rotation = 0 }
                )
                placeables = @()
                pentashields = @()
            }
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'non-negative integers'
        }

        $duplicate = Import-DuneBlueprintLive -Ip 'test' -PlayerPawnId 7 -Blueprint @{
            instances = @(
                @{ instance_id = 1; building_type = 'Wall'; x = 0; y = 0; z = 0; rotation = 0 },
                @{ instance_id = 1; building_type = 'Wall'; x = 0; y = 0; z = 0; rotation = 0 }
            )
            placeables = @()
            pentashields = @()
        }
        $duplicate.ok | Should -BeFalse
        $duplicate.error | Should -Match 'duplicate instance source ids'
        Assert-MockCalled Invoke-DuneSqlRawStdin -Times 0 -Exactly
    }

    It 'exports persisted yaw and pitch to portable ry and rx respectively' {
        $placeable = ConvertTo-DunePortableBlueprintPlaceable -Row @{
            placeable_id = 1
            building_type = 'Shield'
            transform = '1,2,3,45,12,67'
        }

        $placeable.rx | Should -Be 12
        $placeable.ry | Should -Be 45
        $placeable.rz | Should -Be 67
    }

    It 'round-trips nonzero base placeable rotations with the portable pitch yaw roll mapping' {
        $global:BaseExportQuery = 0
        $global:CapturedBlueprintSql = ''
        Mock Invoke-DuneSqlQuery {
            $global:BaseExportQuery++
            if ($global:BaseExportQuery -eq 1) {
                return @{
                    ok = $true
                    rows = @(@{
                        building_type = 'Foundation'
                        transform = '100,200,300,0,0,0,1'
                        owner_entity_id = 99
                    })
                }
            }
            if ($global:BaseExportQuery -eq 2) {
                return @{
                    ok = $true
                    rows = @(@{
                        building_type = 'Storage'
                        location = '(101,202,303)'
                        rotation = '(0.038134576,0.189307857,0.239298338,0.951548525)'
                        properties = ''
                    })
                }
            }
            return @{ ok = $true; rows = @() }
        }
        Mock Invoke-DuneSqlRawStdin {
            param($Ip, $Sql, $TimeoutSec)
            $global:CapturedBlueprintSql = $Sql
            return 'NOTICE: DST_BP_RESULT bp=40 item=50'
        }

        $export = Get-DuneBaseExportLive -Ip 'test' -BaseId 7
        $export.ok | Should -BeTrue
        $basePlaceable = $export.blueprint.placeables[0]
        [Math]::Abs($basePlaceable.rx - 20) | Should -BeLessThan 0.0001
        [Math]::Abs($basePlaceable.ry - 30) | Should -BeLessThan 0.0001
        [Math]::Abs($basePlaceable.rz - 10) | Should -BeLessThan 0.0001

        $savedPlaceable = ConvertTo-DunePortableBlueprintPlaceable -Row @{
            placeable_id = 1
            building_type = 'Storage'
            transform = '1,2,3,30,20,10'
        }
        [Math]::Abs($basePlaceable.rx - $savedPlaceable.rx) | Should -BeLessThan 0.0001
        [Math]::Abs($basePlaceable.ry - $savedPlaceable.ry) | Should -BeLessThan 0.0001
        [Math]::Abs($basePlaceable.rz - $savedPlaceable.rz) | Should -BeLessThan 0.0001

        $import = Import-DuneBlueprintLive -Ip 'test' -PlayerPawnId 8 -Blueprint $export.blueprint
        $import.ok | Should -BeTrue
        $match = [regex]::Match(
            $global:CapturedBlueprintSql,
            "\(v_bp, 1, 'Storage', '\{1,2,3,([^,]+),([^,]+),([^}]+)\}'::real\[\]"
        )
        $match.Success | Should -BeTrue
        [Math]::Abs(([double]$match.Groups[1].Value) - 30) | Should -BeLessThan 0.0001
        [Math]::Abs(([double]$match.Groups[2].Value) - 20) | Should -BeLessThan 0.0001
        [Math]::Abs(([double]$match.Groups[3].Value) - 10) | Should -BeLessThan 0.0001

        Remove-Variable BaseExportQuery -Scope Global
        Remove-Variable CapturedBlueprintSql -Scope Global
    }
}
