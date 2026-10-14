BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . "$PSScriptRoot\_PostgresFixture.ps1"
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'SoloCosmetics.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'Database.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    function Invoke-ReviewedFixture {
        param([string]$Sql)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.sql')
        [IO.File]::WriteAllText($path,$Sql)
        Invoke-TestPostgresFile -SqlPath $path -TuplesOnly
    }
}
Describe 'Selective customization PostgreSQL transaction' -Skip:(-not $env:DST_TEST_POSTGRES_PSQL -or -not $env:DST_TEST_POSTGRES_DATABASE) {
    BeforeEach {
        $script:ownsSchema=$false
        $result=Invoke-ReviewedFixture @'
CREATE SCHEMA dune;
CREATE TABLE dune.encrypted_player_state(player_pawn_id bigint,player_controller_id bigint,account_id bigint,online_status text);
INSERT INTO dune.encrypted_player_state VALUES(1,2,3,'Offline');
CREATE TABLE dune.actors(id bigint PRIMARY KEY,properties jsonb);
INSERT INTO dune.actors VALUES(1,'{"Other":{"keep":7},"CustomizationLibraryActorComponent":{"m_UnlockedCustomizationSerializableList":{"metadata":12,"m_UnlockedCustomizationIds":[{"m_CustomizationId":"Existing","extra":true}]}}}');
'@
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $script:ownsSchema=$result.ExitCode -eq 0
    }
    AfterEach {
        if ($script:ownsSchema) { (Invoke-ReviewedFixture 'DROP SCHEMA dune CASCADE;').ExitCode | Should -Be 0 }
    }
    It 'preserves existing recipe uses while adding missing name and quality pairs' {
        $entry = Get-DuneReviewedCustomization ObservedSchematicRecipes
        $existing = $entry.recipeEntries[0] | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        $existing.m_NumberOfRecipeUses = 99
        $seed = ConvertTo-DuneSqlString ($existing | ConvertTo-Json -Depth 6 -Compress)
        (Invoke-ReviewedFixture "UPDATE dune.actors SET properties=jsonb_set(properties,'{CraftingRecipesLibraryActorComponent}',jsonb_build_object('m_KnownItemRecipes',jsonb_build_array('$seed'::jsonb))); ").ExitCode | Should -Be 0
        $sql = Get-DuneReviewedCustomizationSql 1 2 3 ObservedSchematicRecipes
        $first = Invoke-ReviewedFixture $sql
        $first.ExitCode | Should -Be 0 -Because $first.Error
        [int]$first.Output.Trim() | Should -Be ($entry.recipeEntries.Count - 1)
        $repeat = Invoke-ReviewedFixture $sql
        $repeat.ExitCode | Should -Be 0 -Because $repeat.Error
        $repeat.Output.Trim() | Should -Be '0'
        $uses = Invoke-ReviewedFixture "SELECT properties #>> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes,0,m_NumberOfRecipeUses}' FROM dune.actors WHERE id=1;"
        $uses.Output.Trim() | Should -Be '99'
        $counts = Invoke-ReviewedFixture @'
SELECT min((r->>'m_NumberOfRecipeUses')::int),max((r->>'m_NumberOfRecipeUses')::int)
FROM dune.actors a CROSS JOIN jsonb_array_elements(a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') WITH ORDINALITY t(r,ordinal)
WHERE (r->>'m_bIsLimitedUseRecipe')::boolean
AND ordinal > 1;
'@
        $counts.Output.Trim() | Should -Be '1|8'
    }
    It 'applies both observed bulk selections atomically and preserves existing entries' {
        foreach ($selection in @('ObservedCharacterSwatches','ObservedGearAppearances')) {
            $entry = Get-DuneReviewedCustomization $selection
            $sql = Get-DuneReviewedCustomizationSql 1 2 3 $selection
            $first = Invoke-ReviewedFixture $sql
            $first.ExitCode | Should -Be 0 -Because $first.Error
            [int]$first.Output.Trim() | Should -Be $entry.customizationIds.Count
            $repeat = Invoke-ReviewedFixture $sql
            $repeat.ExitCode | Should -Be 0 -Because $repeat.Error
            $repeat.Output.Trim() | Should -Be '0'
        }
        $verify = Invoke-ReviewedFixture "SELECT (properties->'Other'->>'keep')::int FROM dune.actors WHERE id=1;"
        $verify.Output.Trim() | Should -Be '7'
    }
    It 'adds only the reviewed ID, preserves other state and repeats idempotently' {
        $sql=Get-DuneReviewedCustomizationSql 1 2 3 StillSCharDyepackImota
        $first=Invoke-ReviewedFixture $sql
        $first.ExitCode | Should -Be 0 -Because $first.Error
        $first.Output.Trim() | Should -Be '1'
        $second=Invoke-ReviewedFixture $sql
        $second.ExitCode | Should -Be 0 -Because $second.Error
        $second.Output.Trim() | Should -Be '0'
        $verified=Invoke-ReviewedFixture @'
SELECT properties->'Other' = '{"keep":7}'::jsonb
 AND properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,metadata}' = '12'::jsonb
 AND properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}' = '[{"m_CustomizationId":"Existing","extra":true},{"m_CustomizationId":"StillSCharDyepackImota"}]'::jsonb FROM dune.actors WHERE id=1;
'@
        $verified.Output.Trim() | Should -Be 't'
    }
    It 'adds all five armor appearances atomically and repeats without duplicates' {
        $sql=Get-DuneReviewedCustomizationSql 1 2 3 MercenaryLightArmorSet
        $first=Invoke-ReviewedFixture $sql
        $first.ExitCode | Should -Be 0 -Because $first.Error
        $first.Output.Trim() | Should -Be '5'
        (Invoke-ReviewedFixture $sql).Output.Trim() | Should -Be '0'
        $read=Invoke-ReviewedFixture "SELECT jsonb_array_length(properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}'),properties->'Other' FROM dune.actors;"
        $read.Output.Trim() | Should -Be '6|{"keep": 7}'
    }
    It 'rejects changed identity or Online state without updating the actor' {
        (Invoke-ReviewedFixture "UPDATE dune.encrypted_player_state SET online_status='Online';").ExitCode | Should -Be 0
        (Invoke-ReviewedFixture (Get-DuneReviewedCustomizationSql 1 2 3 StillSCharDyepackImota)).ExitCode | Should -Not -Be 0
        (Invoke-ReviewedFixture (Get-DuneReviewedCustomizationSql 1 2 4 StillSCharDyepackImota)).ExitCode | Should -Not -Be 0
        (Invoke-ReviewedFixture "SELECT jsonb_array_length(properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}') FROM dune.actors;").Output.Trim() | Should -Be '1'
    }
}
