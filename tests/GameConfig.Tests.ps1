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

Describe 'DuneGameConfigSchema: m_Global*Multiplier keys restored under DuneGameMode' -Tag 'GameConfig' {

    # v12.1.1 restored the 10 m_Global*Multiplier keys after they were dropped
    # in v12.0.14 on AMP-derived evidence (Icehunter/dune-admin #122/#139). The
    # Hexaspark community ServerConfig reference (mirrored in our Chroma
    # `infrastructure` collection under sources `hexaspark`) documents every one
    # of these keys as a real Float setting under [/Script/DuneSandbox.DuneGameMode]
    # with a default of 1.0; persistent notes also confirm that scalar
    # DuneGameMode values from UserGame.ini are applied at pod startup on
    # self-hosted Funcom k3s (DST's target). m_GlobalBuildingDamageMultiplier in
    # particular MUST sit under DuneGameMode (Hexaspark places it there) and not
    # under BuildingSettings, which is where v12.0.13 had it.
    It 'includes every m_Global*Multiplier key under [/Script/DuneSandbox.DuneGameMode] and flags ClientApply' {
        $required = @(
            'm_GlobalHealthMultiplier'
            'm_GlobalDamageToNpcsMultiplier'
            'm_GlobalDamageToPlayersMultiplier'
            'm_GlobalXPMultiplier'
            'm_GlobalProgressionSpeedMultiplier'
            'm_GlobalFameMultiplier'
            'm_GlobalHarvestAmountMultiplier'
            'm_GlobalHarvestHealthMultiplier'
            'm_GlobalBuildingDamageMultiplier'
            'm_InventoryWeightMultiplier'
        )
        $byKey = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $byKey[$f.Key] = $f }
        foreach ($k in $required) {
            $byKey.ContainsKey($k) | Should -BeTrue -Because "$k is a real DuneGameMode multiplier and must be exposed"
            $byKey[$k].Section     | Should -Be '/Script/DuneSandbox.DuneGameMode' -Because "$k belongs in DuneGameMode per Hexaspark"
            $byKey[$k].ClientApply | Should -BeTrue -Because "$k is read by both server and client; admin's local Game.ini must mirror it"
        }
    }
}
