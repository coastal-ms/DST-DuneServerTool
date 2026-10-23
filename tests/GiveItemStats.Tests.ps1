# Tests the give-item stats-shape classifier (Get-DuneGiveItemStatsJson) that
# selects the stackable vs equipment FItemStackAndDurabilityStats blob. A wrong
# shape makes the game drop the item on load (it renders in DST but never in-game).
# No DB / network — uses the bundled gameplay-item-data.json for stack_max.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
    Import-DstLib 'AugmentCatalog.ps1'
}

Describe 'ConvertTo-DuneAugmentSelections optional input' -Tag 'Pure' {
    It 'accepts omitted and null augments as an ordinary grant' {
        @(ConvertTo-DuneAugmentSelections).Count | Should -Be 0
        @(ConvertTo-DuneAugmentSelections -Augments $null).Count | Should -Be 0
    }

    It 'accepts an empty array and an empty array unrolled by a body-value helper' {
        @(ConvertTo-DuneAugmentSelections -Augments @()).Count | Should -Be 0
        $body = '{"augments":[]}' | ConvertFrom-Json
        $raw = & { return $body.augments }
        @(ConvertTo-DuneAugmentSelections -Augments $raw).Count | Should -Be 0
    }

    It 'still rejects null entries inside a nonempty selection array' {
        { ConvertTo-DuneAugmentSelections -Augments (, $null) } |
            Should -Throw '*Each selected augment requires an id*'
    }

    It 'still rejects selected objects without an id' {
        { ConvertTo-DuneAugmentSelections -Augments @(@{ quality = 5 }) } |
            Should -Throw '*Each selected augment requires an id*'
    }

    It 'preserves a valid selected augment' {
        $selected = @(ConvertTo-DuneAugmentSelections -Augments @(@{ id = 'T6_Augment_Damage2'; quality = 5 }))
        $selected.Count | Should -Be 1
        $selected[0].id | Should -Be 'T6_Augment_Damage2'
        $selected[0].quality | Should -Be 5
    }
}

Describe 'Get-DuneGiveItemStatsJson' -Tag 'Pure' {
    It 'initializes a granted shotgun with editable empty ammo' {
        $stats=Get-DuneGiveItemStatsJson -TemplateId 'SmugShot5' | ConvertFrom-Json
        $stats.FWeaponItemStats[1].CurrentAmmo | Should -Be 0
        $stats.FCustomizationStats | Should -Not -BeNullOrEmpty
    }

    It 'initializes an empty water container with its actual capacity' {
        $stats=Get-DuneGiveItemStatsJson -TemplateId 'Decajon' | ConvertFrom-Json
        $stats.FFillableItemStats[1].CurrentAmount | Should -Be 0
        $stats.FFillableItemStats[1].MaxAmount | Should -Be 10000
        $stats.FFillableItemStats[1].FillableType | Should -Be 'Water'
    }

    It 'preserves existing ammo and unrelated stats when adding missing defaults' {
        $stats=Add-DuneItemStatDefaults -TemplateId 'SmugShot5' -StatsJson '{"FWeaponItemStats":[[],{"CurrentAmmo":23}],"FCustomizationStats":[[],{"color":7}]}' | ConvertFrom-Json
        $stats.FWeaponItemStats[1].CurrentAmmo | Should -Be 23
        $stats.FCustomizationStats[1].color | Should -Be 7
    }

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
            -Augments @(
                @{ id='T6_Augment_Damage2'; quality=5 },
                @{ id='T6_Augment_Acuracy1'; quality=4 }
            )
        $stats = $json | ConvertFrom-Json
        $augmented = $stats.FAugmentedItemStats[1]

        @($augmented.AppliedAugments).Name | Should -Be @('T6_Augment_Damage2', 'T6_Augment_Acuracy1')
        @($augmented.AppliedAugmentQualities) | Should -Be @(5, 4)
        @($augmented.AppliedAugmentRollData).Count | Should -Be 2
        [double]$augmented.AppliedAugmentRollData[0].StatRolls[0] | Should -Be 1.003398
        $stats.PSObject.Properties.Name | Should -Contain 'FWeaponItemStats'
        $stats.FWeaponItemStats[1].PSObject.Properties.Name | Should -Contain 'CurrentAmmo'
        [int]$stats.FWeaponItemStats[1].CurrentAmmo | Should -Be 0
    }

    It 'rejects incompatible augments instead of creating invalid gear' {
        {
            Get-DuneGiveItemStatsJson `
                -TemplateId 'SMG_Unique_LargeMag_06' `
                -Augments @(@{ id='T6_Augment_Armor1'; quality=3 })
        } | Should -Throw '*not compatible*'
    }

    It 'rejects schematic aliases instead of augmenting a recipe item' {
        {
            Get-DuneGiveItemStatsJson `
                -TemplateId 'SMG_Unique_LargeMag_06_Schematic' `
                -Augments @(@{ id='T6_Augment_Damage2'; quality=5 })
        } | Should -Throw '*no verified augment compatibility mapping*'
    }

    It 'rejects fractional grades instead of rounding them' {
        {
            Get-DuneGiveItemStatsJson `
                -TemplateId 'SMG_Unique_LargeMag_06' `
                -Augments @(@{ id='T6_Augment_Damage2'; quality=1.5 })
        } | Should -Throw '*between 1 and 5*'
    }
}
