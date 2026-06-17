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
    # the key but no gameplay system reads it). The no-op / unverified multipliers
    # were pulled, leaving only the two intentionally kept
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

Describe 'GameConfig: single-section-per-key consistency' -Tag 'GameConfig' {

    It 'consolidates a key that exists in two managed sections into the one being written' {
        $secA = '/Script/DuneSandbox.DuneGameMode'
        $secB = '/Script/DuneSandbox.SandStormConfig'
        $raw = $script:DstManagedBegin + "`n" +
               "[$secA]`n" +
               "m_CycleDurationInDays=36500`n" +
               "[$secB]`n" +
               "m_CycleDurationInDays=36500`n" +
               $script:DstManagedEnd + "`n"
        # Write the key to its canonical section (CoriolisSubsystem here). The stale
        # copies in DuneGameMode + SandStormConfig must be scrubbed so exactly one
        # copy remains.
        $sec = '/Script/DuneSandbox.CoriolisSubsystem'
        $updates = @(@{ section = $sec; key = 'm_CycleDurationInDays'; value = '7' })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $hits = @(($out -replace "`r", '' -split "`n") | Where-Object { $_.Trim() -match '^m_CycleDurationInDays\s*=' })
        $hits.Count | Should -Be 1
        $hits[0] | Should -Match '=\s*7\s*$'
    }

    It 'removing a key strips it from EVERY managed section, not just the declared one' {
        $secA = '/Script/DuneSandbox.DuneGameMode'
        $secB = '/Script/DuneSandbox.SandStormConfig'
        $raw = $script:DstManagedBegin + "`n" +
               "[$secA]`n" +
               "m_CycleDurationInDays=36500`n" +
               "m_bIsDbWipeEnabled=False`n" +
               "[$secB]`n" +
               "m_CycleDurationInDays=36500`n" +
               $script:DstManagedEnd + "`n"
        $sec = '/Script/DuneSandbox.CoriolisSubsystem'
        $updates = @(@{ section = $sec; key = 'm_CycleDurationInDays'; value = '7'; remove = $true })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $out | Should -Not -Match 'm_CycleDurationInDays'
        # an unrelated key in one of those sections survives
        $out | Should -Match 'm_bIsDbWipeEnabled'
    }

    It 'reset-to-default strips a stale copy from an UNMANAGED body section (Coriolis Auto-Spawn toggle-on bug)' {
        # A foreign/older placement of the key sits in an unmanaged section the
        # update does not target. Toggling the field back to its default sends
        # remove=$true against the canonical section; without scrubbing the body
        # copy it would survive and shadow the read (stuck on the old value).
        $foreign = '/Script/DuneSandbox.CoriolisSubsystem'
        $raw = "[$foreign]`n" +
               "m_bCoriolisAutoSpawnEnabled=False`n" +
               "m_CycleDurationInDays=7`n"
        $canonical = '/Script/DuneSandbox.SandStormConfig'
        $updates = @(@{ section = $canonical; key = 'm_bCoriolisAutoSpawnEnabled'; value = 'True'; remove = $true })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        $byKey = Get-DuneIniEffectiveByKey -Raw $out
        # The shadow copy is gone, so the UI falls back to the schema default (On).
        $byKey['m_bCoriolisAutoSpawnEnabled'] | Should -BeNullOrEmpty
        # An unrelated key in that foreign section is untouched.
        $byKey['m_CycleDurationInDays'] | Should -Be '7'
    }

    It 'setting a value consolidates a stale UNMANAGED body copy into the canonical section' {
        $foreign = '/Script/DuneSandbox.CoriolisSubsystem'
        $raw = "[$foreign]`n" +
               "m_bCoriolisAutoSpawnEnabled=False`n"
        $canonical = '/Script/DuneSandbox.SandStormConfig'
        $updates = @(@{ section = $canonical; key = 'm_bCoriolisAutoSpawnEnabled'; value = 'False'; remove = $false })
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        # Exactly one occurrence of the key, and it lives under the canonical section.
        $hits = @(($out -replace "`r", '' -split "`n") | Where-Object { $_.Trim() -match '^m_bCoriolisAutoSpawnEnabled\s*=' })
        $hits.Count | Should -Be 1
        $eff = Get-DuneIniEffective -Raw $out
        $eff["$canonical||m_bCoriolisAutoSpawnEnabled"] | Should -Be 'False'
    }

    It 'Get-DuneIniEffectiveByKey returns last-wins value regardless of section' {
        $raw = "[/Script/DuneSandbox.DuneGameMode]`n" +
               "m_CycleDurationInDays=36500`n" +
               "[/Script/DuneSandbox.SandStormConfig]`n" +
               "m_CycleDurationInDays=7`n"
        $byKey = Get-DuneIniEffectiveByKey -Raw $raw
        $byKey['m_CycleDurationInDays'] | Should -Be '7'
    }
}

Describe 'GameConfig: UE struct-member engine (LandsraadSettings Data blob)' -Tag 'GameConfig' {

    BeforeAll {
        # Real-shape blob: flat scalars mixed with nested members (messages, curve,
        # quoted widget paths, gameplay tags) that must survive byte-for-byte.
        $script:LsBlob = 'Data=(m_NumberOfWeeksTermRetention=4,m_TermStartedMessage=(Name="LandsraadTermStarted"),m_bIsPlayerVotingEnabled=True,m_LandsraadProgressFactionBalanceCurve=/Script/Engine.CurveFloat''"/Game/Dune/Systems/Landsraad/Curve_X.Curve_X"'',m_TaskGoalAmount=5000.0,m_ControlPointsPerCycle=2,m_LandsraadContractsNewMarkerGameplayTags=(GameplayTags=((TagName="X"))),m_ControlPointAreaMaterial="/Game/Dune/M.M")'
    }

    It 'reads only the flat scalar members' {
        $m = Get-DuneStructScalarMembers -Blob $script:LsBlob
        $m['m_NumberOfWeeksTermRetention'] | Should -Be '4'
        $m['m_bIsPlayerVotingEnabled']     | Should -Be 'True'
        $m['m_TaskGoalAmount']             | Should -Be '5000.0'
        $m['m_ControlPointsPerCycle']      | Should -Be '2'
        # nested / quoted members are NOT surfaced as scalars
        $m.ContainsKey('m_TermStartedMessage')   | Should -BeFalse
        $m.ContainsKey('m_ControlPointAreaMaterial') | Should -BeFalse
    }

    It 'updates a scalar member in place and leaves nested members untouched' {
        $out = Set-DuneStructScalarMember -Blob $script:LsBlob -Key 'm_TaskGoalAmount' -Value '12000.0'
        $out | Should -Match 'm_TaskGoalAmount=12000\.0'
        $out | Should -Not -Match 'm_TaskGoalAmount=5000\.0'
        # nested members preserved verbatim
        $out | Should -Match 'm_TermStartedMessage=\(Name="LandsraadTermStarted"\)'
        $out | Should -Match 'GameplayTags=\(\(TagName="X"\)\)'
        $out | Should -Match 'm_ControlPointAreaMaterial="/Game/Dune/M\.M"'
    }

    It 'does not over-match a key that is a prefix of the value or other keys' {
        $out = Set-DuneStructScalarMember -Blob $script:LsBlob -Key 'm_ControlPointsPerCycle' -Value '9'
        $m = Get-DuneStructScalarMembers -Blob $out
        $m['m_ControlPointsPerCycle']      | Should -Be '9'
        $m['m_NumberOfWeeksTermRetention'] | Should -Be '4'
        $m['m_TaskGoalAmount']             | Should -Be '5000.0'
    }

    It 'toggles a bool member' {
        $out = Set-DuneStructScalarMember -Blob $script:LsBlob -Key 'm_bIsPlayerVotingEnabled' -Value 'False'
        (Get-DuneStructScalarMembers -Blob $out)['m_bIsPlayerVotingEnabled'] | Should -Be 'False'
    }

    It 'inserts a missing scalar member after the opening paren' {
        $out = Set-DuneStructScalarMember -Blob $script:LsBlob -Key 'm_NewSetting' -Value '42'
        (Get-DuneStructScalarMembers -Blob $out)['m_NewSetting'] | Should -Be '42'
        # still a single well-formed Data=(...) blob
        $out | Should -Match '^Data=\('
        $out | Should -Match '\)$'
    }
}

Describe 'GameConfig: Landsraad struct fields integrate with read + save' -Tag 'GameConfig' {

    BeforeAll {
        $script:LsRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_NumberOfWeeksTermRetention=4,m_TermStartedMessage=(Name="X"),m_TaskGoalAmount=5000.0,m_bIsPlayerVotingEnabled=True)' + "`n"
    }

    It 'surfaces Landsraad struct members in effectiveByKey' {
        $byKey = Get-DuneIniEffectiveByKey -Raw $script:LsRaw
        $byKey['m_TaskGoalAmount']             | Should -Be '5000.0'
        $byKey['m_NumberOfWeeksTermRetention'] | Should -Be '4'
        $byKey['m_bIsPlayerVotingEnabled']     | Should -Be 'True'
    }

    It 'Convert-DuneStructUpdates folds member edits into one Data update, preserving nested members' {
        $updates = @(
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_TaskGoalAmount'; value='12000.0' },
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_bIsPlayerVotingEnabled'; value='False' }
        )
        $folded = @(Convert-DuneStructUpdates -Raw $script:LsRaw -Updates $updates)
        # exactly one update, targeting the Data key
        $folded.Count | Should -Be 1
        $folded[0].key | Should -Be 'Data'
        $folded[0].value | Should -Match 'm_TaskGoalAmount=12000\.0'
        $folded[0].value | Should -Match 'm_bIsPlayerVotingEnabled=False'
        # nested member preserved
        $folded[0].value | Should -Match 'm_TermStartedMessage=\(Name="X"\)'
    }

    It 'keeps non-struct updates separate from struct folding' {
        $updates = @(
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_TaskGoalAmount'; value='9000.0' },
            @{ file='game'; section='/Script/DuneSandbox.DuneGameMode'; key='m_WaterConsumptionRate'; value='2.0' }
        )
        $folded = @(Convert-DuneStructUpdates -Raw $script:LsRaw -Updates $updates)
        $folded.Count | Should -Be 2
        @($folded | Where-Object { $_.key -eq 'Data' }).Count | Should -Be 1
        @($folded | Where-Object { $_.key -eq 'm_WaterConsumptionRate' }).Count | Should -Be 1
    }

    It 'seeds the full default struct when the file has no prior LandsraadSettings section' {
        # Fresh UserGame.ini: no LandsraadSettings section at all.
        $freshRaw = "[/Script/DuneSandbox.DuneGameMode]`nm_WaterConsumptionRate=1.0`n"
        # A representative DefaultGame.ini Data=(...) blob carrying nested members
        # the operator never touches (message, a board layout struct, a curve).
        $defaultsRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_NumberOfDecreesToNominate=5,m_TaskGoalAmount=26000,m_TermStartedMessage=(Name="LandsraadTermStarted"),m_BoardLayouts=((Houses=2)),m_ContributionCurve=(Keys=((Time=0.0,Value=1.0))),m_bIsPlayerVotingEnabled=True)' + "`n"
        $updates = @(
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_TaskGoalAmount'; value='12000' }
        )
        $folded = @(Convert-DuneStructUpdates -Raw $freshRaw -Updates $updates -DefaultsRaw $defaultsRaw)
        $folded.Count   | Should -Be 1
        $folded[0].key  | Should -Be 'Data'
        # the edited scalar is folded in
        $folded[0].value | Should -Match 'm_TaskGoalAmount=12000'
        # and the full default struct survived -- NOT a 1-member stub
        $folded[0].value | Should -Match 'm_TermStartedMessage=\(Name="LandsraadTermStarted"\)'
        $folded[0].value | Should -Match 'm_BoardLayouts=\(\(Houses=2\)\)'
        $folded[0].value | Should -Match 'm_ContributionCurve=\(Keys='
        $folded[0].value | Should -Match 'm_NumberOfDecreesToNominate=5'
    }

    It 'does NOT seed from defaults when the file already carries a struct blob' {
        # File already has the struct -> keep editing it in place; ignore defaults so
        # we never clobber the user's existing customizations with stock members.
        $defaultsRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_TaskGoalAmount=26000,m_ExtraDefaultOnly=(Name="ShouldNotAppear"))' + "`n"
        $updates = @(
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_TaskGoalAmount'; value='7777.0' }
        )
        $folded = @(Convert-DuneStructUpdates -Raw $script:LsRaw -Updates $updates -DefaultsRaw $defaultsRaw)
        $folded.Count    | Should -Be 1
        $folded[0].value | Should -Match 'm_TaskGoalAmount=7777\.0'
        $folded[0].value | Should -Match 'm_TermStartedMessage=\(Name="X"\)'
        $folded[0].value | Should -Not -Match 'm_ExtraDefaultOnly'
    }

    It 'heals a legacy STUB box in place, restoring dropped default members and keeping customizations' {
        # An older DST build wrote a stripped 5-member stub into the live file.
        $stubRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_LandsraadTaskProgressUpdateFrequency=15.0,m_LandsraadTaskDailyRevealFrequency=25.0,m_VotingPeriodStartBeforeCoriolisCycleInSec=118800.0,m_VotingPeriodDurationInSec=118500.0,m_TaskGoalAmount=9999.0)' + "`n"
        # Full default box ships many more members the stub dropped.
        $defaultsRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_NumberOfDecreesToNominate=5,m_TaskGoalAmount=26000,m_LandsraadTaskProgressUpdateFrequency=10.0,m_LandsraadTaskDailyRevealFrequency=20.0,m_VotingPeriodStartBeforeCoriolisCycleInSec=100000.0,m_VotingPeriodDurationInSec=100000.0,m_ControlPointsPerCycle=10,m_TermStartedMessage=(Name="LandsraadTermStarted"),m_BoardLayouts=((Houses=2)),m_ContributionCurve=(Keys=((Time=0.0,Value=1.0))))' + "`n"
        $updates = @(
            @{ file='game'; section='/Script/DuneSandbox.LandsraadSettings'; key='m_TaskGoalAmount'; value='12000' }
        )
        $folded = @(Convert-DuneStructUpdates -Raw $stubRaw -Updates $updates -DefaultsRaw $defaultsRaw)
        $folded.Count   | Should -Be 1
        $folded[0].key  | Should -Be 'Data'
        # operator edit applied
        $folded[0].value | Should -Match 'm_TaskGoalAmount=12000'
        # dropped default members healed back (nested + scalar)
        $folded[0].value | Should -Match 'm_TermStartedMessage=\(Name="LandsraadTermStarted"\)'
        $folded[0].value | Should -Match 'm_BoardLayouts=\(\(Houses=2\)\)'
        $folded[0].value | Should -Match 'm_ContributionCurve=\(Keys='
        $folded[0].value | Should -Match 'm_NumberOfDecreesToNominate=5'
        $folded[0].value | Should -Match 'm_ControlPointsPerCycle=10'
        # the stub's OWN customized values are preserved (not reset to defaults)
        $folded[0].value | Should -Match 'm_LandsraadTaskProgressUpdateFrequency=15\.0'
        $folded[0].value | Should -Match 'm_VotingPeriodDurationInSec=118500\.0'
    }
}
