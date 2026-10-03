BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Catalog.ps1'
    Import-DstLib 'Gameplay.ps1'
    $script:expected = Get-Content (Join-Path $PSScriptRoot 'fixtures/restored-catalog-entries.json') -Raw | ConvertFrom-Json
    $script:cosmetics = Get-DuneCosmeticsCatalog
    $script:items = Get-DuneItemCatalog
}

Describe 'Restored catalog availability' -Tag 'Catalog' {
    It 'exposes every omitted variant with its intended cosmetic group' {
        foreach ($entry in $script:expected.cosmetics.PSObject.Properties) {
            $found = @($script:cosmetics.templates | Where-Object template -EQ $entry.Name)
            $found.Count | Should -Be 1 -Because $entry.Name
            $found[0].group | Should -Be $entry.Value -Because $entry.Name
        }
    }
    It 'restores every historical Give Item entry and display name' {
        foreach ($entry in $script:expected.items.PSObject.Properties) {
            $found = @($script:items.items | Where-Object templateId -EQ $entry.Name)
            $found.Count | Should -Be 1 -Because $entry.Name
            $found[0].name | Should -Be $entry.Value -Because $entry.Name
        }
        $script:items.meta.total | Should -Be $script:items.items.Count
    }
    It 'preserves all pre-existing cosmetic entries without duplicates' {
        $script:cosmetics.templates.template | Should -Contain 'B1C3_Smuggler_Transport_Ornithopter_Variant'
        $script:cosmetics.templates.template | Should -Contain 'Atreides_LightOrni_Variant'
        @($script:cosmetics.templates | Group-Object template | Where-Object Count -GT 1).Count | Should -Be 0
    }
}
