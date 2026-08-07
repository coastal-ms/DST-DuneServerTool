# Tests the Coriolis seed writes in lib/CoriolisAdmin.ps1.
#
# Background: the game DB ships two broken stored functions,
# dune.debug_set_map_seed() and dune.debug_set_partition_seed(). Both reference
# an undeclared `in_server_info` variable, so calling either aborts with
# `missing FROM-clause entry for table "in_server_info"` and the per-map /
# per-partition Apply buttons fail. debug_set_map_seed() has a second bug: it
# filters dune.world_partition_reset_seed by a `map` column that table does not
# have. DST therefore writes the reset-seed tables directly and cascades a map
# to its partitions by joining dune.world_partition.
#
# dune.debug_set_farm_seed() is clean, so the farm path still calls it — these
# tests pin that split so a future refactor does not quietly reintroduce the
# broken calls.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')

    $script:lastWriteSql = $null
    $script:writeCount   = 0
    $script:lastReadOnly = $null

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        $script:lastWriteSql = $Sql
        $script:lastReadOnly = $ReadOnly
        $script:writeCount   = $script:writeCount + 1
        return @{ ok = $true; maps = @(); message = 'INSERT 0 1' }
    }
    function global:ConvertTo-DuneSqlString {
        param($Value)
        return ([string]$Value) -replace "'", "''"
    }

    Import-DstLib 'CoriolisAdmin.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery    -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneSqlString -ErrorAction SilentlyContinue
}

Describe 'Invoke-DuneCoriolisSetMapSeed (per-map seed)' -Tag 'Coriolis' {
    BeforeEach {
        $script:lastWriteSql = $null
        $script:writeCount   = 0
        $script:lastReadOnly = $null
    }

    It 'never calls the broken dune.debug_set_map_seed function' {
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 7
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Not -Match 'debug_set_map_seed'
    }

    It 'upserts the map row and cascades to that map partitions via world_partition' {
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 7
        $script:lastWriteSql | Should -Match 'INSERT INTO dune\.world_map_reset_seed'
        $script:lastWriteSql | Should -Match 'ON CONFLICT \(map\) DO UPDATE'
        $script:lastWriteSql | Should -Match 'INSERT INTO dune\.world_partition_reset_seed'
        $script:lastWriteSql | Should -Match 'FROM dune\.world_partition'
        $script:lastWriteSql | Should -Match 'ON CONFLICT \(partition_id\) DO UPDATE'
        $script:lastWriteSql | Should -Match "'HaggaBasin'::text"
        $script:lastWriteSql | Should -Match '7::int'
    }

    It 'does not filter world_partition_reset_seed by a map column (that column does not exist)' {
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 3
        $script:lastWriteSql | Should -Not -Match 'UPDATE\s+dune\.world_partition_reset_seed'
        $script:lastWriteSql | Should -Not -Match 'world_partition_reset_seed[\s\S]*?WHERE\s+map'
    }

    It 'runs both writes in one transaction' {
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 3
        $script:lastWriteSql | Should -Match 'BEGIN;'
        $script:lastWriteSql | Should -Match 'COMMIT;'
        $script:writeCount | Should -Be 1
    }

    It 'sends the statement as a write, not a read-only query' {
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 0
        $script:lastReadOnly | Should -BeFalse
    }

    It 'escapes apostrophes in the map name' {
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map "Arrakis'Deep" -Seed 1
        $script:lastWriteSql | Should -Match "Arrakis''Deep"
    }

    It 'requires a map name and sends no SQL without one' {
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map '' -Seed 5
        $r.ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }

    It 'rejects out-of-range seeds without sending SQL' {
        (Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 12).ok | Should -BeFalse
        (Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed -2).ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }

    It 'accepts the -1 (auto) and 11 boundary seeds' {
        (Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed -1).ok | Should -BeTrue
        (Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'HaggaBasin' -Seed 11).ok | Should -BeTrue
    }

    It 'preserves the response shape the routes and UI expect' {
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'DeepDesert' -Seed 4
        $r.ok | Should -BeTrue
        $r.scope | Should -Be 'map'
        $r.map | Should -Be 'DeepDesert'
        $r.seed | Should -Be 4
        $r.message | Should -Match '4'
    }
}

Describe 'Invoke-DuneCoriolisSetPartitionSeed (per-partition seed)' -Tag 'Coriolis' {
    BeforeEach {
        $script:lastWriteSql = $null
        $script:writeCount   = 0
        $script:lastReadOnly = $null
    }

    It 'never calls the broken dune.debug_set_partition_seed function' {
        $r = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed 6
        $r.ok | Should -BeTrue
        $script:lastWriteSql | Should -Not -Match 'debug_set_partition_seed'
    }

    It 'upserts world_partition_reset_seed keyed on partition_id only' {
        $null = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed 6
        $script:lastWriteSql | Should -Match 'INSERT INTO dune\.world_partition_reset_seed'
        $script:lastWriteSql | Should -Match '101::int'
        $script:lastWriteSql | Should -Match '6::int'
        $script:lastWriteSql | Should -Match 'ON CONFLICT \(partition_id\) DO UPDATE'
        $script:lastWriteSql | Should -Not -Match 'world_map_reset_seed'
        $script:lastReadOnly | Should -BeFalse
    }

    It 'requires a positive partition id and sends no SQL otherwise' {
        (Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 0 -Seed 5).ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }

    It 'rejects out-of-range seeds without sending SQL' {
        (Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed 12).ok | Should -BeFalse
        (Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed -2).ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }

    It 'preserves the response shape the routes and UI expect' {
        $r = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 201 -Seed 2
        $r.ok | Should -BeTrue
        $r.scope | Should -Be 'partition'
        $r.partition_id | Should -Be 201
        $r.seed | Should -Be 2
    }
}

Describe 'Invoke-DuneCoriolisSetFarmSeed (unchanged farm path)' -Tag 'Coriolis' {
    BeforeEach {
        $script:lastWriteSql = $null
        $script:writeCount   = 0
    }

    It 'still calls dune.debug_set_farm_seed, which is not broken' {
        $r = Invoke-DuneCoriolisSetFarmSeed -Ip '1.2.3.4' -Seed 9
        $r.ok | Should -BeTrue
        $r.scope | Should -Be 'farm'
        $script:lastWriteSql | Should -Match 'dune\.debug_set_farm_seed\(9::int\)'
    }

    It 'rejects out-of-range seeds without sending SQL' {
        (Invoke-DuneCoriolisSetFarmSeed -Ip '1.2.3.4' -Seed 12).ok | Should -BeFalse
        $script:writeCount | Should -Be 0
    }
}
