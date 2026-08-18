BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Catalog.ps1'
    Import-DstLib 'Gameplay.ps1'

    $script:itemDataPath = Join-Path $PSScriptRoot '..\app\data\gameplay-item-data.json'
    $script:itemData = Get-Content -LiteralPath $script:itemDataPath -Raw | ConvertFrom-Json
    $script:developerIds = @(
        $script:itemData.names.PSObject.Properties |
            Where-Object { $_.Name -Like 'D_*' -or $_.Name -Like 'Developer_*' } |
            ForEach-Object Name
    )
    $script:items = Get-DuneItemCatalog
    $script:cosmetics = Get-DuneCosmeticsCatalog
}

Describe 'Developer template catalog coverage' -Tag 'Catalog' {
    It 'exposes every developer template' {
        $itemIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        $cosmeticIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($entry in $script:items.items) { [void]$itemIds.Add([string]$entry.templateId) }
        foreach ($entry in $script:cosmetics.templates) { [void]$cosmeticIds.Add([string]$entry.template) }

        foreach ($id in $script:developerIds) {
            $matches = [int]$itemIds.Contains($id) + [int]$cosmeticIds.Contains($id)
            $matches | Should -BeGreaterOrEqual 1 -Because "$id must appear in Give Item or Cosmetics"
        }
    }

    It 'includes representative developer blueprints and schematics in Give Item' {
        $script:items.items.templateId | Should -Contain 'D_AmmoBlueprint'
        $script:items.items.templateId | Should -Contain 'D_BuildingBlueprint_Foundation'
        $script:items.items.templateId | Should -Contain 'D_OrnithopterTransportSetSchematic'
        $script:items.items.templateId | Should -Contain 'D_T3_Placeable_CompactThumper_Schematic'
        $script:items.items.templateId | Should -Contain 'Developer_Storage_Container_Patent'
    }

    It 'contains no case-insensitive duplicate Give Item ids' {
        $ids = @($script:items.items.templateId)
        @($ids | Group-Object { $_.ToLowerInvariant() } | Where-Object Count -GT 1).Count | Should -Be 0
    }

    It 'reports the actual Give Item catalog total' {
        $script:items.meta.total | Should -Be $script:items.items.Count
    }

    It 'decodes UTF-8 Give Item names without mojibake under Windows PowerShell' {
        $boots = $script:items.items |
            Where-Object templateId -eq 'MTX_Stillsuit_Smuggler_Boots'
        $boots.name | Should -Be ("Smuggler{0}s Stillsuit Boots" -f [char]0x2019)
        $boots.name | Should -Not -Match ([char]0x00E2)
    }

    It 'gives every entry a searchable display name' {
        @($script:items.items | Where-Object { -not $_.name }).Count | Should -Be 0
    }
}
