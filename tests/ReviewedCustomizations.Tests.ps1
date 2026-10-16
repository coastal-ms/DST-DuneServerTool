BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Database.ps1'
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRead.ps1'
    Import-DstLib 'GameplayPlayers.ps1'
    Import-DstLib 'PlayersAdmin.ps1'
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'SoloCosmetics.ps1'
    function global:Get-DuneVehicleHostScope { throw 'Mock required.' }
    function global:Invoke-DuneVerifiedSafetyBackup { throw 'Mock required.' }
}
AfterAll {
    Remove-Item function:global:Get-DuneVehicleHostScope -ErrorAction SilentlyContinue
    Remove-Item function:global:Invoke-DuneVerifiedSafetyBackup -ErrorAction SilentlyContinue
}
Describe 'Reviewed ordinary customizations' {
    It 'does not attach finite charge counts to repeatable recipe unlocks' {
        $recipes = (Get-DuneReviewedCustomization ObservedSchematicRecipes).recipeEntries
        $repeatable = @($recipes | Where-Object { -not $_.m_bIsLimitedUseRecipe })
        $repeatable.Count | Should -Be 236
        foreach ($recipe in $repeatable) {
            $recipe.m_NumberOfRecipeUses | Should -BeIn @(0,-1) -Because "$($recipe.BaseRecipeId.Name) is a repeatable unlock, not a bundle of charges"
        }
    }
    It 'grants one limited schematic use except the modules needed for a vehicle kit' {
        $recipes = (Get-DuneReviewedCustomization ObservedSchematicRecipes).recipeEntries
        $kits = Get-Content (Join-Path (Get-DstRepoRoot) 'app/data/vehicle-kits.json') -Raw | ConvertFrom-Json
        foreach ($recipe in $recipes) {
            if (-not $recipe.m_bIsLimitedUseRecipe) { continue }
            $name = [string]$recipe.BaseRecipeId.Name
            if ($name -match '^(OrnithopterLight|OrnithopterMedium|OrnithopterTransport|Sandcrawler)Locomotion_') {
                $vehicle = $kits.vehicles | Where-Object id -eq $Matches[1]
                $module = @($vehicle.qty.PSObject.Properties | Where-Object Name -match 'Locomotion')[0]
                $recipe.m_NumberOfRecipeUses | Should -Be $module.Value -Because "$name should craft one complete vehicle's locomotion modules"
            } else {
                $recipe.m_NumberOfRecipeUses | Should -Be 1 -Because "$name should receive one limited schematic use"
            }
        }
    }
    It 'counts exact saved Solo swatches, gear appearances and recipe quality pairs' {
        Mock Add-DuneCosmeticCatalogOwnership {}
        $swatch = (Get-DuneReviewedCustomization ObservedCharacterSwatches).customizationIds[0]
        $gear = (Get-DuneReviewedCustomization ObservedGearAppearances).customizationIds[0]
        $recipe = (Get-DuneReviewedCustomization ObservedSchematicRecipes).recipeEntries[0]
        $ownership = Get-DuneSoloCosmeticOwnership @{cosmetics=@{available=$true;unlocked=@();pending=@();customizations=@($swatch,$gear);recipeKeys=@("$($recipe.BaseRecipeId.Name)|$($recipe.m_QualityLevel)")}}
        $ownership.reviewedCounts.ObservedCharacterSwatches.remaining | Should -Be 310
        $ownership.reviewedCounts.ObservedGearAppearances.remaining | Should -Be 400
        $ownership.reviewedCounts.ObservedSchematicRecipes.remaining | Should -Be 716
    }
    It 'rejects malformed recipe mappings and a conflicting unlimited sentinel' {
        foreach ($kind in @('blank','string-quality','limited-sentinel','duplicate')) {
            $entry = [pscustomobject]@{BaseRecipeId=[pscustomobject]@{Name='FixtureRecipe'}; m_QualityLevel=0; m_NumberOfRecipeUses=-1; m_bIsLimitedUseRecipe=$false; m_Source='SchematicPickup'}
            switch ($kind) {
                'blank' { $entry.BaseRecipeId.Name='' }
                'string-quality' { $entry.m_QualityLevel='0' }
                'limited-sentinel' { $entry.m_bIsLimitedUseRecipe=$true }
            }
            $entries = if ($kind -eq 'duplicate') { @($entry,$entry) } else { @($entry) }
            { Get-DuneReviewedRecipeSql 1 2 3 $entries } | Should -Throw
        }
    }
    It 'accepts only exact evidence-backed IDs' {
        (Get-DuneReviewedCustomization StillSCharDyepackImota).label | Should -Be 'House Imota Garment Swatch'
        foreach ($id in @('stillschardyepackimota','MTX_StillSCharDyepackImota','MTX_Atre_Troopship_Relief_Placeable','Unknown')) {
            { Get-DuneReviewedCustomization $id } | Should -Throw
        }
    }
    It 'requires all identities and verifies offline state inside the transaction' {
        { Get-DuneReviewedCustomizationSql 0 2 3 StillSCharDyepackImota } | Should -Throw
        $sql = Get-DuneReviewedCustomizationSql 1 2 3 StillSCharDyepackImota
        $sql | Should -Match "online_status::text='Offline' FOR UPDATE"
        $sql | Should -Match 'player_pawn_id=1::bigint AND player_controller_id=2::bigint'
        $sql | Should -Match 'account_id=3::bigint'
        $sql | Should -Match 'IF NOT EXISTS'
        $sql | Should -Match 'Customization verification failed'
    }
    BeforeEach {
        Mock Get-DuneVehicleHostScope { @{key='fixture'} }
        Mock Test-DunePlayerOffline { @{ok=$true} }
        Mock Invoke-DuneVerifiedSafetyBackup { @{ok=$true;path='backup';database_scope='fixture'} }
        Mock Invoke-DuneSqlQuery { @{ok=$true;rows=@()} }
    }
    It 'does not back up or write an unknown selection' {
        { Invoke-DunePlayerReviewedCustomization fixture 1 2 3 Unknown } | Should -Throw
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }
    It 'attempts the offline grant without depending on a backup' {
        Mock Invoke-DuneVerifiedSafetyBackup { @{ok=$false;error='backup failed'} }
        (Invoke-DunePlayerReviewedCustomization fixture 1 2 3 StillSCharDyepackImota).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter { $Bulk -and $TimeoutSec -eq 120 }
    }
    It 'does not write when the selected database changes' {
        $script:scopeReads = 0
        Mock Get-DuneVehicleHostScope { $script:scopeReads++; @{key=$(if ($script:scopeReads -eq 1) {'fixture'} else {'other'})} }
        (Invoke-DunePlayerReviewedCustomization fixture 1 2 3 StillSCharDyepackImota).ok | Should -BeFalse
        Should -Invoke Invoke-DuneSqlQuery -Times 0
    }
    It 'does not create a backup while player is online or unknown' {
        Mock Test-DunePlayerOffline { @{ok=$false} }
        (Invoke-DunePlayerReviewedCustomization fixture 1 2 3 StillSCharDyepackImota).ok | Should -BeFalse
        Should -Invoke Invoke-DuneVerifiedSafetyBackup -Times 0
    }
    It 'confirms saved grants after a lost write response without replaying the write' {
        Mock Invoke-DuneSqlQuery { if ($ReadOnly) { @{ok=$true;kind='status'} } else { @{ok=$false;error='timeout'} } }
        Mock ConvertTo-DuneRowMaps { ,@(@{total='311';owned='311'}) }
        $result = Invoke-DunePlayerReviewedCustomization fixture 1 2 3 ObservedCharacterSwatches
        $result.ok | Should -BeTrue
        $result.message | Should -Match 'No retry is needed'
        Should -Invoke Invoke-DuneSqlQuery -Times 1 -ParameterFilter { -not $ReadOnly }
    }
    It 'reports missing grants rather than claiming success after a timeout' {
        Mock Invoke-DuneSqlQuery { if ($ReadOnly) { @{ok=$true} } else { @{ok=$false;error='timeout'} } }
        Mock ConvertTo-DuneRowMaps { ,@(@{total='311';owned='10'}) }
        $result = Invoke-DunePlayerReviewedCustomization fixture 1 2 3 ObservedCharacterSwatches
        $result.ok | Should -BeFalse
        $result.error | Should -Match '301 remain'
    }
}
