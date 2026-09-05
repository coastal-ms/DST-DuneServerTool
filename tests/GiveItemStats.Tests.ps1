# Tests the give-item stats-shape classifier (Get-DuneGiveItemStatsJson) that
# selects the stackable vs equipment FItemStackAndDurabilityStats blob. A wrong
# shape makes the game drop the item on load (it renders in DST but never in-game).
# No DB / network — uses the bundled gameplay-item-data.json for stack_max.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'AugmentCatalog.ps1'
}

Describe 'Get-DuneGiveItemStatsJson' -Tag 'Pure' {
    BeforeAll {
        $script:stackable = '{"FItemStackAndDurabilityStats":[[],{"DecayedMaxDurability":0.0}]}'
        $script:equipment = '{"FCustomizationStats":[[],{}],"FItemStackAndDurabilityStats":[[],{}]}'
    }

    It 'returns the stackable shape (with DecayedMaxDurability) for a stackable resource' {
        # CopperBar (Copper Ingot) has stack_max=500 in gameplay-item-data.json.
        Get-DuneGiveItemStatsJson -TemplateId 'CopperBar' | Should -Be $script:stackable
    }

    It 'returns the stackable shape for another stackable resource (Basalt)' {
        Get-DuneGiveItemStatsJson -TemplateId 'Basalt' | Should -Be $script:stackable
    }

    It 'returns the equipment shape for a non-stackable equipment item' {
        # Combat_Light_SpiceMask is garment/head, stack_max=1.
        Get-DuneGiveItemStatsJson -TemplateId 'Combat_Light_SpiceMask' | Should -Be $script:equipment
    }

    It 'defaults to the equipment shape for an unknown template' {
        Get-DuneGiveItemStatsJson -TemplateId 'NotARealTemplate_xyz' | Should -Be $script:equipment
    }

    It 'defaults to the equipment shape for an empty template' {
        Get-DuneGiveItemStatsJson -TemplateId '' | Should -Be $script:equipment
    }

    It 'never returns an empty stats blob' {
        foreach ($t in @('CopperBar', 'Combat_Light_SpiceMask', 'Unknown_zzz', '')) {
            Get-DuneGiveItemStatsJson -TemplateId $t | Should -Not -Be '{}'
        }
    }

    It 'builds compatible pre-augmented gear with parallel maximum-roll arrays' {
        $json = Get-DuneGiveItemStatsJson `
            -TemplateId 'SMG_Unique_LargeMag_06' `
            -Augments @('T6_Augment_Damage2', 'T6_Augment_Acuracy1') `
            -AugmentQuality 5
        $stats = $json | ConvertFrom-Json
        $augmented = $stats.FAugmentedItemStats[1]

        @($augmented.AppliedAugments).Name | Should -Be @('T6_Augment_Damage2', 'T6_Augment_Acuracy1')
        @($augmented.AppliedAugmentQualities) | Should -Be @(5, 5)
        @($augmented.AppliedAugmentRollData).Count | Should -Be 2
        [double]$augmented.AppliedAugmentRollData[0].StatRolls[0] | Should -Be 1.003398
    }

    It 'rejects incompatible augments instead of creating invalid gear' {
        {
            Get-DuneGiveItemStatsJson `
                -TemplateId 'SMG_Unique_LargeMag_06' `
                -Augments @('T6_Augment_Armor1') `
                -AugmentQuality 3
        } | Should -Throw '*not compatible*'
    }

    It 'rejects schematic aliases instead of augmenting a recipe item' {
        {
            Get-DuneGiveItemStatsJson `
                -TemplateId 'SMG_Unique_LargeMag_06_Schematic' `
                -Augments @('T6_Augment_Damage2') `
                -AugmentQuality 5
        } | Should -Throw '*no verified augment compatibility mapping*'
    }
}
