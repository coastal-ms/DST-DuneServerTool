# Validates app/data/vehicle-kits.json — the single source of truth for the Give
# Vehicle Kit action, shared by the desktop app and the mobile app. Fails fast on
# the common edit mistakes (bad/typo'd template id, malformed JSON, stray qty key,
# missing kit) so a broken kit can't ship and silently fail to deliver in-game.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $root = Get-DstRepoRoot
    $script:VkPath  = Join-Path $root 'app\data\vehicle-kits.json'
    $script:CatPath = Join-Path $root 'app\data\item-catalog.json'

    $script:Vk = $null
    $script:ParseError = $null
    try { $script:Vk = Get-Content -LiteralPath $script:VkPath -Raw | ConvertFrom-Json }
    catch { $script:ParseError = $_.Exception.Message }

    # Set of every catalogued game item template id.
    $script:CatIds = @{}
    $cat = Get-Content -LiteralPath $script:CatPath -Raw | ConvertFrom-Json
    foreach ($p in $cat.items.PSObject.Properties) { $script:CatIds[$p.Name] = $true }

    # Coerce a JSON list field to a clean string array. Windows PowerShell turns a
    # single-element JSON array into a scalar and an empty array into $null; this
    # normalizes all three shapes and drops any $null/empty entries.
    function global:Get-VkArr {
        param($Value)
        return @($Value | Where-Object { $null -ne $_ -and [string]$_ -ne '' } | ForEach-Object { [string]$_ })
    }

    # The give-item guard rejects empty and purely-numeric template ids.
    function global:Test-VkBadId { param([string]$Id) return (-not $Id) -or ($Id -match '^\d+$') }
}

Describe 'vehicle-kits.json schema' -Tag 'Pure' {
    It 'parses as valid JSON' {
        $script:ParseError | Should -BeNullOrEmpty
        $script:Vk | Should -Not -BeNullOrEmpty
    }
    It 'declares fuel + torch consumable templates' {
        [string]$script:Vk.fuelTemplate  | Should -Not -BeNullOrEmpty
        [string]$script:Vk.torchTemplate | Should -Not -BeNullOrEmpty
    }
    It 'fuel + torch templates exist in the item catalog' {
        $script:CatIds.ContainsKey([string]$script:Vk.fuelTemplate)  | Should -BeTrue
        $script:CatIds.ContainsKey([string]$script:Vk.torchTemplate) | Should -BeTrue
    }
    It 'has a non-empty vehicles list' {
        @($script:Vk.vehicles).Count | Should -BeGreaterThan 0
    }
    It 'has at least one give-able kit (kit.length > 0)' {
        (@($script:Vk.vehicles) | Where-Object { (Get-VkArr $_.kit).Count -gt 0 }).Count | Should -BeGreaterThan 0
    }
}

Describe 'vehicle-kits.json per-vehicle integrity' -Tag 'Pure' {
    It 'every vehicle has a non-empty id and label' {
        foreach ($v in @($script:Vk.vehicles)) {
            [string]$v.id    | Should -Not -BeNullOrEmpty
            [string]$v.label | Should -Not -BeNullOrEmpty
        }
    }
    It 'vehicle ids are unique' {
        $ids = @($script:Vk.vehicles | ForEach-Object { [string]$_.id })
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
    It 'no kit/unique template id is empty or purely numeric (give-guard rule)' {
        foreach ($v in @($script:Vk.vehicles)) {
            foreach ($t in (Get-VkArr $v.kit) + (Get-VkArr $v.unique)) {
                Test-VkBadId $t | Should -BeFalse -Because "vehicle '$($v.id)' has invalid template '$t'"
            }
        }
    }
    It 'every kit/unique template id exists in the item catalog' {
        foreach ($v in @($script:Vk.vehicles)) {
            foreach ($t in (Get-VkArr $v.kit) + (Get-VkArr $v.unique)) {
                $script:CatIds.ContainsKey($t) | Should -BeTrue -Because "vehicle '$($v.id)' references unknown template '$t'"
            }
        }
    }
    It 'every qty key maps to a kit/unique part or the fuel/torch consumable' {
        $extra = @([string]$script:Vk.fuelTemplate, [string]$script:Vk.torchTemplate)
        foreach ($v in @($script:Vk.vehicles)) {
            $parts = @{}
            foreach ($t in (Get-VkArr $v.kit) + (Get-VkArr $v.unique) + $extra) { $parts[$t] = $true }
            if ($v.PSObject.Properties['qty'] -and $v.qty) {
                foreach ($k in $v.qty.PSObject.Properties.Name) {
                    $parts.ContainsKey([string]$k) | Should -BeTrue -Because "vehicle '$($v.id)' qty key '$k' is not one of its parts"
                }
            }
        }
    }
}
