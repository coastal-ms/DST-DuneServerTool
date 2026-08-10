# Tests the pure INI-writer engine in GameConfig.ps1, focused on the
# managed-block writer's guarantee that any section name appears EXACTLY ONCE
# in the output. Regression coverage for the v12.0.13 duplicate-header bug where
# DST's managed override was silently ignored by UE5 (first-header / last-key
# wins) because a duplicate header survived in the body.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'GameConfig.ps1'
    . (Join-Path $PSScriptRoot '..\app\lib\K8s.ps1')

    $script:SecBuilding  = '/Script/DuneSandbox.BuildingSettings'
    $script:SecInventory = '/Script/DuneSandbox.InventorySystemSettings'
    $script:SecCrafting  = '/Script/DuneSandbox.CraftingSettings'

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

Describe 'Deep Desert per-partition PvP' -Tag 'GameConfig' {
    It 'parses global and repeated partition settings' {
        $raw = @"
[/Script/DuneSandbox.PvpPveSettings]
m_bShouldForceEnablePvpOnAllPartitions=False
+m_PvpEnabledPartitions=8
+m_PvpEnabledPartitions=12
+m_PvpEnabledPartitions=8
"@
        $state = Get-DuneDeepDesertPvpIniState -Raw $raw
        $state.forceAll | Should -BeFalse
        $state.selectedPartitionIds | Should -Be @(8, 12)
    }

    It 'writes selected partitions while forcing the global override off' {
        $updates = New-DuneDeepDesertPvpUpdates -PartitionIds @(12, 8, 12)
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates $updates -QuotedKeys @{}
        $out | Should -Match 'm_bShouldForceEnablePvpOnAllPartitions=False'
        ([regex]::Matches($out, '\+m_PvpEnabledPartitions=8')).Count | Should -Be 1
        ([regex]::Matches($out, '\+m_PvpEnabledPartitions=12')).Count | Should -Be 1
    }

    It 'disable removes partition array entries but keeps global PvP off' {
        $raw = @"
[/Script/DuneSandbox.PvpPveSettings]
m_bShouldForceEnablePvpOnAllPartitions=True
+m_PvpEnabledPartitions=8
"@
        $out = ConvertTo-DuneIniManaged -Raw $raw `
            -Updates (New-DuneDeepDesertPvpUpdates -PartitionIds @()) `
            -QuotedKeys @{}
        $out | Should -Match 'm_bShouldForceEnablePvpOnAllPartitions=False'
        $out | Should -Not -Match 'm_PvpEnabledPartitions'
    }

    It 'lists only partitions bound to running Deep Desert sets' {
        $bg = [pscustomobject]@{
            spec = [pscustomobject]@{
                serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                    sets = @(
                        [pscustomobject]@{ map='DeepDesert_1'; replicas=0; podSpecs=@(
                            [pscustomobject]@{ index=12; arguments=@('-execcmds="Bgd.ServerDisplayName ''PvP DD''"') }
                        ) },
                        [pscustomobject]@{ map='Survival_1'; replicas=1; partitions=@(1) }
                    )
                } } }
                database = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                    deployment = [pscustomobject]@{ spec = [pscustomobject]@{ worldPartitions=@(
                        [pscustomobject]@{ map='DeepDesert_1'; partitions=@(
                            [pscustomobject]@{ id=8; dimension=0 },
                            [pscustomobject]@{ id=12; dimension=1 },
                            [pscustomobject]@{ id=14; dimension=2 }
                        ) }
                    ) } }
                } } }
            }
            status = [pscustomobject]@{ servers=@(
                [pscustomobject]@{ partitionMap='DeepDesert_1'; partitionIndex=8; dimensionIndex=0; phase='Running'; ready=$true; gamePort=7779 },
                [pscustomobject]@{ partitionMap='DeepDesert_1'; partitionIndex=12; dimensionIndex=1; phase='Starting'; ready=$false; gamePort=7780 },
                [pscustomobject]@{ partitionMap='DeepDesert_1'; partitionIndex=99; dimensionIndex=2; phase='Terminating'; ready=$true; gamePort=7781 },
                [pscustomobject]@{ partitionMap='Survival_1'; partitionIndex=1; dimensionIndex=0; phase='Running'; ready=$true; gamePort=7778 }
            ) }
        }
        $rows = @(Get-V6DeepDesertInstancesFromBg -Bg $bg)
        @($rows.PartitionId) | Should -Be @(8, 12)
        $rows[1].Dimension | Should -Be 1
        $rows[1].ServerDisplayName | Should -Be 'PvP DD'
        $rows[1].Phase | Should -Be 'Starting'
    }
}

Describe 'Fuel burning startup override' -Tag 'GameConfig' {
    It 'leaves a server that sets no console variables completely untouched' {
        # Most servers never open the Experimental lists. A battlegroup restart
        # still rebuilds startup arguments from the INI, so this must not rewrite
        # the battlegroup on their behalf - even when the pod carries unrelated
        # overrides such as per-sietch display names.
        Mock Get-V6Battlegroup {
            @{
                Ns = 'dune-ns'
                Name = 'dune-bg'
                Bg = [pscustomobject]@{ spec = [pscustomobject]@{
                    serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        sets = @([pscustomobject]@{
                            map = 'Survival_1'
                            dedicatedScaling = $false
                            partitions = @(1)
                            podSpecs = @([pscustomobject]@{
                                index = 1
                                arguments = @('-execcmds="Bgd.ServerDisplayName ''Hagga''"')
                            })
                        })
                    } } }
                } }
            }
        }
        Mock _Invoke-V6BgJsonPatch { throw 'Must not patch when the user set no console variables.' }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('dw.FuelBurningMultiplier', 'Deathstill.ConversionTimeOverride') `
            -Values @{}

        $result.Success | Should -BeTrue
        $result.NoChange | Should -BeTrue
        Should -Invoke _Invoke-V6BgJsonPatch -Times 0
    }

    It 'injects boolean console variables instead of aborting the whole rebuild' {
        # Regression (v13.2.2): boolLower controls such as
        # Sandworm.SandwormDangerZonesEnabled carry true/false, but the injector
        # forced every value through [double]::TryParse and threw on the first
        # boolean. Invoke-DuneBattlegroupRestart swallows that exception, so the
        # rebuild silently produced NO startup commands at all and every console
        # variable stopped applying on servers that had set a boolean one.
        $script:patched = $null
        Mock Get-V6Battlegroup {
            @{ Bg = [pscustomobject]@{ spec = [pscustomobject]@{ serverGroup = [pscustomobject]@{
                template = [pscustomobject]@{ spec = [pscustomobject]@{ sets = @(
                    [pscustomobject]@{
                        map = 'Survival_1'
                        partitions = @(1)
                    })
                } } }
            } } }
        }
        Mock _Invoke-V6BgJsonPatch { $script:patched = $Patches; @{ Success = $true; Raw = '' } }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('Sandworm.SandwormDangerZonesEnabled', 'Vehicle.SandwormCollisionInteraction', 'dw.FuelBurningMultiplier') `
            -Values @{
                'Sandworm.SandwormDangerZonesEnabled' = 'false'
                'Vehicle.SandwormCollisionInteraction' = 'true'
                'dw.FuelBurningMultiplier'            = '7'
            }

        $result.Success | Should -BeTrue
        $args = @($script:patched | ForEach-Object { $_.value } | ForEach-Object { $_.arguments })
        $exec = @($args | Where-Object { $_ -like '-execcmds=*' })
        $exec.Count | Should -Be 1
        # The boolean keeps its literal true/false spelling, and the numeric
        # neighbours still ride along in the same argument.
        $exec[0] | Should -BeLike '*Sandworm.SandwormDangerZonesEnabled false*'
        $exec[0] | Should -BeLike '*Vehicle.SandwormCollisionInteraction true*'
        $exec[0] | Should -BeLike '*dw.FuelBurningMultiplier 7*'
    }

    It 'injects into the Deep Desert as well as Hagga, sourcing its partition from status.servers' {
        # Until 13.3.0 the injection was filtered to a non-dedicated Survival_1
        # set, so NO console variable ever reached the Deep Desert - it ran at
        # Funcom defaults out there while working on Hagga. DeepDesert_1 is
        # dedicatedScaling with an EMPTY partitions array and replicas=0 even
        # while its pod is running, so its partition index has to come from the
        # live status.servers[] list.
        Mock Get-V6Battlegroup {
            @{ Bg = [pscustomobject]@{
                spec = [pscustomobject]@{ serverGroup = [pscustomobject]@{
                    template = [pscustomobject]@{ spec = [pscustomobject]@{ sets = @(
                        [pscustomobject]@{ map = 'Survival_1'; partitions = @(1) }
                        [pscustomobject]@{ map = 'Overmap';    partitions = @(2) }
                        [pscustomobject]@{ map = 'DeepDesert_1'; dedicatedScaling = $true; partitions = $null; replicas = 0 }
                    ) } }
                } }
                status = [pscustomobject]@{ servers = @(
                    [pscustomobject]@{ partitionMap = 'Survival_1';   partitionIndex = 1 }
                    [pscustomobject]@{ partitionMap = 'Overmap';      partitionIndex = 2 }
                    [pscustomobject]@{ partitionMap = 'DeepDesert_1'; partitionIndex = 8 }
                ) }
            } }
        }
        $script:ddPatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:ddPatches = $Patches
            @{ Success = $true; Raw = ''; Error = $null }
        }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('dw.FuelBurningMultiplier') `
            -Values @{ 'dw.FuelBurningMultiplier' = '6' }

        $result.Success | Should -BeTrue

        # One patch per gameplay set: Hagga (set 0) and the Deep Desert (set 2).
        @($script:ddPatches).Count | Should -Be 2
        $paths = @($script:ddPatches | ForEach-Object { $_.path })
        $paths | Should -Contain '/spec/serverGroup/template/spec/sets/0/podSpecs'
        $paths | Should -Contain '/spec/serverGroup/template/spec/sets/2/podSpecs'
        # Overmap is the travel/world service and must be left alone.
        $paths | Should -Not -Contain '/spec/serverGroup/template/spec/sets/1/podSpecs'

        $dd = @($script:ddPatches | Where-Object { $_.path -like '*/sets/2/podSpecs' })[0]
        # Exactly one podSpec, and the index has to be the LIVE partition. A null
        # partitions array piped through [int] yields 0, which would invent a
        # podSpec for a partition that does not exist.
        @($dd.value).Count | Should -Be 1
        $dd.value[0].index | Should -Be 8
        @($dd.value[0].arguments | Where-Object { $_ -like '-execcmds=*' })[0] |
            Should -BeLike '*dw.FuelBurningMultiplier 6*'
    }

    It 'accepts safe string-valued console variables' {
        Mock Get-V6Battlegroup {
            [pscustomobject]@{
                Name = 'bg'; Ns = 'dune'
                Bg = [pscustomobject]@{
                    spec = [pscustomobject]@{
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{ sets = @() }
                            }
                        }
                    }
                    status = [pscustomobject]@{ servers = @() }
                }
            }
        }
        { Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('Bgd.ServerRuleset') `
            -Values @{ 'Bgd.ServerRuleset' = 'custom-rules' } } |
            Should -Not -Throw
    }

    It 'rejects string values that cannot be encoded in ExecCmds' {
        { Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('Bgd.ServerRuleset') `
            -Values @{ 'Bgd.ServerRuleset' = 'unsafe,value' } } |
            Should -Throw '*cannot be encoded in ExecCmds*'
    }

    It 'merges fuel and a per-sietch name into one ExecCmds argument' {
        $arguments = @(_Set-V6ExecCommand `
            -Arguments @('-log', '-execcmds="Bgd.ServerDisplayName ''Hagga, Prime''"') `
            -CommandName 'dw.FuelBurningMultiplier' `
            -Command 'dw.FuelBurningMultiplier 10')

        $arguments | Should -Contain '-log'
        @($arguments | Where-Object { $_ -like '-execcmds=*' }).Count | Should -Be 1
        $arguments | Should -Contain '-execcmds="Bgd.ServerDisplayName ''Hagga, Prime'',dw.FuelBurningMultiplier 10"'
    }

    It 'removes only the fuel command when reset to default' {
        $arguments = @(_Set-V6ExecCommand `
            -Arguments @('-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 10"') `
            -CommandName 'dw.FuelBurningMultiplier' `
            -Command $null)

        $arguments | Should -Be @('-execcmds="Bgd.ServerDisplayName ''Hagga''"')
    }

    It 'merges multiple managed vehicle CVars into the existing ExecCmds argument' {
        $arguments = @('-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 10"')
        foreach ($entry in @(
            @{ Name = 'dw.VehicleHeatMultiplier'; Command = 'dw.VehicleHeatMultiplier 0' },
            @{ Name = 'dw.VehiclePowerConsumptionMultiplier'; Command = 'dw.VehiclePowerConsumptionMultiplier 0' },
            @{ Name = 'dw.VehicleCanOverHeat'; Command = 'dw.VehicleCanOverHeat 0' }
        )) {
            $arguments = @(_Set-V6ExecCommand -Arguments $arguments `
                -CommandName $entry.Name -Command $entry.Command)
        }

        @($arguments | Where-Object { $_ -like '-execcmds=*' }).Count | Should -Be 1
        $arguments | Should -Contain '-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 10,dw.VehicleHeatMultiplier 0,dw.VehiclePowerConsumptionMultiplier 0,dw.VehicleCanOverHeat 0"'
    }

    It 'treats default with no existing pod overrides as a successful no-op' {
        Mock Get-V6Battlegroup {
            @{
                Ns = 'dune-ns'
                Name = 'dune-bg'
                Bg = [pscustomobject]@{ spec = [pscustomobject]@{
                    serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        sets = @([pscustomobject]@{
                            map = 'Survival_1'
                            dedicatedScaling = $false
                            partitions = @(1)
                        })
                    } } }
                } }
            }
        }
        Mock _Invoke-V6BgJsonPatch { throw 'Patch must not run for a no-op reset.' }

        $result = Set-V6FuelBurningMultiplier -Ip '192.0.2.1' -Value $null

        $result.Success | Should -BeTrue
        $result.NoChange | Should -BeTrue
        Should -Invoke _Invoke-V6BgJsonPatch -Times 0
    }

    It 'patches every Hagga partition while preserving names and other pod overrides' {
        Mock Get-V6Battlegroup {
            @{
                Ns = 'dune-ns'
                Name = 'dune-bg'
                Bg = [pscustomobject]@{ spec = [pscustomobject]@{
                    serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        sets = @(
                            [pscustomobject]@{
                                map = 'Survival_1'
                                dedicatedScaling = $false
                                partitions = @(1, 4)
                                podSpecs = @(
                                    [pscustomobject]@{
                                        index = 1
                                        arguments = @('-execcmds="Bgd.ServerDisplayName ''Hagga''"')
                                        nodeSelector = @{ disk = 'fast' }
                                    }
                                )
                            },
                            [pscustomobject]@{ map = 'Overmap'; dedicatedScaling = $false; partitions = @(2) }
                        )
                    } } }
                } }
            }
        }
        $script:fuelPatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:fuelPatches = $Patches
            @{ Success = $true; Raw = 'patched'; Error = $null }
        }

        $result = Set-V6FuelBurningMultiplier -Ip '192.0.2.1' -Value '10.0'

        $result.Success | Should -BeTrue
        $result.Value | Should -Be '10'
        @($script:fuelPatches).Count | Should -Be 1
        $specs = @($script:fuelPatches[0].value)
        @($specs.index | Sort-Object) | Should -Be @(1, 4)
        $specs[0].nodeSelector.disk | Should -Be 'fast'
        $specs[0].arguments | Should -Contain '-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 10"'
        $specs[1].arguments | Should -Contain '-execcmds="dw.FuelBurningMultiplier 10"'
    }

    It 'applies multiple experimental CVars in one patch operation' {
        Mock Get-V6Battlegroup {
            @{
                Ns = 'dune-ns'
                Name = 'dune-bg'
                Bg = [pscustomobject]@{ spec = [pscustomobject]@{
                    serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        sets = @([pscustomobject]@{
                            map = 'Survival_1'
                            dedicatedScaling = $false
                            partitions = @(1)
                            podSpecs = @([pscustomobject]@{
                                index = 1
                                arguments = @('-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 10,dw.VehicleHeatMultiplier 1"')
                            })
                        })
                    } } }
                } }
            }
        }
        $script:consolePatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:consolePatches = $Patches
            @{ Success = $true; Raw = 'patched'; Error = $null }
        }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('dw.FuelBurningMultiplier', 'dw.VehicleHeatMultiplier', 'Dune.GiveDoubleDifficultyLoot') `
            -Values @{
                'dw.FuelBurningMultiplier' = '50'
                'dw.VehicleHeatMultiplier' = '0'
                'Dune.GiveDoubleDifficultyLoot' = '1'
            }

        $result.Success | Should -BeTrue
        $args = @($script:consolePatches[0].value[0].arguments)
        @($args | Where-Object { $_ -like '-execcmds=*' }).Count | Should -Be 1
        $args | Should -Contain '-execcmds="Bgd.ServerDisplayName ''Hagga'',dw.FuelBurningMultiplier 50,dw.VehicleHeatMultiplier 0,Dune.GiveDoubleDifficultyLoot 1"'
    }

    It 'keeps fuel and vehicle commands when sietch names are changed' {
        Mock Get-V6Battlegroup {
            @{
                Ns = 'dune-ns'
                Name = 'dune-bg'
                Bg = [pscustomobject]@{ spec = [pscustomobject]@{
                    serverGroup = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        sets = @([pscustomobject]@{
                            map = 'Survival_1'
                            dedicatedScaling = $false
                            replicas = 1
                            partitions = @(1)
                            podSpecs = @([pscustomobject]@{
                                index = 1
                                arguments = @('-execcmds="dw.FuelBurningMultiplier 10,dw.VehicleHeatMultiplier 0,dw.VehicleCanOverHeat 0"')
                            })
                        })
                    } } }
                    database = [pscustomobject]@{ template = [pscustomobject]@{ spec = [pscustomobject]@{
                        deployment = [pscustomobject]@{ spec = [pscustomobject]@{
                            worldPartitions = @([pscustomobject]@{
                                map = 'Survival_1'
                                partitions = @([pscustomobject]@{ id=1; dimension=0; disable=$false; maxX=1; maxY=1; minX=0; minY=0 })
                            })
                        } }
                    } } }
                } }
            }
        }
        $script:sietchPatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:sietchPatches = $Patches
            @{ Success = $true; Raw = 'patched'; Error = $null }
        }

        $result = Set-V6SietchConfig -Ip '192.0.2.1' -Count 1 -Names @('Hagga')

        $result.Success | Should -BeTrue
        $podPatch = $script:sietchPatches | Where-Object { $_.path -like '*/podSpecs' }
        $podPatch.value[0].arguments | Should -Contain '-execcmds="dw.FuelBurningMultiplier 10,dw.VehicleHeatMultiplier 0,dw.VehicleCanOverHeat 0,Bgd.ServerDisplayName ''Hagga''"'
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

Describe 'DuneGameConfigSchema: experimental binary CVars' -Tag 'GameConfig' {
    BeforeAll {
        $script:ExperimentalKeys = @(
            'Abilities.RespecCooldownTotalDurationSeconds'
            'dw.VehicleHeatMultiplier'
            'dw.VehicleHeatInterpolationSpeed'
            'dw.VehiclePowerConsumptionMultiplier'
            'dw.VehicleCanOverHeat'
            'dw.VehicleAbandonedDecayAllowed'
            'dw.VehicleAbandonedDecayTimeMultiplier'
            'Vehicle.DisassemblySpeedMultiplier'
            'Vehicle.RecoveryChassisDurabilityReductionFraction'
            'Vehicle.RecoveryCurrencyBaseCost'
            'Vehicle.RecoveryTimeLimit'
            'Vehicle.MaxActiveVehicles'
            'Vehicle.MaxVehicles'
            'Vehicle.MaxVehiclesForSpawner'
            'Vehicle.MaxVehiclesWarning'
            'Vehicle.CharacterHitDamageModifier'
            'Vehicle.DamagePlayerOnVehicleCollision'
            'Player.IsThrowOffPlayerFromVehicleActive'
            'Player.ThrowOffPlayerFromVehicleVelocityMultiplier'
            'Player.ThrowOffPlayerFromVehicleVelocityThreshold'
            'Vehicle.SandwormInvulnerabilityOnExitInAir'
            'Vehicle.SandwormInvulnerabilityOnLeavingGame'
            'Sandworm.SandwormAttackDifficultyGroup'
            'SandwormSubsystem.DelayedRestartSeconds'
            'SpiceHarvesting.dune.SpawnCraterRocksAfterBloom'
            'dw.MitigateAllDamageToBuildables'
            'dw.EnableOutsideBuildablesToAffectShelter'
            'dw.BuildingShelterThresholdOverride'
            'dw.SandBuildUpPlaceableShelteredTargetValueOverride'
            'dw.SandBuildUpPlaceableUnShelteredTargetValueOverride'
            'Dac.FriendlyPvPDamageMultiplier'
            'Dac.HealingDurationReductionByDamageMultiplier'
            'NPC.AttackLimitOverride'
            'JourneyStory.Instance.Cap'
            'SafeZone.EnableScale'
            'SafeZone.Scale'
            # Second decode pass (build 2051294-0-shipping), UTF-16 aware.
            'NPC.EnableNpcAttackLimits'
            'dw.PlaceableShelterThresholdOverride'
            'Dac.DisablePvpDamage'
            'dw.EnableShelterSystem'
            'dw.BaseBackupMaxNumberOfBackups'
            'dw.bBaseBackupToolBackupEnabled'
            'dw.bBaseBackupToolPlacementEnabled'
            'dw.bBaseBackupToolRecycleEnabled'
            'dw.OverrideBaseBackupToolTimeRestrictionInSeconds'
            'Landsraad.ControlPointCaptureProgressTarget'
            'Sandworm.SandwormEnrageThreshold'
            'Sandworm.SandwormTargetChangeThreshold'
            'Sandworm.SandwormTargetDropThreshold'
            'Sandworm.ThreatWarning.DefaultDistance'
            'Sandworm.ThreatWarning.DeepDesertDistance'
            'Vehicle.RecoveryEnabled'
            'Vehicle.BackupTool.Enabled'
            'Vehicle.WreckedStateDespawnDuration'
            'Vehicle.AmmoBlocksBackup'
            'Bgd.ServerPlayerHardCap'
        )

        $script:Experimental2Keys = @(
            'Combat.DuelingSystem.Enabled'
            'Combat.CanDamageNonCombatNpc'
            'Dac.EnableNearDeathDamageMitigation'
            'Dac.EnableKnockbackDurationDamageScaling'
            'Dac.ShieldBreakWhileAirborne'
            'Abilities.HoltzmanShield.UsePowerWhenDisabled'
            'Abilities.AllowRepsecOutsideLandclaim'
            'Dune.LootNpcDroppedOnCorpseEnabled'
            'Dune.LootNpcDroppedOnContainerEnabled'
            'Inventory.GiveDefaultInventory.Enabled'
            'dw.Inventory.Item.Event.Enabled'
            'dw.Inventory.Item.Quest.Enabled'
            'dw.Inventory.Item.Slotless.Enabled'
            'Dune.Exchange.AllowUncategorizedItems'
            'Contracts.Map.Markers.Enabled'
            'Contracts.IsHiddingOfContractLootItemsEnabled'
            'Dune.Contracts.Board.ShowAllContracts'
            'dw.encounters.Enabled'
            'dw.encounters.LocationCooldown'
            'dw.encounters.PrioritizeNew'
            'dw.encounters.LandscapeLocationsOnly'
            'dw.encounters.ExcludeCoveredLocations'
            'dw.encounters.InstigatorArea.Enabled'
            'dw.encounters.AllowExclusivityRange'
            'dw.encounters.AreaLimits.Enabled.Override'
            'Hazard.ZonesEnabled'
            'Hazard.DestructionTime'
            'Hazard.OrnithoptersSinkInQuicksandEnabled'
            'Hazard.EnableQuicksandOnIGWBorders'
            'Journey.EnableSpiceExposureEvents'
            'Journey.EnableSimplifiedChallengeCompletion'
            'Progression.IgnorePrereqs'
            'Progression.ShowAllPerks'
            'dw.ReturningPlayer.GiveAward.Enabled'
            'dw.ReturningPlayer.DaysBeforeEligibleForReward'
            'dw.ReturningPlayer.GiveAward.TierOverride'
            'NPC.EnableFacingTargetCheck'
            'NPC.FacingTargetAngleStartThreshold'
            'NPC.FacingTargetAngleStopThreshold'
            'NPC.EnableWeaponRotationRateOverride'
            'NPC.DummyWeaponRotationRateOverride'
            'NPC.Respawn.StartCountdownOnEachNPCKilled'
            'NPC.AllowDoorAutoAccessToAllNPCs'
            'NPC.AllowDoorAutoAccessToAllNPCsRadius'
            'NPC.DoorAutoAccessRadius'
            'Sandworm.SandwormSharkwormRoam'
            'Sandworm.SandwormDeathVolumeEnabled'
            'Sandworm.SandwormCheckIfBreachLocationIsFreeOfPlayers'
            'Sandworm.SandwormCheckIfBreachLocationIsFreeOfVehicles'
            'Sandworm.SandwormOnTargetedCommuninetMessageEnabled'
            'Sandworm.SafezoneExpansionOffset'
            'Sandworm.InflatedSafezoneExpansionOffset'
            'SecurityZones.UsePvPOverrideTable'
            'Vehicle.RelocationEnabled'
            'Vehicle.BackupTool.ChannelingTimer.Enabled'
            'Vehicle.BlockDisassemblyInvalidLandclaim'
            'Vehicle.BlockDisassemblyVehicleHarnessed'
            'Vehicle.BlockDisassemblyVehicleInAir'
            'Vehicle.DisableWheeledVehicleTransfer'
            'Vehicle.LaunchCharacterOnVehicleCollision'
            'Vehicle.CharacterHitVelocityModifier'
            'Vehicle.CharacterHitVelocityLimit'
            'Vehicle.TerminalVelocityOverride'
            'Vehicle.MaxWeldingDistance'
            'Vehicle.SeatChangeHotkeysEnabled'
            'Vehicle.SeatChangeCooldown'
            'Vehicle.VehicleSpawnerCheckVehicleRate'
            'Vehicle.VehicleDamageSmokeEnabled'
            'Vehicle.VehicleSmokeTrailEnabled'
            'dw.BaseBackupShouldDetectNpcs'
            'dw.EnableShelterInvestigation'
        )
    }

    It 'isolates every binary-discovered control in the Experimental categories' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }
        $experimental = @($script:DuneGameConfigSchema | Where-Object Category -eq 'Experimental')
        $experimental2 = @($script:DuneGameConfigSchema | Where-Object Category -eq 'Experimental 2')

        $experimental.Count | Should -Be 56
        $experimental2.Count | Should -Be 71
        @($experimental.Key | Sort-Object) | Should -Be @($script:ExperimentalKeys | Sort-Object)
        @($experimental2.Key | Sort-Object) | Should -Be @($script:Experimental2Keys | Sort-Object)
        foreach ($key in @($script:ExperimentalKeys) + @($script:Experimental2Keys)) {
            $fields.ContainsKey($key) | Should -BeTrue
            $fields[$key].Section | Should -Be $script:DuneGcSecConsole
            $fields[$key].File | Should -Be 'engine'
            $fields[$key].Category | Should -BeLike 'Experimental*'
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $key
        }
        $lab = @($script:DuneGameConfigSchema | Where-Object Category -eq 'Experimental Lab')
        $lab.Count | Should -BeGreaterThan 4900
        $script:DuneAdvancedCvarLoadError | Should -BeNullOrEmpty
        @($script:DuneStartupConsoleVariableKeys).Count | Should -BeGreaterThan 5000
        ($lab | Where-Object Key -eq 'ak.soundengine.executeActionOnEvent').Group |
            Should -Be 'Audio - engine/internal'
        ($lab | Where-Object Key -eq 'au.adpcm.DisableSeeking').Group |
            Should -Be 'Audio - engine/internal'
        ($lab | Where-Object Key -eq 'Ai.Dune.EnableBudgetingSystem').Group |
            Should -Be 'AI - engine/internal'
    }

    It 'groups every experimental control for the Experimental page' {
        # The Experimental page renders one card per group, so every control must
        # land somewhere. Anything the rules cannot place is reported as
        # Uncategorized rather than being forced into a neighbouring group.
        $api = @(Get-DuneGameConfigSchemaApi)
        $fields = @($api | Where-Object { $_.category -like 'Experimental*' } | ForEach-Object { $_.fields })
        $fields.Count | Should -BeGreaterThan 5000
        foreach ($f in $fields) {
            $f.group | Should -Not -BeNullOrEmpty
            $f.status | Should -BeIn @('Confirmed', 'Unconfirmed')
            $f.source | Should -BeIn @('Dune', 'Engine')
            $f.risk | Should -BeIn @('experimental', 'diagnostic', 'high', 'critical')
        }
        # Namespace rules must win over keyword ones: a sandworm control that
        # mentions vehicles is a sandworm control.
        (Get-DuneExperimentalGroup -Key 'Sandworm.SandwormCheckIfBreachLocationIsFreeOfVehicles') | Should -Be 'Sandworm'
        (Get-DuneExperimentalGroup -Key 'Vehicle.MaxVehiclesPerPlayer') | Should -Be 'Vehicles'
        (Get-DuneExperimentalGroup -Key 'Deathstill.ConversionTimeOverride') | Should -Be 'Survival & Shelter'
        (Get-DuneExperimentalGroup -Key 'dw.FuelsBurningDuration') | Should -Be 'Fuel & Power'
        (Get-DuneExperimentalGroup -Key 'Bgd.ServerPlayerHardCap') | Should -Be 'Server & Session'
        (Get-DuneExperimentalGroup -Key 'Totally.MadeUpKey') | Should -Be 'Uncategorized'
    }

    It 'loads the advanced catalog as individual fields under Windows PowerShell 5.1' -Skip:($env:OS -ne 'Windows_NT') {
        $gameConfigPath = (Resolve-Path (Join-Path $PSScriptRoot '..\app\server\lib\GameConfig.ps1')).Path.Replace("'", "''")
        $command = ". '$gameConfigPath'; " +
            '$lab = @($script:DuneGameConfigSchema | Where-Object Category -eq ''Experimental Lab''); ' +
            'Write-Output $lab.Count; Write-Output ([string]$lab[0].Key).Length'
        $result = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command)

        [int]$result[0] | Should -BeGreaterThan 4900
        [int]$result[1] | Should -BeLessThan 256
    }

    It 'promotes field-confirmed controls out of Experimental without losing startup injection' {
        # Promotion is a metadata flip: a proven control leaves the Experimental
        # pages for a real category. Startup=$true must travel with it, because
        # these are console variables and INI-only application does nothing - the
        # value only lands when the battlegroup restart rebuilds the startup
        # command. Category alone used to drive that list, so promoting silently
        # broke the very setting being promoted.
        $promoted = @(
            'Dune.DisableShieldOnShooting'
            'Dune.GiveDoubleDifficultyLoot'
            'Deathstill.ConversionTimeOverride'
            'dw.FuelBurningMultiplier'
            'dw.FuelsBurningDuration'
            'dw.LandsraadMissionRewardMultiplierFactionXP'
            'dw.LandsraadMissionRewardMultiplierHouseCredit'
            'dw.LandsraadMissionRewardMultiplierSpecializationXP'
            'Loot.ShouldAlwaysRegeneratePerPlayerLoot'
            'Vehicle.MaxVehiclesPerPlayer'
        )
        foreach ($key in $promoted) {
            $f = $script:DuneGameConfigSchema | Where-Object { $_.Key -eq $key }
            $f | Should -Not -BeNullOrEmpty
            $f.Category | Should -Not -BeLike 'Experimental*'
            $f.Status | Should -Be 'Confirmed'
            $f.Startup | Should -BeTrue
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $key
        }

        # Promotion says a control works, not that the client reads it. Only keys
        # with client-side field evidence are mirrored to a player config;
        # everything else is applied server-side by the startup command alone.
        # Driven off the evidence list itself so adding a newly proven key is a
        # one-line change there, not a test edit.
        foreach ($key in $promoted) {
            $f = $script:DuneGameConfigSchema | Where-Object { $_.Key -eq $key }
            if (@($script:DuneClientEvaluatedConsoleVariables) -contains $key) {
                $f.ClientApply | Should -BeTrue
            } else {
                $f.ClientApply | Should -Not -BeTrue
            }
        }

        # The evidence list is deliberately tiny. If it ever grows large someone
        # has started adding keys that merely look client-read, which is the
        # blanket-mirror bug v13.2.4 removed.
        @($script:DuneClientEvaluatedConsoleVariables).Count | Should -BeLessOrEqual 5
        foreach ($key in @($script:DuneClientEvaluatedConsoleVariables)) {
            $f = $script:DuneGameConfigSchema | Where-Object { $_.Key -eq $key }
            $f | Should -Not -BeNullOrEmpty
            $f.ClientApply | Should -BeTrue
            # A server-instance control could never be client-read.
            $key | Should -Not -BeLike 'Bgd.*'
        }

        # Anything still on the Experimental pages is by definition unproven; a
        # confirmed result is what triggers promotion.
        $api = @(Get-DuneGameConfigSchemaApi)
        $fields = @($api | Where-Object { $_.category -like 'Experimental*' } | ForEach-Object { $_.fields })
        @($fields | Where-Object { $_.status -eq 'Confirmed' }) | Should -BeNullOrEmpty
    }

    It 'injects every non-Experimental console variable into the startup command' {
        # Console variables that shipped in real categories before the Startup flag
        # existed were written to UserEngine.ini and nowhere else, so they never
        # reached the Hagga startup command - and INI-only application is
        # field-proven inert for console variables. Every engine-file console
        # variable outside Experimental must therefore carry Startup=$true. The
        # Bgd.* pair is the deliberate exception: ServerDisplayName is injected per
        # partition by the Sietch code and ServerLoginPassword must never reach a
        # process command line.
        $consoleFields = @(
            $script:DuneGameConfigSchema |
                Where-Object { $_.Section -eq $script:DuneGcSecConsole -and $_.Category -notlike 'Experimental*' }
        )
        $consoleFields.Count | Should -BeGreaterThan 0
        foreach ($f in $consoleFields) {
            if ($f.Key -like 'Bgd.*') {
                $f.Startup | Should -Not -BeTrue
                @($script:DuneStartupConsoleVariableKeys) | Should -Not -Contain $f.Key
                continue
            }
            $f.Startup | Should -BeTrue
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $f.Key
        }
    }

    It 'never lists the same control in both Experimental categories' {
        $overlap = @($script:ExperimentalKeys | Where-Object { $_ -in $script:Experimental2Keys })
        $overlap | Should -BeNullOrEmpty
    }

    It 'does not ship a console variable that duplicates a game setting already on the page' {
        # Recovered from the binary but deliberately omitted: DST already exposes
        # the same behaviour as a UserGame.ini setting, and shipping both would
        # give one behaviour two switches with no known precedence.
        $twins = @{
            'Dune.PlayerDeathLootEnabled'        = 'm_bShouldPlayersDropLootOnDeath'
            'Sandworm.SandwormHibernationActive' = 'm_bEnableHibernation'
        }
        foreach ($cvar in $twins.Keys) {
            @($script:DuneGameConfigSchema.Key) | Should -Not -Contain $cvar
            @($script:DuneGameConfigSchema.Key) | Should -Contain $twins[$cvar]
        }
    }

    It 'never offers to mirror a server-instance control into a player client config' {
        # Bgd.* configures this server instance. Writing it into a player's local
        # Engine.ini would be meaningless at best and confusing at worst.
        $bgd = @($script:DuneGameConfigSchema | Where-Object { $_.Key -like 'Bgd.*' })
        $bgd.Count | Should -BeGreaterThan 0
        foreach ($f in $bgd) { $f.ClientApply | Should -Not -BeTrue }
    }

    It 'exposes the gate that the NPC attack-limit override depends on' {
        # NPC.AttackLimitOverride does nothing unless NPC.EnableNpcAttackLimits is
        # on, so shipping the override alone promised something it could not do.
        @($script:DuneGameConfigSchema.Key) | Should -Contain 'NPC.AttackLimitOverride'
        @($script:DuneGameConfigSchema.Key) | Should -Contain 'NPC.EnableNpcAttackLimits'
    }

    It 'ships both halves of the fuel and shelter pairs' {
        foreach ($pair in @(
            @('dw.FuelBurningMultiplier', 'dw.FuelsBurningDuration'),
            @('dw.BuildingShelterThresholdOverride', 'dw.PlaceableShelterThresholdOverride')
        )) {
            @($script:DuneGameConfigSchema.Key) | Should -Contain $pair[0]
            @($script:DuneGameConfigSchema.Key) | Should -Contain $pair[1]
        }
    }

    It 'surfaces dangerous controls with critical risk metadata' {
        foreach ($key in @(
            'Hazard.DehydrationZonesEnabled'
            'dw.igw.EnableAuthConfirmGainingCrash'
            'dw.igw.EnableAuthStartLosingDisconnect'
            'dw.DisallowDuplicateDatabaseItems'
            'dw.AllowPotentialDuplicatesOnTransfer'
            'Abilities.BypassRespecRequirement'
            'SecurityZones.ForceEnablePvp'
            'dw.EnableDeveloperMode'
        )) {
            $field = @($script:DuneGameConfigSchema | Where-Object Key -eq $key)
            $field.Count | Should -Be 1
            $field[0].Risk | Should -Be 'critical'
        }
    }

    It 'restores the vehicle controls for dual INI and startup-command testing' {
        $restored = @(
            'dw.VehicleHeatMultiplier'
            'dw.VehicleHeatInterpolationSpeed'
            'dw.VehiclePowerConsumptionMultiplier'
            'dw.VehicleCanOverHeat'
            'Vehicle.MaxActiveVehicles'
            'Vehicle.MaxVehicles'
            'Vehicle.MaxVehiclesForSpawner'
            'Vehicle.MaxVehiclesPerPlayer'
            'Vehicle.MaxVehiclesWarning'
        )

        foreach ($key in $restored) {
            @($script:DuneGameConfigSchema.Key) | Should -Contain $key
            @($script:DuneGameConfigDeprecatedManagedKeys) | Should -Not -Contain $key
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $key
        }
    }

    It 'keeps fuel burning available and out of the deprecated-scrub list' {
        # A schema key that is also in the deprecated list would be written and
        # then scrubbed on the same save, so the setting could never persist.
        @($script:DuneGameConfigSchema.Key) | Should -Contain 'dw.FuelBurningMultiplier'
        @($script:DuneGameConfigDeprecatedManagedKeys) | Should -Not -Contain 'dw.FuelBurningMultiplier'
    }

    It 'never lists a live schema key in the deprecated-scrub list' {
        foreach ($key in @($script:DuneGameConfigDeprecatedManagedKeys)) {
            @($script:DuneGameConfigSchema.Key) | Should -Not -Contain $key
        }
    }

    It 'keeps legacy returning-player popup controls available so old injections can be disabled' {
        $legacy = @(
            'dw.ReturningPlayer.GiveAward.Enabled'
            'dw.ReturningPlayer.DaysBeforeEligibleForReward'
            'dw.ReturningPlayer.GiveAward.TierOverride'
        )
        foreach ($key in $legacy) {
            @($script:DuneGameConfigSchema.Key) | Should -Contain $key
            @($script:DuneGameConfigDeprecatedManagedKeys) | Should -Not -Contain $key
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $key
        }

        $raw = @"
; ===== Dune Server Tool (DST) managed section BEGIN =====
[ConsoleVariables]
dw.FuelBurningMultiplier=6
dw.ReturningPlayer.GiveAward.Enabled=1
dw.ReturningPlayer.DaysBeforeEligibleForReward=1
dw.ReturningPlayer.GiveAward.TierOverride=2
; ===== Dune Server Tool (DST) managed section END =====
"@
        $updates = @(
            @{ section = $script:DuneGcSecConsole; key = 'dw.ReturningPlayer.GiveAward.Enabled'; value = '0'; quoted = $false }
        )
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}

        $out | Should -Match 'dw\.ReturningPlayer\.GiveAward\.Enabled=0'
        $out | Should -Match 'dw\.ReturningPlayer\.DaysBeforeEligibleForReward=1'
        $out | Should -Match 'dw\.ReturningPlayer\.GiveAward\.TierOverride=2'
        $out | Should -Match 'dw\.FuelBurningMultiplier=6'
        @([regex]::Matches($out, 'ReturningPlayer\.GiveAward\.Enabled')).Count | Should -Be 1
    }

    It 'keeps restored vehicle controls in the managed INI block on the next save' {
        $raw = @"
; user-owned content remains untouched
[ConsoleVariables]
User.HandEditedSetting=1

$script:DstManagedBegin
[ConsoleVariables]
dw.FuelBurningMultiplier=10
dw.VehicleHeatMultiplier=0
dw.VehicleHeatInterpolationSpeed=0
dw.VehiclePowerConsumptionMultiplier=0
dw.VehicleCanOverHeat=0
Vehicle.MaxActiveVehicles=15
Vehicle.MaxVehicles=15
Vehicle.MaxVehiclesForSpawner=15
Vehicle.MaxVehiclesPerPlayer=15
Vehicle.MaxVehiclesWarning=12
Dune.GiveDoubleDifficultyLoot=1
$script:DstManagedEnd
"@
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @(
            @{ section=$script:DuneGcSecConsole; key='Dune.GiveDoubleDifficultyLoot'; value='1' }
        ) -QuotedKeys @{}

        $out | Should -Match '(?m)^dw\.VehicleHeatMultiplier=0$'
        $out | Should -Match '(?m)^dw\.VehicleHeatInterpolationSpeed=0$'
        $out | Should -Match '(?m)^dw\.VehiclePowerConsumptionMultiplier=0$'
        $out | Should -Match '(?m)^dw\.VehicleCanOverHeat=0$'
        $out | Should -Match '(?m)^Vehicle\.MaxActiveVehicles=15$'
        $out | Should -Match '(?m)^Vehicle\.MaxVehicles=15$'
        $out | Should -Match '(?m)^Vehicle\.MaxVehiclesForSpawner=15$'
        $out | Should -Match '(?m)^Vehicle\.MaxVehiclesPerPlayer=15$'
        $out | Should -Match '(?m)^Vehicle\.MaxVehiclesWarning=12$'
        $out | Should -Match '(?m)^User\.HandEditedSetting=1$'
        $out | Should -Match '(?m)^Dune\.GiveDoubleDifficultyLoot=1$'
    }

    It 'uses binary catalogue types and recovered defaults without inventing unknown defaults' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }

        foreach ($key in @(
            'Dune.GiveDoubleDifficultyLoot',
            'dw.VehicleAbandonedDecayAllowed',
            'Vehicle.DamagePlayerOnVehicleCollision',
            'Player.IsThrowOffPlayerFromVehicleActive',
            'Vehicle.SandwormInvulnerabilityOnExitInAir',
            'Vehicle.SandwormInvulnerabilityOnLeavingGame',
            'SpiceHarvesting.dune.SpawnCraterRocksAfterBloom',
            'dw.MitigateAllDamageToBuildables',
            'dw.EnableOutsideBuildablesToAffectShelter',
            'SafeZone.EnableScale'
        )) {
            $fields[$key].Type | Should -Be 'bool01'
        }

        foreach ($key in @(
            'dw.LandsraadMissionRewardMultiplierFactionXP',
            'dw.LandsraadMissionRewardMultiplierHouseCredit',
            'dw.LandsraadMissionRewardMultiplierSpecializationXP',
            'dw.VehicleAbandonedDecayTimeMultiplier',
            'Vehicle.DisassemblySpeedMultiplier',
            'Vehicle.CharacterHitDamageModifier',
            'SafeZone.Scale'
        )) {
            $fields[$key].Type | Should -Be 'float'
            $fields[$key].Default | Should -Be '1.0'
            $fields[$key].ContainsKey('Max') | Should -BeFalse
        }
        $fields['Abilities.RespecCooldownTotalDurationSeconds'].Type | Should -Be 'int'
        $fields['Abilities.RespecCooldownTotalDurationSeconds'].Default | Should -Be '172800'
        $fields['Abilities.RespecCooldownTotalDurationSeconds'].Min | Should -Be 0
        $fields['Sandworm.SandwormAttackDifficultyGroup'].Type | Should -Be 'select'
        @($fields['Sandworm.SandwormAttackDifficultyGroup'].Options.V) | Should -Be @('-1','0','1','2','3')
        foreach ($key in @(
            'dw.VehicleAbandonedDecayAllowed',
            'Vehicle.RecoveryTimeLimit',
            'Vehicle.DamagePlayerOnVehicleCollision',
            'Vehicle.SandwormInvulnerabilityOnExitInAir',
            'Vehicle.SandwormInvulnerabilityOnLeavingGame',
            'dw.MitigateAllDamageToBuildables',
            'dw.EnableOutsideBuildablesToAffectShelter',
            'Dac.FriendlyPvPDamageMultiplier',
            'Dac.HealingDurationReductionByDamageMultiplier',
            'SafeZone.EnableScale'
        )) {
            $fields[$key].ContainsKey('Default') | Should -BeFalse -Because "$key has no reliably recovered compiled default"
        }
    }

    It 'validates advanced CVar values before they can poison the restart payload' {
        Test-DuneStartupConsoleVariableValue -Value 'custom-rules' | Should -BeTrue
        Test-DuneStartupConsoleVariableValue -Value 'true' | Should -BeTrue
        Test-DuneStartupConsoleVariableValue -Value 'unsafe,value' | Should -BeFalse
        Test-DuneStartupConsoleVariableValue -Value 'unsafe"value' | Should -BeFalse
    }

    It 'keeps experimental CVars out of local client changes' {
        # Experimental controls are unproven console variables; nothing shows the
        # client reads them, and the server applies them through the startup
        # command. Offering them for client apply would tell a player to edit a
        # file for no effect - and would mirror them onto the admin's own machine,
        # confounding the very field test that is meant to prove them.
        Mock Get-DuneGameConfigClientEngineEnabled { $true }
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ file='engine'; section=$script:DuneGcSecConsole; key='Dune.GiveDoubleDifficultyLoot'; value='1' },
            @{ file='engine'; section=$script:DuneGcSecConsole; key='Abilities.RespecCooldownTotalDurationSeconds'; value='0' }
        )

        @($notice.items).Count | Should -Be 0
    }

    It 'offers the one client-read console variable for local client changes' {
        Mock Get-DuneGameConfigClientEngineEnabled { $true }
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ file='engine'; section=$script:DuneGcSecConsole; key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
        )

        @($notice.items).Count | Should -Be 1
        @($notice.items)[0].key | Should -Be 'Vehicle.MaxVehiclesPerPlayer'
        @($notice.items | ForEach-Object { $_.file } | Select-Object -Unique) | Should -Be @('engine')
        $notice.paths.engine | Should -Match 'Engine\.ini$'
    }

    It 'marks Landsraad client notices as struct-member updates' {
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ file='game'; section=$script:DuneGcSecLandsraad; key='m_LandsraadContractsPerVotingBlock'; value='12' }
        )

        @($notice.items).Count | Should -Be 1
        @($notice.items)[0].structKey | Should -Be 'Data'
    }

    It 'exposes the field-confirmed Landsraad abandon cooldown' {
        $field = @($script:DuneGameConfigSchema | Where-Object { $_.Key -eq 'm_LandsraadContractsAbandonCooldownSeconds' })

        $field.Count | Should -Be 1
        $field[0].StructKey | Should -Be 'Data'
        $field[0].Default | Should -Be '3600'
        $field[0].ClientApply | Should -BeTrue
    }

    It 'places the Experimental catalogs last in the curated schema API, in order' {
        $cats = @((Get-DuneGameConfigSchemaApi) | ForEach-Object { $_.category })
        $cats[-3] | Should -Be 'Experimental'
        $cats[-2] | Should -Be 'Experimental 2'
        $cats[-1] | Should -Be 'Experimental Lab'
    }

    It 'persists experimental controls in the UserEngine ConsoleVariables section' {
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates @(
            @{ section=$script:DuneGcSecConsole; key='Dune.GiveDoubleDifficultyLoot'; value='1' },
            @{ section=$script:DuneGcSecConsole; key='dw.VehicleAbandonedDecayTimeMultiplier'; value='0.5' }
        ) -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $script:DuneGcSecConsole) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $script:DuneGcSecConsole -Key 'Dune.GiveDoubleDifficultyLoot') | Should -Be '1'
        (Get-EffectiveValue -Raw $out -Section $script:DuneGcSecConsole -Key 'dw.VehicleAbandonedDecayTimeMultiplier') | Should -Be '0.5'
    }
}

# ---------------------------------------------------------------------------
# Forced Coriolis world seed.
#
# The world-reset seed rows in the game database are the game's OUTPUT: on map
# load the game overwrites them with the seed it derived. The real control is
# this INI key, so it has to be reachable through the normal schema machinery
# (read / write / default / reset / client apply) rather than a bespoke UI.
# ---------------------------------------------------------------------------
Describe 'DuneGameConfigSchema: forced Coriolis world seed' -Tag 'GameConfig' {

    It 'exposes m_ForcedCoriolisWorldSeed as a CoriolisSubsystem game setting' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }

        $fields.ContainsKey('m_ForcedCoriolisWorldSeed') | Should -BeTrue
        $f = $fields['m_ForcedCoriolisWorldSeed']
        $f.Section  | Should -Be '/Script/DuneSandbox.CoriolisSubsystem'
        $f.File     | Should -Be 'game'
        $f.Type     | Should -Be 'int'
        $f.Min      | Should -Be -1
        $f.Max      | Should -Be 11
        $f.Default  | Should -Be '-1'
        $f.Category | Should -Be 'Storm Cycle'
    }

    It 'matches its CoriolisSubsystem neighbours on client apply' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }

        $neighbours = @('m_CycleDurationInDays', 'm_bIsDbWipeEnabled', 'm_bShouldRestartServerOnCycleEnd')
        foreach ($k in $neighbours) { $fields[$k].ClientApply | Should -BeTrue }
        $fields['m_ForcedCoriolisWorldSeed'].ClientApply | Should -BeTrue
    }

    It 'documents that the key is server-wide and not immediate' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }
        $help = [string]$fields['m_ForcedCoriolisWorldSeed'].Help

        # Farm-scoped: it pins every map, not just the Deep Desert.
        $help | Should -Match '(?i)EVERY map'
        $help | Should -Match '(?i)not just the Deep Desert'
        # -1 = automatic per cycle, 0-11 pin a fixed layout.
        $help | Should -Match '\-1 = automatic'
        $help | Should -Match '0-11'
        # Adoption happens on the next regeneration of each map.
        $help | Should -Match '(?i)regenerates'
        $help | Should -Match '(?i)not immediate'
    }

    It 'surfaces the seed through the curated schema API with its range intact' {
        $storm = @((Get-DuneGameConfigSchemaApi) | Where-Object { $_.category -eq 'Storm Cycle' })
        $storm.Count | Should -BeGreaterThan 0
        $field = @($storm[0].fields | Where-Object { $_.key -eq 'm_ForcedCoriolisWorldSeed' })
        $field.Count | Should -Be 1
        $field[0].min | Should -Be -1
        $field[0].max | Should -Be 11
    }

    It 'persists the seed into the server-side managed block' {
        $sec = '/Script/DuneSandbox.CoriolisSubsystem'
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates @(
            @{ section=$sec; key='m_ForcedCoriolisWorldSeed'; value='7' }
        ) -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $sec) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $sec -Key 'm_ForcedCoriolisWorldSeed') | Should -Be '7'
    }
}

Describe 'DuneGameConfigSchema: CraftingSettings fields' -Tag 'GameConfig' {
    It 'exposes repair and recycler weights as server-and-client game settings' {
        $fields = @{}
        foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }

        foreach ($k in @('m_RepairCostWeight', 'm_RecyclerOutputWeight')) {
            $fields.ContainsKey($k) | Should -BeTrue
            $fields[$k].Section | Should -Be $script:SecCrafting
            $fields[$k].File | Should -Be 'game'
            $fields[$k].Type | Should -Be 'float'
            $fields[$k].Default | Should -Be '1.0'
            $fields[$k].ClientApply | Should -BeTrue
        }
    }

    It 'includes Crafting in the curated schema API order' {
        $cats = @((Get-DuneGameConfigSchemaApi) | ForEach-Object { $_.category })
        $cats | Should -Contain 'Crafting'
        ([array]::IndexOf($cats, 'Crafting')) | Should -BeGreaterThan ([array]::IndexOf($cats, 'Resources & Economy'))
        ([array]::IndexOf($cats, 'Crafting')) | Should -BeLessThan ([array]::IndexOf($cats, 'Building'))
    }

    It 'exposes the distributed research reveal switch as an experimental game setting' {
        $field = @($script:DuneGameConfigSchema | Where-Object Key -eq 'm_bRevealItemOnDistributedToCharacter')

        $field.Count | Should -Be 1
        $field[0].Section | Should -Be '/Script/DuneSandbox.TechKnowledgeSettings'
        $field[0].File | Should -Be 'game'
        $field[0].Type | Should -Be 'bool'
        $field[0].Default | Should -Be 'False'
        $field[0].ClientApply | Should -BeTrue
        $field[0].Category | Should -Be 'Crafting'
        $field[0].Label | Should -Match 'Experimental'
        $field[0].Help | Should -Match '(?i)cannot reconstruct missing schematic research-cost metadata'
    }

    It 'persists the distributed research reveal switch in TechKnowledgeSettings' {
        $section = '/Script/DuneSandbox.TechKnowledgeSettings'
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates @(
            @{ section=$section; key='m_bRevealItemOnDistributedToCharacter'; value='True' }
        ) -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $section) | Should -Be 1
        (Get-EffectiveValue -Raw $out -Section $section -Key 'm_bRevealItemOnDistributedToCharacter') | Should -Be 'True'
    }

    It 'returns repair and recycler weights in the client-apply notice after server save' {
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ file='game'; section=$script:SecCrafting; key='m_RepairCostWeight'; value='0.5' },
            @{ file='game'; section=$script:SecCrafting; key='m_RecyclerOutputWeight'; value='2.0' }
        )
        $items = @($notice.items)
        $items.Count | Should -Be 2
        @($items | ForEach-Object { $_.key }) | Should -Contain 'm_RepairCostWeight'
        @($items | ForEach-Object { $_.key }) | Should -Contain 'm_RecyclerOutputWeight'
        foreach ($it in $items) {
            $it.section | Should -Be $script:SecCrafting
        }
    }

    It 'persists repair and recycler weights into the server-side managed block' {
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates @(
            @{ section=$script:SecCrafting; key='m_RepairCostWeight'; value='0.5' },
            @{ section=$script:SecCrafting; key='m_RecyclerOutputWeight'; value='2.0' }
        ) -QuotedKeys @{}

        (Get-HeaderCount -Raw $out -Name $script:SecCrafting) | Should -Be 1
        $out.IndexOf('[' + $script:SecCrafting + ']') | Should -BeGreaterThan ($out.IndexOf($script:DstManagedBegin))
        (Get-EffectiveValue -Raw $out -Section $script:SecCrafting -Key 'm_RepairCostWeight') | Should -Be '0.5'
        (Get-EffectiveValue -Raw $out -Section $script:SecCrafting -Key 'm_RecyclerOutputWeight') | Should -Be '2.0'
    }

    It 'allows the client-side writer to persist repair and recycler weights' {
        $dir = (Get-PSDrive TestDrive).Root
        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='m_RepairCostWeight'; value='0.25' },
            @{ key='m_RecyclerOutputWeight'; value='1.75' }
        )

        $result.ok | Should -BeTrue
        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Game.ini'))
        (Get-HeaderCount -Raw $raw -Name $script:SecCrafting) | Should -Be 1
        (Get-EffectiveValue -Raw $raw -Section $script:SecCrafting -Key 'm_RepairCostWeight') | Should -Be '0.25'
        (Get-EffectiveValue -Raw $raw -Section $script:SecCrafting -Key 'm_RecyclerOutputWeight') | Should -Be '1.75'
    }

    It 'parks client-touched sections inside the DST managed block at the bottom' {
        # Users want to copy the DST section to share with players connecting to
        # their server, so every DST-touched key must live below the BEGIN marker
        # and unrelated sections (audio/video) must stay where they were.
        $dir = (Get-PSDrive TestDrive).Root
        $path = Join-Path $dir 'Game.ini'
        [IO.File]::WriteAllText($path, @"
[Audio]
MasterVolume=0.8

[$script:SecCrafting]
m_RepairCostWeight=1.0

[Video]
ResolutionScale=100
"@)
        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='m_RepairCostWeight'; value='0.25' }
        )
        $result.ok | Should -BeTrue
        $raw = [IO.File]::ReadAllText($path)

        # DST markers present
        $raw | Should -Match ([regex]::Escape($script:DstManagedBegin))
        $raw | Should -Match ([regex]::Escape($script:DstManagedEnd))

        # Touched section lives below the BEGIN marker
        $beginIdx     = $raw.IndexOf($script:DstManagedBegin)
        $craftingIdx  = $raw.IndexOf('[' + $script:SecCrafting + ']')
        $craftingIdx | Should -BeGreaterThan $beginIdx

        # Untouched sections stay above the BEGIN marker
        $raw.IndexOf('[Audio]') | Should -BeLessThan $beginIdx
        $raw.IndexOf('[Video]') | Should -BeLessThan $beginIdx
        $raw.IndexOf('[Audio]') | Should -BeGreaterOrEqual 0
        $raw.IndexOf('[Video]') | Should -BeGreaterOrEqual 0
    }
}

Describe 'GameConfig: client-apply flag covers local gameplay settings' -Tag 'GameConfig' {

    # Settings written to the server's Game.ini are also read by the client, so
    # each one has to be offered for client-side apply. Gameplay console variables
    # are also mirrored to Engine.ini; identity/password/port settings are not.
    #
    # A false positive here is harmless - the client write path strips any value
    # that equals its default, and server config wins regardless - whereas a
    # missing flag silently denies the operator a client apply they needed.

    It 'flags every game-file setting for client apply' {
        $missing = @($script:DuneGameConfigSchema |
            Where-Object { $_.File -eq 'game' -and -not ($_.ContainsKey('ClientApply') -and $_.ClientApply) } |
            ForEach-Object { $_.Key })
        $missing -join ', ' | Should -Be ''
    }

    It 'mirrors only console variables the client is proven to read' {
        # Console variables reach the server through the startup command, not any
        # INI, so a client copy is only meaningful for the ones the client
        # evaluates itself. Flagging the rest is not harmless: it tells players to
        # edit a file for no effect, and it mirrors the whole managed set onto the
        # admin's own machine, which confounds every result he field-tests.
        $gameplayEngine = @($script:DuneGameConfigSchema |
            Where-Object { $_.File -eq 'engine' -and $_.Section -eq $script:DuneGcSecConsole })

        $flagged = @($gameplayEngine | Where-Object { $_.ClientApply } | ForEach-Object { $_.Key })
        @($flagged | Sort-Object) | Should -Be @($script:DuneClientEvaluatedConsoleVariables | Sort-Object)

        # The one control with client-side field evidence.
        $flagged | Should -Contain 'Vehicle.MaxVehiclesPerPlayer'

        # Server-instance and connection settings could never qualify.
        foreach ($key in @('Bgd.ServerDisplayName','Bgd.ServerLoginPassword','Port','IGWPort')) {
            $field = @($script:DuneGameConfigSchema | Where-Object Key -eq $key)[0]
            $field.ContainsKey('ClientApply') | Should -BeFalse
        }
    }

    It 'treats a value equal to its default as a removal, not a write' {
        # Covers the three cases: unchanged default is never written, a changed
        # value is written, and changing back to the default strips the key.
        Test-DuneGameConfigValueIsDefault -Key 'm_StormDuration' -Value '900'  | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'm_StormDuration' -Value '1200' | Should -BeFalse
        # Numeric compare, so formatting differences still count as default.
        Test-DuneGameConfigValueIsDefault -Key 'm_WaterConsumptionRate' -Value '1'   | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'm_WaterConsumptionRate' -Value '1.0' | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'm_WaterConsumptionRate' -Value '2.0' | Should -BeFalse
    }

    It 'only queues a deprecated key for removal when the file actually contains it' {
        # Regression: every deprecated key used to be queued unconditionally, so
        # saving one setting reported "removed 18 keys" against a file that held
        # none of them. The scrub must be driven by the file's real contents.
        $src = (Get-Command Save-DuneGameConfigClient).ScriptBlock.ToString()
        $deprecatedLoop = [regex]::Match(
            $src,
            '(?s)foreach \(\$dk in \$script:DuneGameConfigDeprecatedManagedKeys\).*?\n\s*\}'
        ).Value
        $deprecatedLoop | Should -Not -BeNullOrEmpty
        $deprecatedLoop | Should -Match '\$existing -match'
    }
}

Describe 'GameConfig: Engine.ini opt-in setting' -Tag 'GameConfig' {
    It 'is persisted by config and defaults to disabled' {
        $script:DuneConfigKeys | Should -Contain 'ClientEngineIniEnabled'
        Mock Read-DuneConfig { [ordered]@{ ClientEngineIniEnabled = '' } }
        Get-DuneGameConfigClientEngineEnabled | Should -BeFalse
    }

    It 'enables only for an explicit truthy config value' {
        Mock Read-DuneConfig { [ordered]@{ ClientEngineIniEnabled = 'true' } }
        Get-DuneGameConfigClientEngineEnabled | Should -BeTrue
    }

    It 'reads the configured client folder from the ordered config map' {
        Mock Read-DuneConfig { [ordered]@{ ClientConfigPath = 'C:\DuneClient'; ClientEngineIniEnabled = '' } }
        Get-DuneGameConfigClientDir | Should -Be 'C:\DuneClient'
    }
}

Describe 'GameConfig: local client Game.ini and Engine.ini' -Tag 'GameConfig' {

    BeforeEach {
        Mock Get-DuneGameConfigClientEngineEnabled { $true }
        Mock Test-DuneGameClientRunning { $false }
    }

    It 'reads both client files while preserving legacy Game.ini fields' {
        $dir = (Get-PSDrive TestDrive).Root
        [IO.File]::WriteAllText((Join-Path $dir 'Game.ini'), "[$script:SecCrafting]`nm_RepairCostWeight=0.5`n")
        [IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), "[$script:DuneGcSecConsole]`nVehicle.MaxVehiclesPerPlayer=20`n")

        $client = Get-DuneGameConfigClient -Dir $dir

        $client.path | Should -Be (Join-Path $dir 'Game.ini')
        $client.raw | Should -Be $client.game.raw
        $client.game.exists | Should -BeTrue
        $client.engine.exists | Should -BeTrue
        $client.engineEnabled | Should -BeTrue
        $client.engine.effective["$script:DuneGcSecConsole||Vehicle.MaxVehiclesPerPlayer"] | Should -Be '20'
    }

    It 'routes mixed updates into the correct managed client files' {
        $dir = (Get-PSDrive TestDrive).Root
        [IO.File]::WriteAllText((Join-Path $dir 'Game.ini'), "[Audio]`nMasterVolume=0.8`n")
        [IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), "[Renderer]`nr.ScreenPercentage=100`n")

        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='m_RepairCostWeight'; value='0.25' },
            @{ key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
        )

        $gameRaw = [IO.File]::ReadAllText((Join-Path $dir 'Game.ini'))
        $engineRaw = [IO.File]::ReadAllText((Join-Path $dir 'Engine.ini'))
        $gameRaw | Should -Match 'm_RepairCostWeight=0.25'
        $gameRaw | Should -Not -Match 'Vehicle\.MaxVehiclesPerPlayer'
        $gameRaw | Should -Match 'MasterVolume=0.8'
        $engineRaw | Should -Match 'Vehicle\.MaxVehiclesPerPlayer=20'
        $engineRaw | Should -Not -Match 'm_RepairCostWeight'
        $engineRaw | Should -Match 'r\.ScreenPercentage=100'
        $engineRaw | Should -Match "`r`n"
        $result.files.game.path | Should -Be (Join-Path $dir 'Game.ini')
        $result.files.engine.path | Should -Be (Join-Path $dir 'Engine.ini')
        @($result.items | ForEach-Object file | Sort-Object -Unique) | Should -Be @('engine','game')
    }

    It 'removes an Engine.ini key when reset to its default' {
        $dir = (Get-PSDrive TestDrive).Root
        [IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), @"
[$script:DuneGcSecConsole]
Vehicle.MaxVehiclesPerPlayer=20
"@)

        Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='Vehicle.MaxVehiclesPerPlayer'; value='10' }
        ) | Out-Null

        [IO.File]::ReadAllText((Join-Path $dir 'Engine.ini')) | Should -Not -Match 'Vehicle\.MaxVehiclesPerPlayer'
    }

    It 'refuses Engine.ini writes while the game client is running before touching either file' {
        Mock Test-DuneGameClientRunning { $true }
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'running-guard'
        [void](New-Item -ItemType Directory -Path $dir)

        {
            Save-DuneGameConfigClient -Dir $dir -Updates @(
                @{ key='m_RepairCostWeight'; value='0.25' },
                @{ key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
            )
        } | Should -Throw '*Close Dune: Awakening*'

        Test-Path (Join-Path $dir 'Game.ini') | Should -BeFalse
        Test-Path (Join-Path $dir 'Engine.ini') | Should -BeFalse
    }

    It 'bypasses Engine.ini notices and writes when the opt-in is disabled' {
        Mock Get-DuneGameConfigClientEngineEnabled { $false }
        $dir = (Get-PSDrive TestDrive).Root
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
        )

        @($notice.items).Count | Should -Be 0
        {
            Save-DuneGameConfigClient -Dir $dir -Updates @(
                @{ key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
            )
        } | Should -Throw '*No client-applicable keys*'
    }

    It 'still writes Game.ini while skipping Engine.ini in a mixed disabled request' {
        Mock Get-DuneGameConfigClientEngineEnabled { $false }
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'mixed-disabled'
        [void](New-Item -ItemType Directory -Path $dir)

        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='m_RepairCostWeight'; value='0.25' },
            @{ key='Vehicle.MaxVehiclesPerPlayer'; value='20' }
        )

        $result.files.ContainsKey('game') | Should -BeTrue
        $result.files.ContainsKey('engine') | Should -BeFalse
        Test-Path (Join-Path $dir 'Engine.ini') | Should -BeFalse
    }

    It 'removes managed Engine.ini values when the opt-in is disabled' {
        $dir = (Get-PSDrive TestDrive).Root
        [IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), @"
[Renderer]
r.ScreenPercentage=100

[$script:DuneGcSecConsole]
Vehicle.MaxVehiclesPerPlayer=20
Dune.GiveDoubleDifficultyLoot=1
"@)

        $result = Remove-DuneGameConfigClientEngineValues -Dir $dir
        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Engine.ini'))

        $result.removed | Should -Be 2
        $result.changed | Should -BeTrue
        $raw | Should -Not -Match 'Vehicle\.MaxVehiclesPerPlayer'
        $raw | Should -Not -Match 'Dune\.GiveDoubleDifficultyLoot'
        $raw | Should -Match 'r\.ScreenPercentage=100'
    }

    It 'still removes console variables written by earlier versions on opt-out' {
        # Before the mirror was narrowed to client-read controls, DST flagged every
        # non-Bgd console variable for client apply, so an existing user can have
        # any of them sitting in their Engine.ini. Opting out must clear those too,
        # or narrowing the write set silently strands them in the player's file.
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'legacy-cvars'
        [void](New-Item -ItemType Directory -Path $dir)
        [IO.File]::WriteAllText((Join-Path $dir 'Engine.ini'), @"
[Renderer]
r.ScreenPercentage=100

[$script:DuneGcSecConsole]
dw.FuelBurningMultiplier=7
Abilities.RespecCooldownTotalDurationSeconds=0
"@)

        $result = Remove-DuneGameConfigClientEngineValues -Dir $dir
        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Engine.ini'))

        $result.removed | Should -Be 2
        $raw | Should -Not -Match 'dw\.FuelBurningMultiplier'
        $raw | Should -Not -Match 'Abilities\.RespecCooldownTotalDurationSeconds'
        $raw | Should -Match 'r\.ScreenPercentage=100'
    }

    It 'does not remove Engine.ini values while the game client is running' {
        Mock Test-DuneGameClientRunning { $true }
        $dir = (Get-PSDrive TestDrive).Root
        $path = Join-Path $dir 'Engine.ini'
        [IO.File]::WriteAllText($path, "[$script:DuneGcSecConsole]`nVehicle.MaxVehiclesPerPlayer=20`n")
        $before = [IO.File]::ReadAllText($path)

        { Remove-DuneGameConfigClientEngineValues -Dir $dir } | Should -Throw '*Close Dune: Awakening*'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
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

Describe 'Land-claim (staking unit) extension timer' -Tag 'GameConfig' {

    It 'enable writes both scalars + full removal schedule into the managed BuildingSettings block' {
        $ups = Build-DuneLandclaimUpdates -Enabled $true -Seconds '1' -File 'game'
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates $ups -QuotedKeys @{}
        $out | Should -Match 'm_StakingUnitExtensionDefaultTimes=1'
        $out | Should -Match 'm_StakingUnitVerticalExtensionDefaultTimes=1'
        ([regex]::Matches($out, '-m_StakingUnitExtensionDefaultTimes=')).Count | Should -Be 10
        ([regex]::Matches($out, '-m_StakingUnitVerticalExtensionDefaultTimes=')).Count | Should -Be 10
        $out | Should -Match '-m_StakingUnitExtensionDefaultTimes=30720\.000000'
    }

    It 'state parser reports enabled + seconds + formattedOk on a well-formed block' {
        $ups = Build-DuneLandclaimUpdates -Enabled $true -Seconds '5' -File 'game'
        $out = ConvertTo-DuneIniManaged -Raw '' -Updates $ups -QuotedKeys @{}
        $st  = Get-DuneLandclaimTimerState -Raw $out
        $st.enabled     | Should -BeTrue
        $st.seconds     | Should -Be '5'
        $st.formattedOk | Should -BeTrue
    }

    It 're-applying a new value is idempotent (no duplicate removal lines) and updates the scalar' {
        $first  = ConvertTo-DuneIniManaged -Raw '' -Updates (Build-DuneLandclaimUpdates -Enabled $true -Seconds '1' -File 'game') -QuotedKeys @{}
        $second = ConvertTo-DuneIniManaged -Raw $first -Updates (Build-DuneLandclaimUpdates -Enabled $true -Seconds '7' -File 'game') -QuotedKeys @{}
        ([regex]::Matches($second, '-m_StakingUnitExtensionDefaultTimes=')).Count | Should -Be 10
        $st = Get-DuneLandclaimTimerState -Raw $second
        $st.seconds | Should -Be '7'
    }

    It 'disable removes all staking lines but preserves sibling Building keys' {
        $seed = @"
[/Script/DuneSandbox.BuildingSettings]
m_MaxNumLandclaimSegments=10
"@
        $on  = ConvertTo-DuneIniManaged -Raw $seed -Updates (Build-DuneLandclaimUpdates -Enabled $true -Seconds '2' -File 'game') -QuotedKeys @{}
        $off = ConvertTo-DuneIniManaged -Raw $on  -Updates (Build-DuneLandclaimUpdates -Enabled $false -Seconds '' -File 'game') -QuotedKeys @{}
        $off | Should -Not -Match 'StakingUnit'
        $off | Should -Match 'm_MaxNumLandclaimSegments=10'
        (Get-DuneLandclaimTimerState -Raw $off).enabled | Should -BeFalse
    }

    It 'state parser reports disabled on empty input' {
        $st = Get-DuneLandclaimTimerState -Raw ''
        $st.enabled | Should -BeFalse
        $st.seconds | Should -Be ''
    }

    It 'client block generator emits header + both scalars + full removal schedule (shareable snippet)' {
        $blk = Get-DuneLandclaimClientBlock -Seconds '3'
        $blk | Should -Match '\[/Script/DuneSandbox\.BuildingSettings\]'
        $blk | Should -Match 'm_StakingUnitExtensionDefaultTimes=3'
        $blk | Should -Match 'm_StakingUnitVerticalExtensionDefaultTimes=3'
        ([regex]::Matches($blk, '-m_StakingUnitExtensionDefaultTimes=')).Count | Should -Be 10
        ([regex]::Matches($blk, '-m_StakingUnitVerticalExtensionDefaultTimes=')).Count | Should -Be 10
        $blk | Should -Match "`r`n"   # CRLF for pasting into a Windows client Game.ini
    }

    It 'client block generator returns empty string when no seconds (disabled)' {
        Get-DuneLandclaimClientBlock -Seconds '' | Should -Be ''
    }
}
