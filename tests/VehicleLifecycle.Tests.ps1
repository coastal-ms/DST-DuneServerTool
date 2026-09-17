BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '_PostgresFixture.ps1')
    Import-DstLib 'Database.ps1'
    Import-DstLib 'ApiContract.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'InventoryExplorer.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    Import-DstLib 'VehicleDeletion.ps1'
    Import-DstLib 'VehicleLifecycle.ps1'
    function Get-DuneVehicleKitCatalog {
        @{ vehicles = @(@{ className = '/Game/BP_Buggy.BP_Buggy_C'; label = 'Buggy' }) }
    }
    function Invoke-DuneBackupShell { throw 'Live SSH is forbidden in this test.' }
    function Find-V6DbPod { param($Ip, [switch]$Force); throw 'Live database discovery is forbidden in this test.' }
    function Invoke-DuneBattlegroupRestart { throw 'Live battlegroup restart is forbidden in this test.' }
    $script:scopeKey = 'a' * 64
    $script:DuneGameplayItemNames = @{ Copper = 'Copper' }
    $script:DuneGameplayItemRules = @{}
    function Invoke-TestVehicleSql {
        param([string]$Sql)
        $path = Join-Path $TestDrive 'vehicle-query.sql'
        [IO.File]::WriteAllText($path, $Sql, [Text.UTF8Encoding]::new($false))
        $result = Invoke-TestPostgresFile -SqlPath $path
        if ($result.ExitCode -ne 0) { return @{ ok = $false; error = $result.Error } }
        return ConvertFrom-DunePsqlCsv -Output $result.Output -MaxRows 10001
    }
}

Describe 'Vehicle lifecycle host safety' {
    It 'requires exactly one current namespace and binds the database to it' {
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = "DST_VEHICLE_SCOPE=funcom-seabass-sh-test|11111111-1111-1111-1111-111111111111" } }
        Mock Find-V6DbPod { @{ ns = 'funcom-seabass-sh-test'; name = 'db-dbdepl-sts-0' } }
        $scope = Get-DuneVehicleHostScope -Ip '192.0.2.1'
        $scope.key | Should -Match '^[a-f0-9]{64}$'
        $scope.world | Should -Be 'sh-test'
        Should -Invoke Find-V6DbPod -ParameterFilter { $Force } -Times 1
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = "DST_VEHICLE_SCOPE=funcom-seabass-sh-one|11111111-1111-1111-1111-111111111111`nDST_VEHICLE_SCOPE=funcom-seabass-sh-two|22222222-2222-2222-2222-222222222222" } }
        { Get-DuneVehicleHostScope -Ip '192.0.2.1' } | Should -Throw '*exactly one*'
    }

    It 'requires actual backup proof instead of a successful exit status' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test' } }
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'backup claimed success' } }
        (Invoke-DuneVehicleSafetyBackup -Ip 'fixture').ok | Should -BeFalse
        Mock Invoke-DuneBackupShell {
            param($Script)
            $Script | Should -Match 'stat -c %s'
            $Script | Should -Match '-gt 1024'
            $Script | Should -Match 'database-dumps/sh-test'
            @{ rc = 0; out = 'DST_VEHICLE_BACKUP=/fixture/backup|2048' }
        }
        (Invoke-DuneVehicleSafetyBackup -Ip 'fixture').ok | Should -BeTrue
    }

    It 'rejects a live session even after Kubernetes reports stopped' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test'; namespace = 'funcom-seabass-sh-test' } }
        Mock Invoke-DuneBackupShell { @{ rc = 0; out = 'Stopped' } }
        Mock Invoke-DuneSqlQuery { @{ ok = $true; columns = @('sessions'); rows = @(,@('1')) } }
        (Test-DuneVehicleWindowStopped -Ip 'fixture' -DatabaseScope $script:scopeKey).ok | Should -BeFalse
    }

    It 'never treats missing, nonfinite or negative integrity as full health' {
        foreach ($value in @('', $null, 'NaN', 'Infinity', '-1', 'missing')) {
            ConvertTo-DuneVehicleNumber $value | Should -BeNullOrEmpty
        }
        ConvertTo-DuneVehicleNumber '0' | Should -Be 0
        ConvertTo-DuneVehicleNumber '12.5' | Should -Be 12.5
    }

    It 'keeps all deletion control routes host-local but fleet and integrity readable' {
        $source = Get-Content (Join-Path $PSScriptRoot '..\app\server\routes\VehicleDeletion.ps1') -Raw
        @([regex]::Matches($source, "Register-DuneRoute -Method (GET|POST|DELETE) -Path '/api/gameplay/vehicles/deletions[^']*' -LocalOnly")).Count | Should -Be 4
        $source | Should -Match "-Path '/api/gameplay/vehicles' -Handler"
        $source | Should -Match "-Path '/api/gameplay/vehicles/\{id\}/integrity' -Handler"
        $source | Should -Match "-Path '/api/gameplay/vehicles/delete' -LocalOnly"
        $source | Should -Match '\$body.*vehicle_ids'
        $source | Should -Match 'Select between 1 and 100 vehicles'
        $source | Should -Match "Test-DuneDisruptiveActionGuard"
        $source | Should -Match "-Path '/api/gameplay/vehicles/names' -Handler"
    }

    It 'validates vehicle names with the existing game-safe rules' {
        (Test-DuneVehicleRenameName -Name '  Desert Runner  ').name | Should -Be 'Desert Runner'
        (Test-DuneVehicleRenameName -Name '').ok | Should -BeFalse
        (Test-DuneVehicleRenameName -Name ('x' * 65)).ok | Should -BeFalse
        (Test-DuneVehicleRenameName -Name "bad`nname").ok | Should -BeFalse
        $reservedPrefix = Test-DuneVehicleRenameName -Name '##reserved'
        $reservedPrefix.ok | Should -BeFalse
        $reservedPrefix.error | Should -Be 'Remove the leading ## and enter a custom name.'
        (Test-DuneVehicleRenameName -Name 'None').ok | Should -BeFalse
    }

    It 'writes one exact batch, reads it back after commit, and launches one restart' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test' } }
        $script:renameQueries = @()
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly)
            $script:renameQueries += @{ sql = $Sql; readOnly = [bool]$ReadOnly }
            if ($ReadOnly) {
                return @{ ok = $true; columns = @('vehicle_id', 'actor_name'); rows = @(@('42', 'Desert Runner'), @('43', 'Sand Runner')) }
            }
            return @{ ok = $true; columns = @(); rows = @() }
        }
        Mock Invoke-DuneBattlegroupRestart { @{ ok = $true; message = 'Restart launched.' } }

        $result = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Desert Runner' }
            @{ vehicle_id = 43; expected_current_name = 'Hauler'; name = 'Sand Runner' }
        )

        $result.ok | Should -BeTrue -Because $result.error
        $result.renamed | Should -Be 2
        $result.restart_started | Should -BeTrue
        $script:renameQueries.Count | Should -Be 2
        $script:renameQueries[0].sql | Should -Match 'BEGIN;'
        $script:renameQueries[0].sql | Should -Match 'COMMIT;'
        $script:renameQueries[0].sql | Should -Match 'permission_actor_rank'
        $script:renameQueries[0].sql | Should -Match "online_status IS DISTINCT FROM 'Offline'"
        $script:renameQueries[0].sql | Should -Match 'recovered_vehicles'
        $script:renameQueries[0].sql | Should -Match 'backup_vehicles'
        $script:renameQueries[0].sql | Should -Match "COALESCE\(pa\.actor_name, ''\) IS DISTINCT FROM t\.expected_current_name"
        $script:renameQueries[0].sql | Should -Match "'Scout'::text, 'Desert Runner'::text"
        $script:renameQueries[0].sql | Should -Match "'Hauler'::text, 'Sand Runner'::text"
        Should -Invoke Invoke-DuneBattlegroupRestart -Times 1
    }

    It 'flattens rank-1 controller ownership and treats distinct Offline owners as eligible' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test' } }
        Mock Invoke-DuneSqlQuery {
            return @{
                ok = $true
                columns = @(
                    'vehicle_id','class','map','vehicle_name','actor_state','permissions',
                    'module_count','recovery_count','recovery_durability','backup_count',
                    'cargo_hold_count','cargo_conflict_count','closure_owner_conflict_count',
                    'cargo_stack_count','cargo_max_item_count','cargo_max_item_volume','target_revision'
                )
                rows = @(, @(
                    '42','BP_Buggy_C','Hagga','Scout','Default',
                    '[{"player_id":"101","rank":1,"character_name":"Coastal","online_status":"Offline","player_state_count":1},{"player_id":"111","rank":1,"character_name":"Hawk","online_status":"Offline","player_state_count":1}]',
                    '1','0',$null,'0','1','0','0','0','10','100',('b' * 32)
                ))
            }
        }

        $fleet = Get-DuneVehicleFleetLive -Ip fixture

        $fleet.ok | Should -BeTrue -Because $fleet.error
        $fleet.vehicles[0].permissions.Count | Should -Be 2
        $fleet.vehicles[0].permissions[0].player_id | Should -Be '101'
        $fleet.vehicles[0].rename_blocked_reason | Should -BeNullOrEmpty
    }

    It 'reports a committed batch truthfully when restart launch fails' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test' } }
        Mock Invoke-DuneSqlQuery {
            param($ReadOnly)
            if ($ReadOnly) {
                return @{ ok = $true; columns = @('vehicle_id', 'actor_name'); rows = @(,@('42', 'Desert Runner')) }
            }
            return @{ ok = $true; columns = @(); rows = @() }
        }
        Mock Invoke-DuneBattlegroupRestart { throw 'restart unavailable' }
        $result = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Desert Runner' }
        )
        $result.ok | Should -BeFalse
        $result.committed | Should -BeTrue
        $result.error | Should -Match 'were committed'
        $result.error | Should -Match 'restart unavailable'
    }

    It 'still launches the required restart when committed readback fails' {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; world = 'sh-test' } }
        Mock Invoke-DuneSqlQuery {
            param($ReadOnly)
            if ($ReadOnly) { return @{ ok = $false; error = 'readback unavailable' } }
            return @{ ok = $true; columns = @(); rows = @() }
        }
        Mock Invoke-DuneBattlegroupRestart { @{ ok = $true; message = 'Restart launched.' } }
        $result = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Desert Runner' }
        )
        $result.ok | Should -BeFalse
        $result.committed | Should -BeTrue
        $result.restart_started | Should -BeTrue
        $result.error | Should -Match 'readback unavailable'
        $result.error | Should -Match 'restart was launched'
        Should -Invoke Invoke-DuneBattlegroupRestart -Times 1
    }

    It 'rejects old inventory-cache cursors for vehicle reads' {
        (Invoke-DuneInventoryGroupedPage -Mode live -EntityTypes @('vehicle') -CursorSource cache).status | Should -Be 409
        (Invoke-DuneInventoryOccurrencesPage -Mode live -TemplateId Copper -EntityTypes @('vehicle') -CursorSource cache).status | Should -Be 409
    }

}

Describe 'Vehicle module repair' {
    It 'maps installed positional module templates to recorded default durability' {
        $script:DuneVehicleModuleDurabilityDefaults = $null
        Get-DuneVehicleModuleDefaultDurability 'OrnithopterTransportHullFrontRight_6' | Should -Be 4500
        Get-DuneVehicleModuleDefaultDurability 'OrnithopterTransportLocomotionCenterLeft1_Unique_Speed_6' | Should -Be 3000
        Get-DuneVehicleModuleDefaultDurability 'SandbikeEngine_6' | Should -Be 1000
    }

    It 'uses one catalog-backed database statement for every repairable module' {
        $script:repairQueries = @()
        Mock Get-DuneVehicleModuleRepairDefaults {
            @{ Hull = 4500; Engine = 3000 }
        }
        Mock Invoke-DuneSqlQuery {
            param($Ip, $Sql, $ReadOnly, $MaxRows, $TimeoutSec)
            $script:repairQueries += $Sql
            return @{ ok = $true; columns = @('repaired', 'skipped'); rows = @(,@('2', '0')) }
        }

        $result = Invoke-DuneVehicleRepair -Ip fixture -VehicleId 42

        $result.ok | Should -BeTrue
        $result.repaired | Should -Be 2
        $script:repairQueries.Count | Should -Be 1
        $script:repairQueries[0] | Should -Match 'jsonb_each_text'
        $script:repairQueries[0] | Should -Match '"Hull":4500'
        $script:repairQueries[0] | Should -Match '"Engine":3000'
        $script:repairQueries[0] | Should -Match 'UPDATE dune\.vehicle_modules'
        $script:repairQueries[0] | Should -Match 'MaxDurability'
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter { $Bulk }
    }

    It 'retries one idempotent repair after a transient SSH disconnect' {
        $script:attempt = 0
        Mock Get-DuneVehicleModuleRepairDefaults { @{ Hull = 4500 } }
        Mock Start-Sleep {}
        Mock Invoke-DuneSqlQuery {
            $script:attempt++
            if ($script:attempt -eq 1) {
                return @{ ok = $false; error = 'Connection to 192.0.2.1 closed by remote host.' }
            }
            return @{ ok = $true; columns = @('repaired', 'skipped'); rows = @(,@('1', '0')) }
        }

        $result = Invoke-DuneVehicleRepair -Ip fixture -VehicleId 42

        $result.ok | Should -BeTrue
        $result.repaired | Should -Be 1
        Should -Invoke Invoke-DuneSqlQuery -Times 2
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 2 }
    }
}

Describe 'Disposable PostgreSQL fixture routing' {
    BeforeEach {
        $script:fixtureEnvironment = @{}
        foreach ($name in @('DST_TEST_POSTGRES_DATABASE', 'DST_TEST_POSTGRES_PSQL',
            'PGHOST', 'PGPORT', 'PGUSER', 'PGDATABASE', 'PGHOSTADDR', 'PGSERVICE',
            'PGSERVICEFILE', 'PGSYSCONFDIR', 'PGOPTIONS', 'PGPASSFILE')) {
            $script:fixtureEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $env:DST_TEST_POSTGRES_PSQL = 'fixture-must-not-launch.exe'
        $env:DST_TEST_POSTGRES_DATABASE = 'dst_inventory_fixture_guard'
        $env:PGHOST = 'localhost'
        $env:PGPORT = '55439'
        $env:PGUSER = 'dst_inventory'
    }
    AfterEach {
        foreach ($name in $script:fixtureEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:fixtureEnvironment[$name])
        }
    }

    It 'rejects <Name> overrides before executing any SQL' -TestCases @(
        @{ Name = 'PGHOSTADDR'; Value = '192.0.2.123' }
        @{ Name = 'PGHOSTADDR'; Value = '127.0.0.1,192.0.2.123' }
        @{ Name = 'PGHOSTADDR'; Value = ' ' }
        @{ Name = 'PGSERVICE'; Value = 'other-service' }
        @{ Name = 'PGSERVICEFILE'; Value = 'other-service.conf' }
        @{ Name = 'PGSYSCONFDIR'; Value = 'other-service-directory' }
    ) {
        param($Name, $Value)
        [Environment]::SetEnvironmentVariable($Name, $Value)
        { Invoke-TestVehicleSql -Sql 'SELECT 1;' } | Should -Throw "*$Name*"
        { New-TestPostgresStartInfo -SqlPath 'game-session.sql' } | Should -Throw "*$Name*"
    }

    It 'rejects non-fixture or connection-string <Name> values' -TestCases @(
        @{ Name = 'PGHOST'; Value = '192.0.2.123' }
        @{ Name = 'PGHOST'; Value = 'localhost,192.0.2.123' }
        @{ Name = 'PGPORT'; Value = '5432' }
        @{ Name = 'PGUSER'; Value = 'postgres' }
        @{ Name = 'PGDATABASE'; Value = 'service=other-service' }
        @{ Name = 'DST_TEST_POSTGRES_DATABASE'; Value = 'service=other-service' }
        @{ Name = 'DST_TEST_POSTGRES_DATABASE'; Value = 'postgresql://192.0.2.123/dst_inventory' }
        @{ Name = 'DST_TEST_POSTGRES_DATABASE'; Value = 'dst_inventory host=192.0.2.123' }
    ) {
        param($Name, $Value)
        [Environment]::SetEnvironmentVariable($Name, $Value)
        { Invoke-TestVehicleSql -Sql 'SELECT 1;' } | Should -Throw '*explicit disposable loopback*'
    }

    It 'pins the supported <HostValue> form and sanitizes each subprocess snapshot' -TestCases @(
        @{ HostValue = 'localhost'; Address = '127.0.0.1' }
        @{ HostValue = '127.0.0.1'; Address = '127.0.0.1' }
        @{ HostValue = '::1'; Address = '::1' }
    ) {
        param($HostValue, $Address)
        $env:PGHOST = $HostValue
        $env:PGDATABASE = $env:DST_TEST_POSTGRES_DATABASE
        $env:PGOPTIONS = '-c search_path=other_schema'
        $env:PGPASSFILE = 'personal-password-file'
        $start = New-TestPostgresStartInfo -SqlPath 'fixture with spaces.sql'
        @($start.ArgumentList) | Should -Contain $Address
        @($start.ArgumentList) | Should -Contain '55439'
        @($start.ArgumentList) | Should -Contain 'dst_inventory'
        @($start.ArgumentList) | Should -Contain 'dst_inventory_fixture_guard'
        @($start.ArgumentList) | Should -Contain 'fixture with spaces.sql'
        @($start.ArgumentList) | Should -Contain '-X'
        @($start.ArgumentList) | Should -Contain '-w'
        @($start.Environment.Keys) | Should -Not -Contain 'PGOPTIONS'
        @($start.Environment.Keys) | Should -Not -Contain 'PGHOSTADDR'
        @($start.Environment.Keys) | Should -Not -Contain 'PGSERVICE'
        $start.Environment['PGPASSFILE'] | Should -Not -Be 'personal-password-file'
        $start.Environment['PGSSLMODE'] | Should -Be 'disable'
        $env:PGHOSTADDR = '192.0.2.123'
        @($start.Environment.Keys) | Should -Not -Contain 'PGHOSTADDR'
        { New-TestPostgresStartInfo -SqlPath 'next-query.sql' } | Should -Throw '*PGHOSTADDR*'
    }
}

Describe 'Vehicle lifecycle PostgreSQL model' -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
    BeforeAll {
        $existing = Invoke-TestVehicleSql -Sql "SELECT to_regnamespace('dune') IS NULL AS empty;"
        if (-not $existing.ok -or $existing.rows[0][0] -ne 't') {
            throw 'Vehicle fixture schema must be absent before running destructive tests.'
        }
    }
    BeforeEach {
        Mock Get-DuneVehicleHostScope { @{ key = $script:scopeKey; namespace = 'funcom-seabass-sh-test'; world = 'sh-test' } }
        Mock Test-DuneVehicleWindowStopped { @{ ok = $true } }
        Mock Invoke-DuneBattlegroupRestart { @{ ok = $true; message = 'Restart launched.' } }
        Mock Invoke-DuneSqlQuery {
            param($Sql, $ReadOnly)
            if ($ReadOnly) { $Sql = Wrap-DuneReadOnlySql -Sql $Sql }
            Invoke-TestVehicleSql -Sql $Sql
        }
        $schema = @'
CREATE SCHEMA dune;
SET search_path TO dune, public;
CREATE TABLE dune.actors (id bigint PRIMARY KEY, class text, map text, owner_account_id bigint, state text NOT NULL DEFAULT 'Default');
CREATE TABLE dune.vehicles (id bigint PRIMARY KEY REFERENCES dune.actors(id) ON DELETE CASCADE);
CREATE TABLE dune.vehicle_modules (
    id bigint PRIMARY KEY, vehicle_id bigint REFERENCES dune.vehicles(id) ON DELETE CASCADE,
    template_id text, stats jsonb
);
CREATE TABLE dune.inventories (
    id bigint PRIMARY KEY, actor_id bigint REFERENCES dune.actors(id) ON DELETE CASCADE,
    inventory_type int, vehicle_module_id bigint REFERENCES dune.vehicle_modules(id) ON DELETE CASCADE,
    exchange_id bigint, item_id bigint, max_item_count int, max_item_volume numeric
);
CREATE TABLE dune.items (
    id bigint PRIMARY KEY, inventory_id bigint REFERENCES dune.inventories(id) ON DELETE CASCADE,
    template_id text, stack_size int, quality_level int, stats jsonb
);
CREATE TABLE dune.player_state (player_pawn_id bigint, player_controller_id bigint, character_name text, account_id bigint, online_status text);
CREATE TABLE dune.permission_actor (actor_id bigint PRIMARY KEY, actor_type int, actor_name text);
CREATE TABLE dune.permission_actor_rank (permission_actor_id bigint, player_id bigint, rank int);
CREATE TABLE dune.recovered_vehicles (vehicle_id bigint REFERENCES dune.vehicles(id) ON DELETE CASCADE, character_id bigint, chassis_durability numeric);
CREATE TABLE dune.backup_vehicles (vehicle_id bigint REFERENCES dune.vehicles(id) ON DELETE CASCADE, character_id bigint);
CREATE TABLE dune.markers (marker_hash_id bigint);
CREATE TABLE dune.player_markers (marker_hash_id bigint);
CREATE TABLE dune.placeables (id bigint, building_type text, is_hologram boolean, owner_entity_id bigint);
CREATE TABLE dune.actor_fgl_entities (actor_id bigint, entity_id bigint);
CREATE FUNCTION dune.permission_actor_destroy(target bigint) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM permission_actor_rank WHERE permission_actor_id = target;
    DELETE FROM permission_actor WHERE actor_id = target;
    DELETE FROM markers WHERE marker_hash_id = target;
    DELETE FROM player_markers WHERE marker_hash_id = target;
END $$;
CREATE FUNCTION dune.delete_actors(targets bigint[]) RETURNS void LANGUAGE sql AS $$
    DELETE FROM actors WHERE id = ANY(targets);
$$;
INSERT INTO dune.actors (id, class, map, owner_account_id) VALUES
    (42, 'BP_Buggy_C', 'Hagga', NULL), (43, 'BP_Unknown_C', 'Hagga', NULL),
    (100, 'BP_Player_C', 'Hagga', 900), (200, 'BP_Container_C', 'Hagga', NULL);
INSERT INTO dune.vehicles VALUES (42), (43);
INSERT INTO dune.player_state VALUES (100, 101, 'Owner', 900, 'Offline'), (110, 111, 'Shared', 901, 'Offline');
INSERT INTO dune.permission_actor VALUES (42, 2, 'Scout');
INSERT INTO dune.permission_actor_rank VALUES (42, 101, 1), (42, 111, 2);
INSERT INTO dune.vehicle_modules VALUES (300, 42, 'Chassis', '{"FVehicleModuleDurabilityStats":[{},{"CurrentDurability":25,"MaxDurability":100,"DecayedMaxDurability":80}]}'),
    (301, 42, 'Engine', '{}');
INSERT INTO dune.inventories (id, actor_id, inventory_type, vehicle_module_id, max_item_count, max_item_volume) VALUES
    (500, 42, 0, NULL, 10, 100), (501, 42, NULL, NULL, 1, 1), (502, 43, 0, NULL, 0, 0), (503, 100, 0, NULL, 10, 100), (504, 200, 0, NULL, 10, 100),
    (505, NULL, NULL, 300, 1, 1);
INSERT INTO dune.items VALUES (600, 500, 'Copper', 7, 1, '{}'), (601, 501, 'Copper', 99, 1, '{}'),
    (602, 503, 'Copper', 88, 1, '{}'), (603, 504, 'Copper', 77, 1, '{}'), (604, 505, 'Copper', 1, 1, '{}');
INSERT INTO dune.recovered_vehicles VALUES (42, 1000, 0.5);
INSERT INTO dune.backup_vehicles VALUES (42, 1000);
INSERT INTO dune.markers VALUES (42);
INSERT INTO dune.player_markers VALUES (42);
'@
        $setup = Invoke-TestVehicleSql -Sql $schema
        if (-not $setup.ok) { throw $setup.error }
    }
    AfterEach {
        $cleanup = Invoke-TestVehicleSql -Sql 'SET client_min_messages = warning; DROP SCHEMA IF EXISTS dune CASCADE;'
        if (-not $cleanup.ok) { throw $cleanup.error }
    }

    It 'reads claimed and unclaimed structural vehicles with correct ranks, subtype and nullable integrity' {
        $fleet = Get-DuneVehicleFleetLive -Ip fixture
        $fleet.ok | Should -BeTrue -Because $fleet.error
        $fleet.total | Should -Be 2
        $claimed = $fleet.vehicles | Where-Object id -eq 42
        $claimed.owners | Should -Be 'Owner'
        $claimed.permissions.Count | Should -Be 2
        $claimed.permissions[0].online_status | Should -Be 'Offline'
        $claimed.subtype | Should -Be 'Buggy'
        $claimed.subtype_source | Should -Be 'catalog'
        $claimed.actor_state | Should -Be 'Default'
        $claimed.cargo_stack_count | Should -Be 1
        ($fleet.vehicles | Where-Object id -eq 43).ownership_status | Should -Be 'unowned'
        $integrity = Get-DuneVehicleIntegrityLive -Ip fixture -VehicleId 42
        $integrity.ok | Should -BeTrue -Because $integrity.error
        $integrity.modules[0].current_durability | Should -Be 25
        $integrity.modules[1].current_durability | Should -BeNullOrEmpty
    }

    It 'renames an exact active vehicle and rejects stale expected names' {
        [void](Invoke-TestVehicleSql -Sql 'DELETE FROM dune.recovered_vehicles WHERE vehicle_id = 42; DELETE FROM dune.backup_vehicles WHERE vehicle_id = 42;')
        $renamed = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Desert Runner' }
        )
        $renamed.ok | Should -BeTrue -Because $renamed.error
        $renamed.restart_started | Should -BeTrue
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].vehicle_name | Should -Be 'Desert Runner'
        $stale = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Old Target' }
        )
        $stale.ok | Should -BeFalse
        $stale.error | Should -Match 'changed'
        Should -Invoke Invoke-DuneBattlegroupRestart -Times 1
    }

    It 'renames an unnamed vehicle using the empty fleet representation' {
        [void](Invoke-TestVehicleSql -Sql @'
DELETE FROM dune.recovered_vehicles WHERE vehicle_id = 42;
DELETE FROM dune.backup_vehicles WHERE vehicle_id = 42;
UPDATE dune.permission_actor SET actor_name = NULL WHERE actor_id = 42;
'@)
        $renamed = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = ''; name = 'Desert Runner' }
        )

        $renamed.ok | Should -BeTrue -Because $renamed.error
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].vehicle_name | Should -Be 'Desert Runner'
        Should -Invoke Invoke-DuneBattlegroupRestart -Times 1
    }

    It 'blocks online, unresolved, backup, and recovery vehicle names without partial writes' {
        $online = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Online Rename' }
        )
        $online.ok | Should -BeFalse
        $online.error | Should -Match 'Backed-up or recovery'
        [void](Invoke-TestVehicleSql -Sql "DELETE FROM dune.recovered_vehicles; DELETE FROM dune.backup_vehicles; UPDATE dune.player_state SET online_status = 'Online' WHERE player_controller_id = 101;")
        $online = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Online Rename' }
        )
        $online.ok | Should -BeFalse
        $online.error | Should -Match 'Offline'
        [void](Invoke-TestVehicleSql -Sql "UPDATE dune.player_state SET online_status = 'Offline' WHERE player_controller_id = 101; DELETE FROM dune.player_state WHERE player_controller_id = 101;")
        $unresolved = Invoke-DuneVehicleRenameBatch -Ip fixture -DatabaseScope $script:scopeKey -Changes @(
            @{ vehicle_id = 42; expected_current_name = 'Scout'; name = 'Unknown Owner' }
        )
        $unresolved.ok | Should -BeFalse
        $unresolved.error | Should -Match 'resolve exactly once'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].vehicle_name | Should -Be 'Scout'
        Should -Invoke Invoke-DuneBattlegroupRestart -Times 0
    }

    It 'excludes component, player and placeable holds from all vehicle cargo projections' {
        $items = Invoke-DuneInventorySearchLive -Ip fixture -EntityTypes @('vehicle')
        $items.ok | Should -BeTrue -Because $items.error
        $items.items.Count | Should -Be 1
        $items.items[0].id | Should -Be 600
        $items.items[0].entity.workspacePath | Should -Be '/vehicles?view=cargo&scope_type=vehicle&scope_id=42'
        $grouped = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('vehicle') -ScopeType vehicle -ScopeId 42
        $grouped.ok | Should -BeTrue -Because $grouped.error
        $grouped.groups[0].totalQuantity | Should -Be 7
        $grouped.players[0].id | Should -Be 100
        $rows = Invoke-DuneInventoryOccurrencesLive -Ip fixture -EntityTypes @('vehicle') -ScopeType vehicle -ScopeId 42 -TemplateId Copper
        $rows.ok | Should -BeTrue -Because $rows.error
        $rows.items.Count | Should -Be 1
        $wrongScope = Invoke-DuneInventoryOccurrencesLive -Ip fixture -EntityTypes @('vehicle') -ScopeType vehicle -ScopeId 43 -TemplateId Copper
        $wrongScope.ok | Should -BeTrue -Because $wrongScope.error
        $wrongScope.items.Count | Should -Be 0
    }

    It 'refuses multiple cargo holds and does not attribute cargo to a shared or ambiguous owner' {
        $additionalHold = Invoke-TestVehicleSql -Sql 'INSERT INTO dune.inventories (id, actor_id, inventory_type) VALUES (506, 42, 0);'
        $additionalHold.ok | Should -BeTrue -Because $additionalHold.error
        (Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('vehicle')).ok | Should -BeFalse
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].deletion_blocked_reason | Should -Match 'cannot prove'
        $clearAdditionalHold = Invoke-TestVehicleSql -Sql 'DELETE FROM dune.inventories WHERE id = 506; INSERT INTO dune.permission_actor_rank VALUES (42,111,1);'
        $clearAdditionalHold.ok | Should -BeTrue -Because $clearAdditionalHold.error
        $fleet = Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42
        $fleet.vehicles[0].ownership_status | Should -Be 'ambiguous'
        $cargo = Invoke-DuneInventoryGroupedLive -Ip fixture -EntityTypes @('vehicle') -PlayerId 110
        $cargo.ok | Should -BeTrue -Because $cargo.error
        $cargo.groups.Count | Should -Be 0
    }

    It 'rejects a conflicting single cargo hold before queueing and inside deletion' {
        [void](Invoke-TestVehicleSql -Sql 'UPDATE dune.inventories SET exchange_id = 700 WHERE id = 500;')
        $fleet = Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42
        $fleet.vehicles[0].cargo_hold_count | Should -Be 1
        $fleet.vehicles[0].deletion_blocked_reason | Should -Match 'cannot prove'
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $fleet.vehicles[0].target_revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'conflicting ownership'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).total | Should -Be 1
    }

    It 'rejects cross-actor module inventory type <InventoryType> before queueing and inside deletion' -TestCases @(
        @{ InventoryType = '0' }
        @{ InventoryType = '1' }
        @{ InventoryType = 'NULL' }
    ) {
        param($InventoryType)
        $setup = Invoke-TestVehicleSql -Sql "INSERT INTO dune.inventories (id, actor_id, inventory_type, vehicle_module_id) VALUES (506, 100, $InventoryType, 300);"
        $setup.ok | Should -BeTrue -Because $setup.error
        $fleet = Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42
        $fleet.vehicles[0].deletion_blocked_reason | Should -Match 'cannot prove'
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $fleet.vehicles[0].target_revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'owned by another actor'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).total | Should -Be 1
    }

    It 'rejects a target-owned non-cargo inventory linked to another vehicle module' {
        $setup = Invoke-TestVehicleSql -Sql @'
INSERT INTO dune.vehicle_modules VALUES (302, 43, 'Engine', '{}');
INSERT INTO dune.inventories (id, actor_id, inventory_type, vehicle_module_id) VALUES (506, 42, 1, 302);
'@
        $setup.ok | Should -BeTrue -Because $setup.error
        $fleet = Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42
        $fleet.vehicles[0].deletion_blocked_reason | Should -Match 'cannot prove'
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $fleet.vehicles[0].target_revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'owned by another actor'
        (Get-DuneVehicleFleetLive -Ip fixture).total | Should -Be 2
        $survivor = Invoke-TestVehicleSql -Sql 'SELECT count(*) FROM dune.inventories WHERE id = 506;'
        $survivor.rows[0][0] | Should -Be '1'
    }

    It 'binds actor and module inventory changes to deletion but ignores ordinary integrity updates' {
        $before = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        [void](Invoke-TestVehicleSql -Sql "UPDATE dune.vehicle_modules SET stats = '{}' WHERE id = 300;")
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision | Should -Be $before
        [void](Invoke-TestVehicleSql -Sql 'UPDATE dune.items SET stack_size = 8 WHERE id = 600;')
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $before -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'changed'
        $afterActorInventoryChange = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        [void](Invoke-TestVehicleSql -Sql 'UPDATE dune.items SET stack_size = 2 WHERE id = 604;')
        $moduleInventoryResult = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $afterActorInventoryChange -DatabaseScope $script:scopeKey
        $moduleInventoryResult.ok | Should -BeFalse
        $moduleInventoryResult.error | Should -Match 'changed'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).total | Should -Be 1
    }

    It 'deletes exactly one vehicle and proves cargo, markers, modules and recovery cleanup' {
        $revision = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeTrue -Because $result.error
        (Get-DuneVehicleFleetLive -Ip fixture).total | Should -Be 1
        $survivors = Invoke-TestVehicleSql -Sql 'SELECT count(*) FROM dune.items;'
        $survivors.rows[0][0] | Should -Be '2'
    }

    It 'blocks travel inside the transaction' {
        $revision = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        [void](Invoke-TestVehicleSql -Sql "UPDATE dune.actors SET state = 'Travel' WHERE id = 42;")
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'travel is still pending'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).total | Should -Be 1
    }

    It 'allows backup and recovery state records to be explicitly deleted' -TestCases @(@{ State = 'VehicleRecovery' }, @{ State = 'VehicleBackup' }) {
        param($State)
        [void](Invoke-TestVehicleSql -Sql "UPDATE dune.actors SET state = '$State' WHERE id = 42;")
        $fleet = Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42
        $fleet.vehicles[0].deletion_blocked_reason | Should -BeNullOrEmpty
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $fleet.vehicles[0].target_revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeTrue -Because $result.error
    }

    It 'rejects an actual connected game session inside the deletion transaction' {
        $revision = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        $sleepPath = Join-Path $TestDrive 'game-session.sql'
        [IO.File]::WriteAllText($sleepPath, "SET application_name = 'DuneSandbox - fixture'; SELECT pg_sleep(30);")
        $process = [Diagnostics.Process]::Start((New-TestPostgresStartInfo -SqlPath $sleepPath))
        $backendPid = 0
        try {
            $connected = $false
            for ($attempt = 0; $attempt -lt 10 -and -not $connected; $attempt++) {
                $probe = Invoke-TestVehicleSql -Sql "SELECT pid::text FROM pg_stat_activity WHERE application_name = 'DuneSandbox - fixture';"
                $connected = $probe.ok -and $probe.rows.Count -eq 1
                if ($connected) { $backendPid = [int]$probe.rows[0][0] }
                if (-not $connected) { Start-Sleep -Milliseconds 100 }
            }
            $connected | Should -BeTrue
            $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $revision -DatabaseScope $script:scopeKey
            $result.ok | Should -BeFalse
            $result.error | Should -Match 'live game database session'
            (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).total | Should -Be 1
        } finally {
            if ($backendPid -gt 0) { [void](Invoke-TestVehicleSql -Sql "SELECT pg_terminate_backend($backendPid);") }
            if (-not $process.HasExited) { Stop-Process -Id $process.Id }
            $process.Dispose()
        }
    }

    It 'rolls permission cleanup back when a dependent record fails postflight' {
        [void](Invoke-TestVehicleSql -Sql 'CREATE OR REPLACE FUNCTION dune.permission_actor_destroy(target bigint) RETURNS void LANGUAGE sql AS $$ DELETE FROM dune.permission_actor WHERE actor_id = target; $$;')
        $revision = (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision
        $result = Invoke-DuneVehicleDeleteTransaction -Ip fixture -VehicleId 42 -TargetRevision $revision -DatabaseScope $script:scopeKey
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'postflight failed'
        (Get-DuneVehicleFleetLive -Ip fixture -VehicleId 42).vehicles[0].target_revision | Should -Be $revision
    }
}
