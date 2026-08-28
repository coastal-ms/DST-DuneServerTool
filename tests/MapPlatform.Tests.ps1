BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'ApiContract.ps1'
    Import-DstLib 'PlatformRuntime.ps1'
    Import-DstLib 'PlatformCache.ps1'
    Import-DstLib 'MapPlatform.ps1'

    function global:New-MapPlatformActiveResult {
        param(
            [ValidateSet('ready','partial')][string]$Status = 'ready',
            [int]$Count = 1,
            [bool]$Truncated = $false
        )
        $observedAt = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
        $fields = @(1..$Count | ForEach-Object {
            [ordered]@{
                fieldId = [string](100 + $_)
                map = 'DeepDesert'
                dimensionIndex = 0
                fieldKindId = 1
                state = 'active'
                spawnTime = 605236.5
                valueRemaining = 150000
                position = [ordered]@{
                    status = 'unresolved'
                    coordinateSystem = $null
                    x = $null
                    y = $null
                    z = $null
                    reason = 'No independently verified coordinate columns are available.'
                }
            }
        })
        return [ordered]@{
            ok = $true
            status = $Status
            fields = $fields
            observations = @()
            historyStatus = 'current-observation-only'
            totalAvailable = if ($Truncated) { $Count + 5 } else { $Count }
            returned = $Count
            truncated = $Truncated
            partialReasons = @($(if ($Truncated) { 'row-limit' }))
            freshness = [ordered]@{
                state = 'fresh'
                observedAt = $observedAt
                ageSeconds = 5
                staleAfterSec = 60
            }
            source = [ordered]@{
                schemaFingerprint = ('a' * 64)
                spatialStatus = 'unresolved'
            }
        }
    }

    function global:ConvertTo-MapPlatformSnapshot {
        param([Parameter(Mandatory)]$Generation)
        return [ordered]@{
            generation = $Generation.generation
            hydratedAt = [DateTime]::UtcNow.ToString('o')
            sources = @($Generation.sources)
            maps = @($Generation.maps)
            layers = @($Generation.layers)
            activeSpice = @($Generation.activeSpiceCurrent)
            activeSpiceHistory = @($Generation.activeSpiceHistory)
            publicPois = @($Generation.publicPois)
        }
    }
}

AfterAll {
    Remove-Item function:global:New-MapPlatformActiveResult -ErrorAction SilentlyContinue
    Remove-Item function:global:ConvertTo-MapPlatformSnapshot -ErrorAction SilentlyContinue
}

Describe 'Maps platform cache generation' -Tag 'MapPlatform' {
    BeforeEach {
        $script:DunePlatformSnapshotState = $null
        $script:DuneApiLockTable = [Collections.Hashtable]::Synchronized(@{})
    }

    It 'projects the active-spice source into one coherent bounded generation' {
        Mock Invoke-DunePlatformSourceRead {
            [pscustomobject]@{ active = New-MapPlatformActiveResult }
        }

        $generation = New-DuneMapsPlatformGeneration -Ip '192.0.2.1'

        @($generation.maps).Count | Should -Be 1
        @($generation.layers).Count | Should -Be 2
        @($generation.activeSpiceCurrent).Count | Should -Be 1
        @($generation.activeSpiceHistory).Count | Should -Be 1
        $generation.activeSpiceCurrent[0].coordinateSpace | Should -Be 'none'
        $generation.activeSpiceCurrent[0].x | Should -BeNullOrEmpty
        $generation.layers[0].freshnessState | Should -Be 'fresh'
        $generation.layers[0].rowCount | Should -Be 1
        $generation.layers[1].freshnessState | Should -Be 'unavailable'
        $generation.layers[1].lastErrorCode | Should -Be 'privacy-proof-unavailable'
        @($generation.publicPois).Count | Should -Be 0
        ($generation | ConvertTo-Json -Depth 12 -Compress).Length | Should -BeLessThan (5MB)
    }

    It 'preserves partial and truncation state instead of presenting complete success' {
        Mock Invoke-DunePlatformSourceRead {
            [pscustomobject]@{
                active = New-MapPlatformActiveResult -Status partial -Count 2 -Truncated $true
            }
        }

        $generation = New-DuneMapsPlatformGeneration -Ip '192.0.2.1'

        $generation.layers[0].freshnessState | Should -Be 'partial'
        $generation.layers[0].truncated | Should -BeTrue
        $generation.layers[0].rowCount | Should -Be 2
    }

    It 'retains prior rows as stale when the database or schema is unavailable' {
        $prior = [ordered]@{
            maps = @([ordered]@{
                farmId = 'local-farm'; mapId = 'deep-desert'; partitionId = 'current'
                label = 'Deep Desert'; kind = 'deep-desert'
                lastSeenAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); active = $true
            })
            layers = @([ordered]@{
                layerId = 'active-spice'
                observedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
                expiresAt = [DateTime]::UtcNow.AddMinutes(-4).ToString('o')
                truncated = $false
            })
            activeSpice = @([ordered]@{
                farmId = 'local-farm'; mapId = 'deep-desert'; partitionId = 'current'
                fieldId = '101'; state = 'active'; coordinateSpace = 'none'
                x = $null; y = $null; sourceFingerprint = ('b' * 64)
                observedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
                expiresAt = [DateTime]::UtcNow.AddMinutes(-4).ToString('o')
            })
        }

        foreach ($errorCode in @('source-unavailable','unsupported-schema')) {
            $generation = New-DuneMapsPlatformGeneration `
                -PreviousSnapshot $prior `
                -SourceErrorCode $errorCode
            @($generation.activeSpiceCurrent).Count | Should -Be 1
            $generation.layers[0].freshnessState | Should -Be 'stale'
            $generation.layers[0].lastErrorCode | Should -Be $errorCode
            $generation.layers[0].rowCount | Should -Be 1
        }
    }

    It 'never converts an unavailable source with no fallback into fresh empty success' {
        $generation = New-DuneMapsPlatformGeneration -SourceErrorCode 'source-read-failed'

        $generation.layers[0].freshnessState | Should -Be 'unavailable'
        $generation.layers[0].lastErrorCode | Should -Be 'source-read-failed'
        @($generation.activeSpiceCurrent).Count | Should -Be 0
    }

    It 'retains a successful empty observation as stale after a failed refresh' {
        $prior = [ordered]@{
            layers = @([ordered]@{
                layerId = 'active-spice'
                freshnessState = 'fresh'
                observedAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
                expiresAt = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
                truncated = $false
            })
            activeSpice = @()
        }

        $generation = New-DuneMapsPlatformGeneration `
            -PreviousSnapshot $prior `
            -SourceErrorCode 'source-read-failed'

        $generation.layers[0].freshnessState | Should -Be 'stale'
        $generation.layers[0].rowCount | Should -Be 0
        $generation.layers[0].lastErrorCode | Should -Be 'source-read-failed'
    }

    It 'keeps the startup cadence within 15 seconds plus or minus ten percent' {
        (Get-DuneMapsRefreshDelaySec -Sample 0) | Should -Be 13.5
        (Get-DuneMapsRefreshDelaySec -Sample 0.5) | Should -Be 15
        (Get-DuneMapsRefreshDelaySec -Sample 1) | Should -Be 16.5
        $script:DuneMapsActiveSpiceStaleAfterSec | Should -Be 60
    }

    It 'repeats refreshes until cancellation and survives a failed attempt' {
        $cancellation = [Threading.CancellationTokenSource]::new()
        $state = [Collections.Hashtable]::Synchronized(@{ attempts = 0; successes = 0 })
        try {
            $attempts = Invoke-DuneMapsPlatformRefreshLoop `
                -CancellationToken $cancellation.Token `
                -InitialDelaySec 0 `
                -NextDelay { 0.01 } `
                -Refresh ({
                    $state.attempts++
                    if ($state.attempts -eq 1) { throw 'transient fixture failure' }
                    $state.successes++
                    $cancellation.Cancel()
                }.GetNewClosure())

            $attempts | Should -Be 2
            $state.attempts | Should -Be 2
            $state.successes | Should -Be 1
        } finally {
            $cancellation.Dispose()
        }
    }

    It 'does not schedule before the active source backoff window' {
        $table = Get-DunePlatformCoordinationTable
        $table["platform-backoff:$script:DuneMapsActiveSpiceSourceKey"] = [pscustomobject]@{
            nextAttemptAt = [DateTime]::UtcNow.AddSeconds(90)
        }
        try {
            (Get-DuneMapsScheduledRefreshDelaySec -Sample 0) | Should -BeGreaterThan 85
        } finally {
            [void]$table.Remove("platform-backoff:$script:DuneMapsActiveSpiceSourceKey")
        }
    }

    It 'drops non-Deep-Desert rows rather than relabeling them' {
        $source = New-MapPlatformActiveResult
        $source.fields += [ordered]@{
            fieldId = '999'
            map = 'HaggaBasin'
            state = 'active'
            position = [ordered]@{ status = 'unresolved' }
        }

        $rows = @(ConvertTo-DuneMapsActiveSpiceCacheRows -Result $source)

        $rows.Count | Should -Be 1
        $rows[0].fieldId | Should -Be '101'
    }
}

Describe 'Maps v1 cached API contracts' -Tag 'MapPlatform' {
    BeforeEach {
        $script:DunePlatformSnapshotState = $null
        Mock Invoke-DunePlatformSourceRead {
            [pscustomobject]@{ active = New-MapPlatformActiveResult }
        }
        $generation = New-DuneMapsPlatformGeneration -Ip '192.0.2.1'
        $snapshot = ConvertTo-MapPlatformSnapshot $generation
        $null = Set-DunePlatformSnapshot -Snapshot $snapshot
    }

    It 'carries active spice from source projection through cache and aggregate API' {
        $response = Get-DuneDeepDesertMapResponse -RequestId 'request-1'
        $active = @($response.data.layers | Where-Object layerId -eq 'active-spice')[0]
        $poi = @($response.data.layers | Where-Object layerId -eq 'public-poi')[0]

        $response.schemaVersion | Should -Be 1
        $response.capabilities | Should -Contain 'map.live-cache'
        $active.source | Should -Be 'cache'
        $active.count | Should -Be 1
        $active.data.summary.activeCount | Should -Be 1
        $active.data.summary.spatialStatus | Should -Be 'unresolved'
        $active.data.items[0].position.status | Should -Be 'unresolved'
        $active.data.items[0].position.x | Should -BeNullOrEmpty
        $poi.source | Should -Be 'unavailable'
        $poi.error.code | Should -Be 'privacy-proof-unavailable'
    }

    It 'serves catalog and layer responses without a source or helper invocation' {
        (Get-Command Get-DuneMapsCatalogResponse).Definition | Should -Not -Match 'Invoke-DunePlatformSourceRead'
        (Get-Command Get-DuneDeepDesertMapResponse).Definition | Should -Not -Match 'Invoke-DunePlatformSourceRead'
        (Get-Command Get-DuneDeepDesertLayerResponse).Definition | Should -Not -Match 'Invoke-DunePlatformHelper'

        $catalog = Get-DuneMapsCatalogResponse -RequestId 'request-2'
        $layer = Get-DuneDeepDesertLayerResponse -RequestId 'request-3' -LayerId active-spice
        @($catalog.data.maps).Count | Should -Be 1
        $layer.source | Should -Be 'cache'
        $layer.data.layerId | Should -Be 'active-spice'
        $layer.data.data.items[0].fieldId | Should -Be '101'
    }

    It 'preserves the complete active-spice layer envelope on its layer endpoint' {
        $response = Get-DuneDeepDesertLayerResponse `
            -RequestId 'active-layer-contract' `
            -LayerId active-spice

        @($response.data.Keys | Sort-Object) | Should -Be @(
            'count', 'data', 'error', 'freshness', 'layerId', 'page', 'source'
        )
        $response.data.layerId | Should -Be 'active-spice'
        $response.data.source | Should -Be 'cache'
        $response.data.count | Should -Be 1
        $response.data.error | Should -BeNullOrEmpty
        $response.data.freshness.state | Should -Be 'fresh'
        $response.data.page.limit | Should -Be 200
        $response.data.page.truncated | Should -BeFalse
        $response.data.data.summary.activeCount | Should -Be 1
        $response.data.data.items[0].fieldId | Should -Be '101'
    }

    It 'preserves unavailable error and count metadata on the public-POI layer endpoint' {
        $response = Get-DuneDeepDesertLayerResponse `
            -RequestId 'poi-layer-contract' `
            -LayerId public-poi

        @($response.data.Keys | Sort-Object) | Should -Be @(
            'count', 'data', 'error', 'freshness', 'layerId', 'page', 'source'
        )
        $response.source | Should -Be 'unavailable'
        $response.data.layerId | Should -Be 'public-poi'
        $response.data.source | Should -Be 'unavailable'
        $response.data.count | Should -Be 0
        $response.data.freshness.state | Should -Be 'unavailable'
        $response.data.freshness.lastErrorCode | Should -Be 'privacy-proof-unavailable'
        $response.data.error.code | Should -Be 'privacy-proof-unavailable'
        $response.data.error.message | Should -Match 'cannot prove'
        $response.data.page.truncated | Should -BeFalse
        @($response.data.data).Count | Should -Be 0
    }

    It 'marks an expired cached layer stale on every response' {
        $snapshot = (Get-DunePlatformSnapshot).snapshot
        $mutable = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $mutable.layers[0].freshnessState = 'fresh'
        $mutable.layers[0].observedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
        $mutable.layers[0].expiresAt = [DateTime]::UtcNow.AddMinutes(-4).ToString('o')
        $null = Set-DunePlatformSnapshot -Snapshot $mutable

        (Get-DuneDeepDesertMapResponse -RequestId 'expired').data.layers[0].freshness.state |
            Should -Be 'stale'
    }

    It 'keeps the maximum active-spice API payload below the planned bound' {
        Mock Invoke-DunePlatformSourceRead {
            [pscustomobject]@{ active = New-MapPlatformActiveResult -Count 200 }
        }
        $generation = New-DuneMapsPlatformGeneration -Ip '192.0.2.1'
        $null = Set-DunePlatformSnapshot -Snapshot (ConvertTo-MapPlatformSnapshot $generation)

        $json = Get-DuneDeepDesertMapResponse -RequestId 'payload-bound' |
            ConvertTo-Json -Depth 12 -Compress
        [Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessThan (256KB)
    }

    It 'hydrates persisted state before scheduling the recurring startup refresh' {
        $entrypoint = Get-Content (Join-Path (Get-DstRepoRoot) 'app\DuneServer.ps1') -Raw
        $hydrate = $entrypoint.IndexOf('Initialize-DunePlatformCache')
        $refresh = $entrypoint.IndexOf('Start-DuneMapsPlatformStartupRefresh')
        $routes = $entrypoint.IndexOf('# Auto-load all route files')

        $hydrate | Should -BeGreaterOrEqual 0
        $refresh | Should -BeGreaterThan $hydrate
        $routes | Should -BeGreaterThan $refresh
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Match 'MapsRefreshRunner'
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Match 'CancellationTokenSource'
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Match 'DuneLog\.ps1'
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Match 'Set-DuneLogPath'
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Match 'DuneMapsRefreshCompletion'
        (Get-Command Start-DuneMapsPlatformStartupRefresh).Definition | Should -Not -Match 'BeginInvoke'
        (Get-Command Stop-DuneMapsPlatformRefresh).Definition | Should -Match 'BeginStop'
        (Get-Command Stop-DuneMapsPlatformRefresh).Definition | Should -Not -Match '\.Stop\('
        $entrypoint | Should -Match 'Stop-DuneMapsPlatformRefresh'
        $entrypoint.IndexOf('Stop-DuneMapsPlatformRefresh') |
            Should -BeLessThan $entrypoint.LastIndexOf('Stop-DuneHttpServer')
    }

    It 'cancels, awaits, and disposes a completed refresh scheduler' {
        $cancellation = [Threading.CancellationTokenSource]::new()
        $token = $cancellation.Token
        $completion = [Threading.ManualResetEventSlim]::new($true)
        $script:DuneMapsRefreshCancellation = $cancellation
        $script:DuneMapsRefreshCompletion = $completion
        $script:DuneMapsRefreshPowerShell = $null
        $script:DuneMapsStartupRefreshStarted = $true

        (Stop-DuneMapsPlatformRefresh -WaitMs 10) | Should -BeTrue

        $token.IsCancellationRequested | Should -BeTrue
        $script:DuneMapsStartupRefreshStarted | Should -BeFalse
        $script:DuneMapsRefreshCancellation | Should -BeNullOrEmpty
        $script:DuneMapsRefreshCompletion | Should -BeNullOrEmpty
    }

    It 'registers only additive read-only v1 map routes' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Maps.ps1') -Raw
        foreach ($path in @(
            '/api/v1/maps/catalog',
            '/api/v1/maps/deep-desert',
            '/api/v1/maps/deep-desert/layers/{layer}'
        )) {
            $source | Should -Match "Register-DuneRoute -Method GET -Path '$([regex]::Escape($path))'"
        }
        $source | Should -Not -Match "Register-DuneRoute -Method POST -Path '/api/v1/maps"
    }

    It 'keeps cached live Maps explicitly unavailable on Linux' {
        $catalog = Get-DuneMapsCatalogResponse -RequestId 'linux-catalog' -RuntimePlatform linux
        $map = Get-DuneDeepDesertMapResponse -RequestId 'linux-map' -RuntimePlatform linux
        $layer = Get-DuneDeepDesertLayerResponse `
            -RequestId 'linux-layer' `
            -LayerId active-spice `
            -RuntimePlatform linux

        $catalog.source | Should -Be 'unavailable'
        $catalog.capabilities | Should -BeNullOrEmpty
        $catalog.data.health.cache.lastErrorCode | Should -Be 'live-cache-unsupported'
        $map.source | Should -Be 'unavailable'
        $map.capabilities | Should -BeNullOrEmpty
        @($map.data.layers | Where-Object source -ne 'unavailable').Count | Should -Be 0
        @($map.data.layers | Where-Object { $_.freshness.state -eq 'fresh' }).Count | Should -Be 0
        $map.data.layers[0].error.code | Should -Be 'live-cache-unsupported'
        $layer.source | Should -Be 'unavailable'
        $layer.data.error.code | Should -Be 'live-cache-unsupported'
        (Invoke-DuneMapsPlatformRefresh -RuntimePlatform linux).reasonCode |
            Should -Be 'live-cache-unsupported'
        (Start-DuneMapsPlatformStartupRefresh `
            -ServerDir (Join-Path (Get-DstRepoRoot) 'app\server') `
            -RuntimePlatform linux) | Should -BeFalse
    }

    It 'replaces a stale persisted snapshot with a fresh source generation through the helper' {
        $priorLocalAppData = $env:LOCALAPPDATA
        $priorSelfTest = $env:DST_PLATFORM_SELF_TEST
        $testRoot = Join-Path ([IO.Path]::GetTempPath()) "dst-map-platform-$([guid]::NewGuid().ToString('N'))"
        try {
            $env:LOCALAPPDATA = $testRoot
            $env:DST_PLATFORM_SELF_TEST = '1'
            $script:DunePlatformSnapshotState = $null
            $null = Invoke-DunePlatformHelper -Command migrate
            $stale = New-DuneMapsPlatformGeneration -SourceErrorCode 'source-unavailable'
            $null = Invoke-DunePlatformGenerationReplace -Generation $stale
            (Get-DuneDeepDesertMapResponse -RequestId 'stale').data.layers[0].freshness.state |
                Should -Be 'unavailable'

            Mock Invoke-DunePlatformSourceRead {
                [pscustomobject]@{ active = New-MapPlatformActiveResult }
            }
            $fresh = New-DuneMapsPlatformGeneration `
                -Ip '192.0.2.1' `
                -PreviousSnapshot (Get-DunePlatformSnapshot).snapshot
            $null = Invoke-DunePlatformGenerationReplace -Generation $fresh
            $response = Get-DuneDeepDesertMapResponse -RequestId 'fresh'

            $response.data.layers[0].freshness.state | Should -Be 'fresh'
            $response.data.layers[0].count | Should -Be 1
            @((Get-DunePlatformSnapshot).snapshot['activeSpiceHistory']).Count | Should -BeGreaterOrEqual 1
        } finally {
            $env:LOCALAPPDATA = $priorLocalAppData
            $env:DST_PLATFORM_SELF_TEST = $priorSelfTest
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
