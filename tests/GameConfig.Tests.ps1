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
    BeforeAll {
        function Invoke-DuneDeployInstalledUserSettings { param([string]$Ip) }
        function Restart-DuneMapPods { param([string]$Key) }
    }

    BeforeEach {
        Mock Invoke-DuneDeployInstalledUserSettings { throw 'PvP save must not deploy installed INIs implicitly' }
        Mock Restart-DuneMapPods { throw 'PvP save must not restart pods implicitly' }
    }

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

    It 'saves as pending without deploying INIs or restarting pods implicitly' {
        Mock Get-DuneGameConfigContext { @{ ok=$true; ip='192.0.2.10' } }
        Mock Get-DuneDeepDesertPvp {
            @{
                ok=$true
                inactiveSelectedPartitionIds=@()
                instances=@(@{ partitionId=8; pvpEnabled=$true })
            }
        }
        Mock Save-DuneGameConfigLocked {}

        $state = Set-DuneDeepDesertPvp -Enabled $true -PartitionIds @(8)

        $state.ok | Should -BeTrue
        $state.pendingApply | Should -BeTrue
        $state.message | Should -Match 'Apply INIs & restart'
        $state.message | Should -Match 'not active yet'
        Should -Invoke Save-DuneGameConfigLocked -Times 1 -Exactly
        Should -Invoke Invoke-DuneDeployInstalledUserSettings -Times 0 -Exactly
        Should -Invoke Restart-DuneMapPods -Times 0 -Exactly
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

    It 'processes configured and stale managed CVars without scanning blank catalog names' {
        Mock Get-V6Battlegroup {
            [pscustomobject]@{
                Name = 'bg'; Ns = 'dune'
                Bg = [pscustomobject]@{
                    spec = [pscustomobject]@{
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{ sets = @(
                                    [pscustomobject]@{
                                        map = 'Survival_1'
                                        partitions = @(1)
                                        podSpecs = @(
                                            [pscustomobject]@{
                                                index = 1
                                                arguments = @('-execcmds="Old.Advanced 1,Bgd.ServerDisplayName ''Hagga''"')
                                            }
                                        )
                                    }
                                ) }
                            }
                        }
                    }
                    status = [pscustomobject]@{ servers = @() }
                }
            }
        }
        $script:optimizedPatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:optimizedPatches = $Patches
            @{ Success = $true; Raw = ''; Error = $null }
        }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('New.Advanced') `
            -Values @{ 'New.Advanced' = '2' } `
            -ManagedNames @{ 'New.Advanced' = $true; 'Old.Advanced' = $true; 'Never.Configured' = $true }

        $result.Success | Should -BeTrue
        @($result.Values.Keys | Sort-Object) | Should -Be @('New.Advanced', 'Old.Advanced')
        $arguments = @($script:optimizedPatches[0].value[0].arguments)
        $arguments | Should -Contain '-execcmds="Bgd.ServerDisplayName ''Hagga'',New.Advanced 2"'
    }

    It 'prunes podSpecs for inactive non-dedicated partitions' {
        Mock Get-V6Battlegroup {
            [pscustomobject]@{
                Name = 'bg'; Ns = 'dune'
                Bg = [pscustomobject]@{
                    spec = [pscustomobject]@{ serverGroup = [pscustomobject]@{
                        template = [pscustomobject]@{ spec = [pscustomobject]@{ sets = @(
                            [pscustomobject]@{
                                map = 'Survival_1'
                                dedicatedScaling = $false
                                partitions = @(1)
                                podSpecs = @(
                                    [pscustomobject]@{ index = 0; arguments = @('-execcmds="dw.FuelBurningMultiplier 6"') }
                                    [pscustomobject]@{ index = 1; arguments = @('-execcmds="dw.FuelBurningMultiplier 6"') }
                                )
                            }
                        ) } }
                    } }
                    status = [pscustomobject]@{ servers = @(
                        [pscustomobject]@{ partitionMap = 'Survival_1'; partitionIndex = 1 }
                    ) }
                }
            }
        }
        $script:stalePodSpecPatches = $null
        Mock _Invoke-V6BgJsonPatch {
            param($Ip, $Info, $Patches)
            $script:stalePodSpecPatches = $Patches
            @{ Success = $true; Raw = ''; Error = $null }
        }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('dw.FuelBurningMultiplier') `
            -Values @{ 'dw.FuelBurningMultiplier' = '6' } `
            -ManagedNames @{ 'dw.FuelBurningMultiplier' = $true }

        $result.Success | Should -BeTrue
        @($script:stalePodSpecPatches[0].value).Count | Should -Be 1
        $script:stalePodSpecPatches[0].value[0].index | Should -Be 1
    }

    It 'preserves dormant podSpecs for dedicated maps' {
        Mock Get-V6Battlegroup {
            [pscustomobject]@{
                Name = 'bg'; Ns = 'dune'
                Bg = [pscustomobject]@{
                    spec = [pscustomobject]@{ serverGroup = [pscustomobject]@{
                        template = [pscustomobject]@{ spec = [pscustomobject]@{ sets = @(
                            [pscustomobject]@{
                                map = 'DeepDesert_1'
                                dedicatedScaling = $true
                                partitions = $null
                                podSpecs = @(
                                    [pscustomobject]@{ index = 8; arguments = @('-execcmds="dw.FuelBurningMultiplier 6"') }
                                )
                            }
                        ) } }
                    } }
                    status = [pscustomobject]@{ servers = @() }
                }
            }
        }
        Mock _Invoke-V6BgJsonPatch { throw 'Dormant dedicated podSpec must not be removed.' }

        $result = Set-V6ConsoleVariableOverrides -Ip '192.0.2.1' `
            -Names @('dw.FuelBurningMultiplier') `
            -Values @{ 'dw.FuelBurningMultiplier' = '6' } `
            -ManagedNames @{ 'dw.FuelBurningMultiplier' = $true }

        $result.Success | Should -BeTrue
        $result.NoChange | Should -BeTrue
        Should -Invoke _Invoke-V6BgJsonPatch -Times 0
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
            'dw.VehicleDurabilityDamageMultiplier'
            'dw.VehicleHeatMultiplier'
            'dw.VehicleHeatInterpolationSpeed'
            'dw.VehiclePowerConsumptionMultiplier'
            'dw.VehicleCanOverHeat'
            'dw.VehicleAbandonedDecayAllowed'
            'dw.VehicleAbandonedDecayTimeMultiplier'
            'Vehicle.DisassemblySpeedMultiplier'
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
            'NPC.EnableFacingTargetCheck'
            'NPC.FacingTargetAngleStartThreshold'
            'NPC.FacingTargetAngleStopThreshold'
            'NPC.EnableWeaponRotationRateOverride'
            'NPC.DummyWeaponRotationRateOverride'
            'NPC.Respawn.StartCountdownOnEachNPCKilled'
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

        $experimental.Count | Should -Be 54
        $experimental2.Count | Should -Be 65
        @($experimental.Key | Sort-Object) | Should -Be @($script:ExperimentalKeys | Sort-Object)
        @($experimental2.Key | Sort-Object) | Should -Be @($script:Experimental2Keys | Sort-Object)
        foreach ($key in @($script:ExperimentalKeys) + @($script:Experimental2Keys)) {
            $fields.ContainsKey($key) | Should -BeTrue
            $fields[$key].Section | Should -Be $script:DuneGcSecConsole
            $fields[$key].File | Should -Be 'engine'
            $fields[$key].Category | Should -BeLike 'Experimental*'
            @($script:DuneStartupConsoleVariableKeys) | Should -Contain $key
        }
        @($script:DuneGameConfigSchema | Where-Object Category -eq 'Experimental Lab').Count | Should -Be 0
        (Test-DuneStartupConsoleVariableKey -Key 'm_TaskGoalAmount') | Should -BeFalse
        $script:DuneAdvancedCvarCatalogCache | Should -BeNullOrEmpty
        @($script:DuneStartupConsoleVariableKeys).Count | Should -Be 142

        $lab = @(Get-DuneAdvancedCvarCatalog)
        $lab.Count | Should -BeGreaterThan 4900
        $lab.key | Should -Not -Contain 'dw.BaseBackupMaxNumberOfBackups'
        ($lab | Where-Object key -eq 'ak.soundengine.executeActionOnEvent').group |
            Should -Be 'Audio - engine/internal'
        ($lab | Where-Object key -eq 'au.adpcm.DisableSeeking').group |
            Should -Be 'Audio - engine/internal'
        ($lab | Where-Object key -eq 'Ai.Dune.EnableBudgetingSystem').group |
            Should -Be 'AI - engine/internal'
        foreach ($key in @(
            'Bgd.BgdRetryCount',
            'Bgd.CVarTravelBgdRetrySecondsGap',
            'Bgd.CVarTravelBgdServerStatsTicker'
        )) {
            $field = @($lab | Where-Object key -eq $key)
            $field.Count | Should -Be 1
            $field[0].group | Should -Be 'Server & Session'
            $field[0].source | Should -Be 'Dune'
            $field[0].scope | Should -Be 'Server'
        }
        foreach ($key in @(
            'Travel.BgdRetryCount',
            'Travel.CVarTravelBgdRetrySecondsGap',
            'Travel.CVarTravelBgdServerStatsTicker'
        )) {
            @($lab | Where-Object key -eq $key).Count | Should -Be 0
            (Test-DuneStartupConsoleVariableKey -Key $key) | Should -BeFalse
            (Get-DuneManagedStartupConsoleVariableKeyMap).ContainsKey($key) | Should -BeTrue
        }
    }

    It 'groups every experimental control for the Experimental page' {
        # The Experimental page renders one card per group, so every control must
        # land somewhere. Anything the rules cannot place is reported as
        # Uncategorized rather than being forced into a neighbouring group.
        $api = @(Get-DuneGameConfigSchemaApi)
        $fields = @($api | Where-Object { $_.category -like 'Experimental*' } | ForEach-Object { $_.fields })
        $fields.Count | Should -Be 119
        foreach ($f in $fields) {
            $f.group | Should -Not -BeNullOrEmpty
            $f.status | Should -BeIn @('Confirmed', 'Unconfirmed')
            $f.source | Should -BeIn @('Dune', 'Engine')
            $f.risk | Should -BeIn @('experimental', 'diagnostic', 'high', 'critical')
        }
        $categories = @(Get-DuneAdvancedCvarCategoriesApi)
        ($categories | Measure-Object count -Sum).Sum | Should -BeGreaterThan 4900
        @(Get-DuneAdvancedCvarCategoryApi -Category 'Dune gameplay').Count | Should -BeGreaterThan 500
        $fullCatalog = @(Get-DuneAdvancedCvarCatalog)
        @(Get-DuneAdvancedCvarCategoryApi -Category 'All').Count | Should -Be $fullCatalog.Count
        $searchResults = @(Search-DuneAdvancedCvarCatalogApi -Query 'EXECUTEACTIONONEVENT')
        @($searchResults.key) | Should -Contain 'ak.soundengine.executeActionOnEvent'
        @($searchResults.group | Select-Object -Unique).Count | Should -BeGreaterThan 0
        @(Search-DuneAdvancedCvarCatalogApi -Query '  ').Count | Should -Be 0
        $singleResult = [object[]]@(Search-DuneAdvancedCvarCatalogApi -Query 'fuel')
        $singleResult.Count | Should -Be 1
        (@{ fields = $singleResult } | ConvertTo-Json -Compress) | Should -Match '"fields":\['
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
            '$lab = @(Get-DuneAdvancedCvarCatalog); ' +
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
            'Vehicle.RecoveryChassisDurabilityReductionFraction'
            'Vehicle.RecoveryCurrencyBaseCost'
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
        $catalog = @(Get-DuneAdvancedCvarCatalog)
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
            $field = @($catalog | Where-Object key -eq $key)
            $field.Count | Should -Be 1
            $field[0].risk | Should -Be 'critical'
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

    It 'scrubs retired returning-player controls from INI and startup injection' {
        $retired = @(
            'dw.ReturningPlayer.GiveAward.Enabled'
            'dw.ReturningPlayer.DaysBeforeEligibleForReward'
            'dw.ReturningPlayer.GiveAward.TierOverride'
        )
        foreach ($key in $retired) {
            @($script:DuneGameConfigSchema.Key) | Should -Not -Contain $key
            @($script:DuneGameConfigDeprecatedManagedKeys) | Should -Contain $key
            @($script:DuneStartupConsoleVariableKeys) | Should -Not -Contain $key
            (Get-DuneManagedStartupConsoleVariableKeyMap).ContainsKey($key) | Should -BeTrue
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
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @() -QuotedKeys @{}

        $out | Should -Not -Match 'dw\.ReturningPlayer'
        $out | Should -Match 'dw\.FuelBurningMultiplier=6'
    }

    It 'scrubs NPC door CVars removed from the Retail server binary' {
        $retired = @(
            'NPC.AllowDoorAutoAccessToAllNPCs'
            'NPC.AllowDoorAutoAccessToAllNPCsRadius'
            'NPC.DoorAutoAccessRadius'
        )
        foreach ($key in $retired) {
            @($script:DuneGameConfigSchema.Key) | Should -Not -Contain $key
            @($script:DuneGameConfigDeprecatedManagedKeys) | Should -Contain $key
            @($script:DuneStartupConsoleVariableKeys) | Should -Not -Contain $key
            (Get-DuneManagedStartupConsoleVariableKeyMap).ContainsKey($key) | Should -BeTrue
        }

        $raw = @"
; ===== Dune Server Tool (DST) managed section BEGIN =====
[ConsoleVariables]
NPC.AllowDoorAutoAccessToAllNPCs=1
NPC.AllowDoorAutoAccessToAllNPCsRadius=100000
NPC.DoorAutoAccessRadius=25000
dw.FuelBurningMultiplier=6
; ===== Dune Server Tool (DST) managed section END =====
"@
        $out = ConvertTo-DuneIniManaged -Raw $raw -Updates @() -QuotedKeys @{}

        $out | Should -Not -Match 'NPC\.AllowDoorAutoAccessToAllNPCs='
        $out | Should -Not -Match 'NPC\.AllowDoorAutoAccessToAllNPCsRadius'
        $out | Should -Not -Match 'NPC\.DoorAutoAccessRadius'
        $out | Should -Match 'dw\.FuelBurningMultiplier=6'
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

    It 'rebuilds restart injection from configured managed CVars only' {
        Mock Get-DuneGameConfig {
            @{
                engine = @{
                    effectiveByKey = @{
                        'ak.soundengine.executeActionOnEvent' = '1'
                        'Bgd.BgdRetryCount' = '4'
                        'dw.FuelBurningMultiplier' = '6'
                        'Travel.BgdRetryCount' = '9'
                        'User.HandEditedSetting' = '9'
                    }
                }
            }
        }
        $script:optimizedSyncValues = $null
        Mock Set-DuneStartupConsoleVariableOverrides {
            param($Ip, $Values)
            $script:optimizedSyncValues = $Values
            @{ Success = $true }
        }

        Sync-DuneStartupConsoleVariableOverrides -Ip '192.0.2.1' | Out-Null

        @($script:optimizedSyncValues.Keys | Sort-Object) |
            Should -Be @('ak.soundengine.executeActionOnEvent', 'Bgd.BgdRetryCount', 'dw.FuelBurningMultiplier')
        $script:optimizedSyncValues.ContainsKey('Travel.BgdRetryCount') | Should -BeFalse
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

    It 'places the curated Experimental catalogs last in the schema API, in order' {
        $cats = @((Get-DuneGameConfigSchemaApi) | ForEach-Object { $_.category })
        $cats[-2] | Should -Be 'Experimental'
        $cats[-1] | Should -Be 'Experimental 2'
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

    Describe 'DuneGameConfigSchema: Coriolis cycle start hour' -Tag 'GameConfig' {
        It 'exposes the GMT start hour through the normal bounded game-setting path' {
            $fields = @{}
            foreach ($f in $script:DuneGameConfigSchema) { $fields[$f.Key] = $f }

            $fields.ContainsKey('m_CycleStartHour') | Should -BeTrue
            $f = $fields['m_CycleStartHour']
            $f.Section  | Should -Be '/Script/DuneSandbox.CoriolisSubsystem'
            $f.File     | Should -Be 'game'
            $f.Type     | Should -Be 'int'
            $f.Min      | Should -Be 0
            $f.Max      | Should -Be 23
            $f.Default  | Should -Be '5'
            $f.Category | Should -Be 'Storm Cycle'
        }

        It 'documents GMT storage, local display, daylight saving, and restart behavior' {
            $field = @($script:DuneGameConfigSchema | Where-Object Key -eq 'm_CycleStartHour')
            $field.Count | Should -Be 1
            $help = [string]$field[0].Help

            $help | Should -Match 'GMT/UTC'
            $help | Should -Match 'browser-local'
            $help | Should -Match 'daylight saving'
            $help | Should -Match 'Apply INIs & restart'
        }
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

Describe 'DuneGameConfigSchema: experimental twilight evidence gate' -Tag 'GameConfig' {
    BeforeAll {
        function Invoke-V6Ssh { throw 'Unexpected unmocked twilight SSH call.' }
    }

    BeforeEach {
        $script:TwilightLivePaths = @{
            source = 'installed'
            game = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
            engine = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
        }
        Mock Resolve-DuneGameConfigPaths { $script:TwilightLivePaths }
    }

    It 'exposes the verified Time of Day surface without making the raw phase writable' {
        $timeFields = @($script:DuneGameConfigSchema | Where-Object {
            $_.Section -eq '/Script/DuneSandbox.TimeOfDaySettings'
        })
        $start = @($timeFields | Where-Object Key -eq 'm_StartTime')
        $cycle = @($timeFields | Where-Object Key -eq 'm_bTimeOfDayEnabled')

        $start.Count | Should -Be 0
        $cycle.Count | Should -Be 1
        $cycle[0].Category | Should -Be 'Time of Day'
        $cycle[0].Help | Should -Match '(?i)field-verified phase controls'
        $cycle[0].Help | Should -Match '(?i)simulation-safety testing is still in progress'
    }

    It 'keeps the schema free of invented phase and visual-lock writes' {
        $keys = @($script:DuneGameConfigSchema | ForEach-Object Key)
        $keys | Should -Not -Contain 'm_StartTime'
        ($keys -join "`n") | Should -Not -Match '(?i)twilight|sunangle|settimeofday'
    }

    It 'blocks the evidence-only startup-hour target from the raw update API' {
        (Test-DuneGameConfigRawTargetBlocked `
            -File game `
            -Section '/Script/DuneSandbox.TimeOfDaySettings' `
            -Key m_StartTime) | Should -BeTrue
        (Test-DuneGameConfigRawTargetBlocked `
            -File ' game ' `
            -Section ' /Script/DuneSandbox.TimeOfDaySettings ' `
            -Key 'm_StartTime ') | Should -BeTrue
        (Test-DuneGameConfigRawTargetBlocked `
            -File game `
            -Section '/Script/DuneSandbox.TimeOfDaySettings' `
            -Key '+m_StartTime') | Should -BeTrue
        (Test-DuneGameConfigRawTargetBlocked `
            -File game `
            -Section '/Script/DuneSandbox.TimeOfDaySettings' `
            -Key m_bTimeOfDayEnabled) | Should -BeFalse

        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        $route | Should -Match 'Test-DuneGameConfigRawTargetBlocked'
        $route | Should -Match 'evidence-only and cannot be written by DST'
    }

    It 'rejects raw array lines that do not match their submitted key' {
        (Test-DuneGameConfigArrayLineMatchesKey `
            -Line '+AllowedMap=DeepDesert_1' `
            -Key AllowedMap) | Should -BeTrue
        (Test-DuneGameConfigArrayLineMatchesKey `
            -Line '-AllowedMap=DeepDesert_1' `
            -Key AllowedMap) | Should -BeTrue
        (Test-DuneGameConfigArrayLineMatchesKey `
            -Line 'm_StartTime=18' `
            -Key AllowedMap) | Should -BeFalse
        (Test-DuneGameConfigArrayLineMatchesKey `
            -Line '+m_StartTime=18' `
            -Key AllowedMap) | Should -BeFalse
        (Test-DuneGameConfigArrayLineMatchesKey `
            -Line "+AllowedMap=x`nm_StartTime=18" `
            -Key AllowedMap) | Should -BeFalse
        (Test-DuneGameConfigRawTextSafe -Value "m_StartTime`n") | Should -BeFalse
        (Test-DuneGameConfigRawTextSafe -Value "18`r`nInjected=True") | Should -BeFalse

        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        $route | Should -Match 'Test-DuneGameConfigArrayLineMatchesKey'
        $route | Should -Match 'Every arrayLines entry must be a'
        $route | Should -Match 'Raw scalar INI values must be one physical line'
        $route | Should -Match 'must not include Unreal \+ or - operator prefixes'
    }

    It 'offers only finite bounded candidate values' {
        $experiment = Get-DuneTwilightLockExperiment
        @($experiment.candidates.value) | Should -Be @('18.0', '19.0', '20.0', '21.0', '4.0')
        @($experiment.candidates.label) | Should -Be @(
            'Sunset - 18:00',
            'Twilight - 19:00',
            'Dark night - 20:00',
            'Full night - 21:00',
            'Dew harvest - 04:00'
        )
        $experiment.evidenceStatus | Should -Be 'visual-phases-verified'
        $experiment.clientApply.available | Should -BeFalse
        $experiment.restartRequired | Should -BeTrue
        $experiment.minimumObservationMinutes | Should -Be 30
        foreach ($valid in @('18.0', '19.0', '20.0', '21.0', '4.0')) {
            (Test-DuneTwilightCandidateHour -Value $valid) | Should -BeTrue
        }
        foreach ($invalid in @('', '17.0', '20', '22.0', 'NaN', 'Infinity', "18`nInjected=True")) {
            (Test-DuneTwilightCandidateHour -Value $invalid) | Should -BeFalse
        }
    }

    It 'writes an active candidate when the source contains only a commented value' {
        $raw = @'
[/Script/DuneSandbox.TimeOfDaySettings]
;m_StartTime=18.0
'@
        $updates = @(
            @{ file='game'; section=$script:DuneGcSecTimeOfDay; key='m_StartTime'; value='18.0'; remove=$false },
            @{ file='game'; section=$script:DuneGcSecTimeOfDay; key='m_bTimeOfDayEnabled'; value='False'; remove=$false }
        )

        $written = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates -QuotedKeys @{}
        @($written -split "`n" | Where-Object { $_ -eq 'm_StartTime=18.0' }).Count | Should -Be 1
        { Assert-DuneTwilightStageReadback -Raw @'
[/Script/DuneSandbox.TimeOfDaySettings]
;m_StartTime=18.0
m_bTimeOfDayEnabled=False
'@ -Candidate '18.0' } | Should -Throw '*write verification failed*'
    }

    It 'backs up before staging the exact server-only candidate pair' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$true; backup='/fixture/UserGame.ini.dstbak' }) }
        }
        Mock Save-DuneGameConfigLocked {}
        Mock Invoke-V6Ssh {
            @(
                '[/Script/DuneSandbox.TimeOfDaySettings]',
                'm_StartTime=18.0',
                'm_bTimeOfDayEnabled=False'
            )
        }

        $result = Invoke-DuneTwilightLockStage -Ip '192.0.2.1' -Candidate '18.0'

        $result.ok | Should -BeTrue
        $result.candidate | Should -Be '18.0'
        $result.clientApplied | Should -BeFalse
        Assert-MockCalled Backup-DuneGameConfig -Times 1 -ParameterFilter {
            $ResolvedPaths.source -eq 'installed' -and
            $ResolvedPaths.game -eq $script:TwilightLivePaths.game
        }
        Assert-MockCalled Save-DuneGameConfigLocked -Times 1 -ParameterFilter {
            $ResolvedPaths.game -eq $script:TwilightLivePaths.game -and
            @($Updates).Count -eq 2 -and
            @($Updates | Where-Object { $_.key -eq 'm_StartTime' -and $_.value -eq '18.0' -and -not $_.remove }).Count -eq 1 -and
            @($Updates | Where-Object { $_.key -eq 'm_bTimeOfDayEnabled' -and $_.value -eq 'False' -and -not $_.remove }).Count -eq 1
        }
        Assert-MockCalled Invoke-V6Ssh -Times 1
    }

    It 'refuses a generated live PVC copy before backup or mutation' {
        Mock Resolve-DuneGameConfigPaths {
            @{
                source = 'legacy-live'
                game = '/var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings/UserGame.ini'
                engine = '/var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings/UserEngine.ini'
            }
        }
        Mock Backup-DuneGameConfig {}
        Mock Save-DuneGameConfigLocked {}

        { Invoke-DuneTwilightLockStage -Ip '192.0.2.1' -Candidate '18.0' } |
            Should -Throw '*requires the installed authoritative UserGame.ini*'
        { Invoke-DuneTwilightLockRestore -Ip '192.0.2.1' } |
            Should -Throw '*requires the installed authoritative UserGame.ini*'
        Assert-MockCalled Backup-DuneGameConfig -Times 0
        Assert-MockCalled Save-DuneGameConfigLocked -Times 0
    }

    It 'fails closed when the pre-stage backup cannot be verified' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$false; backup=$null }) }
        }
        Mock Save-DuneGameConfigLocked {}

        { Invoke-DuneTwilightLockStage -Ip '192.0.2.1' -Candidate '18.0' } |
            Should -Throw '*backup could not be verified*'
        Assert-MockCalled Save-DuneGameConfigLocked -Times 0
    }

    It 'fails stage when the exact live readback does not match the requested values' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$true; backup='/fixture/UserGame.ini.dstbak' }) }
        }
        Mock Save-DuneGameConfigLocked {}
        Mock Invoke-V6Ssh {
            @(
                '[/Script/DuneSandbox.TimeOfDaySettings]',
                'm_StartTime=17.0',
                'm_bTimeOfDayEnabled=True'
            )
        }

        { Invoke-DuneTwilightLockStage -Ip '192.0.2.1' -Candidate '18.0' } |
            Should -Throw '*write verification failed*'
    }

    It 'fails stage when SSH exposes a write/readback failure as output' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$true; backup='/fixture/UserGame.ini.dstbak' }) }
        }
        Mock Save-DuneGameConfigLocked {}
        Mock Invoke-V6Ssh { 'ERROR: remote write failed' }

        { Invoke-DuneTwilightLockStage -Ip '192.0.2.1' -Candidate '18.0' } |
            Should -Throw '*could not verify the authoritative UserGame.ini*'
    }

    It 'backs up then removes both managed overrides on restore' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$true; backup='/fixture/UserGame.ini.dstbak' }) }
        }
        Mock Save-DuneGameConfigLocked {}
        Mock Invoke-V6Ssh {
            @(
                '[/Script/DuneSandbox.DuneGameMode]',
                'm_WaterConsumptionRate=1.0'
            )
        }

        $result = Invoke-DuneTwilightLockRestore -Ip '192.0.2.1'

        $result.restored | Should -BeTrue
        $result.clientApplied | Should -BeFalse
        Assert-MockCalled Backup-DuneGameConfig -Times 1 -ParameterFilter {
            $ResolvedPaths.game -eq $script:TwilightLivePaths.game
        }
        Assert-MockCalled Save-DuneGameConfigLocked -Times 1 -ParameterFilter {
            $ResolvedPaths.game -eq $script:TwilightLivePaths.game -and
            @($Updates).Count -eq 2 -and
            @($Updates | Where-Object { $_.key -eq 'm_StartTime' -and $_.remove }).Count -eq 1 -and
            @($Updates | Where-Object { $_.key -eq 'm_bTimeOfDayEnabled' -and $_.remove }).Count -eq 1
        }
    }

    It 'fails restore while either exact live override remains' {
        Mock Backup-DuneGameConfig {
            @{ files = @(@{ file='game'; ok=$true; backup='/fixture/UserGame.ini.dstbak' }) }
        }
        Mock Save-DuneGameConfigLocked {}
        Mock Invoke-V6Ssh {
            @(
                '[/Script/DuneSandbox.TimeOfDaySettings]',
                'm_bTimeOfDayEnabled=False'
            )
        }

        { Invoke-DuneTwilightLockRestore -Ip '192.0.2.1' } |
            Should -Throw '*restore verification failed*'
    }

    It 'registers dedicated guarded stage and restore routes' {
        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        foreach ($path in @(
            '/api/gameconfig/time-of-day',
            '/api/gameconfig/time-of-day/stage',
            '/api/gameconfig/time-of-day/restore'
        )) {
            $route | Should -Match ([regex]::Escape($path))
        }
        $route | Should -Match 'Invoke-DuneTwilightLockStage'
        $route | Should -Match 'Invoke-DuneTwilightLockRestore'
        $route | Should -Match 'Test-DunePlayerGuard'
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

    It 'offers Deep Desert Base Backup Tool availability for explicit client Game.ini apply' {
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{
                file = 'game'
                section = $script:DuneGcSecBuilding
                key = 'm_BaseBackupToolMapRestriction'
                value = '((Name="HaggaBasin"), (Name="DeepDesert"))'
            }
        )

        @($notice.items).Count | Should -Be 1
        @($notice.items)[0].key | Should -Be 'm_BaseBackupToolMapRestriction'
        @($notice.items)[0].file | Should -Be 'game'
        $notice.paths.game | Should -Match 'Game\.ini$'
    }

    It 'offers Maximum Vehicles Per Player and Shield Drops While Shooting as proven client-read settings' {
        # Console variables reach the server through the startup command, not any
        # INI, so a client copy is only meaningful for the ones the client
        # evaluates itself. Flagging the rest is not harmless: it tells players to
        # edit a file for no effect, and it mirrors the whole managed set onto the
        # admin's own machine, which confounds every result he field-tests.
        $gameplayEngine = @($script:DuneGameConfigSchema |
            Where-Object { $_.File -eq 'engine' -and $_.Section -eq $script:DuneGcSecConsole })

        $flagged = @($gameplayEngine | Where-Object { $_.ClientApply } | ForEach-Object { $_.Key })
        @($flagged | Sort-Object) | Should -Be @($script:DuneClientEvaluatedConsoleVariables | Sort-Object)

        # Both controls have client-side field evidence: the displayed vehicle
        # cap and shield behavior follow each Retail player's local values.
        $flagged | Should -Contain 'Vehicle.MaxVehiclesPerPlayer'
        $flagged | Should -Contain 'Dune.DisableShieldOnShooting'

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
        Test-DuneGameConfigValueIsDefault -Key 'Dune.DisableShieldOnShooting' -Value '1' | Should -BeTrue
        Test-DuneGameConfigValueIsDefault -Key 'Dune.DisableShieldOnShooting' -Value '0' | Should -BeFalse
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

    It 'defaults Retail client config to the active Windows folder' {
        Mock Read-DuneConfig { [ordered]@{ ClientConfigPath = ''; ClientEngineIniEnabled = '' } }
        Get-DuneGameConfigClientDir | Should -Be '%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows'
        $script:DuneGameConfigClientPath | Should -Be '%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows\Game.ini'
        $script:DuneGameConfigClientEnginePath | Should -Be '%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows\Engine.ini'
    }

    It 'migrates the former default WindowsClient folder to Retail Windows' {
        Mock Read-DuneConfig { [ordered]@{ ClientConfigPath = '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient'; ClientEngineIniEnabled = '' } }
        Get-DuneGameConfigClientDir | Should -Be '%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows'
        Resolve-DuneGameConfigClientDir -Dir '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient' |
            Should -Be ([Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows'))
    }

    It 'offers only field-proven non-default WindowsClient settings and flags conflicts' {
        Mock Read-DuneConfig { [ordered]@{ ClientConfigPath = ''; ClientEngineIniEnabled = 'true' } }
        Mock Resolve-DuneGameConfigClientDir {
            [Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%\DuneSandbox\Saved\Config\Windows')
        }
        Mock Get-DuneGameConfigLegacyClientFile {
            param($File)
            if ($File -eq 'engine') {
                return @{
                    exists = $true
                    effective = @{
                        "$script:DuneGcSecConsole||Vehicle.MaxVehiclesPerPlayer" = '20'
                        "$script:DuneGcSecConsole||Dune.DisableShieldOnShooting" = '0'
                    }
                    effectiveByKey = @{}
                }
            }
            return @{
                exists = $true
                effective = @{
                    "$script:DuneGcSecInventory||PlayerInventoryStartingSize" = '70'
                    "$script:DuneGcSecInventory||PlayerInventoryStartingVolumeCapacity" = '250'
                    "$script:DuneGcSecSandworm||m_bGiantWormSystemEnabled" = 'False'
                }
                effectiveByKey = @{}
            }
        }
        Mock Get-DuneGameConfigClientFile {
            param($Dir, $File)
            if ($File -eq 'engine') {
                return @{
                    effective = @{
                        "$script:DuneGcSecConsole||Vehicle.MaxVehiclesPerPlayer" = '20'
                        "$script:DuneGcSecConsole||Dune.DisableShieldOnShooting" = '1'
                    }
                    effectiveByKey = @{}
                }
            }
            return @{
                effective = @{
                    "$script:DuneGcSecInventory||PlayerInventoryStartingVolumeCapacity" = '175'
                }
                effectiveByKey = @{}
            }
        }

        $migration = Get-DuneGameConfigLegacyMigration

        $migration.available | Should -BeTrue
        @($migration.candidates).Count | Should -Be 4
        ($migration.candidates | Where-Object key -eq 'PlayerInventoryStartingSize').state | Should -Be 'missing'
        ($migration.candidates | Where-Object key -eq 'PlayerInventoryStartingSize').selected | Should -BeTrue
        ($migration.candidates | Where-Object key -eq 'PlayerInventoryStartingVolumeCapacity').state | Should -Be 'conflict'
        ($migration.candidates | Where-Object key -eq 'PlayerInventoryStartingVolumeCapacity').selected | Should -BeFalse
        ($migration.candidates | Where-Object key -eq 'Vehicle.MaxVehiclesPerPlayer').state | Should -Be 'current'
        @($migration.excludedRecognized | Where-Object key -eq 'm_bGiantWormSystemEnabled').Count | Should -Be 1
    }

    It 'does not report numeric formatting differences as migration conflicts' {
        Test-DuneGameConfigValuesEqual -Left '300.000000' -Right '300.0' | Should -BeTrue
        Test-DuneGameConfigValuesEqual -Left 'False' -Right 'false' | Should -BeTrue
    }

    It 'does not offer the default WindowsClient migration for a custom destination' {
        Mock Resolve-DuneGameConfigClientDir { 'D:\CustomClientConfig' }
        Mock Get-DuneGameConfigLegacyClientFile { throw 'must not read the legacy default for a custom destination' }

        $migration = Get-DuneGameConfigLegacyMigration -CurrentDir 'D:\CustomClientConfig'

        $migration.available | Should -BeFalse
        $migration.reason | Should -Be 'custom-client-directory'
        Assert-MockCalled Get-DuneGameConfigLegacyClientFile -Times 0
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
        $result.backups.game | Should -Not -BeNullOrEmpty
        $result.backups.engine | Should -Not -BeNullOrEmpty
        [IO.File]::ReadAllText($result.backups.game) | Should -Match 'MasterVolume=0.8'
        [IO.File]::ReadAllText($result.backups.engine) | Should -Match 'r\.ScreenPercentage=100'
        @(Get-ChildItem -LiteralPath $dir -Filter '*.dst-tmp-*').Count | Should -Be 0
        @($result.items | ForEach-Object file | Sort-Object -Unique) | Should -Be @('engine','game')
    }

    It 'writes customized inventory slots, volume, and weight to Retail client Game.ini' {
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'inventory-client'
        [void](New-Item -ItemType Directory -Path $dir)

        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='PlayerInventoryStartingSize'; value='70' },
            @{ key='PlayerInventoryStartingVolumeCapacity'; value='2500' },
            @{ key='m_InventoryWeightMultiplier'; value='0.5' }
        )

        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Game.ini'))
        $raw | Should -Match '(?m)^PlayerInventoryStartingSize=70\r?$'
        $raw | Should -Match '(?m)^PlayerInventoryStartingVolumeCapacity=2500\r?$'
        $raw | Should -Match '(?m)^m_InventoryWeightMultiplier=0\.5\r?$'
        $result.files.game.path | Should -Be (Join-Path $dir 'Game.ini')
        @($result.items).Count | Should -Be 3
    }

    It 'writes the disabled shield setting to the Retail client Engine.ini' {
        $dir = (Get-PSDrive TestDrive).Root

        $result = Save-DuneGameConfigClient -Dir $dir -Updates @(
            @{ key='Dune.DisableShieldOnShooting'; value='0' }
        )

        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Engine.ini'))
        $raw | Should -Match '(?m)^\[ConsoleVariables\]\r?$'
        $raw | Should -Match '(?m)^Dune\.DisableShieldOnShooting=0\r?$'
        $result.files.engine.path | Should -Be (Join-Path $dir 'Engine.ini')
        @($result.items).Count | Should -Be 1
    }

    It 'writes the complete spice startup struct through the normal client Game.ini path' {
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'spice-client'
        [void](New-Item -ItemType Directory -Path $dir)
        $defaultsRaw = "[$script:DuneGcSecSpice]`n" +
            'm_PerMapSystemSettings=(("Editor_Default", (m_SpiceFieldTypeSettings=(((Name="Large"), (MaxGloballyPrimed=3,MaxGloballyActive=3))))),("DeepDesert_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=60,MaxGloballyActive=60)),((Name="Medium"), (MaxGloballyPrimed=12,MaxGloballyActive=12)),((Name="Large"), (MaxGloballyPrimed=1,MaxGloballyActive=1))))),("Survival_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=5,MaxGloballyActive=5))))))' + "`n" +
            'm_DefaultSystemSettings=(m_SpiceFieldTypeSettings=(((Name="Large"), (MaxGloballyPrimed=5,MaxGloballyActive=3))))' + "`n"

        Save-DuneGameConfigClient -Dir $dir -DefaultsRaw $defaultsRaw -Updates @(
            @{ key='DST.SpiceStartup.DeepDesert.Large.Max'; value='6' }
        ) | Out-Null

        $raw = [IO.File]::ReadAllText((Join-Path $dir 'Game.ini'))
        $blob = Get-DuneIniSectionScalarValue -Raw $raw -Section $script:DuneGcSecSpice -Key 'm_PerMapSystemSettings'
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $blob -MapId 'DeepDesert_1' -FieldType 'Large'
        $state.maxActive | Should -Be 6
        $state.maxPrimed | Should -Be 6
        (Get-DuneSpicefieldLimitsFromBlob -Blob $blob -MapId 'Survival_1' -FieldType 'Small').maxActive | Should -Be 5
        $raw | Should -Match 'm_DefaultSystemSettings='
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

    It 'refuses active Retail client-file writes while the game is running before touching either file' {
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

    It 'refuses a Game.ini-only write while the Retail client is running' {
        Mock Test-DuneGameClientRunning { $true }
        $dir = Join-Path (Get-PSDrive TestDrive).Root 'running-game-only'
        [void](New-Item -ItemType Directory -Path $dir)

        {
            Save-DuneGameConfigClient -Dir $dir -Updates @(
                @{ key='m_RepairCostWeight'; value='0.25' }
            )
        } | Should -Throw '*Close Dune: Awakening*'

        Test-Path (Join-Path $dir 'Game.ini') | Should -BeFalse
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

Describe 'GameConfig: spicefield startup defaults' -Tag 'GameConfig' {
    BeforeAll {
        function Invoke-V6Ssh { param([string]$Ip, [string]$Cmd) }
        function Get-V6RetailSpicefieldActivity { param([string]$Ip) }
        function Get-DuneActiveMapPartitions { param([string]$Ip) }
        $script:SpiceSection = '/Script/DuneSandbox.SpiceHarvestingSystem'
        $script:SpiceOverride = 'm_PerMapSystemSettings=(("Editor_Default", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=3,MaxGloballyActive=5)),((Name="Medium"), (MaxGloballyPrimed=2,MaxGloballyActive=22)),((Name="Large"), (MaxGloballyPrimed=2,MaxGloballyActive=6))))),("DeepDesert_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=10,MaxGloballyActive=60)),((Name="Medium"), (MaxGloballyPrimed=12,MaxGloballyActive=12)),((Name="Large"), (MaxGloballyPrimed=2,MaxGloballyActive=6))))),("Survival_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=3,MaxGloballyActive=10))))))'
        $script:SpiceFallback = 'm_DefaultSystemSettings=(m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=3,MaxGloballyActive=20)),((Name="Medium"), (MaxGloballyPrimed=2,MaxGloballyActive=10)),((Name="Large"), (MaxGloballyPrimed=2,MaxGloballyActive=6))))'
        $script:SpiceUserRaw = "[$script:SpiceSection]`n$script:SpiceOverride`n$script:SpiceFallback`n"
        $script:SpiceDefaultsRaw = "[$script:SpiceSection]`n" +
            'm_PerMapSystemSettings=(("DeepDesert_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=60,MaxGloballyActive=60)),((Name="Medium"), (MaxGloballyPrimed=12,MaxGloballyActive=12)),((Name="Large"), (MaxGloballyPrimed=1,MaxGloballyActive=1))))),("Survival_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=5,MaxGloballyActive=5))))))' + "`n" +
            'm_DefaultSystemSettings=(m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=6,MaxGloballyActive=3)),((Name="Medium"), (MaxGloballyPrimed=10,MaxGloballyActive=5)),((Name="Large"), (MaxGloballyPrimed=5,MaxGloballyActive=3))))' + "`n"
    }

    It 'exposes Deep Desert sizes and Hagga Small in the normal Spice card' {
        $fields = @($script:DuneGameConfigSchema | Where-Object { $_.ContainsKey('SpiceMap') })

        $fields.Count | Should -Be 4
        $fields.Key | Should -Contain 'DST.SpiceStartup.DeepDesert.Small.Max'
        $fields.Key | Should -Contain 'DST.SpiceStartup.DeepDesert.Medium.Max'
        $fields.Key | Should -Contain 'DST.SpiceStartup.DeepDesert.Large.Max'
        $fields.Key | Should -Contain 'DST.SpiceStartup.Hagga.Small.Max'
        $fields.Key | Should -Not -Contain 'DST.SpiceStartup.Hagga.Medium.Max'
        $fields.Key | Should -Not -Contain 'DST.SpiceStartup.Hagga.Large.Max'
        @($fields | Where-Object { -not $_.ClientApply }).Count | Should -Be 0
        @($fields | Where-Object { $_.Category -ne 'Spice' }).Count | Should -Be 0
        @($fields | Where-Object { $_.SpiceLimit -ne 'Both' }).Count | Should -Be 0
        @($fields | Where-Object { $_.ClientStructKey -ne 'm_PerMapSystemSettings' }).Count | Should -Be 0
        ($fields | Where-Object Key -eq 'DST.SpiceStartup.DeepDesert.Large.Max').Help |
            Should -Match 'ceiling.*max of 6.*only 4'
        ($fields | Where-Object Key -eq 'DST.SpiceStartup.DeepDesert.Small.Max').Default | Should -Be '60'
        ($fields | Where-Object Key -eq 'DST.SpiceStartup.DeepDesert.Medium.Max').Default | Should -Be '12'
        ($fields | Where-Object Key -eq 'DST.SpiceStartup.DeepDesert.Large.Max').Default | Should -Be '1'
        ($fields | Where-Object Key -eq 'DST.SpiceStartup.Hagga.Small.Max').Default | Should -Be '5'
    }

    It 'defines the complete Retail compatibility surface without removing a field size' {
        $defs = @(Get-DuneRetailSpicefieldDefinitions)
        $defs.Count | Should -Be 4
        @($defs | Where-Object mapId -eq 'Survival_1').fieldType | Should -Be @('Small')
        @($defs | Where-Object mapId -eq 'DeepDesert_1').fieldType | Should -Be @('Small', 'Medium', 'Large')
        @($defs.id | Sort-Object -Unique).Count | Should -Be 4
    }

    It 'preserves the unavailable Retail primed count as null instead of numeric zero' {
        Mock Get-DuneGameConfig { @{ game = @{ raw = $script:SpiceUserRaw } } }
        Mock Get-DuneGameConfigDefaults { @{ game = $script:SpiceDefaultsRaw } }
        Mock Get-V6RetailSpicefieldActivity {
            @([pscustomobject]@{
                map_name = 'HaggaBasin'
                dimension_index = 0
                field_type = 'Small'
                current_active = 5
            })
        }
        Mock Get-DuneActiveMapPartitions {
            @{ ok = $true; partitions = @([pscustomobject]@{
                mapId = 'Survival_1'
                dimensionIndex = 0
                live = $true
                pinned = $false
            }) }
        }

        $row = @((Get-DuneRetailSpicefieldRows -Ip '192.0.2.1').rows |
            Where-Object spicefield_type_id -eq 9101)[0]

        $row.current_globally_active | Should -Be 5
        $row.current_globally_primed | Should -BeNullOrEmpty
        $row.current_primed_exact | Should -BeFalse
        $row.max_globally_primed | Should -Be 3
        $row.default_max_globally_active | Should -Be 5
        $row.default_max_globally_primed | Should -Be 5
        $row.guidance_max | Should -Be 5
        $row.configured_override | Should -BeTrue
    }

    It 'keeps a changed live Funcom default separate from DST guidance' {
        $retailDefaults = $script:SpiceDefaultsRaw.Replace(
            'MaxGloballyPrimed=5,MaxGloballyActive=5',
            'MaxGloballyPrimed=10,MaxGloballyActive=10'
        )
        Mock Get-DuneGameConfig { @{ game = @{ raw = $retailDefaults } } }
        Mock Get-DuneGameConfigDefaults { @{ game = $retailDefaults } }
        Mock Get-V6RetailSpicefieldActivity { @() }
        Mock Get-DuneActiveMapPartitions { @{ ok = $true; partitions = @() } }

        $row = @((Get-DuneRetailSpicefieldRows -Ip '192.0.2.1').rows |
            Where-Object spicefield_type_id -eq 9101)[0]

        $row.max_globally_active | Should -Be 10
        $row.default_max_globally_active | Should -Be 10
        $row.guidance_max | Should -Be 5
        $row.configured_override | Should -BeFalse
    }

    It 'uses the installed files immediately after the v2 migration is marked ready' {
        Mock Invoke-V6Ssh { 'ready' }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.source | Should -Be 'installed'
        $paths.game | Should -Be '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
        $paths.engine | Should -Be '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
        Should -Invoke Invoke-V6Ssh -Times 1
    }

    # --- Fix (2026-09-22): a Steam/Funcom update can silently overwrite the
    # installed template out from under an already-'ready' marker, reverting a
    # player's real customized values to Funcom's stock numbers in DST's own
    # reads/UI while the actually-running server (unaffected) kept the real
    # values the whole time. Proven live against a real self-hosted server:
    # SteamCMD overwrote UserGame.ini at patch time, dropping the
    # SpiceHarvestingSystem section entirely, while the marker file was
    # untouched and still claimed 'ready'.

    It 're-migrates when the template was overwritten since the marker was written (hash mismatch = stale, not ready)' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match '__DST_AUTH__:migrated') { return '__DST_AUTH__:migrated' }
            # The state-check script computes real sha256sums of the (mocked)
            # installed files and compares them to what's stored in the
            # marker; since this test doesn't touch real files, simulate the
            # detection result directly instead of re-implementing sha256sum.
            if ($Cmd -match 'if test -f') { return 'stale' }
            if ($Cmd -match 'ls -t') { return '/srv/managed' }
            if ($Cmd -match "cat '/srv/managed/UserGame.ini'") {
                return "$script:DstManagedBegin`n[$script:DuneGcSecGame]`nm_PlayerStartingWater=250`n$script:DstManagedEnd"
            }
            if ($Cmd -match 'sudo cat') { return '[ConsoleVariables]' }
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        # 'stale' takes the same merge-base path as 'uninitialized' (the
        # current, freshly-overwritten template IS the correct Funcom
        # baseline to merge onto), not the 'repair-v1' backup path.
        $paths.source | Should -Be 'installed'
        $paths.migrated | Should -BeTrue
        $paths.game | Should -Be '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
        Should -Invoke Invoke-V6Ssh -ParameterFilter { $Cmd -match 'pre-live-import-\*' } -Times 0
    }

    It 'writes the current template file hashes into the marker on migration, so a later untouched read reports ready' {
        $script:writes = @()
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match "printf 'live-imported-v2") { $script:writes += $Cmd }
            if ($Cmd -match '__DST_AUTH__:migrated') { return '__DST_AUTH__:migrated' }
            if ($Cmd -match 'if test -f') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/managed' }
            if ($Cmd -match "cat '/srv/managed/UserGame.ini'") {
                return "$script:DstManagedBegin`n[$script:DuneGcSecGame]`nm_PlayerStartingWater=250`n$script:DstManagedEnd"
            }
            if ($Cmd -match 'sudo cat') { return '[ConsoleVariables]' }
        }

        Resolve-DuneGameConfigPaths -Ip '192.0.2.1' | Out-Null

        $script:writes.Count | Should -Be 1
        # The marker command must carry two hash lines after the literal
        # 'live-imported-v2' line - a marker with no hashes is exactly the
        # old-format case that must always compare as stale, never ready.
        ($script:writes[0] -split '\\n').Count | Should -BeGreaterOrEqual 3
    }

    It 're-stamps the marker as ready (no Initialize-Game-Config banner) when a stale template has nothing to carry forward' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'if test -f') { return 'stale' }
            if ($Cmd -match 'ls -t') { return @() }
            return '[ConsoleVariables]'
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.source | Should -Be 'installed'
        $paths.authoritative | Should -Not -Be $false
        $paths.needsInitialization | Should -BeNullOrEmpty
        Should -Invoke Invoke-V6Ssh -ParameterFilter { $Cmd -match "printf 'live-imported-v2" } -Times 1
    }

    It 'fetches current complete defaults before migrating Spice from a sparse installed baseline' {
        Mock Get-DuneGameConfigDefaults { @{ game = $script:SpiceDefaultsRaw } }
        Mock Invoke-V6Ssh {
            param($Ip, $Cmd, $StdinData)
            if ($Cmd -match '__DST_AUTH__:migrated') { return '__DST_AUTH__:migrated' }
            if ($Cmd -match 'if test -f') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/managed' }
            if ($Cmd -match "cat '/srv/managed/UserGame.ini'") {
                return "$script:DstManagedBegin`n$script:SpiceUserRaw`n$script:DstManagedEnd"
            }
            if ($Cmd -match 'sudo cat') { return "[Other]`nKeepMe=42" }
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.migrated | Should -BeTrue
        Should -Invoke Get-DuneGameConfigDefaults -Times 1 -Exactly -ParameterFilter { $Force -and $Ip -eq '192.0.2.1' }
    }

    It 'fetches complete defaults when the installed Spice struct is present but incomplete' {
        Mock Get-DuneGameConfigDefaults { @{ game = $script:SpiceDefaultsRaw } }
        Mock Invoke-V6Ssh {
            param($Ip, $Cmd, $StdinData)
            if ($Cmd -match '__DST_AUTH__:migrated') { return '__DST_AUTH__:migrated' }
            if ($Cmd -match 'if test -f') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/managed' }
            if ($Cmd -match "cat '/srv/managed/UserGame.ini'") {
                $partialSpice = $script:SpiceUserRaw.Replace($script:SpiceOverride, 'm_PerMapSystemSettings=(("DeepDesert_1", (m_SpiceFieldTypeSettings=(((Name="Small"), (MaxGloballyPrimed=60,MaxGloballyActive=60))))))')
                return "$script:DstManagedBegin`n$partialSpice`n$script:DstManagedEnd"
            }
            if ($Cmd -match 'sudo cat') { return "[Other]`nKeepMe=42" }
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.migrated | Should -BeTrue
        Should -Invoke Get-DuneGameConfigDefaults -Times 1 -Exactly -ParameterFilter { $Force -and $Ip -eq '192.0.2.1' }
    }

    It 'does not write migration files if current Spice defaults cannot be read' {
        Mock Get-DuneGameConfigDefaults { throw 'defaults read failed' }
        Mock Invoke-V6Ssh {
            param($Ip, $Cmd, $StdinData)
            if ($Cmd -match 'if test -f') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/managed' }
            if ($Cmd -match "cat '/srv/managed/UserGame.ini'") {
                return "$script:DstManagedBegin`n$script:SpiceUserRaw`n$script:DstManagedEnd"
            }
            if ($Cmd -match 'sudo cat') { return "[Other]`nKeepMe=42" }
        }

        { Resolve-DuneGameConfigPaths -Ip '192.0.2.1' } | Should -Throw '*defaults read failed*'
        Should -Invoke Invoke-V6Ssh -Times 0 -Exactly -ParameterFilter { $Cmd -match 'sudo tee|sudo install|sudo cp' }
    }

    It 'migrates prior managed overrides onto installed Funcom defaults' {
        $oldGame = @"
[$script:DuneGcSecGame]
m_InventoryWeightMultiplier=0.25
$script:DstManagedBegin
[$script:SecInventory]
PlayerInventoryStartingSize=80
PlayerInventoryStartingVolumeCapacity=350
[$script:SecBuilding]
m_BaseBackupToolMapRestriction=((Name="HaggaBasin"), (Name="DeepDesert"))
m_bBuildingRestrictionLimitsEnabled=False
$script:DstManagedEnd
"@
        $installedGame = @"
[$script:SecInventory]
PlayerInventoryStartingSize=35
PlayerInventoryStartingVolumeCapacity=175
RetailAddedInventoryDefault=42
[$script:SecBuilding]
m_BaseBackupToolMapRestriction=((Name="HaggaBasin"))
m_bBuildingRestrictionLimitsEnabled=True
RetailAddedBuildingDefault=True
"@
        $script:writes = @()
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match '__DST_AUTH__:migrated') { return '__DST_AUTH__:migrated' }
            if ($Cmd -match 'if test -f') { return 'repair-v1' }
            if ($Cmd -match 'pre-live-import-\*') { return '/home/dune/.dune/download/scripts/setup/config/UserGame.ini.pre-live-import-20260917120000' }
            if ($Cmd -match 'ls -t') { return @('/srv/new-defaults', '/srv/old-managed') }
            if ($Cmd -match "cat '/home/dune/.dune/download/scripts/setup/config/UserGame.ini.pre-live-import-") { return $installedGame }
            if ($Cmd -match "cat '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini.pre-live-import-") { return '[ConsoleVariables]' }
            if ($Cmd -match "cat '/srv/new-defaults/") { return '[Unmanaged]' }
            if ($Cmd -match "cat '/srv/old-managed/UserGame.ini'") { return $oldGame }
            if ($Cmd -match "cat '/srv/old-managed/UserEngine.ini'") { return '[ConsoleVariables]' }
            if ($StdinData) {
                $script:writes += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData))
            }
        }
        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.source | Should -Be 'installed'
        $paths.migrated | Should -BeTrue
        $paths.migratedFrom | Should -Be '/srv/old-managed'
        $paths.migratedKeys | Should -Be 4
        $paths.game | Should -Be '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
        $paths.engine | Should -Be '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
        $merged = @($script:writes | Where-Object { $_ -match 'PlayerInventoryStartingSize' })[0]
        $merged | Should -Match 'PlayerInventoryStartingSize=80'
        $merged | Should -Match 'PlayerInventoryStartingVolumeCapacity=350'
        $merged | Should -Match 'm_BaseBackupToolMapRestriction=\(\(Name="HaggaBasin"\), \(Name="DeepDesert"\)\)'
        $merged | Should -Match 'm_bBuildingRestrictionLimitsEnabled=False'
        $merged | Should -Match 'RetailAddedInventoryDefault=42'
        $merged | Should -Match 'RetailAddedBuildingDefault=True'
        $merged | Should -Not -Match 'm_InventoryWeightMultiplier'
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter {
            $Cmd -match 'sha256sum -c' -and
            $Cmd -match '__DST_AUTH__:migrated' -and
            $Cmd -match 'pre-v2-migration-attempt-' -and
            $Cmd -notmatch "cp '[^']+' '[^']+\.pre-live-import-"
        }
    }

    It 'keeps the clean v1 repair baseline isolated across a failed v2 retry' {
        $oldGame = @"
$script:DstManagedBegin
[$script:SecInventory]
PlayerInventoryStartingSize=80
$script:DstManagedEnd
"@
        $installedGame = @"
[$script:SecInventory]
PlayerInventoryStartingSize=35
"@
        $script:migrationCommands = @()
        $script:migrationAttempt = 0
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match '__DST_AUTH__:migrated') {
                $script:migrationCommands += $Cmd
                $script:migrationAttempt++
                if ($script:migrationAttempt -eq 1) { return 'migration failed' }
                return '__DST_AUTH__:migrated'
            }
            if ($Cmd -match 'if test -f') { return 'repair-v1' }
            if ($Cmd -match 'pre-live-import-\*') {
                return '/home/dune/.dune/download/scripts/setup/config/UserGame.ini.pre-live-import-clean'
            }
            if ($Cmd -match 'ls -t') { return '/srv/old-managed' }
            if ($Cmd -match "cat '/home/dune/.dune/download/scripts/setup/config/UserGame.ini.pre-live-import-clean'") { return $installedGame }
            if ($Cmd -match "cat '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini.pre-live-import-clean'") { return '[ConsoleVariables]' }
            if ($Cmd -match "cat '/srv/old-managed/UserGame.ini'") { return $oldGame }
            if ($Cmd -match "cat '/srv/old-managed/UserEngine.ini'") { return '[ConsoleVariables]' }
        }

        { Resolve-DuneGameConfigPaths -Ip '192.0.2.1' } |
            Should -Throw '*could not safely migrate*'
        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.migrated | Should -BeTrue
        $script:migrationCommands.Count | Should -Be 2
        foreach ($command in $script:migrationCommands) {
            $command | Should -Match 'pre-v2-migration-attempt-'
            $command | Should -Not -Match "cp '[^']+' '[^']+\.pre-live-import-"
        }
        Should -Invoke Invoke-V6Ssh -Times 2 -ParameterFilter { $Cmd -match 'pre-live-import-\*' }
    }

    It 'blocks installed defaults when no existing battlegroup configuration can be imported' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            return ''
        }

        { Resolve-DuneGameConfigPaths -Ip '192.0.2.1' } |
            Should -Throw '*Deployment is blocked*'
    }

    # --- Field defect fix (Jess, v15.1.1): installed-uninitialized read fallback ---

    It 'returns the installed defaults as a non-authoritative read for the exact Jess v15.1.1 field defect, with zero writes' {
        $script:writes = @()
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return @() }
            if ($Cmd -match 'sudo cat') { return '[ConsoleVariables]' }
            if ($StdinData) { $script:writes += $StdinData }
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.source | Should -Be 'installed-uninitialized'
        $paths.authoritative | Should -BeFalse
        $paths.needsInitialization | Should -BeTrue
        $paths.game | Should -Be $script:DuneGameConfigTplGamePath
        $paths.engine | Should -Be $script:DuneGameConfigTplEnginePath
        $script:writes.Count | Should -Be 0
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'tee|sha256sum -c|install -o dune' }
    }

    It 'propagates non-authoritative/needsInitialization through Get-DuneGameConfig with zero writes' {
        $script:writes = @()
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [string]$StdinData)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return @() }
            if ($Cmd -match 'sudo cat') { return '[ConsoleVariables]' }
            if ($StdinData) { $script:writes += $StdinData }
        }

        $cfg = Get-DuneGameConfig -Ip '192.0.2.1'

        $cfg.source | Should -Be 'installed-uninitialized'
        $cfg.authoritative | Should -BeFalse
        $cfg.needsInitialization | Should -BeTrue
        $cfg.game.path | Should -Be $script:DuneGameConfigTplGamePath
        $script:writes.Count | Should -Be 0
    }

    It 'treats a live directory with no DST-managed content as safe to fall back to installed defaults' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/vanilla' }
            return '[ConsoleVariables]'
        }

        $paths = Resolve-DuneGameConfigPaths -Ip '192.0.2.1'

        $paths.source | Should -Be 'installed-uninitialized'
        $paths.needsInitialization | Should -BeTrue
    }

    It 'keeps a prior-managed candidate blocked even when it produces zero migration updates' {
        $managedButNoOp = @"
$script:DstManagedBegin
[ConsoleVariables]
$script:DstManagedEnd
"@
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/old-managed' }
            if ($Cmd -match "cat '/srv/old-managed/UserGame.ini'") { return $managedButNoOp }
            return '[ConsoleVariables]'
        }

        { Resolve-DuneGameConfigPaths -Ip '192.0.2.1' } | Should -Throw '*Deployment is blocked*'
    }

    It 'keeps a malformed live candidate blocked rather than falling back to installed defaults' {
        $malformedGame = @"
$script:DstManagedBegin
[ConsoleVariables]
dw.FuelBurningMultiplier=10
"@
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/broken' }
            if ($Cmd -match "cat '/srv/broken/UserGame.ini'") { return $malformedGame }
            return '[ConsoleVariables]'
        }

        { Resolve-DuneGameConfigPaths -Ip '192.0.2.1' } | Should -Throw '*Deployment is blocked*'
    }

    It 'refuses to save Game Config while it is uninitialized (installed-uninitialized)' {
        Mock Resolve-DuneGameConfigPaths {
            @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'installed-uninitialized'; authoritative = $false; needsInitialization = $true }
        }
        Mock Invoke-V6Ssh {}

        { Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecGame; key = 'm_InventoryWeightMultiplier'; value = '0.5'; remove = $false }) } |
            Should -Throw '*has not been initialized*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'refuses to save even when a non-authoritative ResolvedPaths object is supplied directly (deploy entry points)' {
        Mock Invoke-V6Ssh {}
        $paths = @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'installed-uninitialized'; authoritative = $false; needsInitialization = $true }

        { Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecGame; key = 'm_InventoryWeightMultiplier'; value = '0.5'; remove = $false }) -ResolvedPaths $paths } |
            Should -Throw '*has not been initialized*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'refuses to initialize Game Config without explicit confirmation' {
        Mock Invoke-V6Ssh {}
        { Initialize-DuneGameConfigAuthority -Ip '192.0.2.1' -Confirmed $false } | Should -Throw '*confirmation is required*'
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'BUG FIXED 2026-09-22: re-stamps the v2 authority marker hash after saving to the installed template, so the next read is not falsely stale' {
        # Reproduces the live report: resetting "Database Wipe on
        # Season End" / "Forced Coriolis World Seed" to default reverted to the
        # old values immediately after Save. Root cause: Save-DuneGameConfig
        # wrote the template but never re-stamped the marker's sha256 lines that
        # Resolve-DuneGameConfigPaths' staleness check relies on, so the very
        # next read saw a hash mismatch, called it 'stale', and re-ran the
        # carry-forward migration - reasserting whatever the last live/legacy
        # managed directory still held.
        $paths = @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'installed'; authoritative = $true; needsInitialization = $false }
        $stampedCmd = $null
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [int]$TimeoutSec, [string]$StdinData)
            if ($Cmd -match "cat '$([regex]::Escape($script:DuneGameConfigTplGamePath))'") { return '[CoriolisSubsystem]' }
            if ($Cmd -match "cat '$([regex]::Escape($script:DuneGameConfigTplEnginePath))'") { return '[Engine]' }
            if ($Cmd -match 'base64 -d \| sudo tee') {
                # Simulate the remote: hash what was actually sent, exactly the
                # readback contract the fixed write-verification relies on.
                $bytes = [Convert]::FromBase64String($StdinData)
                return Get-DuneGameConfigTextSha256 -Value ([Text.Encoding]::UTF8.GetString($bytes))
            }
            if ($Cmd -match [regex]::Escape($script:DuneGameConfigAuthorityMarker)) {
                $script:stampedCmd = $Cmd
                if ($Cmd -match "printf 'live-imported-v2\\n([0-9a-f]{64})\\n([0-9a-f]{64})\\n'") {
                    return Get-DuneGameConfigTextSha256 -Value "live-imported-v2`n$($Matches[1])`n$($Matches[2])`n"
                }
                return ''
            }
            return ''
        }

        Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecCoriolis; key = 'm_bIsDbWipeEnabled'; value = 'True'; remove = $true }) -ResolvedPaths $paths

        $script:stampedCmd | Should -Not -BeNullOrEmpty
        $script:stampedCmd | Should -Match 'live-imported-v2'
        $script:stampedCmd | Should -Match ([regex]::Escape($script:DuneGameConfigAuthorityMarker))
        # Marker must carry two fresh, non-empty hash lines (game + untouched
        # engine, re-read since this save only wrote game).
        if ($script:stampedCmd -notmatch "printf 'live-imported-v2\\n([0-9a-f]{64})\\n([0-9a-f]{64})\\n'") {
            throw "Marker stamp command did not contain two 64-char hex hashes: $script:stampedCmd"
        }
    }

    It 'BUG FIXED 2026-09-22 (Copilot review, PR #857): throws instead of stamping the marker when the remote content write cannot be verified' {
        # Invoke-V6Ssh discards the remote exit code, so a failed `tee` and a
        # successful one can both come back as empty stdout. Simulate that
        # silent-failure shape (mock returns '' instead of the real hash) and
        # assert the save refuses to proceed - it must never trust content
        # that was never confirmed to reach disk, and must never stamp the
        # marker off content that might not be there.
        $paths = @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'installed'; authoritative = $true; needsInitialization = $false }
        $markerTouched = $false
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [int]$TimeoutSec, [string]$StdinData)
            if ($Cmd -match "cat '$([regex]::Escape($script:DuneGameConfigTplGamePath))'") { return '[CoriolisSubsystem]' }
            if ($Cmd -match 'base64 -d \| sudo tee') { return '' }  # silent write failure
            if ($Cmd -match [regex]::Escape($script:DuneGameConfigAuthorityMarker)) { $script:markerTouched = $true; return '' }
            return ''
        }

        { Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecCoriolis; key = 'm_bIsDbWipeEnabled'; value = 'True'; remove = $true }) -ResolvedPaths $paths } |
            Should -Throw '*write verification failed*'
        $script:markerTouched | Should -BeFalse
    }

    It 'BUG FIXED 2026-09-22 (Copilot review, PR #857): throws when the marker re-stamp itself cannot be verified' {
        $paths = @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'installed'; authoritative = $true; needsInitialization = $false }
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [int]$TimeoutSec, [string]$StdinData)
            if ($Cmd -match "cat '$([regex]::Escape($script:DuneGameConfigTplGamePath))'") { return '[CoriolisSubsystem]' }
            if ($Cmd -match "cat '$([regex]::Escape($script:DuneGameConfigTplEnginePath))'") { return '[Engine]' }
            if ($Cmd -match 'base64 -d \| sudo tee') {
                $bytes = [Convert]::FromBase64String($StdinData)
                return Get-DuneGameConfigTextSha256 -Value ([Text.Encoding]::UTF8.GetString($bytes))
            }
            if ($Cmd -match [regex]::Escape($script:DuneGameConfigAuthorityMarker)) { return '' }  # silent marker-write failure
            return ''
        }

        { Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecCoriolis; key = 'm_bIsDbWipeEnabled'; value = 'True'; remove = $true }) -ResolvedPaths $paths } |
            Should -Throw '*marker re-stamp verification failed*'
    }

    It 'does not touch the v2 authority marker when saving to a non-installed (legacy-live) target' {
        $paths = @{ game = '/srv/live/UserGame.ini'; engine = '/srv/live/UserEngine.ini'; source = 'legacy-live' }
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd, [int]$TimeoutSec, [string]$StdinData)
            if ($Cmd -match [regex]::Escape($script:DuneGameConfigAuthorityMarker)) { throw 'marker should not be restamped for a non-installed source' }
            if ($Cmd -match 'base64 -d \| sudo tee') {
                $bytes = [Convert]::FromBase64String($StdinData)
                return Get-DuneGameConfigTextSha256 -Value ([Text.Encoding]::UTF8.GetString($bytes))
            }
            return ''
        }

        { Save-DuneGameConfig -Ip '192.0.2.1' -Updates @(@{ file = 'game'; section = $script:DuneGcSecGame; key = 'm_InventoryWeightMultiplier'; value = '0.5'; remove = $false }) -ResolvedPaths $paths } |
            Should -Not -Throw
    }

    It 'initializes Game Config by writing only the v2 authority marker, never UserGame.ini/UserEngine.ini' {
        $script:writes = @()
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'sudo tee') { $script:writes += $Cmd; return '__DST_AUTH__:initialized' }
            if ($Cmd -match 'echo ready') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return @() }
            if ($Cmd -match 'echo yes \|\| echo no') { return 'yes' }
            if ($Cmd -match 'sudo cat') { return '[ConsoleVariables]' }
            return ''
        }

        $result = Initialize-DuneGameConfigAuthority -Ip '192.0.2.1' -Confirmed $true

        $result.ok | Should -BeTrue
        $result.initialized | Should -BeTrue
        $result.source | Should -Be 'installed'
        $result.authoritative | Should -BeTrue
        $result.needsInitialization | Should -BeFalse
        $script:writes.Count | Should -Be 1
        $script:writes[0] | Should -Match ([regex]::Escape($script:DuneGameConfigAuthorityMarker))
        $script:writes[0] | Should -Not -Match 'UserGame\.ini|UserEngine\.ini'
    }

    It 'reports already-initialized without writing when another admin initialized concurrently (race safety)' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'ready' }
            return ''
        }

        $result = Initialize-DuneGameConfigAuthority -Ip '192.0.2.1' -Confirmed $true

        $result.ok | Should -BeTrue
        $result.alreadyInitialized | Should -BeTrue
        $result.source | Should -Be 'installed'
        Should -Invoke Invoke-V6Ssh -Times 0 -ParameterFilter { $Cmd -match 'sudo tee' }
    }

    It 'refuses to initialize when the recheck finds a prior-managed candidate now exists (race safety)' {
        $managedButNoOp = @"
$script:DstManagedBegin
[ConsoleVariables]
$script:DstManagedEnd
"@
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'uninitialized' }
            if ($Cmd -match 'ls -t') { return '/srv/appeared' }
            if ($Cmd -match "cat '/srv/appeared/UserGame.ini'") { return $managedButNoOp }
            return '[ConsoleVariables]'
        }

        { Initialize-DuneGameConfigAuthority -Ip '192.0.2.1' -Confirmed $true } | Should -Throw '*Deployment is blocked*'
    }

    It 'reads as fully authoritative immediately after Initialize-DuneGameConfigAuthority completes' {
        Mock Invoke-V6Ssh {
            param([string]$Ip, [string]$Cmd)
            if ($Cmd -match 'DuneGameConfigAuthorityMarker|dst-live-settings-imported') { return 'ready' }
            return '[ConsoleVariables]'
        }

        $cfg = Get-DuneGameConfig -Ip '192.0.2.1'

        $cfg.source | Should -Be 'installed'
        $cfg.authoritative | Should -BeTrue
        $cfg.needsInitialization | Should -BeFalse
    }

    It 'registers POST /api/gameconfig/initialize with an exact typed confirmation, marker-only write' {
        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw

        $route | Should -Match "Register-DuneRoute -Method POST -Path '/api/gameconfig/initialize' -Handler"
        $route | Should -Match "-cne 'INITIALIZE GAME CONFIG'"
        $route | Should -Match 'Initialize-DuneGameConfigAuthority -Ip \$ctx\.ip -Confirmed \$true'
    }

    It 'writes the Retail spawning flag as an exact Unreal boolean' {
        Mock Get-DuneRetailSpicefieldRows {
            @{
                defaultRaw = ''
                blob = 'existing'
                rows = @(@{
                    spicefield_type_id = 9101
                    max_globally_active = 5
                    max_globally_primed = 5
                    is_spawning_active = $true
                })
            }
        }
        Mock Set-DuneSpicefieldLimitsInBlob { 'updated' }
        Mock Save-DuneGameConfigLocked {}

        $null = Set-DuneRetailSpicefieldRow -Ip '192.0.2.1' -TypeId 9101 `
            -MaxActive 5 -MaxPrimed 5 -SpawningActive $true

        Should -Invoke Save-DuneGameConfigLocked -Times 1 -ParameterFilter {
            @($Updates | Where-Object key -eq 'm_bSpawningActive')[0].value -eq 'True'
        }
    }

    It 'surfaces the active cap from the complete existing override' {
        $values = Get-DuneIniEffectiveByKey -Raw $script:SpiceUserRaw

        $values['DST.SpiceStartup.DeepDesert.Small.Max'] | Should -Be '60'
        $values['DST.SpiceStartup.DeepDesert.Medium.Max'] | Should -Be '12'
        $values['DST.SpiceStartup.DeepDesert.Large.Max'] | Should -Be '6'
        $values['DST.SpiceStartup.Hagga.Small.Max'] | Should -Be '10'
    }

    It 'shares the complete parent struct instead of invalid pseudo keys' {
        $notice = Get-DuneGameConfigClientApplyNotice -Updates @(
            @{ key='DST.SpiceStartup.DeepDesert.Large.Max'; value='6' }
        )

        @($notice.items).Count | Should -Be 1
        $notice.items[0].structKey | Should -Be 'm_PerMapSystemSettings'
    }

    It 'loads live defaults before applying spice startup fields to a fresh client file' {
        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        $route | Should -Match 'Test-DuneUpdatesHaveStructMember[\s\S]+?-or[\s\S]+?Test-DuneUpdatesHaveSpicefieldMember'
    }

    It 'keeps every host client-config route local-only' {
        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        foreach ($path in @(
            '/api/gameconfig/client',
            '/api/gameconfig/client/dir',
            '/api/gameconfig/client/engine',
            '/api/gameconfig/client/apply',
            '/api/gameconfig/client/open'
        )) {
            $escaped = [regex]::Escape($path)
            $route | Should -Match "Register-DuneRoute[^\r\n]+-Path '$escaped' -LocalOnly -Handler"
        }
    }

    It 'patches only the selected map and size' {
        $blob = Get-DuneIniLineValue $script:SpiceOverride
        $patched = Set-DuneSpicefieldLimitsInBlob -Blob $blob -MapId 'DeepDesert_1' `
            -FieldType 'Large' -MaxPrimed 4 -MaxActive 9

        (Get-DuneSpicefieldLimitsFromBlob -Blob $patched -MapId 'DeepDesert_1' -FieldType 'Large').maxActive | Should -Be 9
        (Get-DuneSpicefieldLimitsFromBlob -Blob $patched -MapId 'DeepDesert_1' -FieldType 'Large').maxPrimed | Should -Be 4
        (Get-DuneSpicefieldLimitsFromBlob -Blob $patched -MapId 'Editor_Default' -FieldType 'Large').maxActive | Should -Be 6
        (Get-DuneSpicefieldLimitsFromBlob -Blob $patched -MapId 'DeepDesert_1' -FieldType 'Medium').maxActive | Should -Be 12
        $patched.Replace('MaxGloballyPrimed=4,MaxGloballyActive=9', 'MaxGloballyPrimed=2,MaxGloballyActive=6') | Should -Be $blob
    }

    It 'folds one simple max field into both required subnode members and writes the complete struct' {
        $folded = @(Convert-DuneSpicefieldUpdates -Raw $script:SpiceUserRaw -DefaultsRaw $script:SpiceDefaultsRaw -Updates @(
            @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='4'; remove=$false }
        ))
        $folded.Count | Should -Be 1
        $folded[0].key | Should -Be 'm_PerMapSystemSettings'
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'DeepDesert_1' -FieldType 'Large'
        $state.maxActive | Should -Be 4
        $state.maxPrimed | Should -Be 4
        (Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'Editor_Default' -FieldType 'Large').maxActive | Should -Be 6
        (Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'Survival_1' -FieldType 'Small').maxActive | Should -Be 10

        $out = ConvertTo-DuneIniManaged -Raw $script:SpiceUserRaw -Updates $folded -QuotedKeys @{}
        ([regex]::Matches($out, '(?m)^m_PerMapSystemSettings=')).Count | Should -Be 1
        $out | Should -Match 'm_DefaultSystemSettings='
    }

    It 'seeds the complete Funcom struct when the client or server file has no override' {
        $folded = @(Convert-DuneSpicefieldUpdates -Raw '' -DefaultsRaw $script:SpiceDefaultsRaw -Updates @(
            @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='6'; remove=$false }
        ))
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'DeepDesert_1' -FieldType 'Large'

        $state.maxActive | Should -Be 6
        $state.maxPrimed | Should -Be 6
        (Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'Survival_1' -FieldType 'Small').maxActive | Should -Be 5
    }

    It 'migrates Spice onto a sparse installed baseline using complete vendor defaults' {
        $merged = Merge-DuneGameConfigMigrationValues -BaseRaw "[Other]`nKeepMe=42" -File game -DefaultsRaw $script:SpiceDefaultsRaw -Updates @(
            @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='6'; remove=$false }
        )
        $doc = ConvertFrom-DuneIniDoc -Raw $merged
        $blob = Get-DuneStructBlobFromDoc -Doc $doc -Section $script:SpiceSection -StructKey 'm_PerMapSystemSettings'
        (Get-DuneSpicefieldLimitsFromBlob -Blob $blob -MapId 'DeepDesert_1' -FieldType 'Large').maxActive | Should -Be 6
        (Get-DuneSpicefieldLimitsFromBlob -Blob $blob -MapId 'Survival_1' -FieldType 'Small').maxActive | Should -Be 5
        $merged | Should -Match 'KeepMe=42'
    }

    It 'still refuses Spice migration when the complete structure is unavailable' {
        { Merge-DuneGameConfigMigrationValues -BaseRaw '[Other]' -File game -DefaultsRaw '[Other]' -Updates @(
            @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='6'; remove=$false }
        ) } | Should -Throw '*refusing to create a partial override*'
    }

    It 'resets a Funcom per-map size to its exact active and primed defaults' {
        $folded = @(Convert-DuneSpicefieldUpdates -Raw $script:SpiceUserRaw -DefaultsRaw $script:SpiceDefaultsRaw -Updates @(
            @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='1'; remove=$true }
        ))
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $folded[0].value -MapId 'DeepDesert_1' -FieldType 'Large'

        $state.maxActive | Should -Be 1
        $state.maxPrimed | Should -Be 1
    }

    It 'refuses an inexact reset when Funcom defaults are unavailable' {
        {
            Convert-DuneSpicefieldUpdates -Raw $script:SpiceUserRaw -DefaultsRaw '' -Updates @(
                @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='1'; remove=$true }
            )
        } | Should -Throw '*defaults are unavailable*'
    }

    It 'refuses an inexact reset when the Funcom default subnode is malformed' {
        $malformedDefaults = $script:SpiceDefaultsRaw.Replace(
            'MaxGloballyPrimed=1,MaxGloballyActive=1',
            'MaxGloballyPrimed=1'
        )
        {
            Convert-DuneSpicefieldUpdates -Raw $script:SpiceUserRaw `
                -DefaultsRaw $malformedDefaults -Updates @(
                    @{ file='game'; section=$script:SpiceSection; key='DST.SpiceStartup.DeepDesert.Large.Max'; value='1'; remove=$true }
                )
        } | Should -Throw '*malformed*'
    }

    It 'fails closed for malformed targets' {
        { Set-DuneSpicefieldLimitsInBlob -Blob '(("DeepDesert_1", (broken)))' `
                -MapId 'DeepDesert_1' -FieldType 'Large' -MaxPrimed 2 -MaxActive 3 } |
            Should -Throw '*malformed*'
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

    It 'exposes current Funcom Landsraad timing members without hiding legacy values' {
        $landsraadKeys = @($script:DuneGameConfigSchema |
            Where-Object { $_.Category -eq 'Landsraad' } |
            ForEach-Object { $_.Key })

        $landsraadKeys | Should -Contain 'm_LandsraadVotingPeriodDurationInSec'
        $landsraadKeys | Should -Contain 'm_LandsraadCycleDurationInSeconds'
        $landsraadKeys | Should -Contain 'm_LandsraadSuspendedPeriodDurationInSeconds'
        $landsraadKeys | Should -Contain 'm_VotingPeriodDurationInSec'
        $landsraadKeys | Should -Contain 'm_VotingPeriodStartBeforeCoriolisCycleInSec'
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

    It 'heals a legacy STUB box while preserving legacy and current members independently' {
        # An older DST build wrote a stripped 5-member stub into the live file.
        $stubRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_LandsraadTaskProgressUpdateFrequency=15.0,m_LandsraadTaskDailyRevealFrequency=25.0,m_VotingPeriodStartBeforeCoriolisCycleInSec=118800.0,m_VotingPeriodDurationInSec=43210,m_TaskGoalAmount=9999.0)' + "`n"
        # Full default box ships many more members the stub dropped.
        $defaultsRaw = "[/Script/DuneSandbox.LandsraadSettings]`n" +
            'Data=(m_NumberOfDecreesToNominate=5,m_TaskGoalAmount=26000,m_LandsraadTaskProgressUpdateFrequency=10.0,m_LandsraadTaskDailyRevealFrequency=20.0,m_LandsraadVotingPeriodDurationInSec=118500,m_LandsraadCycleDurationInSeconds=604800,m_LandsraadSuspendedPeriodDurationInSeconds=300,m_ControlPointsPerCycle=10,m_TermStartedMessage=(Name="LandsraadTermStarted"),m_BoardLayouts=((Houses=2)),m_ContributionCurve=(Keys=((Time=0.0,Value=1.0))))' + "`n"
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
        $folded[0].value | Should -Match 'm_LandsraadVotingPeriodDurationInSec=118500'
        $folded[0].value | Should -Match 'm_VotingPeriodDurationInSec=43210'
        $folded[0].value | Should -Match 'm_VotingPeriodStartBeforeCoriolisCycleInSec=118800\.0'
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
