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
    $script:lastReadSql  = $null
    $script:readCount    = 0
    # How the faked read-back behaves: 'ok' returns $script:readbackRows,
    # 'unsupported' / 'fail' / 'throw' exercise the unverified paths.
    $script:readbackMode = 'ok'
    $script:readbackRows = @()

    function global:Invoke-DuneSqlQuery {
        param([string] $Ip, [string] $Sql, [bool] $ReadOnly, [int] $MaxRows, [int] $TimeoutSec)
        $script:lastWriteSql = $Sql
        $script:lastReadOnly = $ReadOnly
        $script:writeCount   = $script:writeCount + 1
        return @{ ok = $true; maps = @(); message = 'INSERT 0 1' }
    }
    function global:Invoke-DuneSqlSoft {
        param([string] $Ip, [string] $Sql, [int] $MaxRows, [int] $TimeoutSec)
        $script:lastReadSql = $Sql
        $script:readCount   = $script:readCount + 1
        switch ($script:readbackMode) {
            'throw'       { throw 'ssh transport died' }
            'fail'        { return @{ ok = $false; error = 'connection refused' } }
            'unsupported' { return @{ ok = $true; unsupported = $true; reason = 'relation does not exist'; rows = @() } }
            default       { return @{ ok = $true; unsupported = $false; raw = @{ rows = $script:readbackRows } } }
        }
    }
    function global:ConvertTo-DuneRowMaps {
        param($Result)
        return @($script:readbackRows)
    }
    function global:ConvertTo-DuneInt {
        param($Value)
        return [int]$Value
    }
    function global:ConvertTo-DuneSqlString {
        param($Value)
        return ([string]$Value) -replace "'", "''"
    }

    # Build the row shape Get-DuneCoriolisSeedReadback consumes.
    function global:New-FakeSeedRow {
        param([string] $Kind, [string] $Name, [int] $Seed)
        return @{ kind = $Kind; name = $Name; seed = $Seed }
    }

    Import-DstLib 'CoriolisAdmin.ps1'
}

AfterAll {
    Remove-Item function:global:Invoke-DuneSqlQuery     -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneSqlSoft      -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneRowMaps   -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneInt       -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-DuneSqlString -ErrorAction SilentlyContinue
    Remove-Item function:global:New-FakeSeedRow         -ErrorAction SilentlyContinue
}

Describe 'Invoke-DuneCoriolisSetMapSeed (per-map seed)' -Tag 'Coriolis' {
    BeforeEach {
        $script:lastWriteSql = $null
        $script:writeCount   = 0
        $script:lastReadOnly = $null
        $script:lastReadSql  = $null
        $script:readCount    = 0
        $script:readbackMode = 'unsupported'
        $script:readbackRows = @()
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
        $script:lastReadSql  = $null
        $script:readCount    = 0
        $script:readbackMode = 'unsupported'
        $script:readbackRows = @()
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
        $script:lastReadSql  = $null
        $script:readCount    = 0
        $script:readbackMode = 'unsupported'
        $script:readbackRows = @()
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

# ---------------------------------------------------------------------------
# Honest reporting (issue #655).
#
# The reset-seed tables are the game's OUTPUT: on map load the game calls
# dune.coriolis_update_seed(...) and stamps its own derived seed over them. A
# read-back straight after the write therefore proves only that the WRITE
# LANDED — the replacement happens later, on the next map load. These tests pin
# that distinction so nobody re-introduces "applied" wording, and pin that the
# real control (the m_ForcedCoriolisWorldSeed setting) is always pointed at.
# ---------------------------------------------------------------------------
Describe 'Coriolis seed writes report honestly' -Tag 'Coriolis' {
    BeforeEach {
        $script:lastWriteSql = $null
        $script:writeCount   = 0
        $script:lastReadSql  = $null
        $script:readCount    = 0
        $script:readbackMode = 'ok'
        $script:readbackRows = @()
    }

    It 'never claims the seed was applied or set on the map' {
        $script:readbackRows = @(
            (New-FakeSeedRow -Kind 'map'       -Name 'Survival_1' -Seed 7),
            (New-FakeSeedRow -Kind 'partition' -Name '1'          -Seed 7)
        )
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Survival_1' -Seed 7
        $r.message | Should -Not -Match '(?i)\bapplied\b'
        $r.message | Should -Not -Match "(?i)^Set map"
        $r.message | Should -Match '(?i)Recorded seed 7'
    }

    It 'always says the value is transient and points at the Forced Coriolis World Seed setting' {
        $script:readbackRows = @((New-FakeSeedRow -Kind 'partition' -Name '101' -Seed 5))
        $partition = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed 5
        $script:readbackRows = @((New-FakeSeedRow -Kind 'farm' -Name 'farm' -Seed 5))
        $farm = Invoke-DuneCoriolisSetFarmSeed -Ip '1.2.3.4' -Seed 5
        $script:readbackRows = @((New-FakeSeedRow -Kind 'map' -Name 'Overmap' -Seed 5))
        $map = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Overmap' -Seed 5

        foreach ($r in @($partition, $farm, $map)) {
            $r.transient | Should -BeTrue
            $r.message | Should -Match '(?i)transient'
            $r.message | Should -Match 'Forced Coriolis World Seed'
        }
    }

    It 'says the read-back only confirms the write landed, not that the map will use it' {
        $script:readbackRows = @((New-FakeSeedRow -Kind 'map' -Name 'DeepDesert_1' -Seed 3))
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'DeepDesert_1' -Seed 3
        $r.verified | Should -BeTrue
        $r.message | Should -Match '(?i)confirms the write landed'
        $r.message | Should -Match "map 'DeepDesert_1'"
    }

    It 'reports plainly when a re-read shows the value was already replaced' {
        $script:readbackRows = @(
            (New-FakeSeedRow -Kind 'map'       -Name 'Survival_1' -Seed 7),
            (New-FakeSeedRow -Kind 'partition' -Name '1'          -Seed 0)
        )
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Survival_1' -Seed 7
        $r.ok | Should -BeTrue
        $r.verified | Should -BeFalse
        $r.message | Should -Match "(?i)partition '1' now reads 0"
        $r.message | Should -Match '(?i)already replaced'
    }

    It 'reports an unverified write instead of failing when the read-back is unavailable' {
        foreach ($mode in @('unsupported', 'fail', 'throw')) {
            $script:readbackMode = $mode
            $r = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 101 -Seed 4
            $r.ok | Should -BeTrue
            $r.verified | Should -BeFalse
            $r.message | Should -Match '(?i)Could not re-read'
        }
    }

    It 'reads back only rows it actually queried, labelled with the key it read' {
        $script:readbackRows = @(
            (New-FakeSeedRow -Kind 'map'       -Name 'Survival_1' -Seed 7),
            (New-FakeSeedRow -Kind 'partition' -Name '1'          -Seed 7)
        )
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Survival_1' -Seed 7
        # No name is ever assumed: the query only ever names the map that was
        # asked for, and the friendly-name counterpart is not hardcoded anywhere.
        $script:lastReadSql | Should -Match "wm\.map = 'Survival_1'::text"
        $script:lastReadSql | Should -Not -Match 'HaggaBasin'
        @($r.readback).Count | Should -Be 2
        @($r.readback)[0].key | Should -Be 'Survival_1'
    }

    It 'reads the other naming scheme rows too, but only as unclaimed context' {
        # world_map_reset_seed carries both the partition name (Survival_1) and
        # the friendly name (HaggaBasin) for the same map, and the friendly-name
        # row is the one the game rewrites. It is read and reported verbatim, but
        # DST does not claim the two rows describe the same map, and the context
        # row must not decide whether the write landed.
        $script:readbackRows = @(
            (New-FakeSeedRow -Kind 'map'       -Name 'Survival_1' -Seed 7),
            (New-FakeSeedRow -Kind 'partition' -Name '1'          -Seed 7),
            (New-FakeSeedRow -Kind 'other_map' -Name 'HaggaBasin' -Seed 0)
        )
        $r = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Survival_1' -Seed 7

        $script:lastReadSql | Should -Match "wm2\.map <> 'Survival_1'::text"
        # Context is surfaced...
        @($r.other_map_rows).Count | Should -Be 1
        @($r.other_map_rows)[0].key | Should -Be 'HaggaBasin'
        $r.message | Should -Match "'HaggaBasin' = 0"
        $r.message | Should -Match '(?i)does not assume which map'
        # ...but it is not treated as a written row, and does not flip the verdict.
        @($r.readback).Count | Should -Be 2
        $r.verified | Should -BeTrue
        $r.message | Should -Match '(?i)confirms the write landed'
    }

    It 'sources the partition read-back through dune.world_partition, not a guessed map column' {
        $script:readbackRows = @()
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Overmap' -Seed 2
        $script:lastReadSql | Should -Match 'FROM dune\.world_partition wp'
        $script:lastReadSql | Should -Match 'JOIN dune\.world_partition_reset_seed'
        $script:lastReadSql | Should -Not -Match 'world_partition_reset_seed\s+\w*\s*WHERE\s+map'
    }

    It 'never calls the destructive coriolis_update_seed or cleanup functions' {
        $script:readbackRows = @((New-FakeSeedRow -Kind 'map' -Name 'Overmap' -Seed 1))
        $null = Invoke-DuneCoriolisSetMapSeed -Ip '1.2.3.4' -Map 'Overmap' -Seed 1
        $null = Invoke-DuneCoriolisSetPartitionSeed -Ip '1.2.3.4' -PartitionId 2 -Seed 1
        $null = Invoke-DuneCoriolisSetFarmSeed -Ip '1.2.3.4' -Seed 1
        foreach ($sql in @($script:lastWriteSql, $script:lastReadSql)) {
            $sql | Should -Not -Match 'coriolis_update_seed'
            $sql | Should -Not -Match 'corilis_cleanup_map'
            $sql | Should -Not -Match 'coriolis_cleanup_partition'
        }
    }

    It 'issues the read-back as a soft read that cannot fail the write' {
        $script:readbackRows = @((New-FakeSeedRow -Kind 'farm' -Name 'farm' -Seed 6))
        $r = Invoke-DuneCoriolisSetFarmSeed -Ip '1.2.3.4' -Seed 6
        $r.ok | Should -BeTrue
        $script:readCount | Should -Be 1
        $script:lastReadSql | Should -Match 'dune\.world_farm_reset_seed'
    }
}
