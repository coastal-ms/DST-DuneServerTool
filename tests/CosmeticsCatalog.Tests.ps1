# Tests the building-set additions to the cosmetics catalog: the group-mapping
# helper (pure) and that Get-DuneCosmeticsCatalog surfaces the MTX_*_Patent
# building sets (Observer Twitch set, murals, etc.) alongside the existing
# appearance cosmetics.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Gameplay.ps1'
}

Describe 'Get-DuneBuildingSetGroup' -Tag 'Pure' {
    It 'maps the Observer Twitch reward pieces to the Observer group' {
        Get-DuneBuildingSetGroup -Id 'MTX_Choam_TwitchReward_Wall_01_Patent' | Should -Be 'Building Sets - Observer (Twitch)'
    }
    It 'maps murals/wall art' {
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_MuralPainting_01_Patent'   | Should -Be 'Building Sets - Murals & Wall Art'
        Get-DuneBuildingSetGroup -Id 'MTX_Caladan_Movie_Mural_Patent'     | Should -Be 'Building Sets - Murals & Wall Art'
    }
    It 'maps statues & decor' {
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_Statue_Patent'    | Should -Be 'Building Sets - Statues & Decor'
        Get-DuneBuildingSetGroup -Id 'MTX_Neut_Miniature_01_Patent' | Should -Be 'Building Sets - Statues & Decor'
    }
    It 'maps furniture & themed rooms' {
        Get-DuneBuildingSetGroup -Id 'MTX_Atre_BreakfastRoomSet_Patent' | Should -Be 'Building Sets - Furniture & Themed Rooms'
        Get-DuneBuildingSetGroup -Id 'MTX_Choam_OfficeSet_Furniture_Patent' | Should -Be 'Building Sets - Furniture & Themed Rooms'
    }
    It 'maps movie collab sets' {
        Get-DuneBuildingSetGroup -Id 'MTX_Atre_Movie_Something_Patent' | Should -Be 'Building Sets - Movie Collab'
    }
    It 'falls back to Structures & Other for plain building sets' {
        Get-DuneBuildingSetGroup -Id 'MTX_Smug_BuildingSet_Patent'        | Should -Be 'Building Sets - Structures & Other'
        Get-DuneBuildingSetGroup -Id 'MTX_WaterShippers_BuildingSet_Patent' | Should -Be 'Building Sets - Structures & Other'
    }
}

Describe 'Get-DuneCosmeticsCatalog includes building sets' -Tag 'Catalog' {
    BeforeAll { $script:cat = Get-DuneCosmeticsCatalog }

    It 'returns ok with entries (data file loaded)' {
        $script:cat.ok | Should -BeTrue
        $script:cat.total | Should -BeGreaterThan 0
    }
    It 'surfaces the 39 Observer Twitch building pieces' {
        $observer = @($script:cat.templates | Where-Object { $_.template -like 'MTX_Choam_TwitchReward_*_Patent' })
        $observer.Count | Should -Be 39
        ($observer | ForEach-Object group | Select-Object -Unique) | Should -Be 'Building Sets - Observer (Twitch)'
    }
    It 'surfaces other MTX building-set patents (murals, structures)' {
        $script:cat.templates.template | Should -Contain 'MTX_Neut_MuralPainting_01_Patent'
        @($script:cat.templates | Where-Object { $_.group -like 'Building Sets*' }).Count | Should -BeGreaterThan 100
    }
    It 'still includes the existing appearance cosmetics (regression)' {
        @($script:cat.templates | Where-Object { $_.group -eq 'Armor & Suit Sets' }).Count | Should -BeGreaterThan 0
        @($script:cat.templates | Where-Object { $_.group -eq 'Swatches (Dyes)' }).Count   | Should -BeGreaterThan 0
    }
    It 'every building-set entry has a template, name, and Building Sets group' {
        foreach ($e in ($script:cat.templates | Where-Object { $_.group -like 'Building Sets*' })) {
            $e.template | Should -Not -BeNullOrEmpty
            $e.name     | Should -Not -BeNullOrEmpty
        }
    }
}
