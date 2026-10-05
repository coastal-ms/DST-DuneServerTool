BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'PlayersRead.ps1'
}

Describe 'Get-DunePlayerOwnedCosmeticsLive' -Tag 'Pure' {
    BeforeEach {
        $script:capturedSql = ''
        function global:Invoke-DuneSqlQuery {
            param([string]$Ip, [string]$Sql, [bool]$ReadOnly, [int]$MaxRows, [int]$TimeoutSec)
            $script:capturedSql = $Sql
            $row = [object[]]@(
                '["D_Choam_HeavyArmor_Swatch","MTX_DesertMechanic_Dirk","AtreidesHeavy_Boots_MeshVariant","MTX_Smug_Formal01_Bottom","FVehDyePackAtre01","Atreides_Buggy","AtreSandbike","HarkSandbike_Customization","Artreides_Light_Ornithopter","Atreides_Medium_Ornithopter","BuggyAtreides","BuggyHarkonnen","BuggySmuggler","MTX_Buggy_Nomad","MTX_WaterS_Light_Orni","Smuggler_Light_Ornithopter"]'
                '["MTX_Atre_BreakfastRoomSet"]'
                '["MTX_Atre_Movie_Bench"]'
                '["D_TestMeshVariant"]'
            )
            return @{
                ok = $true
                columns = @('customizations', 'building_sets', 'buildable_pieces', 'pending_items')
                rows = [object[]]@(,$row)
            }
        }
    }

    AfterEach {
        Remove-Item function:global:Invoke-DuneSqlQuery -ErrorAction SilentlyContinue
    }

    It 'unions customization, progression, and pending inventory ids' {
        $result = Get-DunePlayerOwnedCosmeticsLive -Ip '192.0.2.1' -AccountId 42

        $result.ok | Should -BeTrue
        $result.owned | Should -Contain 'D_Choam_HeavyArmor_Swatch'
        $result.owned | Should -Contain 'MTX_DesertMechanic_Dirk_Variant'
        $result.owned | Should -Contain 'AtreidesHeavy_SetVariant'
        $result.owned | Should -Contain 'MTX_SmugFormalSetVariant_Bottom'
        $result.owned | Should -Contain 'Atreides_FlyingVehicle_01_Swatch'
        $result.owned | Should -Contain 'Atreides_Buggy_Variant'
        $result.owned | Should -Contain 'AtreSandbike_MeshCustomization'
        $result.owned | Should -Contain 'HarkSandbike_MeshCustomization'
        $result.owned | Should -Contain 'Atreides_LightOrni_Variant'
        $result.owned | Should -Contain 'Atreides_MediumOrni_Variant'
        $result.owned | Should -Contain 'Atreides_Buggy_Variant'
        $result.owned | Should -Contain 'Harkonnen_Buggy_Variant'
        $result.owned | Should -Contain 'B1C3_Smuggler_Buggy_Variant'
        $result.owned | Should -Contain 'MTX_B1C3_Nomad_Buggy_Variant'
        $result.owned | Should -Contain 'MTX_B1C4_WaterS_Light_Orni_Variant'
        $result.owned | Should -Contain 'B1C3_Smuggler_Scout_Ornithopter_Variant'
        $result.owned | Should -Contain 'MTX_Atre_BreakfastRoomSet'
        $result.owned | Should -Contain 'MTX_Atre_BreakfastRoomSet_Patent'
        $result.owned | Should -Contain 'MTX_Atre_Movie_Bench_Patent'
        $result.owned | Should -Contain 'D_TestMeshVariant'
        $result.pending | Should -Contain 'D_TestMeshVariant'
        $result.unlocked | Should -Not -Contain 'D_TestMeshVariant'
        $result.unlocked | Should -Contain 'MTX_Atre_Movie_Bench_Patent'
        $result.owned | Should -Not -Contain 'D_TestMeshVariant_Patent'
    }

    It 'reconciles persisted IDs with catalog wrappers through canonical keys' {
        Get-DuneCosmeticCanonicalKey 'BuggyAtreides' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Atreides_Buggy_Variant'
        )
        Get-DuneCosmeticCanonicalKey 'Artreides_Light_Ornithopter' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Atreides Scout Ornithopter Variant'
        )
        Get-DuneCosmeticCanonicalKey 'AllDyepackChoam' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Choam_Free_01_Swatch'
        )
        Get-DuneCosmeticCanonicalKey 'MTX_Smug_Formal01_Bottom' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'MTX_SmugFormalSetVariant_Bottom'
        )
        Get-DuneCosmeticCanonicalKey 'HArmCharDyepackAgrosaz' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Agrosaz_HeavyArmor_Swatch'
        )
        Get-DuneCosmeticCanonicalKey 'LArmCharDyepackEcaz' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Ecaz_LightArmor_Swatch'
        )
        Get-DuneCosmeticCanonicalKey 'StillSCharDyepackTalgari' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Taligari_Stillsuit_Swatch'
        )
        Get-DuneCosmeticCanonicalKey 'PlaceableDyePackArgosaz' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Argosaz_Placeables_Swatch'
        )
        Get-DuneCosmeticCanonicalKey 'PlaceableDyePackWayku' | Should -Be (
            Get-DuneCosmeticCanonicalKey 'Wakyu_Placeables_Swatch'
        )
    }

    It 'queries all persistence locations read by the ownership filter' {
        Get-DunePlayerOwnedCosmeticsLive -Ip '192.0.2.1' -AccountId 42 | Out-Null

        $script:capturedSql | Should -Match 'm_UnlockedCustomizationIds'
        $script:capturedSql | Should -Match 'learned_building_sets'
        $script:capturedSql | Should -Match 'new_buildable_pieces'
        $script:capturedSql | Should -Match 'JOIN dune.items'
        $script:capturedSql | Should -Match 'account_id = 42::bigint'
    }

    It 'rejects an invalid account id before querying' {
        $result = Get-DunePlayerOwnedCosmeticsLive -Ip '192.0.2.1' -AccountId 0

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'account_id'
        $script:capturedSql | Should -BeNullOrEmpty
    }

    It 'recognizes saved campaign weapon IDs without confusing distinct weapons' {
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('Atre_Karpov_Rifle','MTX_Choam_SpiceMask_Head')
        $owned | Should -Contain 'B1C3_Atre_Karpov_Rifle'
        $owned | Should -Contain 'MTX_Choam_SpiceMask_Variant'
        $owned | Should -Not -Contain 'B1C3_Atre_Spitdart_Rifle'
        $owned | Should -Not -Contain 'B1C3_Hark_Spitdart_Rifle'
    }

    It 'requires every persisted trainer armor slot to mark its set unlocked' {
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('Trainer_Mentat_Top_MeshVariant')
        $owned | Should -Not -Contain 'AdvancedTrainer_Mentat_SetVariant'
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('Trainer_Mentat_Top_MeshVariant','Trainer_Mentat_Bottom_MeshVariant','Trainer_Mentat_Boots_MeshVariant','Trainer_Mentat_Gloves_MeshVariant','Trainer_Mentat_Helmet_MeshVariant')
        $owned | Should -Contain 'AdvancedTrainer_Mentat_SetVariant'
        $owned | Should -Not -Contain 'AdvancedTrainer_Trooper_SetVariant'
    }
    It 'does not mark an individual clothing slot owned from a different slot' {
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('MTX_Smug_Formal01_Gloves')
        $owned | Should -Not -Contain 'MTX_SmugFormalSetVariant_Bottom'
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('MTX_Smug_Formal01_Bottom')
        $owned | Should -Contain 'MTX_SmugFormalSetVariant_Bottom'
    }
    It 'handles a character with no saved cosmetic unlocks' {
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        { Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @() } | Should -Not -Throw
        $owned.Count | Should -Be 0
    }
    It 'recognizes the exact saved customization for <TemplateId>' -TestCases @(
        @{ TemplateId = 'B1C3_Atre_TransportOrnithopter'; Saved = 'Atre_TransportOrnithopter' }
        @{ TemplateId = 'B1C3_Atre_Ornitopther'; Saved = 'Atre_Ornitopther' }
        @{ TemplateId = 'B1C3_Hark_TransportOrnithopter'; Saved = 'Hark_TransportOrnithopter' }
        @{ TemplateId = 'B1C3_Hark_Ornitopther'; Saved = 'Hark_Ornitopther' }
        @{ TemplateId = 'B1C3_Smuggler_Transport_Ornithopter_Variant'; Saved = 'MTX_Smuggler_Transport_Ornithopter' }
        @{ TemplateId = 'MTX_Nomad_SetVariant_Top'; Saved = 'MTX_HeavyRacer_Top' }
        @{ TemplateId = 'MTX_Nomad_SetVariant_Bottom'; Saved = 'MTX_HeavyRacer_Bottom' }
        @{ TemplateId = 'Atreides_FlyingVehicle_01_Swatch'; Saved = 'FVehDyePackAtre01' }
        @{ TemplateId = 'Atreides_GroundVehicle_01_Swatch'; Saved = 'GVehDyePackAtre01' }
        @{ TemplateId = 'Atreides_MeleeWeapon_01_Swatch'; Saved = 'MWpnDyepackAtre' }
        @{ TemplateId = 'Atreides_RangedWeapon_01_Swatch'; Saved = 'RWpnDyepackAtre' }
        @{ TemplateId = 'Harkonnen_FlyingVehicle_01_Swatch'; Saved = 'FVehDyePackHark01' }
        @{ TemplateId = 'Harkonnen_GroundVehicle_01_Swatch'; Saved = 'GVehDyePackHark01' }
        @{ TemplateId = 'Harkonnen_MeleeWeapon_01_Swatch'; Saved = 'MWpnDyepackHark' }
        @{ TemplateId = 'Harkonnen_RangedWeapon_01_Swatch'; Saved = 'RWpnDyepackHark' }
        @{ TemplateId = 'MTX_Ultimate_Ornithopter_01_Swatch'; Saved = 'FVehDyePackUltimate01' }
        @{ TemplateId = 'MTX_WaterFat_Ornithopter_01_Swatch'; Saved = 'FVehDyePackWaterFat01' }
        @{ TemplateId = 'MTX_Deluxe_Sandbike_01_Swatch'; Saved = 'SandbikeDyePackDeluxe01' }
        @{ TemplateId = 'MTX_Graben_Flamethrower_01_Swatch'; Saved = 'FlamerDyepackGraben' }
        @{ TemplateId = 'MTX_Graben_Melee_01_Swatch'; Saved = 'MWpnDyepackGraben' }
        @{ TemplateId = 'MTX_Graben_Pistol_01_Swatch'; Saved = 'LPistolDyepackGraben' }
        @{ TemplateId = 'MTX_Graben_Sandcrawler_01_Swatch'; Saved = 'SandcrawlerDyePackGraben01' }
        @{ TemplateId = 'MTX_Graben_Social_01_Swatch'; Saved = 'SocialCharDyepackGraben' }
        @{ TemplateId = 'MTX_Bonus_Universal_01_Swatch'; Saved = 'AllDyePackBonusUniversal01' }
        @{ TemplateId = 'B1C3_SmugTech_Swatch'; Saved = 'SmugTechGlobal' }
        @{ TemplateId = 'MTX_B1C3_Smuggler_Universal_Swatch'; Saved = 'SmugglerGlobal' }
        @{ TemplateId = 'B1C3_Smuggler_Universal_Swatch'; Saved = 'SmugglerGlobal' }
        @{ TemplateId = 'MTX_Watershippers_Swatch'; Saved = 'Watershippers Global' }
        @{ TemplateId = 'MTX_CargoContainer_RedD_Swatch'; Saved = 'CargoContainerRedDSwatch' }
    ) {
        param($TemplateId, $Saved)
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @($Saved)
        $owned | Should -Contain $TemplateId
    }

    It 'keeps faction, vehicle and dye types distinct when using saved aliases' {
        $owned = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Add-DuneCosmeticCatalogOwnership -Owned $owned -CustomizationIds @('Atre_Ornitopther','FVehDyePackAtre01','MTX_HeavyRacer_Top')
        $owned | Should -Not -Contain 'B1C3_Atre_TransportOrnithopter'
        $owned | Should -Not -Contain 'B1C3_Hark_Ornitopther'
        $owned | Should -Not -Contain 'Atreides_GroundVehicle_01_Swatch'
        $owned | Should -Not -Contain 'Harkonnen_FlyingVehicle_01_Swatch'
        $owned | Should -Not -Contain 'MTX_Nomad_SetVariant_Bottom'
        $owned | Should -Not -Contain 'MTX_DesertMechanicBike_Variant'
        $owned | Should -Not -Contain 'MTX_Kirab_Buggy_Variant'
    }
}
