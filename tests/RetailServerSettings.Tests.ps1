BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RetailServerSettings.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\lib\K8s.ps1')
    function global:Invoke-V6Ssh { param($Ip, $Cmd, $TimeoutSec, $StdinData) }

    $script:RetailSection = '/Script/DuneSandbox.UserServerCustomSettings'
    $script:RetailRaw = @"
[$script:RetailSection]
DifficultyLevel=Medium
PVPMode=Limited
bIsBuildingRestrictionsEnabled=True
FiefdomLimit=3
BuildingPieceLimitMultiplier=1.000000
bBuildingInfiniteStability=False
FutureRetailKey=27
"@
}

Describe 'Official Retail Server Settings parsing' -Tag 'GameConfig', 'RetailServerSettings' {
    It 'accepts a Retail section on the first line after a UTF-8 BOM' {
        $raw = [char]0xFEFF + "[$script:RetailSection]`nFiefdomLimit=3"
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw
        $result.sectionFound | Should -BeTrue
        ($result.settings | Where-Object key -eq 'FiefdomLimit').value | Should -Be '3'
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{ FiefdomLimit = '4' }
        $updated | Should -Be ([char]0xFEFF + "[$script:RetailSection]`nFiefdomLimit=4")
    }

    It 'covers the complete current 47-key Retail catalogue' {
        (Get-DuneRetailServerSettingKeyMap).Count | Should -Be 47
    }

    It 'types all current values and keeps unknown keys read-only' {
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw $script:RetailRaw

        $result.sectionFound | Should -BeTrue
        @($result.settings).Count | Should -Be 48
        @($result.settings | Where-Object present).Count | Should -Be 7
        ($result.settings | Where-Object key -eq 'FiefdomLimit').type | Should -Be 'int'
        ($result.settings | Where-Object key -eq 'BuildingPieceLimitMultiplier').type | Should -Be 'float'
        $unknown = $result.settings | Where-Object key -eq 'FutureRetailKey'
        $unknown.supported | Should -BeFalse
        $unknown.readOnly | Should -BeTrue
        $unknown.value | Should -Be '27'
    }

    It 'presents field-proven building labels with inverted stability semantics' {
        $restrictions = (ConvertFrom-DuneRetailServerSettingsRaw -Raw $script:RetailRaw).settings |
            Where-Object key -eq 'bIsBuildingRestrictionsEnabled'
        $stability = (ConvertFrom-DuneRetailServerSettingsRaw -Raw $script:RetailRaw).settings |
            Where-Object key -eq 'bBuildingInfiniteStability'

        $restrictions.label | Should -Be 'General Building Restrictions'
        $restrictions.displayValue | Should -Be 'Enabled'
        $stability.label | Should -Be 'Building Stability Limits'
        $stability.inverted | Should -BeTrue
        $stability.value | Should -Be 'False'
        $stability.displayValue | Should -Be 'Enabled'
    }

    It 'maps Unlimited Landsraad Decree Rerolls directly without inversion' {
        $rawFalse = "$script:RetailRaw`nbLandsraadDisableDecreeRerollLimit=False"
        $rawTrue = "$script:RetailRaw`nbLandsraadDisableDecreeRerollLimit=True"
        $disabled = (ConvertFrom-DuneRetailServerSettingsRaw -Raw $rawFalse).settings |
            Where-Object key -eq 'bLandsraadDisableDecreeRerollLimit'
        $enabled = (ConvertFrom-DuneRetailServerSettingsRaw -Raw $rawTrue).settings |
            Where-Object key -eq 'bLandsraadDisableDecreeRerollLimit'

        $disabled.inverted | Should -BeFalse
        $disabled.displayValue | Should -Be 'Disabled'
        $enabled.inverted | Should -BeFalse
        $enabled.displayValue | Should -Be 'Enabled'
    }

    It 'reports malformed lines and malformed known values without dropping them' {
        $raw = @"
[$script:RetailSection]
FiefdomLimit=not-a-number
this line is malformed
"@
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw

        @($result.malformedLines).Count | Should -Be 1
        $fiefdom = $result.settings | Where-Object key -eq 'FiefdomLimit'
        $fiefdom.valid | Should -BeFalse
        $fiefdom.value | Should -Be 'not-a-number'
    }

    It 'does not mistake matching keys in another section for Retail settings' {
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw @"
[Other]
FiefdomLimit=99
"@
        $result.sectionFound | Should -BeFalse
        @($result.settings).Count | Should -Be 47
        @($result.settings | Where-Object present).Count | Should -Be 0
        ($result.settings | Where-Object key -eq 'FiefdomLimit').value | Should -BeExactly ''
    }

    It 'exposes the entire catalogue without inventing values for an empty source' -ForEach @(
        @{ Raw = '' }
        @{ Raw = "[/Script/DuneSandbox.UserServerCustomSettings]`n" }
        @{ Raw = "[/Script/DuneSandbox.UserServerCustomSettings]`nFutureRetailKey=keep-me" }
    ) {
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw $Raw
        $supported = @($result.settings | Where-Object supported)
        $supported.Count | Should -Be 47
        @($supported | Where-Object present).Count | Should -Be 0
        @($supported | Where-Object { $_.value -ne '' }).Count | Should -Be 0
        @($supported | Where-Object { $_.displayValue -ne 'Not configured' }).Count | Should -Be 0
        ($supported | Where-Object key -eq 'BuildingCostMultiplier').editable | Should -BeTrue
        ($supported | Where-Object key -eq 'PlayerDamageToNPC').editable | Should -BeTrue
    }

    It 'accepts case variants of booleans and canonicalizes API and requested writes only' {
        $raw = "[$script:RetailSection]`nbBuildingInfiniteStability=false ; stability`nbAllowSandworms=tRuE`nFutureBool=FALSE"
        $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw
        $stability = $parsed.settings | Where-Object key -eq 'bBuildingInfiniteStability'
        $stability.valid | Should -BeTrue
        $stability.value | Should -BeExactly 'False'
        $stability.displayValue | Should -Be 'Enabled'
        ($parsed.settings | Where-Object key -eq 'bAllowSandworms').value | Should -BeExactly 'True'
        ($parsed.settings | Where-Object key -eq 'FutureBool').type | Should -Be 'bool'
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{ bBuildingInfiniteStability = 'TRUE' }
        $updated | Should -BeExactly "[$script:RetailSection]`nbBuildingInfiniteStability=True ; stability`nbAllowSandworms=tRuE`nFutureBool=FALSE"
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{ bAllowSandworms = 'yes' } } |
            Should -Throw '*invalid bool value*'
    }

    It 'initializes only requested supported keys and preserves an unrelated section exactly' {
        $raw = [char]0xFEFF + "; heading`r`n[Other]`r`nFiefdomLimit=99`r`nFutureRetailKey=untouched"
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{
            BuildingCostMultiplier = '1.000000'
            PlayerDamageToNPC = '2.000000'
        }
        $updated | Should -BeExactly "$raw`r`n[$script:RetailSection]`r`nBuildingCostMultiplier=1.000000`r`nPlayerDamageToNPC=2.000000`r`n"
        $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $updated
        @($parsed.settings | Where-Object present).Count | Should -Be 2
    }

    It 'adds missing keys inside the official section without touching other sections or duplicate values' {
        $raw = "[$script:RetailSection]`r`n; note`r`nFiefdomLimit=3`r`nFutureRetailKey=keep-me`r`n[Other]`r`nBuildingCostMultiplier=99`r`n"
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{ BuildingCostMultiplier = '1.000000' }
        $updated | Should -BeExactly "[$script:RetailSection]`r`n; note`r`nFiefdomLimit=3`r`nFutureRetailKey=keep-me`r`nBuildingCostMultiplier=1.000000`r`n[Other]`r`nBuildingCostMultiplier=99`r`n"
    }

    It 'creates a section from an empty source and leaves absent keys unconfigured' {
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw '' -Updates @{ bAllowSandworms = 'false' }
        $updated | Should -BeExactly "[$script:RetailSection]`nbAllowSandworms=False`n"
        @((ConvertFrom-DuneRetailServerSettingsRaw -Raw $updated).settings | Where-Object present).Count | Should -Be 1
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw '' -Updates @{ FutureRetailKey = '1' } } |
            Should -Throw '*not editable*'
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw '' -Updates @{ DifficultyLevel = 'Custom' } } |
            Should -Throw '*not editable*'
    }

    It 'initializes the 45 editable documented defaults with catalogue-valid values' {
        $card = Get-Content (Join-Path (Get-DstRepoRoot) 'webui\src\pages\gameconfig\OfficialRetailServerSettingsCard.tsx') -Raw
        $guidance = [regex]::Matches($card, "(?m)^  (\w+): \{ defaultValue: '([^']+)'")
        $guidance.Count | Should -Be 47
        $updates = @{}
        foreach ($entry in $guidance) {
            $definition = Get-DuneRetailServerSettingDefinition -Key $entry.Groups[1].Value
            $definition | Should -Not -BeNullOrEmpty
            if ($definition.editable) { $updates[$entry.Groups[1].Value] = $entry.Groups[2].Value }
        }
        $updates.Count | Should -Be 45
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw '' -Updates $updates
        $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $updated
        @($parsed.settings | Where-Object present).Count | Should -Be 45
        @($parsed.settings | Where-Object { -not $_.valid }).Count | Should -Be 0
        ($parsed.settings | Where-Object key -eq 'DifficultyLevel').present | Should -BeFalse
        ($parsed.settings | Where-Object key -eq 'PVPMode').present | Should -BeFalse
    }

    It 'updates only requested values while preserving comments, order, and unknown keys' {
        $raw = @"
; retained heading
[$script:RetailSection]
FutureRetailKey=keep-me
bIsBuildingRestrictionsEnabled=True
FiefdomLimit=3

[Other]
OtherKey=OtherValue
"@
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{
            bIsBuildingRestrictionsEnabled = 'False'
            FiefdomLimit = '4'
        }

        $updated | Should -Match '(?m)^; retained heading\r?$'
        $updated | Should -Match '(?m)^FutureRetailKey=keep-me\r?$'
        $updated | Should -Match '(?m)^bIsBuildingRestrictionsEnabled=False\r?$'
        $updated | Should -Match '(?m)^FiefdomLimit=4\r?$'
        $updated | Should -Match '(?m)^OtherKey=OtherValue\r?$'
    }

    It 'preserves spacing and trailing comments on changed lines' {
        $raw = @(
            "[$script:RetailSection]"
            ('FiefdomLimit=   3   ; retained limit note' + '  ')
            "bIsBuildingRestrictionsEnabled =`tTrue`t# retained restriction note"
            'FutureRetailKey = keep-me ; untouched'
        ) -join "`n"
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{
            FiefdomLimit = '4'
            bIsBuildingRestrictionsEnabled = 'False'
        }

        $updated | Should -Match '(?m)^FiefdomLimit=   4   ; retained limit note  $'
        $updated | Should -Match "(?m)^bIsBuildingRestrictionsEnabled =`tFalse`t# retained restriction note$"
        $updated | Should -Match '(?m)^FutureRetailKey = keep-me ; untouched$'
    }

    It 'parses typed values before trailing comments and preserves comments when updating' {
        $raw = @(
            "[$script:RetailSection]"
            'FiefdomLimit=3 ; retained limit note'
            'bIsBuildingRestrictionsEnabled=True # retained restriction note'
        ) -join "`n"

        $parsed = ConvertFrom-DuneRetailServerSettingsRaw -Raw $raw
        $fiefdom = $parsed.settings | Where-Object key -eq 'FiefdomLimit'
        $restrictions = $parsed.settings | Where-Object key -eq 'bIsBuildingRestrictionsEnabled'
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{
            FiefdomLimit = '4'
            bIsBuildingRestrictionsEnabled = 'False'
        }

        $fiefdom.value | Should -Be '3'
        $fiefdom.valid | Should -BeTrue
        $restrictions.value | Should -Be 'True'
        $restrictions.valid | Should -BeTrue
        $updated | Should -Match '(?m)^FiefdomLimit=4 ; retained limit note$'
        $updated | Should -Match '(?m)^bIsBuildingRestrictionsEnabled=False # retained restriction note$'
    }

    It 'preserves CRLF line endings exactly when updating one setting' {
        $raw = "[$script:RetailSection]`r`nFiefdomLimit=3 ; retained`r`nFutureRetailKey=keep-me`r`n"

        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $raw -Updates @{ FiefdomLimit = '4' }

        $updated | Should -BeExactly "[$script:RetailSection]`r`nFiefdomLimit=4 ; retained`r`nFutureRetailKey=keep-me`r`n"
        $updated.Replace("`r`n", '').Contains("`n") | Should -BeFalse
    }

    It 'rejects unsupported, read-only, and malformed writes' {
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:RetailRaw -Updates @{ FutureRetailKey = '1' } } |
            Should -Throw '*not editable*'
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:RetailRaw -Updates @{ DifficultyLevel = 'Hard' } } |
            Should -Throw '*not editable*'
        { ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:RetailRaw -Updates @{ FiefdomLimit = '1.5' } } |
            Should -Throw '*invalid int value*'
    }
}

Describe 'Official Retail Server Settings discovery' -Tag 'GameConfig', 'RetailServerSettings' {
    BeforeEach {
        Mock Get-V6Battlegroup {
            @{ Ns = 'funcom-test'; Name = 'retail-test'; Bg = [pscustomobject]@{} }
        }
    }

    It 'discovers the Funcom File Browser Saved-PVC projection including an empty file' -ForEach @(
        @{ Empty = $false }
        @{ Empty = $true }
    ) {
        $podJson = @{
            items = @(@{
                metadata = @{ name = 'retail-test-fb-deploy-abc' }
                spec = @{
                    containers = @(@{
                        name = 'filebrowser'
                        volumeMounts = @(@{ name = 'volume-0'; mountPath = '/srv'; subPath = 'Saved' })
                    })
                    volumes = @(@{
                        name = 'volume-0'
                        persistentVolumeClaim = @{ claimName = 'retail-test-pvc' }
                    })
                }
            })
        } | ConvertTo-Json -Depth 8 -Compress
        $raw = if ($Empty) { '' } else { $script:RetailRaw }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
        Mock Invoke-V6Ssh {
            if ($Cmd -like '*get pods*') { return $podJson }
            return @('__DST_META__', '1789707124|321', ('a' * 64), '__DST_CONTENT__', $encoded)
        }

        $result = Get-DuneRetailServerSettings -Ip '192.0.2.10'

        $result.available | Should -BeTrue
        $result.readOnly | Should -BeFalse
        $result.target.path | Should -Be '/srv/Config/LinuxServer/ServerCustomSettings.ini'
        $result.target.gamePath | Should -Be '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer/ServerCustomSettings.ini'
        $result.target.persistentVolumeClaim | Should -Be 'retail-test-pvc'
        $result.applyBehavior.restartRequired | Should -BeTrue
        $result.writeBehavior.supported | Should -BeTrue
        @($result.settings).Count | Should -Be $(if ($Empty) { 47 } else { 48 })
        @($result.settings | Where-Object present).Count | Should -Be $(if ($Empty) { 0 } else { 7 })
    }

    It 'returns an explicit unavailable state when the generated file is missing' {
        $podJson = @{
            items = @(@{
                metadata = @{ name = 'retail-test-fb-deploy-abc' }
                spec = @{
                    containers = @(@{
                        name = 'filebrowser'
                        volumeMounts = @(@{ name = 'volume-0'; mountPath = '/srv'; subPath = 'Saved' })
                    })
                    volumes = @(@{
                        name = 'volume-0'
                        persistentVolumeClaim = @{ claimName = 'retail-test-pvc' }
                    })
                }
            })
        } | ConvertTo-Json -Depth 8 -Compress
        Mock Invoke-V6Ssh {
            if ($Cmd -like '*get pods*') { return $podJson }
            return '__DST_MISSING__'
        }

        $result = Get-DuneRetailServerSettings -Ip '192.0.2.10'

        $result.available | Should -BeFalse
        $result.reason | Should -Match 'runtime file is missing'
        @($result.settings).Count | Should -Be 0
    }

    It 'prefers the configured operator source over the stale PVC projection' {
        $script:UpstreamRetailRaw = $script:RetailRaw.Replace('FiefdomLimit=3', 'FiefdomLimit=4')
        Mock Get-V6Battlegroup {
            @{
                Ns = 'funcom-test'
                Name = 'retail-test'
                Bg = [pscustomobject]@{
                    metadata = [pscustomobject]@{ resourceVersion = '101' }
                    spec = [pscustomobject]@{
                        stop = $true
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{
                                    global = [pscustomobject]@{
                                        userIniConfig = [pscustomobject]@{
                                            mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                                            files = [pscustomobject]@{ 'ServerCustomSettings.ini' = $script:UpstreamRetailRaw }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        $podJson = @{
            items = @(@{
                metadata = @{ name = 'retail-test-fb-deploy-abc'; labels = @{} }
                spec = @{
                    containers = @(@{
                        name = 'filebrowser'
                        volumeMounts = @(@{ name = 'volume-0'; mountPath = '/srv'; subPath = 'Saved' })
                    })
                    volumes = @(@{
                        name = 'volume-0'
                        persistentVolumeClaim = @{ claimName = 'retail-test-pvc' }
                    })
                }
            })
        } | ConvertTo-Json -Depth 8 -Compress
        Mock Invoke-V6Ssh { return $podJson }

        $result = Get-DuneRetailServerSettings -Ip '192.0.2.10'

        $result.source | Should -Be 'funcom-servergroup-user-ini-config'
        $result.target.upstreamConfigured | Should -BeTrue
        $result.PSObject.Properties['raw'] | Should -BeNullOrEmpty
        ($result.settings | Where-Object key -eq 'FiefdomLimit').value | Should -Be '4'
        Should -Invoke Invoke-V6Ssh -Times 1
    }

    It 'refuses discovery when the File Browser mount is not the Saved PVC' {
        Mock Invoke-V6Ssh {
            @{
                items = @(@{
                    metadata = @{ name = 'retail-test-fb-deploy-abc' }
                    spec = @{
                        containers = @(@{
                            name = 'filebrowser'
                            volumeMounts = @(@{ name = 'volume-0'; mountPath = '/srv'; subPath = 'Other' })
                        })
                        volumes = @(@{
                            name = 'volume-0'
                            persistentVolumeClaim = @{ claimName = 'retail-test-pvc' }
                        })
                    }
                })
            } | ConvertTo-Json -Depth 8 -Compress
        }

        $result = Resolve-DuneRetailServerSettingsTarget -Ip '192.0.2.10'

        $result.available | Should -BeFalse
        $result.reason | Should -Match 'does not expose the Saved PVC'
    }
}

Describe 'Official Retail Server Settings route safety' -Tag 'GameConfig', 'RetailServerSettings' {
    It 'registers a guarded operator write endpoint without direct-file mutation routes' {
        $route = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1') -Raw
        @([regex]::Matches($route, "Register-DuneRoute -Method GET -Path '/api/gameconfig/retail-server-settings'")).Count |
            Should -Be 1
        @([regex]::Matches($route, "Register-DuneRoute -Method PUT -Path '/api/gameconfig/retail-server-settings'")).Count |
            Should -Be 1
        $route | Should -Match "Test-DunePlayerGuard"
        Get-Command Set-DuneRetailServerSettings -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Set-DuneRetailServerSettingsFile -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'runs a stable stopped save through the registered PUT handler' {
        $routeFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\GameConfig.ps1'
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
            }
            . $routeFile
        })
        $put = $routes | Where-Object {
            $_.method -eq 'PUT' -and $_.path -eq '/api/gameconfig/retail-server-settings'
        } | Select-Object -First 1
        $script:CommentedRetailRaw = $script:RetailRaw.Replace(
            'FiefdomLimit=3',
            'FiefdomLimit=3 ; retained limit note'
        )
        $revision = Get-DuneRetailServerSettingsTextSha256 -Value $script:CommentedRetailRaw
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw `
            -Raw $script:CommentedRetailRaw `
            -Updates @{ FiefdomLimit = '4' }
        $script:RouteBgRead = 0
        $script:RouteResult = $null
        $script:RouteError = $null
        function Get-DuneGameConfigContext {}
        function Test-DunePlayerGuard {}
        Mock Get-DuneGameConfigContext { @{ ok = $true; ip = '192.0.2.10' } }
        Mock Test-DunePlayerGuard { $true }
        Mock Resolve-DuneRetailServerSettingsTarget {
            @{
                available = $true
                namespace = 'funcom-test'
                battlegroup = 'retail-test'
                pod = 'retail-test-fb-deploy-abc'
                path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
                upstreamConfigured = $true
                upstreamFileName = 'ServerCustomSettings.ini'
                upstreamContent = $script:CommentedRetailRaw
                resourceVersion = '100'
                stopped = $true
                serverPodCount = 0
            }
        }
        Mock Backup-DuneRetailServerSettingsContent {
            @{ path = 'backup'; sha256 = 'backup'; timestamp = '1' }
        }
        Mock Get-V6Battlegroup {
            $script:RouteBgRead++
            $content = if ($script:RouteBgRead -eq 1) { $script:CommentedRetailRaw } else { $updated }
            @{
                Bg = [pscustomobject]@{
                    metadata = [pscustomobject]@{ resourceVersion = "$($script:RouteBgRead + 99)" }
                    spec = [pscustomobject]@{
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{
                                    global = [pscustomobject]@{
                                        userIniConfig = [pscustomobject]@{
                                            mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                                            files = [pscustomobject]@{ 'ServerCustomSettings.ini' = $content }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        Mock Invoke-V6Ssh { 'battlegroup.igw.funcom.com/retail-test patched' }
        function Write-DuneJson { param($Response, $Body); $script:RouteResult = $Body }
        function Write-DuneError { param($Response, $Status, $Message); $script:RouteError = "$Status $Message" }
        $body = @{ revision = $revision; updates = @{ FiefdomLimit = '4' } } |
            ConvertTo-Json -Depth 4 |
            ConvertFrom-Json -AsHashtable

        & $put.handler $null $null @{} $body

        $script:RouteError | Should -BeNullOrEmpty
        $script:RouteResult.ok | Should -BeTrue
        ($script:RouteResult.settings | Where-Object key -eq 'FiefdomLimit').value | Should -Be '4'
        ($script:RouteResult.settings | Where-Object key -eq 'FiefdomLimit').valid | Should -BeTrue
        $updated | Should -Match '(?m)^FiefdomLimit=4 ; retained limit note\r?$'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1
        Should -Invoke Invoke-V6Ssh -Times 1
    }
}

Describe 'Official Retail Server Settings backups' -Tag 'GameConfig', 'RetailServerSettings' {
    It 'writes and verifies a timestamped full-content backup including an empty source' -ForEach @(
        @{ Empty = $false }
        @{ Empty = $true }
    ) {
        $raw = if ($Empty) { '' } else { $script:RetailRaw }
        $expected = Get-DuneRetailServerSettingsTextSha256 -Value $raw
        Mock Invoke-V6Ssh { "$expected  /srv/Config/LinuxServer/ServerCustomSettings.ini.dstbak-test" }

        $result = Backup-DuneRetailServerSettingsContent -Ip '192.0.2.10' -Target @{
            namespace = 'funcom-test'
            pod = 'retail-test-fb-deploy-abc'
            path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
        } -Raw $raw

        $result.sha256 | Should -Be $expected
        $result.path | Should -Match '\.dstbak-\d{8}-\d{9}$'
        Should -Invoke Invoke-V6Ssh -Times 1
    }
}

Describe 'Official Retail Windows PowerShell runtime' -Tag 'GameConfig', 'RetailServerSettings' {
    It 'preserves operator files through an actual Windows PowerShell 5.1 save' -Skip:(
        -not (Test-Path 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe')
    ) {
        $probe = @'
$ErrorActionPreference = 'Stop'
. (Join-Path $env:DST_REPO_ROOT 'app\server\lib\RetailServerSettings.ps1')
$script:document = [pscustomobject]@{
    metadata = [pscustomobject]@{ resourceVersion = '100' }
    spec = [pscustomobject]@{ serverGroup = [pscustomobject]@{
        template = [pscustomobject]@{ spec = [pscustomobject]@{
            global = [pscustomobject]@{ userIniConfig = [pscustomobject]@{
                mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                files = [pscustomobject]@{ 'UserGame.ini' = 'game'; 'UserEngine.ini' = '' }
                futureField = [pscustomobject]@{ items = @('one', 'two') }
            } }
        } }
    } }
}
function Get-DuneRetailServerSettingsSnapshot {
    @{
        available = $true; raw = ''
        revision = Get-DuneRetailServerSettingsTextSha256 -Value ''
        target = @{
            resourceVersion = '100'; stopped = $true; serverPodCount = 0
            namespace = 'test'; battlegroup = 'test'
        }
    }
}
function Get-V6Battlegroup { @{ Bg = $script:document } }
function Backup-DuneRetailServerSettingsContent { @{ path = 'mock-backup' } }
function Invoke-V6Ssh {
    param($Ip, $Cmd, $TimeoutSec, $StdinData)
    $ops = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData)) | ConvertFrom-Json
    if ($ops.Count -ne 2 -or $ops[0].op -ne 'test' -or $Cmd -notmatch '--patch-file=/dev/stdin') {
        throw 'Unexpected patch transport'
    }
    $script:document.spec.serverGroup.template.spec.global.userIniConfig = $ops[1].value
    $script:document.metadata.resourceVersion = '101'
    'battlegroup patched'
}
$result = Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ bAllowSandworms = 'false' } `
    -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '')
$saved = $script:document.spec.serverGroup.template.spec.global.userIniConfig
if (-not $result.ok -or $saved.files.'UserGame.ini' -cne 'game' -or
    $null -eq $saved.files.PSObject.Properties['UserEngine.ini'] -or
    $saved.files.'ServerCustomSettings.ini' -notmatch 'bAllowSandworms=False' -or
    $saved.futureField.items.Count -ne 2) { throw 'Windows PowerShell runtime preservation failed' }
'Windows PowerShell save passed'
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $output = & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match 'Windows PowerShell save passed'
    }
}

Describe 'Official Retail operator configuration preservation' -Tag 'GameConfig', 'RetailServerSettings' {
    BeforeAll {
        function Invoke-RetailTestJsonPatch {
            param([string]$Cmd, [string]$StdinData)
            $Cmd | Should -Match '--type=json'
            $Cmd | Should -Match '^base64 -d \| sudo kubectl patch .* --patch-file=/dev/stdin 2>&1$'
            $Cmd | Should -Not -Match '\becho\b|\s-p\s'
            $Cmd.Length | Should -BeLessThan 512
            $StdinData | Should -Not -BeNullOrEmpty
            $Cmd.Contains($StdinData) | Should -BeFalse
            $script:OperatorTransport.Add(@{ cmd = $Cmd; stdin = $StdinData })
            $operations = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($StdinData)) |
                ConvertFrom-Json -AsHashtable
            $operations.Count | Should -Be $(if ($script:OperatorPatches.Count -eq 0) { 2 } else { 3 })
            $operations[0].op | Should -BeExactly 'test'
            $operations[0].path | Should -BeExactly '/metadata/resourceVersion'
            if ($operations.Count -eq 3) {
                $operations[1].op | Should -BeExactly 'test'
                $operations[1].path | Should -BeExactly $operations[2].path
            }
            $script:OperatorPatches.Add($operations)
            foreach ($operation in $operations) {
                $segments = $operation.path.TrimStart('/').Split('/')
                $parent = $script:OperatorDocument
                for ($i = 0; $i -lt $segments.Count - 1; $i++) { $parent = $parent[$segments[$i]] }
                $key = $segments[-1]
                switch ($operation.op) {
                    'test' {
                        $actual = ConvertTo-Json -InputObject $parent[$key] -Depth 100 -Compress
                        $expected = ConvertTo-Json -InputObject $operation.value -Depth 100 -Compress
                        if (-not $parent.Contains($key) -or $actual -cne $expected) {
                            return "Error: JSON Patch test failed at $($operation.path)"
                        }
                    }
                    'add' { $parent[$key] = $operation.value }
                    'replace' {
                        $parent.Contains($key) | Should -BeTrue
                        $parent[$key] = $operation.value
                    }
                    'remove' {
                        $parent.Contains($key) | Should -BeTrue
                        $parent.Remove($key)
                    }
                    default { throw "Unexpected test patch operation $($operation.op)" }
                }
            }
            $script:OperatorDocument.metadata.resourceVersion = [string]([int]$script:OperatorDocument.metadata.resourceVersion + 1)
            return 'battlegroup.igw.funcom.com/retail-test patched'
        }
    }

    BeforeEach {
        $script:OperatorDocument = @{
            metadata = @{ resourceVersion = '100' }
            spec = @{ stop = $true; serverGroup = @{ template = @{ spec = [ordered]@{} } } }
        }
        $script:OperatorPatches = [Collections.Generic.List[object]]::new()
        $script:OperatorTransport = [Collections.Generic.List[object]]::new()
        $script:OperatorSource = ''
        $script:OperatorReads = 0
        $script:FailReadback = $false
        $script:OmitSiblingOnReadback = $false
        $script:ConcurrentBeforeRollbackRead = $false
        $script:ConcurrentAfterRollbackRead = $false
        $script:ConcurrentDocumentJson = $null
        Mock Get-DuneRetailServerSettingsSnapshot {
            @{
                available = $true
                raw = $script:OperatorSource
                revision = Get-DuneRetailServerSettingsTextSha256 -Value $script:OperatorSource
                target = @{
                    namespace = 'funcom-test'; battlegroup = 'retail-test'
                    pod = 'retail-test-fb-deploy-abc'
                    path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
                    resourceVersion = '100'; stopped = $true; serverPodCount = 0
                }
            }
        }
        Mock Backup-DuneRetailServerSettingsContent {
            @{ path = 'backup'; sha256 = 'backup'; timestamp = '1' }
        }
        Mock Get-V6Battlegroup {
            $script:OperatorReads++
            if ($script:OperatorReads -eq 3 -and $script:ConcurrentBeforeRollbackRead) {
                $script:OperatorDocument.spec.serverGroup.template.spec.global.userIniConfig.concurrentField = 'operator change'
                $script:OperatorDocument.metadata.resourceVersion = '102'
                $script:ConcurrentDocumentJson = $script:OperatorDocument | ConvertTo-Json -Depth 100 -Compress
            }
            $copy = $script:OperatorDocument | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            if ($script:OperatorReads -eq 2 -and $script:FailReadback) {
                $copy.spec.serverGroup.template.spec.global.userIniConfig.files.'ServerCustomSettings.ini' = 'readback mismatch'
            }
            if ($script:OperatorReads -eq 2 -and $script:OmitSiblingOnReadback) {
                $copy.spec.serverGroup.template.spec.global.userIniConfig.files.PSObject.Properties.Remove('UserEngine.ini')
            }
            @{ Bg = $copy }
        }
        Mock Invoke-V6Ssh {
            if ($script:OperatorPatches.Count -eq 1 -and $script:ConcurrentAfterRollbackRead) {
                $script:OperatorDocument.spec.serverGroup.template.spec.global.userIniConfig.concurrentField = 'operator change'
                $script:OperatorDocument.metadata.resourceVersion = '102'
                $script:ConcurrentDocumentJson = $script:OperatorDocument | ConvertTo-Json -Depth 100 -Compress
            }
            Invoke-RetailTestJsonPatch -Cmd $Cmd -StdinData $StdinData
        }
    }

    It 'preserves sibling files, unknown fields and the exact canonical mount spelling' -ForEach @(
        @{ Mount = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'; ExistingRetail = $false }
        @{ Mount = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer/'; ExistingRetail = $false }
        @{ Mount = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'; ExistingRetail = $true }
        @{ Mount = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer/'; ExistingRetail = $true }
    ) {
        $original = [ordered]@{
            mountPath = $Mount
            files = [ordered]@{ 'UserGame.ini' = "; game`n[Game]`nFoo=bar"; 'UserEngine.ini' = ''; 'Other.ini' = 'other' }
            futureField = [ordered]@{ mode = 'unchanged'; extra = @('one', 'two') }
        }
        $script:OperatorDocument.spec.serverGroup.template.spec.global = @{
            unrelatedGlobal = 'keep-me'; userIniConfig = $original
        }
        if ($ExistingRetail) {
            $script:OperatorSource = "; retained heading`n[$script:RetailSection]`nFiefdomLimit=3"
            $original.files['ServerCustomSettings.ini'] = $script:OperatorSource
        }
        $originalJson = $original | ConvertTo-Json -Depth 20 -Compress
        $result = Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value $script:OperatorSource)

        $actual = $script:OperatorDocument.spec.serverGroup.template.spec.global.userIniConfig
        $actual.mountPath | Should -BeExactly $Mount
        $actual.files.Count | Should -Be 4
        $actual.files['UserGame.ini'] | Should -BeExactly $original.files['UserGame.ini']
        $actual.files['UserEngine.ini'] | Should -BeExactly ''
        $actual.files['Other.ini'] | Should -BeExactly 'other'
        if ($ExistingRetail) { $actual.files['ServerCustomSettings.ini'] | Should -Match '(?m)^; retained heading$' }
        ($actual.futureField | ConvertTo-Json -Depth 10 -Compress) |
            Should -BeExactly ($original.futureField | ConvertTo-Json -Depth 10 -Compress)
        $script:OperatorDocument.spec.serverGroup.template.spec.global.unrelatedGlobal | Should -BeExactly 'keep-me'
        ($original | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $originalJson
        $result.target.upstreamMountPath | Should -BeExactly $Mount
        $script:OperatorPatches[0][1].op | Should -BeExactly 'replace'
        $script:OperatorPatches[0][1].path | Should -BeExactly '/spec/serverGroup/template/spec/global/userIniConfig'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1
    }

    It 'rejects incompatible or missing existing mount paths without backup or mutation' -ForEach @(
        @{ Mount = '/custom/config' }
        @{ Mount = '/srv/Config/LinuxServer' }
        @{ Mount = '/home/dune/server/DuneSandbox/Saved/Config/linuxserver' }
        @{ Mount = '' }
        @{ Mount = $null }
    ) {
        $original = [ordered]@{ files = @{ 'UserGame.ini' = 'keep-game'; 'UserEngine.ini' = 'keep-engine' } }
        if ($null -ne $Mount) { $original.mountPath = $Mount }
        $script:OperatorDocument.spec.serverGroup.template.spec.global = @{ userIniConfig = $original }
        $before = $script:OperatorDocument | ConvertTo-Json -Depth 20 -Compress
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') } |
            Should -Throw '*incompatible or missing mount path*'
        ($script:OperatorDocument | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 0
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'initializes absent or null fields and restores their exact original state on failed readback' -ForEach @(
        @{ State = 'global-absent'; Fail = $false }
        @{ State = 'global-null'; Fail = $false }
        @{ State = 'user-absent'; Fail = $false }
        @{ State = 'user-null'; Fail = $false }
        @{ State = 'global-absent'; Fail = $true }
        @{ State = 'global-null'; Fail = $true }
        @{ State = 'user-absent'; Fail = $true }
        @{ State = 'user-null'; Fail = $true }
        @{ State = 'siblings-only'; Fail = $true }
        @{ State = 'existing-retail'; Fail = $true }
        @{ State = 'files-absent'; Fail = $false }
        @{ State = 'files-null'; Fail = $false }
        @{ State = 'files-absent'; Fail = $true }
        @{ State = 'files-null'; Fail = $true }
    ) {
        $group = $script:OperatorDocument.spec.serverGroup.template.spec
        switch ($State) {
            'global-null' { $group.global = $null }
            'user-absent' { $group.global = [ordered]@{ unrelatedGlobal = 'keep-me' } }
            'user-null' { $group.global = [ordered]@{ unrelatedGlobal = 'keep-me'; userIniConfig = $null } }
            { $_ -in @('files-absent', 'files-null') } {
                $group.global = [ordered]@{
                    userIniConfig = [ordered]@{ mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer' }
                }
                if ($State -eq 'files-null') { $group.global.userIniConfig.files = $null }
            }
            { $_ -in @('siblings-only', 'existing-retail') } {
                $files = [ordered]@{ 'UserGame.ini' = 'game'; 'UserEngine.ini' = 'engine' }
                if ($State -eq 'existing-retail') {
                    $script:OperatorSource = '; original retail'
                    $files['ServerCustomSettings.ini'] = $script:OperatorSource
                }
                $group.global = [ordered]@{
                    unrelatedGlobal = 'keep-me'
                    userIniConfig = [ordered]@{
                        mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                        files = $files
                        futureField = 'preserve'
                    }
                }
            }
        }
        $before = $group | ConvertTo-Json -Depth 20 -Compress
        $script:FailReadback = $Fail
        $action = {
            Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
                -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value $script:OperatorSource)
        }
        if ($Fail) {
            $action | Should -Throw '*original operator configuration was restored*'
            ($group | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
            $script:OperatorPatches.Count | Should -Be 2
            $script:OperatorPatches[1][0].value | Should -BeExactly '101'
            $script:OperatorPatches[1][2].op | Should -BeExactly $(if ($State -in @('global-absent', 'user-absent')) { 'remove' } else { 'replace' })
        } else {
            (& $action).ok | Should -BeTrue
            $group.global.userIniConfig.files['ServerCustomSettings.ini'] | Should -Match 'FiefdomLimit=4'
            $script:OperatorPatches.Count | Should -Be 1
        }
        $script:OperatorPatches[0][1].op | Should -BeExactly $(if ($State -in @('global-absent', 'user-absent')) { 'add' } else { 'replace' })
    }

    It 'rolls back if readback drops an empty sibling file instead of treating absence as empty content' {
        $group = $script:OperatorDocument.spec.serverGroup.template.spec
        $group.global = [ordered]@{
            userIniConfig = [ordered]@{
                mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                files = [ordered]@{ 'UserGame.ini' = 'game'; 'UserEngine.ini' = '' }
            }
        }
        $before = $group | ConvertTo-Json -Depth 20 -Compress
        $script:OmitSiblingOnReadback = $true
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') } |
            Should -Throw '*did not preserve all configured files*'
        ($group | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly $before
    }

    It 'refuses rollback rather than overwriting a concurrent change to our patched field' -ForEach @(
        @{ ExistingGlobal = $true; Timing = 'before-read' }
        @{ ExistingGlobal = $false; Timing = 'before-read' }
        @{ ExistingGlobal = $true; Timing = 'after-read' }
        @{ ExistingGlobal = $false; Timing = 'after-read' }
    ) {
        $group = $script:OperatorDocument.spec.serverGroup.template.spec
        if ($ExistingGlobal) {
            $group.global = [ordered]@{
                unrelatedGlobal = 'unchanged'
                userIniConfig = [ordered]@{
                    mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                    files = [ordered]@{ 'UserGame.ini' = 'game'; 'UserEngine.ini' = 'engine' }
                }
            }
        }
        $script:FailReadback = $true
        $script:ConcurrentBeforeRollbackRead = $Timing -eq 'before-read'
        $script:ConcurrentAfterRollbackRead = $Timing -eq 'after-read'
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') } |
            Should -Throw '*rollback also failed or was refused*JSON Patch test failed*'

        ($script:OperatorDocument | ConvertTo-Json -Depth 100 -Compress) |
            Should -BeExactly $script:ConcurrentDocumentJson
        $group.global.userIniConfig.concurrentField | Should -BeExactly 'operator change'
        $group.global.userIniConfig.files['ServerCustomSettings.ini'] | Should -Match 'FiefdomLimit=4'
        $script:OperatorPatches.Count | Should -Be 2
        $script:OperatorPatches[1][1].path | Should -BeExactly $(if ($ExistingGlobal) {
            '/spec/serverGroup/template/spec/global/userIniConfig'
        } else { '/spec/serverGroup/template/spec/global' })
        $script:OperatorDocument.metadata.resourceVersion | Should -BeExactly '102'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1
    }

    It 'streams large forward and rollback patches through stdin without command-line payloads' {
        $group = $script:OperatorDocument.spec.serverGroup.template.spec
        $game = ("; game setting 'quoted'`r`nFoo=$([char]0x03B1)`r`n" * 4000)
        $engine = ("; engine setting`nBar=unchanged`n" * 4000)
        $group.global = [ordered]@{
            userIniConfig = [ordered]@{
                mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                files = [ordered]@{ 'UserGame.ini' = $game; 'UserEngine.ini' = $engine }
            }
        }
        $before = $group | ConvertTo-Json -Depth 100 -Compress
        $script:FailReadback = $true
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value '') } |
            Should -Throw '*original operator configuration was restored*'

        $script:OperatorTransport.Count | Should -Be 2
        foreach ($transport in $script:OperatorTransport) {
            $transport.stdin.Length | Should -BeGreaterThan 100000
            $transport.cmd.Length | Should -BeLessThan 512
            $transport.cmd.Contains($game) | Should -BeFalse
            $transport.cmd.Contains($engine) | Should -BeFalse
        }
        $script:OperatorTransport[1].cmd | Should -BeExactly $script:OperatorTransport[0].cmd
        ($group | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $before
        Should -Invoke Invoke-V6Ssh -Times 2 -ParameterFilter { $StdinData.Length -gt 100000 }
    }
}

Describe 'Official Retail Server Settings writes' -Tag 'GameConfig', 'RetailServerSettings' {
    BeforeEach {
        $script:PatchCount = 0
        $script:WriteSourceRaw = $script:RetailRaw
        Mock Get-DuneRetailServerSettingsSnapshot {
            @{
                available = $true
                source = 'funcom-servergroup-user-ini-config'
                raw = $script:WriteSourceRaw
                revision = Get-DuneRetailServerSettingsTextSha256 -Value $script:WriteSourceRaw
                target = @{
                    namespace = 'funcom-test'
                    battlegroup = 'retail-test'
                    pod = 'retail-test-fb-deploy-abc'
                    path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
                    resourceVersion = '100'
                    stopped = $true
                    serverPodCount = 0
                }
            }
        }
        Mock Backup-DuneRetailServerSettingsContent {
            @{ path = '/srv/Config/LinuxServer/ServerCustomSettings.ini.dstbak-1'; sha256 = 'backup'; timestamp = '1' }
        }
        Mock Invoke-V6Ssh {
            $script:PatchCount++
            'battlegroup.igw.funcom.com/retail-test patched'
        }
    }

    It 'rejects a stale expected revision before backup or patch' {
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } -ExpectedRevision 'stale' } |
            Should -Throw '*changed since*'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 0
        Should -Invoke Invoke-V6Ssh -Times 0
    }

    It 'rejects writes until the battlegroup is fully stopped' {
        Mock Get-DuneRetailServerSettingsSnapshot {
            @{
                available = $true
                source = 'funcom-servergroup-user-ini-config'
                raw = $script:RetailRaw
                revision = 'current'
                target = @{ stopped = $false; serverPodCount = 1 }
            }
        }
        { Set-DuneRetailServerSettings -Ip '192.0.2.10' -Updates @{ FiefdomLimit = '4' } -ExpectedRevision 'current' } |
            Should -Throw '*Stop the battlegroup fully*'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 0
    }

    It 'backs up, patches the operator field, and verifies exact readback including initialization' -ForEach @(
        @{ Empty = $false }
        @{ Empty = $true }
    ) {
        if ($Empty) { $script:WriteSourceRaw = '' }
        $script:UpdatedRetailRaw = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:WriteSourceRaw -Updates @{ FiefdomLimit = '4' }
        $script:BgRead = 0
        Mock Get-V6Battlegroup {
            $script:BgRead++
            $content = if ($script:BgRead -eq 1) { $script:WriteSourceRaw } else { $script:UpdatedRetailRaw }
            @{
                Ns = 'funcom-test'
                Name = 'retail-test'
                Bg = [pscustomobject]@{
                    metadata = [pscustomobject]@{ resourceVersion = "$($script:BgRead + 99)" }
                    spec = [pscustomobject]@{
                        stop = $true
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{
                                    global = [pscustomobject]@{
                                        userIniConfig = [pscustomobject]@{
                                            mountPath = '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer'
                                            files = [pscustomobject]@{ 'ServerCustomSettings.ini' = $content }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        $result = Set-DuneRetailServerSettings -Ip '192.0.2.10' `
            -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value $script:WriteSourceRaw)

        $result.ok | Should -BeTrue
        $result.restartRequired | Should -BeTrue
        $result.backup.path | Should -Match '\.dstbak-'
        ($result.settings | Where-Object key -eq 'FiefdomLimit').value | Should -Be '4'
        ($result.settings | Where-Object key -eq 'FiefdomLimit').present | Should -BeTrue
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1 -ParameterFilter { $Raw -ceq $script:WriteSourceRaw }
        Should -Invoke Invoke-V6Ssh -Times 1 -ParameterFilter { $Cmd -like '*kubectl patch battlegroup*' }
    }

    It 'restores the original operator configuration when exact readback fails' {
        $script:BgRead = 0
        Mock Get-V6Battlegroup {
            $script:BgRead++
            @{
                Ns = 'funcom-test'
                Name = 'retail-test'
                Bg = [pscustomobject]@{
                    metadata = [pscustomobject]@{ resourceVersion = "$($script:BgRead + 99)" }
                    spec = [pscustomobject]@{
                        stop = $true
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{ global = $null }
                            }
                        }
                    }
                }
            }
        }

        { Set-DuneRetailServerSettings -Ip '192.0.2.10' `
            -Updates @{ FiefdomLimit = '4' } `
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value $script:RetailRaw) } |
            Should -Throw '*original operator configuration was restored*'
        Should -Invoke Invoke-V6Ssh -Times 2
    }
}
