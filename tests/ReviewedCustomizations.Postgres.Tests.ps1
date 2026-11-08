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
        $repeatable = Invoke-ReviewedFixture @'
SELECT count(*),count(*) FILTER (WHERE (r->>'m_NumberOfRecipeUses')::int NOT IN (0,-1))
FROM dune.actors a CROSS JOIN jsonb_array_elements(a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') r
WHERE NOT (r->>'m_bIsLimitedUseRecipe')::boolean;
'@
        $repeatable.ExitCode | Should -Be 0 -Because $repeatable.Error
        $repeatable.Output.Trim() | Should -Be '236|0'
    }
    It 'reissues only the two exhausted recipes and preserves every usable or unlimited entry' {
        (Invoke-ReviewedFixture "UPDATE dune.actors SET properties=jsonb_set(properties,'{CraftingRecipesLibraryActorComponent}','{`"m_KnownItemRecipes`":[]}'::jsonb);").ExitCode | Should -Be 0
        $sql = Get-DuneReviewedCustomizationSql 1 2 3 ObservedSchematicRecipes
        (Invoke-ReviewedFixture $sql).ExitCode | Should -Be 0
        $recipes = (Get-DuneReviewedCustomization ObservedSchematicRecipes).recipeEntries
        $names = @($recipes | Where-Object m_bIsLimitedUseRecipe | Select-Object -First 2 | ForEach-Object { "'$(ConvertTo-DuneSqlString $_.BaseRecipeId.Name)'" }) -join ','
        (Invoke-ReviewedFixture "UPDATE dune.actors SET properties=jsonb_set(properties,'{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}',(SELECT jsonb_agg(CASE WHEN r #>> '{BaseRecipeId,Name}' IN ($names) THEN jsonb_set(r,'{m_NumberOfRecipeUses}','0'::jsonb)||'{`"customMetadata`":42}'::jsonb ELSE r END ORDER BY n) FROM jsonb_array_elements(properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') WITH ORDINALITY x(r,n))); ").ExitCode | Should -Be 0
        $preview = (Get-DuneReviewedGrantStatusSql 1 2 3 ObservedSchematicRecipes).TrimEnd(';')
        (Invoke-ReviewedFixture "WITH preview AS ($preview) SELECT total,owned,grantable FROM preview;").Output.Trim() | Should -Be '717|717|2'
        (Invoke-ReviewedFixture $sql).Output.Trim() | Should -Be '2'
        (Invoke-ReviewedFixture $sql).Output.Trim() | Should -Be '0'
        (Invoke-ReviewedFixture "SELECT count(*),min((r->>'m_NumberOfRecipeUses')::integer),min((r->>'customMetadata')::integer) FROM dune.actors a CROSS JOIN jsonb_array_elements(a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') r WHERE r #>> '{BaseRecipeId,Name}' IN ($names);").Output.Trim() | Should -Be '2|1|42'
        (Invoke-ReviewedFixture "SELECT count(*) FROM dune.actors a CROSS JOIN jsonb_array_elements(a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') r WHERE r->'m_bIsLimitedUseRecipe'='false'::jsonb AND r->'m_NumberOfRecipeUses' IN ('0'::jsonb,'-1'::jsonb);").Output.Trim() | Should -Be '236'
        (Invoke-ReviewedFixture "SELECT properties->'Other' FROM dune.actors WHERE id=1;").Output.Trim() | Should -Be '{"keep": 7}'
    }
    It 'grants maximum-level augmentation uses again on each press without changing other levels' {
        (Invoke-ReviewedFixture "UPDATE dune.actors SET properties=jsonb_set(properties,'{CraftingRecipesLibraryActorComponent}','{`"m_KnownItemRecipes`":[]}'::jsonb);").ExitCode | Should -Be 0
        $normal = Get-DuneReviewedCustomizationSql 1 2 3 ObservedSchematicRecipes
        (Invoke-ReviewedFixture $normal).ExitCode | Should -Be 0
        $sql = Get-DuneReviewedCustomizationSql 1 2 3 MaxAugmentationSchematics
        (Invoke-ReviewedFixture $sql).Output.Trim() | Should -Be '104'
        $preview = (Get-DuneReviewedGrantStatusSql 1 2 3 MaxAugmentationSchematics).TrimEnd(';')
        (Invoke-ReviewedFixture "WITH preview AS ($preview) SELECT total,owned,grantable FROM preview;").Output.Trim() | Should -Be '104|104|104'
        (Invoke-ReviewedFixture $sql).Output.Trim() | Should -Be '104'
        (Invoke-ReviewedFixture "SELECT count(*),min((r->>'m_NumberOfRecipeUses')::integer),max((r->>'m_NumberOfRecipeUses')::integer) FROM dune.actors a CROSS JOIN jsonb_array_elements(a.properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}') r WHERE r->'m_QualityLevel'='5'::jsonb;").Output.Trim() | Should -Be '104|2|2'
        (Invoke-ReviewedFixture $normal).Output.Trim() | Should -Be '0'
        (Invoke-ReviewedFixture "SELECT jsonb_array_length(properties #> '{CraftingRecipesLibraryActorComponent,m_KnownItemRecipes}'),properties->'Other' FROM dune.actors;").Output.Trim() | Should -Be '821|{"keep": 7}'
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
