BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '_PostgresFixture.ps1')
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'ReserveRecovery.ps1'
    function global:Get-DuneVehicleHostScope { throw 'Test must mock Get-DuneVehicleHostScope.' }
    function global:Invoke-DuneVerifiedSafetyBackup { throw 'Test must mock Invoke-DuneVerifiedSafetyBackup.' }

    function Invoke-ReserveFixtureSql {
        param([string]$Sql)
        $path = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).sql"
        [IO.File]::WriteAllText($path, $Sql)
        $execution = Invoke-TestPostgresFile -SqlPath $path
        if ($execution.ExitCode -ne 0) { return @{ ok = $false; error = $execution.Error } }
        return ConvertFrom-DunePsqlCsv -Output $execution.Output -MaxRows 5000
    }
    function Get-ReserveFixtureLocation {
        $result = Invoke-ReserveFixtureSql 'SELECT inventory_id::text FROM dune.items WHERE id = 301;'
        $result.ok | Should -BeTrue
        return (ConvertTo-DuneRowMaps -Result $result)[0]['inventory_id']
    }
    function Remove-ReserveFixtureSchema {
        if (-not $script:ReserveFixtureOwnsSchema) { return }
        $cleanup = Invoke-ReserveFixtureSql 'SET client_min_messages = warning; DROP SCHEMA dune CASCADE;'
        if (-not $cleanup.ok) { throw $cleanup.error }
        $script:ReserveFixtureOwnsSchema = $false
        $probe = Invoke-ReserveFixtureSql "SELECT to_regnamespace('dune') IS NULL AS empty;"
        if (-not $probe.ok -or (ConvertTo-DuneRowMaps -Result $probe)[0]['empty'] -ne 't') {
            throw 'Reserve fixture schema cleanup could not be verified.'
        }
    }
}

AfterAll {
    Remove-Item function:global:Get-DuneVehicleHostScope -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneVerifiedSafetyBackup -ErrorAction SilentlyContinue
}

Describe 'Reserve disposable PostgreSQL transactions' -Skip:(
    -not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE
) {
    BeforeEach {
        $script:ReserveFixtureOwnsSchema = $false
        $script:DuneReserveRecoveryStateFile = Join-Path $TestDrive 'postgres-state.json'
        Remove-Item -LiteralPath $script:DuneReserveRecoveryStateFile -Force -ErrorAction SilentlyContinue
        $probe = Invoke-ReserveFixtureSql 'SELECT current_database() AS database;'
        $probe.ok | Should -BeTrue
        (ConvertTo-DuneRowMaps -Result $probe)[0]['database'] | Should -BeExactly $env:DST_TEST_POSTGRES_DATABASE
        $existing = Invoke-ReserveFixtureSql "SELECT to_regnamespace('dune') IS NULL AS empty;"
        if (-not $existing.ok -or (ConvertTo-DuneRowMaps -Result $existing)[0]['empty'] -ne 't') {
            throw 'Reserve fixture schema must be absent before running destructive tests.'
        }
        $created = Invoke-ReserveFixtureSql 'CREATE SCHEMA dune;'
        if (-not $created.ok) { throw $created.error }
        # AfterEach also runs when the remaining setup or a test assertion fails.
        $script:ReserveFixtureOwnsSchema = $true
        $setup = Invoke-ReserveFixtureSql @'
CREATE TABLE dune.encrypted_player_state (
    id bigint PRIMARY KEY, account_id bigint, player_pawn_id bigint,
    player_controller_id bigint, online_status text
);
CREATE VIEW dune.player_state AS SELECT * FROM dune.encrypted_player_state;
CREATE TABLE dune.inventories (
    id bigint PRIMARY KEY, actor_id bigint, inventory_type integer,
    max_item_count integer, max_item_volume numeric
);
CREATE TABLE dune.actor_inventories (inventory_id bigint, component_name_hash bigint);
CREATE TABLE dune.items (
    id bigint PRIMARY KEY, inventory_id bigint REFERENCES dune.inventories(id),
    position_index integer, template_id text, stack_size bigint, quality_level integer,
    volume_override numeric, stats jsonb
);
INSERT INTO dune.encrypted_player_state VALUES (1,99,42,43,'Offline');
INSERT INTO dune.inventories VALUES (216,42,33,50,1000),(205,42,0,10,100);
INSERT INTO dune.actor_inventories VALUES (216,-689927216);
INSERT INTO dune.items VALUES (301,216,4,'CopperBar',6,0,2,'{}'),(201,205,1,'CopperBar',2,0,1,'{}');
'@
        $setup.ok | Should -BeTrue
        Mock Get-DuneVehicleHostScope { @{ key = ('b' * 64) } }
        Mock Invoke-DuneSqlQuery { param($Sql) Invoke-ReserveFixtureSql $Sql }
        Mock Invoke-DuneVerifiedSafetyBackup { @{ ok = $true; path = 'synthetic'; bytes = 2048; database_scope = ('b' * 64) } }
    }
    AfterEach {
        Remove-ReserveFixtureSchema
    }

    It 'executes the exact snapshot, guarded move, independent readback and guarded rollback' {
        $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        $preview.available | Should -BeTrue
        $preview.items.Count | Should -Be 1
        $move = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $preview.revision
        $move.ok | Should -BeTrue -Because $move.error
        Get-ReserveFixtureLocation | Should -Be '205'
        $empty = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        $empty.available | Should -BeFalse
        $empty.rollback.recovery_id | Should -Be $move.recovery_id
        $rollback = Invoke-DuneReserveRecoveryRollback -Ip fixture -PawnId 42 -ControllerId 43 -RecoveryId $move.recovery_id
        $rollback.ok | Should -BeTrue -Because $rollback.error
        Get-ReserveFixtureLocation | Should -Be '216'
        (Read-DuneReserveRecoveryState).history[0].status | Should -Be 'rolled_back'
    }

    It 'fails closed on <Case> without making up a matching identity' -TestCases @(
        @{ Case = 'stale controller'; Change = 'UPDATE dune.encrypted_player_state SET player_controller_id=44;' }
        @{ Case = 'ambiguous exact pair'; Change = "INSERT INTO dune.encrypted_player_state VALUES (2,100,42,43,'Offline');" }
        @{ Case = 'missing account'; Change = 'UPDATE dune.encrypted_player_state SET account_id=NULL;' }
        @{ Case = 'online player'; Change = "UPDATE dune.encrypted_player_state SET online_status='Online';" }
        @{ Case = 'multiple Reserve inventories'; Change = 'INSERT INTO dune.inventories VALUES (217,42,33,50,1000); INSERT INTO dune.actor_inventories VALUES (217,-689927216);' }
        @{ Case = 'multiple Backpacks'; Change = 'INSERT INTO dune.inventories VALUES (206,42,0,10,100);' }
    ) {
        param($Case, $Change)
        (Invoke-ReserveFixtureSql $Change).ok | Should -BeTrue
        $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        $preview.ok | Should -BeTrue
        $preview.available | Should -BeFalse
        $preview.blocked_reason | Should -Not -BeNullOrEmpty
        Get-ReserveFixtureLocation | Should -Be '216'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }

    It 'rejects a snapshot revision after its account identity changes' {
        $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        (Invoke-ReserveFixtureSql 'UPDATE dune.encrypted_player_state SET account_id=100;').ok | Should -BeTrue
        $move = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $preview.revision
        $move.error | Should -Match 'changed'
        Get-ReserveFixtureLocation | Should -Be '216'
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }

    It 'rolls the transaction back if <Case> after backup' -TestCases @(
        @{ Case = 'the player logs in'; Change = "UPDATE dune.encrypted_player_state SET online_status='Online';" }
        @{ Case = 'the account changes'; Change = 'UPDATE dune.encrypted_player_state SET account_id=100;' }
        @{ Case = 'the exact pair becomes ambiguous'; Change = "INSERT INTO dune.encrypted_player_state VALUES (2,100,42,43,'Offline');" }
        @{ Case = 'an item changes'; Change = 'UPDATE dune.items SET stack_size=7 WHERE id=301;' }
    ) {
        param($Case, $Change)
        $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        Mock Invoke-DuneVerifiedSafetyBackup {
            (Invoke-ReserveFixtureSql $Change).ok | Should -BeTrue
            return @{ ok = $true; path = 'synthetic'; bytes = 2048; database_scope = ('b' * 64) }
        }
        $move = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $preview.revision
        $move.ok | Should -BeFalse
        $move.error | Should -Match 'transaction rolled back'
        Get-ReserveFixtureLocation | Should -Be '216'
        (Read-DuneReserveRecoveryState).entries[0].status | Should -Be 'failed'
    }

    It 'refuses rollback if <Case> after the rollback backup' -TestCases @(
        @{ Case = 'the account changes'; Change = 'UPDATE dune.encrypted_player_state SET account_id=100;' }
        @{ Case = 'the exact pair becomes ambiguous'; Change = "INSERT INTO dune.encrypted_player_state VALUES (2,100,42,43,'Offline');" }
        @{ Case = 'a recovered item changes'; Change = 'UPDATE dune.items SET stack_size=7 WHERE id=301;' }
    ) {
        param($Case, $Change)
        $preview = Get-DuneReserveRecoveryPreview -Ip fixture -PawnId 42 -ControllerId 43
        $move = Invoke-DuneReserveRecovery -Ip fixture -PawnId 42 -ControllerId 43 -Revision $preview.revision
        $move.ok | Should -BeTrue
        Mock Invoke-DuneVerifiedSafetyBackup {
            (Invoke-ReserveFixtureSql $Change).ok | Should -BeTrue
            return @{ ok = $true; path = 'synthetic'; bytes = 2048; database_scope = ('b' * 64) }
        }
        $rollback = Invoke-DuneReserveRecoveryRollback -Ip fixture -PawnId 42 -ControllerId 43 -RecoveryId $move.recovery_id
        $rollback.ok | Should -BeFalse
        $rollback.error | Should -Match 'transaction made no changes'
        Get-ReserveFixtureLocation | Should -Be '205'
        (Read-DuneReserveRecoveryState).entries[0].status | Should -Be 'moved'
    }
}

Describe 'Reserve fixture isolation postcondition' -Skip:(
    -not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE
) {
    It 'leaves no Reserve schema for subsequent PostgreSQL suites' {
        $probe = Invoke-ReserveFixtureSql "SELECT to_regnamespace('dune') IS NULL AS empty;"
        $probe.ok | Should -BeTrue
        (ConvertTo-DuneRowMaps -Result $probe)[0]['empty'] | Should -Be 't'
    }
}
