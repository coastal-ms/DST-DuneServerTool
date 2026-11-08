BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    . (Join-Path $PSScriptRoot '_PostgresFixture.ps1')
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    Import-DstLib 'TestingStations.ps1'
    function global:Get-DuneVehicleHostScope { throw 'Mock required.' }
    function global:Invoke-DuneVerifiedSafetyBackup { throw 'Mock required.' }
    function Invoke-StationFixtureSql {
        param([string]$Sql)
        $path = Join-Path $TestDrive "$([guid]::NewGuid()).sql"
        [IO.File]::WriteAllText($path,$Sql)
        $execution = Invoke-TestPostgresFile -SqlPath $path
        if ($execution.ExitCode -ne 0) { return @{ok=$false;error=$execution.Error} }
        ConvertFrom-DunePsqlCsv -Output $execution.Output -MaxRows 5000
    }
    function Get-StationFixtureCount {
        $result = Invoke-StationFixtureSql 'SELECT count(*)::text AS n FROM dune.dungeon_completion;'
        $result.ok | Should -BeTrue
        [int](ConvertTo-DuneRowMaps -Result $result)[0]['n']
    }
}
AfterAll {
    Remove-Item function:global:Get-DuneVehicleHostScope -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneVerifiedSafetyBackup -ErrorAction SilentlyContinue
}
Describe 'Testing Station disposable PostgreSQL writes' -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
    BeforeEach {
        $script:StationOwnsSchema = $false
        $probe = Invoke-StationFixtureSql "SELECT to_regnamespace('dune') IS NULL AS empty;"
        if (-not $probe.ok -or (ConvertTo-DuneRowMaps -Result $probe)[0]['empty'] -ne 't') { throw 'Fixture schema must be absent.' }
        (Invoke-StationFixtureSql 'CREATE SCHEMA dune;').ok | Should -BeTrue
        $script:StationOwnsSchema = $true
        $setup = Invoke-StationFixtureSql @'
CREATE TABLE dune.actors(id bigint PRIMARY KEY);
INSERT INTO dune.actors VALUES(42),(43),(44);
CREATE TABLE dune.encrypted_player_state(id bigint PRIMARY KEY,player_pawn_id bigint,player_controller_id bigint,account_id bigint,online_status text);
INSERT INTO dune.encrypted_player_state VALUES(1,42,43,99,'Offline');
CREATE VIEW dune.player_state AS SELECT * FROM dune.encrypted_player_state;
CREATE TABLE dune.dungeon_completion(completion_id bigserial PRIMARY KEY,dungeon_id text,difficulty integer,duration_ms integer,players_num integer);
CREATE TABLE dune.dungeon_completion_players(player_id bigint REFERENCES dune.actors(id),completion_id bigint REFERENCES dune.dungeon_completion(completion_id),PRIMARY KEY(player_id,completion_id));
INSERT INTO dune.dungeon_completion VALUES(1,'DA_Dgn_024_Darkness',1200,17,1),(2,'OtherDungeon',3,23,1),(3,'DA_Dgn_089_Radiation',1000,29,1);
SELECT setval('dune.dungeon_completion_completion_id_seq',3);
INSERT INTO dune.dungeon_completion_players VALUES(43,1),(43,2),(44,3);
'@
        $setup.ok | Should -BeTrue -Because $setup.error
        Mock Get-DuneVehicleHostScope { @{key='fixture'} }
        Mock Invoke-DuneVerifiedSafetyBackup { @{ok=$true;path='synthetic';database_scope='fixture'} }
        Mock Invoke-DuneSqlQuery { param($Sql) Invoke-StationFixtureSql $Sql }
    }
    AfterEach {
        if ($script:StationOwnsSchema) {
            (Invoke-StationFixtureSql 'SET client_min_messages=warning; DROP SCHEMA dune CASCADE;').ok | Should -BeTrue
        }
    }
    It 'unlocks all six for the controller, preserves existing progress and repeats without additions' {
        $result = Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all
        $result.ok | Should -BeTrue -Because $result.error
        $result.added | Should -Be 5
        $result.selected | Should -Be 6
        Get-StationFixtureCount | Should -Be 8
        (Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all).added | Should -Be 0
        $rows = ConvertTo-DuneRowMaps -Result (Invoke-StationFixtureSql 'SELECT difficulty::text,duration_ms::text FROM dune.dungeon_completion WHERE completion_id=1;')
        $rows[0]['difficulty'] | Should -Be '1200'
        $rows[0]['duration_ms'] | Should -Be '17'
        $links = ConvertTo-DuneRowMaps -Result (Invoke-StationFixtureSql 'SELECT count(*)::text AS n FROM dune.dungeon_completion_players WHERE player_id=44;')
        $links[0]['n'] | Should -Be '1'
    }
    It 'limits a single-station operation to its selected station' {
        $result = Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 DA_Dgn_136_Fire
        $result.ok | Should -BeTrue -Because $result.error
        $result.added | Should -Be 1
        $result.selected | Should -Be 1
        Get-StationFixtureCount | Should -Be 4
    }
    It 'parses the real non-quiet psql transaction response and safely repeats an already committed unlock' {
        $sql=Get-DuneTestingStationUnlockSql 42 43 99 all
        $path=Join-Path $TestDrive 'actual-transport.sql'
        function Invoke-StationNonQuietTransport {
            param([string]$Text)
            [IO.File]::WriteAllText($path,$Text)
            $start=New-TestPostgresStartInfo -SqlPath $path
            [void]$start.ArgumentList.Remove('-q')
            $process=[Diagnostics.Process]::Start($start)
            try {
                $stdout=$process.StandardOutput.ReadToEndAsync()
                $stderr=$process.StandardError.ReadToEndAsync()
                $process.WaitForExit(15000) | Should -BeTrue
                $process.ExitCode | Should -Be 0 -Because $stderr.GetAwaiter().GetResult()
                ConvertFrom-DunePsqlCsv -Output $stdout.GetAwaiter().GetResult() -MaxRows 1
            } finally {$process.Dispose()}
        }
        # Reproduce the original failure with actual psql command tags, even
        # though PostgreSQL has already committed the intended completion rows.
        $beforeFix=Invoke-StationNonQuietTransport ($sql -replace '(?m)^\\set QUIET on\r?\n','')
        $beforeFix.ok | Should -BeFalse
        $beforeFix.message | Should -Match 'row has 2 fields but the header has 1'
        Get-StationFixtureCount | Should -Be 8
        $fixed=Invoke-StationNonQuietTransport $sql
        $fixed.ok | Should -BeTrue -Because $fixed.message
        ($fixed.columns -join '|') | Should -Be 'added|selected'
        $row=(ConvertTo-DuneRowMaps -Result $fixed)[0]
        $row.added | Should -Be '0'
        $row.selected | Should -Be '6'
        Get-StationFixtureCount | Should -Be 8
    }
    It 'rejects <Status> before creating a backup' -TestCases @(@{Status='Online'},@{Status='LoggingOut'}) {
        param($Status)
        (Invoke-StationFixtureSql "UPDATE dune.encrypted_player_state SET online_status='$Status';").ok | Should -BeTrue
        (Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Get-StationFixtureCount | Should -Be 3
    }
    It 'rolls back when the player logs in after the initial offline check' {
        $script:scopeChecks=0
        Mock Get-DuneVehicleHostScope {
            $script:scopeChecks++
            if($script:scopeChecks -eq 2){
                (Invoke-StationFixtureSql "UPDATE dune.encrypted_player_state SET online_status='Online';").ok | Should -BeTrue
            }
            @{key='fixture'}
        }
        (Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all).ok | Should -BeFalse
        Get-StationFixtureCount | Should -Be 3
    }
    It 'allows an offline unlock without attempting or requiring an automatic backup' {
        Mock Invoke-DuneVerifiedSafetyBackup { throw 'Backup is unavailable and must not be attempted' }
        $result=Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all
        $result.ok | Should -BeTrue -Because $result.error
        $result.ContainsKey('safetyBackup') | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Get-StationFixtureCount | Should -Be 8
    }
    It 'stops when the selected database changes before the write' {
        $script:scopeChecks=0
        Mock Get-DuneVehicleHostScope {$script:scopeChecks++;@{key=$(if($script:scopeChecks -eq 1){'fixture'}else{'other'})}}
        (Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all).ok | Should -BeFalse
        Get-StationFixtureCount | Should -Be 3
        Should -Invoke Invoke-DuneSqlQuery -Times 0 -ParameterFilter { -not $ReadOnly }
    }
    It 'rejects a stale account identity without creating a backup' {
        (Invoke-DunePlayerUnlockTestingStations fixture 42 43 100 all).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Get-StationFixtureCount | Should -Be 3
    }
    It 'rejects an unsupported player-link schema without saving any completion' {
        (Invoke-StationFixtureSql 'ALTER TABLE dune.dungeon_completion_players DROP CONSTRAINT dungeon_completion_players_player_id_fkey;').ok | Should -BeTrue
        $result = Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 all
        $result.ok | Should -BeFalse
        $result.error | Should -Match 'Unsupported'
        Get-StationFixtureCount | Should -Be 3
    }
    It 'rejects unsupported station input before probing or backing up' {
        { Invoke-DunePlayerUnlockTestingStations fixture 42 43 99 'unknown' } | Should -Throw
        Should -Invoke Invoke-DuneSqlQuery -Times 0
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }
}
