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
                '["D_Choam_HeavyArmor_Swatch","MTX_DesertMechanic_Dirk","AtreidesHeavy_Boots_MeshVariant","MTX_Smug_Formal01_Bottom","Atreides_FlyingVehicle_01","Atreides_Buggy","AtreSandbike","HarkSandbike_Customization","Artreides_Light_Ornithopter","Atreides_Medium_Ornithopter","BuggyAtreides","BuggyHarkonnen","BuggySmuggler","MTX_Buggy_Nomad","MTX_WaterS_Light_Orni","Smuggler_Light_Ornithopter"]'
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
}
