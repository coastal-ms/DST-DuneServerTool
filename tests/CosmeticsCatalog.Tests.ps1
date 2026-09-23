# Tests the building-set additions to the cosmetics catalog: the group-mapping
# helper (pure), the building-sets.json loader, and that Get-DuneCosmeticsCatalog
# surfaces the full grantable building-set universe (Observer Twitch set, collab
# murals, statues/decor, furniture, movie sets, faction/house sets, base-game
# crafting stations) alongside the existing appearance cosmetics.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
}

Describe 'Get-DuneBuildingSetGroup' -Tag 'Pure' {
    It 'maps the Observer Twitch reward pieces' {
        Get-DuneBuildingSetGroup -Id 'MTX_Choam_TwitchReward_Wall_01_Patent' | Should -Be 'Building Sets - Observer (Twitch)'
    }
    It 'maps murals/wall art' {
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_MuralPainting_01_Patent' | Should -Be 'Building Sets - Murals & Wall Art'
        Get-DuneBuildingSetGroup -Id 'MTX_Caladan_Movie_Mural_Patent'   | Should -Be 'Building Sets - Murals & Wall Art'
    }
    It 'maps statues & decor (incl. placeables)' {
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_Statue_Patent'              | Should -Be 'Building Sets - Statues & Decor'
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_TeleporterDevice_Placeable' | Should -Be 'Building Sets - Statues & Decor'
    }
    It 'maps furniture & themed rooms' {
        Get-DuneBuildingSetGroup -Id 'MTX_Atre_BreakfastRoomSet_Patent'     | Should -Be 'Building Sets - Furniture & Themed Rooms'
        Get-DuneBuildingSetGroup -Id 'MTX_Choam_OfficeSet_Furniture_Patent' | Should -Be 'Building Sets - Furniture & Themed Rooms'
    }
    It 'maps crafting stations & utilities (base-game recipes)' {
        Get-DuneBuildingSetGroup -Id 'AdvancedWeaponsFabricator_Patent' | Should -Be 'Building Sets - Crafting Stations & Utilities'
        Get-DuneBuildingSetGroup -Id 'SmallSpiceRefinery'               | Should -Be 'Building Sets - Crafting Stations & Utilities'
    }
    It 'maps faction & house building sets' {
        Get-DuneBuildingSetGroup -Id 'AtreidesSet'                          | Should -Be 'Building Sets - Faction & House Sets'
        Get-DuneBuildingSetGroup -Id 'HarkonnenSet'                         | Should -Be 'Building Sets - Faction & House Sets'
        Get-DuneBuildingSetGroup -Id 'MTX_Smug_BuildingSet_Patent'          | Should -Be 'Building Sets - Faction & House Sets'
        Get-DuneBuildingSetGroup -Id 'MTX_WaterShippers_BuildingSet_Patent' | Should -Be 'Building Sets - Faction & House Sets'
        Get-DuneBuildingSetGroup -Id 'MTX_Sardaukar_BuildingSet_Patent'     | Should -Be 'Building Sets - Faction & House Sets'
        Get-DuneBuildingSetGroup -Id 'MTX_SardaukarDecorationSet_Patent'    | Should -Be 'Building Sets - Faction & House Sets'
    }
    It 'maps movie collab sets' {
        Get-DuneBuildingSetGroup -Id 'MTX_Atre_Movie_Glowglobe_Patent' | Should -Be 'Building Sets - Movie Collab'
    }
    It 'falls back to Structures & Other' {
        Get-DuneBuildingSetGroup -Id 'MTX_LandingPadSet_Patent' | Should -Be 'Building Sets - Structures & Other'
    }
}

Describe 'Get-DuneCosmeticsCatalog includes the full building-set universe' -Tag 'Catalog' {
    BeforeAll { $script:cat = Get-DuneCosmeticsCatalog }

    It 'returns ok with entries (data files loaded)' {
        $script:cat.ok | Should -BeTrue
        $script:cat.total | Should -BeGreaterThan 0
    }
    It 'surfaces the full grantable building-set universe (200+ ids)' {
        @($script:cat.templates | Where-Object { $_.group -like 'Building Sets*' }).Count | Should -BeGreaterThan 200
    }
    It 'surfaces the 39 Observer Twitch building pieces under one group' {
        $observer = @($script:cat.templates | Where-Object { $_.template -like 'MTX_Choam_TwitchReward_*' })
        $observer.Count | Should -Be 39
        ($observer | ForEach-Object group | Select-Object -Unique) | Should -Be 'Building Sets - Observer (Twitch)'
    }
    It 'includes base-game faction sets and crafting stations (not just MTX)' {
        $script:cat.templates.template | Should -Contain 'AtreidesSet'
        $script:cat.templates.template | Should -Contain 'HarkonnenSet'
        $script:cat.templates.template | Should -Contain 'SmallSpiceRefinery'
        $script:cat.templates.template | Should -Contain 'MTX_Neut_MuralPainting_01_Patent'
    }
    It 'still includes the existing appearance cosmetics (regression)' {
        @($script:cat.templates | Where-Object { $_.group -eq 'Armor & Suit Sets' }).Count | Should -BeGreaterThan 0
        @($script:cat.templates | Where-Object { $_.group -eq 'Swatches (Dyes)' }).Count   | Should -BeGreaterThan 0
    }
    It 'decodes UTF-8 cosmetic names without mojibake under Windows PowerShell' {
        $boots = $script:cat.templates |
            Where-Object template -eq 'MTX_B1C3_Smug_LightArmor_SetVariant_Boots'
        $boots.name | Should -Be ("Smuggler{0}s Agile Assault Boots" -f [char]0x2019)
        $boots.name | Should -Not -Match ([char]0x00E2)
    }
    It 'includes developer cosmetics and building unlocks' {
        $script:cat.templates.template | Should -Contain 'D_Choam_HeavyArmor_Swatch'
        $script:cat.templates.template | Should -Contain 'D_TestMeshVariant'
        $script:cat.templates.template | Should -Contain 'D_AdvFabricationSet_Patent'
        $script:cat.templates.template | Should -Contain 'D_StartingSet'
    }
    It 'includes the exact Matron''s Decor templates and friendly names (regression)' {
        # Pins the six live-account-verified MTX_ReverendMotherRoom_* ids
        # exactly, not just a raised count - the community item database
        # lists these with an NA_ prefix that silently no-ops on grant, so a
        # `-Contain` per id (rather than a wider count assertion) is what
        # actually catches a misspelled or reverted template.
        $expected = @{
            'MTX_ReverendMotherRoom_Banner_Patent'     = "Matron's Banner"
            'MTX_ReverendMotherRoom_Carpet_Patent'     = "Matron's Rug"
            'MTX_ReverendMotherRoom_Chair_01_Patent'   = "Matron's Cathedra"
            'MTX_ReverendMotherRoom_Chair_02_Patent'   = "Matron's Chair"
            'MTX_ReverendMotherRoom_TableRound_Patent' = "Matron's Roundtable"
            'MTX_ReverendMotherRoom_Table_Patent'      = "Matron's Table"
        }
        foreach ($id in $expected.Keys) {
            $script:cat.templates.template | Should -Contain $id
            $entry = $script:cat.templates | Where-Object { $_.template -eq $id }
            $entry.name | Should -Be $expected[$id]
            $entry.group | Should -BeLike 'Building Sets*'
        }
        $script:cat.templates.template | Should -Not -Contain 'NA_ReverendMotherRoom_Chair_01_Patent'
    }

    It 'includes the Sardaukar building-set umbrella patents added 2026-09-22' {
        $expected = @{
            'MTX_Sardaukar_BuildingSet_Patent'  = 'Sardaukar Building Set'
            'MTX_SardaukarDecorationSet_Patent' = 'Sardaukar Decoration Set'
        }
        foreach ($id in $expected.Keys) {
            $script:cat.templates.template | Should -Contain $id
            $entry = $script:cat.templates | Where-Object { $_.template -eq $id }
            $entry.name | Should -Be $expected[$id]
            $entry.group | Should -Be 'Building Sets - Faction & House Sets'
        }
    }

    It 'every building-set entry has a template, a name, and a Building Sets group' {
        foreach ($e in ($script:cat.templates | Where-Object { $_.group -like 'Building Sets*' })) {
            $e.template | Should -Not -BeNullOrEmpty
            $e.name     | Should -Not -BeNullOrEmpty
        }
    }
}
