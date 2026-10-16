BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . "$PSScriptRoot\_PostgresFixture.ps1"
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'Codex.ps1'
    Import-DstLib 'Database.ps1'
    Import-DstLib 'PlayersWrites.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    $script:fragment = 'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title.ImperiumFragment2Content'
    function Invoke-CodexFixture {
        param([string]$Sql)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.sql')
        [IO.File]::WriteAllText($path, $Sql)
        Invoke-TestPostgresFile -SqlPath $path -TuplesOnly
    }
}

Describe 'Codex PostgreSQL grant transaction' -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
    BeforeEach {
        $script:ownsCodexSchema = $false
        $result = Invoke-CodexFixture @"
CREATE SCHEMA dune;
CREATE TABLE dune.encrypted_player_state(account_id bigint PRIMARY KEY, online_status text);
CREATE TABLE dune.player_state(id bigint PRIMARY KEY, account_id bigint);
CREATE TABLE dune.journey_story_node(character_id bigint,story_node_id text,complete_condition_state jsonb,reveal_condition_state jsonb,has_pending_reward boolean,metadata_state jsonb,PRIMARY KEY(character_id,story_node_id));
INSERT INTO dune.encrypted_player_state VALUES(3,'Offline'),(4,'Offline');
INSERT INTO dune.player_state VALUES(1,3),(2,4);
INSERT INTO dune.journey_story_node VALUES
(1,'$script:fragment','{}','true',false,'{"keep":1}'),
(2,'$script:fragment','{}','true',false,'{"keep":2}'),
(1,'DA_Dunipedia_KnownUniverse','{}','{}',false,'{}'),
(1,'DA_Dunipedia_KnownUniverse.Imperium','{}','{}',false,'{}'),
(1,'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title','{}','{}',false,'{}'),
(1,'DA_MQ_Test','{}','true',true,'{"quest":3}');
"@
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $script:ownsCodexSchema = $result.ExitCode -eq 0
    }
    AfterEach {
        if ($script:ownsCodexSchema) { (Invoke-CodexFixture 'DROP SCHEMA dune CASCADE;').ExitCode | Should -Be 0 }
    }
    It 'grants only selected content and preserves other characters, quests and row metadata' {
        $sql = Get-DuneCodexGrantSql -AccountId 3 -Ids @($script:fragment)
        $first = Invoke-CodexFixture $sql
        $first.ExitCode | Should -Be 0 -Because $first.Error
        $first.Output.Trim() | Should -Be '1'
        (Invoke-CodexFixture $sql).Output.Trim() | Should -Be '0'
        $check = Invoke-CodexFixture @"
SELECT complete_condition_state::text,reveal_condition_state::text,has_pending_reward,metadata_state::text FROM dune.journey_story_node WHERE character_id=1 AND story_node_id='$script:fragment';
SELECT complete_condition_state::text FROM dune.journey_story_node WHERE character_id=2;
SELECT complete_condition_state::text,reveal_condition_state::text,has_pending_reward,metadata_state::text FROM dune.journey_story_node WHERE story_node_id='DA_MQ_Test';
"@
        $check.Output.Trim().Replace("`r`n","`n") | Should -Be "true|true|f|{`"keep`": 1}`n{}`n{}|true|t|{`"quest`": 3}"
        $parents = Invoke-CodexFixture "SELECT count(*) FROM dune.journey_story_node WHERE character_id=1 AND story_node_id IN ('DA_Dunipedia_KnownUniverse','DA_Dunipedia_KnownUniverse.Imperium','DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment2Title') AND complete_condition_state='{}'::jsonb AND reveal_condition_state='true'::jsonb;"
        $parents.Output.Trim() | Should -Be '3'
    }
    It 'refuses an online character without altering content' {
        (Invoke-CodexFixture "UPDATE dune.encrypted_player_state SET online_status='Online' WHERE account_id=3;").ExitCode | Should -Be 0
        $result = Invoke-CodexFixture (Get-DuneCodexGrantSql -AccountId 3 -Ids @($script:fragment))
        $result.ExitCode | Should -Not -Be 0
        $result.Error | Should -Match 'fully Offline'
        (Invoke-CodexFixture "SELECT complete_condition_state::text FROM dune.journey_story_node WHERE character_id=1 AND story_node_id='$script:fragment';").Output.Trim() | Should -Be '{}'
    }
    It 'rolls back the entire selection when a fragment is absent from this save' {
        $missing = 'DA_Dunipedia_KnownUniverse.Imperium.ImperiumFragment1Title.ImperiumFragment1Content'
        $result = Invoke-CodexFixture (Get-DuneCodexGrantSql -AccountId 3 -Ids @($script:fragment,$missing))
        $result.ExitCode | Should -Not -Be 0
        (Invoke-CodexFixture "SELECT complete_condition_state::text FROM dune.journey_story_node WHERE character_id=1 AND story_node_id='$script:fragment';").Output.Trim() | Should -Be '{}'
    }
}
