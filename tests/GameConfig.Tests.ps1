# Tests the pure INI-writer engine in GameConfig.ps1, focused on the
# managed-block writer's guarantee that any section name appears EXACTLY ONCE
# in the output. Regression coverage for the v12.0.13 duplicate-header bug where
# DST's managed override was silently ignored by UE5 (first-header / last-key
# wins) because a duplicate header survived in the body.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'GameConfig.ps1'

    $script:SecBuilding  = '/Script/DuneSandbox.BuildingSettings'
    $script:SecInventory = '/Script/DuneSandbox.InventorySystemSettings'

    # Count how many times a given section header occurs in rendered output.
    function Get-HeaderCount {
        param([string] $Raw, [string] $Name)
        $needle = '[' + $Name + ']'
        $n = 0
        foreach ($line in ($Raw -replace "`r", '' -split "`n")) {
            if ($line.Trim() -eq $needle) { $n++ }
        }
        return $n
    }

    # Effective last-wins value for a section||key across the whole file.
    function Get-EffectiveValue {
        param([string] $Raw, [string] $Section, [string] $Key)
        $cur = $null
        $val = $null
        foreach ($line in ($Raw -replace "`r", '' -split "`n")) {
            $t = $line.Trim()
            if ($t.StartsWith('[') -and $t.EndsWith(']')) {
                $cur = $t.Substring(1, $t.Length - 2)
                continue
            }
            if ($cur -eq $Section -and $t -match ('^' + [regex]::Escape($Key) + '\s*=')) {
                $val = $t.Substring($t.IndexOf('=') + 1)
            }
        }
        return $val
    }
}

Describe 'ConvertTo-DuneIniManaged: duplicate-section de-dup' -Tag 'GameConfig' {

    It 'collapses a pre-existing duplicate NON-target header to exactly one' {
        $raw = @"
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=10

[/Script/DuneSandbox.OtherSettings]
SomeKey=1

[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=20
"@
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @() -QuotedKeys @{}
        (Get-HeaderCount -Raw $out -Name $script:SecBuilding) | Should -Be 1
        # last-wins on the duplicate scalar key
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_BuildingBlueprintMaxExtensions') | Should -Be '20'
    }

    It 'updating a section that already exists in the body yields exactly one header (in managed block) with managed value winning' {
        $raw = @"
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=10
m_bBuildingRestrictionLimitsEnabled=False
"@
        $updates = @(@{ section = $script:SecBuilding; key = 'm_BuildingBlueprintMaxExtensions'; value = '99' })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $script:SecBuilding) | Should -Be 1
        # the single surviving copy must be inside the managed block
        $beginIdx = $out.IndexOf($script:DstManagedBegin)
        $hdrIdx   = $out.IndexOf('[' + $script:SecBuilding + ']')
        $beginIdx | Should -BeGreaterThan -1
        $hdrIdx   | Should -BeGreaterThan $beginIdx
        # managed override wins; untouched key preserved
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_BuildingBlueprintMaxExtensions') | Should -Be '99'
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_bBuildingRestrictionLimitsEnabled') | Should -Be 'False'
    }

    It 'reported repro: body BuildingSettings + managed update -> single authoritative section with override applied' {
        $raw = @"
[/Script/DuneSandbox.DuneGameMode]
m_Whatever=1

[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=10
m_BaseBackupMaxExtensions=10
m_bBuildingRestrictionLimitsEnabled=False
"@
        $updates = @(
            @{ section = $script:SecBuilding; key = 'm_BuildingBlueprintMaxExtensions'; value = '50' },
            @{ section = $script:SecBuilding; key = 'm_BaseBackupMaxExtensions';        value = '50' },
            @{ section = $script:SecBuilding; key = 'm_bBuildingRestrictionLimitsEnabled'; value = 'True' }
        )
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $script:SecBuilding) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_BuildingBlueprintMaxExtensions') | Should -Be '50'
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_BaseBackupMaxExtensions') | Should -Be '50'
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_bBuildingRestrictionLimitsEnabled') | Should -Be 'True'
    }

    It 'InventorySystemSettings volume update lands as a single section (UI/file agree)' {
        $raw = @"
[$script:SecInventory]
PlayerInventoryStartingVolumeCapacity=185
"@
        $updates = @(@{ section = $script:SecInventory; key = 'PlayerInventoryStartingVolumeCapacity'; value = '195' })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $script:SecInventory) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $script:SecInventory -Key 'PlayerInventoryStartingVolumeCapacity') | Should -Be '195'
    }

    It 'de-dupes a duplicate header that spans the managed block (one body copy + one managed copy)' {
        $managedBegin = $script:DstManagedBegin
        $managedEnd   = $script:DstManagedEnd
        $raw = @"
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=10


$managedBegin
;
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=42
$managedEnd
"@
        # No new updates: the managed copy is adopted, the body copy must be absorbed too.
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @() -QuotedKeys @{}
        (Get-HeaderCount -Raw $out -Name $script:SecBuilding) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $script:SecBuilding -Key 'm_BuildingBlueprintMaxExtensions') | Should -Be '42'
    }
}

Describe 'ConvertTo-DuneIniManaged: non-duplicate round-trip' -Tag 'GameConfig' {

    It 'leaves a normal single-occurrence body section structurally intact (no managed block when nothing changes)' {
        $raw = @"
[/Script/DuneSandbox.OtherSettings]
KeyA=1
+ArrayKey=foo
+ArrayKey=bar
"@
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @() -QuotedKeys @{}
        (Get-HeaderCount -Raw $out -Name '/Script/DuneSandbox.OtherSettings') | Should -Be 1
        $out | Should -Not -Match ([regex]::Escape($script:DstManagedBegin))
        # array (+/-) lines preserved verbatim and not collapsed
        $out | Should -Match '\+ArrayKey=foo'
        $out | Should -Match '\+ArrayKey=bar'
    }
}

Describe 'Set-DuneIniValuesInPlace: client-file duplicate-key collapse' -Tag 'GameConfig' {

    # Regression for the v12.0.16 report: the client Game.ini carried the same
    # scalar key TWICE in one section (e.g. PlayerInventoryStartingSize=100 then
    # =145). The in-place writer replaced only the FIRST occurrence, but UE5 and
    # Get-DuneIniEffective are last-wins, so the trailing duplicate shadowed the
    # write and the "Fix" never cleared the mismatch.
    It 'collapses a duplicate scalar key to a single line carrying the written value' {
        $raw = @"
[/Script/DuneSandbox.InventorySystemSettings]
PlayerInventoryStartingSize=100
PlayerInventoryStartingSize=145
"@
        $out = Set-DuneIniValuesInPlace -Raw $raw `
            -Updates @(@{ section = $script:SecInventory; key = 'PlayerInventoryStartingSize'; value = '100' }) `
            -QuotedKeys @{}

        # exactly one occurrence of the key remains...
        $hits = @(($out -replace "`r", '' -split "`n") | Where-Object { $_.Trim() -match '^PlayerInventoryStartingSize\s*=' })
        $hits.Count | Should -Be 1
        # ...and the effective (last-wins) value is the one we wrote
        (Get-EffectiveValue -Raw $out -Section $script:SecInventory -Key 'PlayerInventoryStartingSize') | Should -Be '100'
        (Get-DuneIniEffective -Raw $out)["$($script:SecInventory)||PlayerInventoryStartingSize"] | Should -Be '100'
    }

    It 'upserts a brand-new key into an existing section without duplicating it' {
        $raw = "[/Script/DuneSandbox.InventorySystemSettings]`nOtherKey=1`n"
        $out = Set-DuneIniValuesInPlace -Raw $raw `
            -Updates @(@{ section = $script:SecInventory; key = 'PlayerInventoryStartingSize'; value = '50' }) `
            -QuotedKeys @{}
        $hits = @(($out -replace "`r", '' -split "`n") | Where-Object { $_.Trim() -match '^PlayerInventoryStartingSize\s*=' })
        $hits.Count | Should -Be 1
        (Get-DuneIniEffective -Raw $out)["$($script:SecInventory)||PlayerInventoryStartingSize"] | Should -Be '50'
    }

    It 'leaves array (+/-) lines untouched when collapsing a scalar duplicate' {
        $raw = @"
[/Script/DuneSandbox.InventorySystemSettings]
+SomeArray=a
PlayerInventoryStartingSize=100
+SomeArray=b
PlayerInventoryStartingSize=145
"@
        $out = Set-DuneIniValuesInPlace -Raw $raw `
            -Updates @(@{ section = $script:SecInventory; key = 'PlayerInventoryStartingSize'; value = '100' }) `
            -QuotedKeys @{}
        $out | Should -Match '\+SomeArray=a'
        $out | Should -Match '\+SomeArray=b'
        $hits = @(($out -replace "`r", '' -split "`n") | Where-Object { $_.Trim() -match '^PlayerInventoryStartingSize\s*=' })
        $hits.Count | Should -Be 1
    }
}

Describe 'DuneGameConfigSchema: only proven m_Global*Multiplier keys remain' -Tag 'GameConfig' {

    # 2026-06-15: live in-game testing proved m_GlobalDamageToNpcsMultiplier and
    # m_GlobalXPMultiplier are NO-OPS via UserGame.ini on self-hosted (UE parses
    # the key but no gameplay system reads it). By Neil's call the no-op /
    # unverified multipliers were pulled, leaving only the two intentionally kept
    # (Building Damage + Inventory Weight). See issue #225. Do NOT re-add the
    # removed keys without a fresh in-game test showing a real effect.
    It 'no longer exposes the multipliers that were removed' {
        $removed = @(
            'm_GlobalHealthMultiplier'
            'm_GlobalDamageToNpcsMultiplier'
            'm_GlobalDamageToPlayersMultiplier'
            'm_GlobalXPMultiplier'
            'm_GlobalProgressionSpeedMultiplier'
            'm_GlobalFameMultiplier'
            'm_GlobalHarvestAmountMultiplier'
            'm_GlobalHarvestHealthMultiplier'
        )
        $keys = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $keys[$f.Key] = $true }
        foreach ($k in $removed) {
            $keys.ContainsKey($k) | Should -BeFalse -Because "$k was proven/assumed no-op via UserGame.ini and removed (issue #225)"
        }
    }
}

Describe 'GameConfig: reset-to-default removes the key from the INI' -Tag 'GameConfig' {

    It 'ConvertTo-DuneIniManaged drops a managed scalar when remove=$true' {
        $raw = @"
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=99
m_bBuildingRestrictionLimitsEnabled=False
"@
        $updates = @(@{ section = $script:SecBuilding; key = 'm_BuildingBlueprintMaxExtensions'; value = '4'; remove = $true })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $out | Should -Not -Match 'm_BuildingBlueprintMaxExtensions'
        # the untouched key survives
        $out | Should -Match 'm_bBuildingRestrictionLimitsEnabled'
    }

    It 'ConvertTo-DuneIniManaged omits a managed section header when all its keys are removed' {
        $raw = @"
[$script:SecBuilding]
m_BuildingBlueprintMaxExtensions=99
"@
        $updates = @(@{ section = $script:SecBuilding; key = 'm_BuildingBlueprintMaxExtensions'; value = '4'; remove = $true })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        (Get-HeaderCount -Raw $out -Name $script:SecBuilding) | Should -Be 0
    }

    It 'Set-DuneIniValuesInPlace removes a client-file scalar when remove=$true' {
        $raw = @"
[$script:SecInventory]
PlayerInventoryStartingSize=100
PlayerInventoryStartingVolumeCapacity=300.0
"@
        $out = Set-DuneIniValuesInPlace -Raw $raw `
            -Updates @(@{ section = $script:SecInventory; key = 'PlayerInventoryStartingSize'; value = '35'; remove = $true }) `
            -QuotedKeys @{}
        $out | Should -Not -Match 'PlayerInventoryStartingSize'
        $out | Should -Match 'PlayerInventoryStartingVolumeCapacity'
    }

    It 'Test-DuneGameConfigValueIsDefault is numeric/bool aware' {
        Test-DuneGameConfigValueIsDefault -Key 'm_InventoryWeightMultiplier' -Value '1.0'  | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'm_InventoryWeightMultiplier' -Value '1'    | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'm_InventoryWeightMultiplier' -Value '2.0'  | Should -BeFalse
        Test-DuneGameConfigValueIsDefault -Key 'm_bBuildingRestrictionLimitsEnabled' -Value 'true' | Should -BeTrue
    }

    It 'scrubs deprecated no-op multiplier keys out of the managed block on any save' {
        $sec = '/Script/DuneSandbox.DuneGameMode'
        $raw = $script:DstManagedBegin + "`n" +
               "[$sec]`n" +
               "m_GlobalXPMultiplier=1000`n" +
               "m_GlobalHarvestAmountMultiplier=1.1`n" +
               "m_InventoryWeightMultiplier=0.8`n" +
               "m_bIsDbWipeEnabled=False`n" +
               $script:DstManagedEnd + "`n"
        # An unrelated save (touch a kept key) must still scrub the dead keys.
        $updates = @(@{ section = $sec; key = 'm_InventoryWeightMultiplier'; value = '0.5' })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $out | Should -Not -Match 'm_GlobalXPMultiplier'
        $out | Should -Not -Match 'm_GlobalHarvestAmountMultiplier'
        # kept keys survive
        $out | Should -Match 'm_InventoryWeightMultiplier'
        $out | Should -Match 'm_bIsDbWipeEnabled'
    }
}
