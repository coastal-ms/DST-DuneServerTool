BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RetailServerSettings.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\lib\K8s.ps1')
    function global:Invoke-V6Ssh { param($Ip, $Cmd, $TimeoutSec) }

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
    It 'covers the complete current 47-key Retail catalogue' {
        (Get-DuneRetailServerSettingKeyMap).Count | Should -Be 47
    }

    It 'types all current values and keeps unknown keys read-only' {
        $result = ConvertFrom-DuneRetailServerSettingsRaw -Raw $script:RetailRaw

        $result.sectionFound | Should -BeTrue
        @($result.settings).Count | Should -Be 7
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

        $restrictions.label | Should -Be 'Area Building Restrictions'
        $restrictions.displayValue | Should -Be 'Enabled'
        $stability.label | Should -Be 'Building Stability Limits'
        $stability.inverted | Should -BeTrue
        $stability.value | Should -Be 'False'
        $stability.displayValue | Should -Be 'Enabled'
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
        @($result.settings).Count | Should -Be 0
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

        $updated | Should -Match '(?m)^; retained heading$'
        $updated | Should -Match '(?m)^FutureRetailKey=keep-me$'
        $updated | Should -Match '(?m)^bIsBuildingRestrictionsEnabled=False$'
        $updated | Should -Match '(?m)^FiefdomLimit=4$'
        $updated | Should -Match '(?m)^OtherKey=OtherValue$'
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

    It 'discovers the Funcom File Browser Saved-PVC projection and reads the complete file' {
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
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:RetailRaw))
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
        @($result.settings).Count | Should -Be 7
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
        $revision = Get-DuneRetailServerSettingsTextSha256 -Value $script:RetailRaw
        $updated = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:RetailRaw -Updates @{ FiefdomLimit = '4' }
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
                upstreamContent = $script:RetailRaw
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
            $content = if ($script:RouteBgRead -eq 1) { $script:RetailRaw } else { $updated }
            @{
                Bg = [pscustomobject]@{
                    metadata = [pscustomobject]@{ resourceVersion = "$($script:RouteBgRead + 99)" }
                    spec = [pscustomobject]@{
                        serverGroup = [pscustomobject]@{
                            template = [pscustomobject]@{
                                spec = [pscustomobject]@{
                                    global = [pscustomobject]@{
                                        userIniConfig = [pscustomobject]@{
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
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1
        Should -Invoke Invoke-V6Ssh -Times 1
    }
}

Describe 'Official Retail Server Settings backups' -Tag 'GameConfig', 'RetailServerSettings' {
    It 'writes and verifies a timestamped full-content backup' {
        $expected = Get-DuneRetailServerSettingsTextSha256 -Value $script:RetailRaw
        Mock Invoke-V6Ssh { "$expected  /srv/Config/LinuxServer/ServerCustomSettings.ini.dstbak-test" }

        $result = Backup-DuneRetailServerSettingsContent -Ip '192.0.2.10' -Target @{
            namespace = 'funcom-test'
            pod = 'retail-test-fb-deploy-abc'
            path = '/srv/Config/LinuxServer/ServerCustomSettings.ini'
        } -Raw $script:RetailRaw

        $result.sha256 | Should -Be $expected
        $result.path | Should -Match '\.dstbak-\d{8}-\d{9}$'
        Should -Invoke Invoke-V6Ssh -Times 1
    }
}

Describe 'Official Retail Server Settings writes' -Tag 'GameConfig', 'RetailServerSettings' {
    BeforeEach {
        $script:PatchCount = 0
        Mock Get-DuneRetailServerSettingsSnapshot {
            @{
                available = $true
                source = 'funcom-servergroup-user-ini-config'
                raw = $script:RetailRaw
                revision = Get-DuneRetailServerSettingsTextSha256 -Value $script:RetailRaw
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

    It 'backs up, patches the operator field, and verifies exact readback' {
        $script:UpdatedRetailRaw = ConvertTo-DuneRetailServerSettingsUpdatedRaw -Raw $script:RetailRaw -Updates @{ FiefdomLimit = '4' }
        $script:BgRead = 0
        Mock Get-V6Battlegroup {
            $script:BgRead++
            $content = if ($script:BgRead -eq 1) { $script:RetailRaw } else { $script:UpdatedRetailRaw }
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
            -ExpectedRevision (Get-DuneRetailServerSettingsTextSha256 -Value $script:RetailRaw)

        $result.ok | Should -BeTrue
        $result.restartRequired | Should -BeTrue
        $result.backup.path | Should -Match '\.dstbak-'
        ($result.settings | Where-Object key -eq 'FiefdomLimit').value | Should -Be '4'
        Should -Invoke Backup-DuneRetailServerSettingsContent -Times 1
        Should -Invoke Invoke-V6Ssh -Times 1
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
