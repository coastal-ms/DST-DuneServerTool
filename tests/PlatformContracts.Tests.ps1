BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    Import-DstLib 'ApiContract.ps1'
    Import-DstLib 'RequestPrincipal.ps1'
    Import-DstLib 'PlatformRuntime.ps1'
    Import-DstLib 'Capabilities.ps1'

    function Get-PlatformRouteRecords {
        $records = @()
        $routesRoot = Join-Path (Get-DstRepoRoot) 'app\server\routes'
        foreach ($file in Get-ChildItem -LiteralPath $routesRoot -Filter '*.ps1' | Sort-Object Name) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$errors
            )
            $errors.Count | Should -Be 0
            foreach ($command in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Register-DuneRoute','Register-DuneWebSocket')
            }, $true)) {
                $name = $command.GetCommandName()
                $method = if ($name -eq 'Register-DuneRoute') { '' } else { 'CONNECT' }
                $path = ''
                $localOnly = $false
                for ($i = 1; $i -lt $command.CommandElements.Count; $i++) {
                    $text = $command.CommandElements[$i].Extent.Text
                    if ($text -eq '-Method') {
                        $method = $command.CommandElements[++$i].Extent.Text.Trim("'`"")
                    } elseif ($text -eq '-Path') {
                        $path = $command.CommandElements[++$i].Extent.Text.Trim("'`"")
                    } elseif ($text -eq '-LocalOnly') {
                        $localOnly = $true
                    }
                }
                $method | Should -Not -BeNullOrEmpty
                $path | Should -Match '^/(api|ws)/'
                $records += [pscustomobject]@{
                    Protocol = if ($name -eq 'Register-DuneRoute') { 'http' } else { 'ws' }
                    Method = $method
                    Path = $path
                    LocalOnly = $localOnly
                    SourceFile = $file.Name
                }
            }
        }
        return $records
    }

    function New-PlatformTestResponse {
        return [pscustomobject]@{
            StatusCode = 0
            ContentType = ''
            ContentLength64 = 0L
            Headers = @{}
            OutputStream = [IO.MemoryStream]::new()
        }
    }
}

Describe 'Platform capability registry' {
    It 'loads a unique versioned registry with only known contract values' {
        $registry = Get-DuneCapabilityRegistry
        $registry.schemaVersion | Should -Be 1
        { Assert-DuneCapabilityRegistry $registry } | Should -Not -Throw
        @($registry.capabilities.id | Sort-Object -Unique).Count | Should -Be @($registry.capabilities).Count
        @($registry.capabilities | Where-Object { $_.rolloutState -ne 'unavailable' -and 'linked-player' -in @($_.allowedPrincipals) }).Count |
            Should -Be 0
    }

    It 'rejects duplicate IDs, unknown guards, and duplicate endpoint IDs' {
        $baseCapability = {
            param($Id, $Endpoint, $Guards)
            [pscustomobject]@{
                id = $Id
                lifecycle = 'read'
                allowedPrincipals = @('owner')
                guards = $Guards
                endpointIds = @($Endpoint)
                rolloutState = 'stable'
            }
        }
        $duplicateIds = [pscustomobject]@{
            schemaVersion = 1
            knownGuards = @('local-only')
            capabilities = @(
                (& $baseCapability 'test.read' 'test.one' @()),
                (& $baseCapability 'test.read' 'test.two' @())
            )
        }
        { Assert-DuneCapabilityRegistry $duplicateIds } | Should -Throw '*Duplicate capability ID*'

        $unknownGuard = [pscustomobject]@{
            schemaVersion = 1
            knownGuards = @('local-only')
            capabilities = @((& $baseCapability 'test.read' 'test.one' @('unknown')))
        }
        { Assert-DuneCapabilityRegistry $unknownGuard } | Should -Throw '*Unknown guard*'

        $duplicateEndpoint = [pscustomobject]@{
            schemaVersion = 1
            knownGuards = @()
            capabilities = @(
                (& $baseCapability 'test.read' 'test.same' @()),
                (& $baseCapability 'test.write' 'test.same' @())
            )
        }
        { Assert-DuneCapabilityRegistry $duplicateEndpoint } | Should -Throw '*Duplicate endpoint ID*'
    }

    It 'filters out unavailable capabilities for every current principal' {
        foreach ($principal in @(
            @{ type = 'local-host'; role = 'local-host' },
            @{ type = 'portal-account'; role = 'owner' },
            @{ type = 'portal-account'; role = 'admin' }
        )) {
            $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal)
            $capabilities.Count | Should -BeGreaterThan 0
            @($capabilities | Where-Object rolloutState -eq 'unavailable').Count | Should -Be 0
        }
        @(Get-DuneCapabilitiesForPrincipal @{ type = 'linked-player'; role = 'player' }).Count | Should -Be 0
    }

    It 'advertises static Maps but not the Windows cache capability on Linux' {
        $principal = @{ type = 'local-host'; role = 'local-host' }
        $windows = @(Get-DuneCapabilitiesForPrincipal $principal -RuntimePlatform windows)
        $linux = @(Get-DuneCapabilitiesForPrincipal $principal -RuntimePlatform linux)

        $windows.id | Should -Contain 'map.view'
        $windows.id | Should -Contain 'map.live-cache'
        $linux.id | Should -Contain 'map.view'
        $linux.id | Should -Not -Contain 'map.live-cache'
    }
}

Describe 'Complete route classification' {
    It 'has no route registration hidden inside a handler scriptblock' {
        $routesRoot = Join-Path (Get-DstRepoRoot) 'app\server\routes'
        $nested = @()
        foreach ($file in Get-ChildItem -LiteralPath $routesRoot -Filter '*.ps1') {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName,
                [ref]$tokens,
                [ref]$errors
            )
            foreach ($command in $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Register-DuneRoute','Register-DuneWebSocket')
            }, $true)) {
                $ancestor = $command.Parent
                while ($ancestor -and $ancestor -ne $ast) {
                    if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                        $nested += "$($file.Name):$($command.Extent.StartLineNumber)"
                        break
                    }
                    $ancestor = $ancestor.Parent
                }
            }
        }
        $nested | Should -BeNullOrEmpty
    }

    It 'classifies the exact registered HTTP and WebSocket inventory' {
        $records = @(Get-PlatformRouteRecords)
        $manifest = Get-DuneRoutePolicyManifest
        $records.Count | Should -Be 357
        $sources = @($records.SourceFile | Sort-Object -Unique)
        @($manifest.groups.source | Sort-Object) | Should -Be $sources

        foreach ($group in @($manifest.groups)) {
            $groupRecords = @($records | Where-Object SourceFile -eq $group.source)
            [string[]]$keys = @($groupRecords | ForEach-Object { "$($_.Protocol) $($_.Method) $($_.Path)" })
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            $groupRecords.Count | Should -Be ([int]$group.routeCount)
            (Get-DuneSha256Hex ($keys -join "`n")) | Should -BeExactly ([string]$group.sha256)
        }
        $routeKeys = @($records | ForEach-Object { "$($_.Protocol) $($_.Method) $($_.Path)" })
        foreach ($property in $manifest.routeLifecycleOverrides.PSObject.Properties) {
            $routeKeys | Should -Contain $property.Name
        }
        foreach ($property in $manifest.routeCapabilityOverrides.PSObject.Properties) {
            $routeKeys | Should -Contain $property.Name
        }
    }

    It 'produces a classification for every inventoried route' {
        $records = @(Get-PlatformRouteRecords)
        $script:DuneRoutes = [System.Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes = [System.Collections.Generic.List[object]]::new()
        foreach ($record in $records) {
            $route = [pscustomobject]@{
                Path = $record.Path
                LocalOnly = $record.LocalOnly
                SourceFile = $record.SourceFile
                Classification = $null
            }
            if ($record.Protocol -eq 'http') {
                $route | Add-Member -NotePropertyName Method -NotePropertyValue $record.Method
                $script:DuneRoutes.Add($route)
            } else {
                $script:DuneWsRoutes.Add($route)
            }
        }
        Update-DuneRouteClassifications
        $classifications = @((@($script:DuneRoutes) + @($script:DuneWsRoutes)) | ForEach-Object {
            Get-DuneRouteClassification $_
        })
        @($classifications | Where-Object { -not $_.classified }).Count | Should -Be 0
        @($classifications | Where-Object { -not $_.capabilityId }).Count | Should -Be 0
        @($classifications | Where-Object { -not (Test-DuneRouteCapabilityCompatibility $_) }).Count |
            Should -Be 0
        @($classifications | Where-Object { $_.lifecycle -notin @('read','reversible-write','transactional-write','destructive') }).Count |
            Should -Be 0
        @($classifications | Where-Object {
            $_.source -eq 'Terminal.ps1' -and $_.lifecycle -ne 'destructive'
        }).Count | Should -Be 0
        @($classifications | Where-Object {
            $_.source -eq 'PlayersWrites.ps1' -and
            $_.lifecycle -eq 'destructive'
        }).Count | Should -BeGreaterThan 0
        @($script:DuneRoutes | Where-Object Path -eq '/api/gameplay/players/journey/reset').Classification.lifecycle |
            Should -Be 'destructive'
        @($script:DuneRoutes | Where-Object Path -eq '/api/gameplay/players/prepare-pattern-upgrading').Classification.lifecycle |
            Should -Be 'destructive'
        @($script:DuneRoutes | Where-Object Path -eq '/api/gameplay/players/prepare-pattern-upgrading').Classification.capabilityId |
            Should -Be 'player.manage.destructive'
        foreach ($path in @(
            '/api/gameplay/players/clean-inventory',
            '/api/gameplay/players/reset-progression'
        )) {
            @($script:DuneRoutes | Where-Object Path -eq $path).Classification.lifecycle |
                Should -Be 'destructive'
        }
        @($script:DuneRoutes | Where-Object Path -eq '/api/server/name').Classification.capabilityId |
            Should -Be 'settings.game-server'
        $mapReadRoutes = @($script:DuneRoutes | Where-Object {
            $_.Path -like '/api/v1/maps/*'
        })
        $mapReadRoutes.Count | Should -Be 3
        @($mapReadRoutes | Where-Object {
            $_.Classification.capabilityId -ne 'map.live-cache' -or
            $_.Classification.lifecycle -ne 'read' -or
            $_.Classification.currentAccess -ne 'owner-admin'
        }).Count | Should -Be 0
        $mapView = @((Get-DuneCapabilityRegistry).capabilities | Where-Object id -eq 'map.view')[0]
        $mapLiveCache = @((Get-DuneCapabilityRegistry).capabilities | Where-Object id -eq 'map.live-cache')[0]
        @($mapView.allowedPrincipals | Sort-Object) | Should -Be @('admin','local-host','owner')
        @($mapLiveCache.allowedPrincipals | Sort-Object) | Should -Be @('admin','local-host','owner')
        $mapRoute = $mapReadRoutes[0]
        (Test-DuneRoutePrincipalAccess -Route $mapRoute -Principal @{
            type = 'portal-account'; role = 'member'
        }) | Should -BeFalse
        (Test-DuneRoutePrincipalAccess -Route $mapRoute -Principal @{
            type = 'portal-account'; role = 'admin'
        }) | Should -BeTrue
        @($script:DuneRoutes | Where-Object Path -eq '/api/diagnostics/cleanup-old-images').Classification.capabilityId |
            Should -Be 'operation.diagnostics.manage'
        @($script:DuneRoutes | Where-Object Path -eq '/api/status').Classification.capabilityId |
            Should -Be 'platform.status'
    }

    It 'matches the actual startup registrations and keeps the Pods cleanup reachable' {
        $repo = Get-DstRepoRoot
        $scriptText = @'
$ErrorActionPreference = 'Stop'
$Repo = $env:DST_PLATFORM_TEST_ROOT
$serverDir = Join-Path $Repo 'app\server'
$script:DuneServerDir = $serverDir
$script:AppDir = Join-Path $Repo 'app'
$script:DuneToolVersion = 'test'
. (Join-Path $serverDir 'HttpServer.ps1')
foreach ($file in Get-ChildItem (Join-Path $serverDir 'lib') -Filter '*.ps1' | Sort-Object Name) { . $file.FullName }
foreach ($file in Get-ChildItem (Join-Path $serverDir 'routes') -Filter '*.ps1' | Sort-Object Name) { . $file.FullName }
Update-DuneRouteClassifications
$all = @($script:DuneRoutes) + @($script:DuneWsRoutes)
$result = @{
    total = $all.Count
    unclassified = @($all | Where-Object { -not $_.Classification }).Count
    incompatible = @($all | Where-Object {
        $_.Classification -and -not (Test-DuneRouteCapabilityCompatibility $_.Classification)
    }).Count
    podsCleanup = @($script:DuneRoutes | Where-Object {
        $_.Method -eq 'POST' -and $_.Path -eq '/api/pods/prune-terminal-director'
    }).Count
}
'ROUTE_RESULT:' + ($result | ConvertTo-Json -Compress)
'@
        $priorRoot = $env:DST_PLATFORM_TEST_ROOT
        $env:DST_PLATFORM_TEST_ROOT = $repo
        try {
            $output = & pwsh -NoProfile -Command $scriptText 2>&1
        } finally {
            $env:DST_PLATFORM_TEST_ROOT = $priorRoot
        }
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $resultLine = @($output | Where-Object { [string]$_ -like 'ROUTE_RESULT:*' })[-1]
        $result = ([string]$resultLine).Substring('ROUTE_RESULT:'.Length) | ConvertFrom-Json
        $result.total | Should -Be 357
        $result.unclassified | Should -Be 0
        $result.incompatible | Should -Be 0
        $result.podsCleanup | Should -Be 1
    }

    It 'default-denies future principals on an unclassified route without changing current access' {
        $route = [pscustomobject]@{
            Method = 'GET'
            Path = '/api/future-unclassified'
            LocalOnly = $false
            SourceFile = 'Future.ps1'
            Classification = $null
        }
        (Test-DuneRoutePrincipalAccess -Route $route -Principal @{ type = 'linked-player'; role = 'player' }) |
            Should -BeFalse
        (Test-DuneRoutePrincipalAccess -Route $route -Principal @{ type = 'api-key'; role = 'api-key' }) |
            Should -BeFalse
        (Test-DuneRoutePrincipalAccess -Route $route -Principal @{ type = 'portal-account'; role = 'admin' }) |
            Should -BeTrue
        (Test-DuneRoutePrincipalAccess -Route $route -Principal @{ type = 'local-host'; role = 'local-host' }) |
            Should -BeTrue
    }

    It 'permits anonymous access only to an exactly classified public auth route' {
        $publicRoute = [pscustomobject]@{
            Method = 'GET'
            Path = '/api/portal-auth/status'
            LocalOnly = $false
            SourceFile = 'PortalAuth.ps1'
            Classification = $null
        }
        $privateRoute = [pscustomobject]@{
            Method = 'GET'
            Path = '/api/status'
            LocalOnly = $false
            SourceFile = 'Status.ps1'
            Classification = $null
        }
        $publicRoute.Classification = [ordered]@{
            classified = $true
            currentAccess = 'public'
            allowedPrincipalTypes = @('anonymous')
            capabilityId = 'platform.access'
        }
        $privateRoute.Classification = [ordered]@{
            classified = $true
            currentAccess = 'authenticated'
            allowedPrincipalTypes = @()
            capabilityId = 'platform.status'
        }
        (Test-DuneRoutePrincipalAccess -Route $publicRoute -Principal @{ type = 'anonymous'; role = 'anonymous' }) |
            Should -BeTrue
        (Test-DuneRoutePrincipalAccess -Route $privateRoute -Principal @{ type = 'anonymous'; role = 'anonymous' }) |
            Should -BeFalse
    }
}

Describe 'Server-created request principals' {
    It 'uses admitted server auth and ignores client identity fields' {
        $request = [pscustomobject]@{
            Headers = @{ 'X-Claimed-Role' = 'owner' }
            QueryString = @{ role = 'owner'; accountId = 'client-supplied' }
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Parse('192.0.2.20') }
        }
        $auth = @{
            ok = $true
            sessionId = 'server-session'
            account = @{
                id = 'server-account'
                username = 'admin-user'
                role = 'admin'
                gameCharacterId = 'character-1'
                gameCharacterLabel = 'Character One'
            }
        }
        $principal = New-DuneRequestPrincipal `
            -Request $request `
            -IsLocalRequest $false `
            -AccountMode $true `
            -PortalSessionAuth $auth `
            -Authentication 'portal-session'

        $principal.type | Should -Be 'portal-account'
        $principal.role | Should -Be 'admin'
        $principal.account.id | Should -Be 'server-account'
        $principal.session.id | Should -Be 'server-session'
        $principal.linkedCharacter.id | Should -Be 'character-1'
        $principal.context.isRemote | Should -BeTrue
    }

    It 'keeps an unauthenticated public request anonymous' {
        $request = [pscustomobject]@{
            Headers = @{}
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Parse('192.0.2.30') }
        }
        $principal = New-DuneRequestPrincipal `
            -Request $request `
            -IsLocalRequest $false `
            -AccountMode $false `
            -Authentication 'none'
        $principal.type | Should -Be 'anonymous'
        $principal.role | Should -Be 'anonymous'
    }

    It 'preserves trusted local-host authority while retaining account provenance' {
        $request = [pscustomobject]@{
            Headers = @{}
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Loopback }
        }
        $auth = @{
            ok = $true
            sessionId = 'local-session'
            account = @{ id = 'admin-account'; username = 'admin'; role = 'admin' }
        }
        $principal = New-DuneRequestPrincipal -Request $request -IsLocalRequest $true -AccountMode $true -PortalSessionAuth $auth
        $principal.type | Should -Be 'local-host'
        $principal.role | Should -Be 'local-host'
        $principal.account.id | Should -Be 'admin-account'
        $principal.transport.kind | Should -Be 'loopback'
    }
}

Describe 'Versioned response and cursor contracts' {
    It 'keeps source, freshness, count, page, and error independent per layer' {
        $fresh = New-DuneApiLayerEnvelope `
            -LayerId players `
            -Source live `
            -Freshness (New-DuneApiFreshness -State fresh -AgeSeconds 0) `
            -Count 2 `
            -Data @(@{ id = 'projection-1' }, @{ id = 'projection-2' }) `
            -Page (New-DuneApiPage -Limit 500)
        $stale = New-DuneApiLayerEnvelope `
            -LayerId bases `
            -Source cache `
            -Freshness (New-DuneApiFreshness -State stale -AgeSeconds 90 -LastErrorCode 'source-timeout') `
            -Count 1 `
            -Data @(@{ id = 'projection-3' }) `
            -Page (New-DuneApiPage -Limit 500 -NextCursor 'opaque' -Truncated $true) `
            -Error @{ code = 'source-timeout'; message = 'Base source timed out.' }
        $aggregate = New-DuneApiAggregateEnvelope -RequestId 'request-1' -Layers @($fresh, $stale)

        $aggregate.schemaVersion | Should -Be 1
        $aggregate.source | Should -Be 'mixed'
        $aggregate.freshness.state | Should -Be 'partial'
        $aggregate.data.layers[0].source | Should -Be 'live'
        $aggregate.data.layers[0].error | Should -BeNullOrEmpty
        $aggregate.data.layers[1].source | Should -Be 'cache'
        $aggregate.data.layers[1].freshness.state | Should -Be 'stale'
        $aggregate.data.layers[1].page.truncated | Should -BeTrue
        $aggregate.data.layers[1].error.code | Should -Be 'source-timeout'
    }

    It 'marks an aggregate unavailable when every layer failed' {
        $failed = @(
            (New-DuneApiLayerEnvelope `
                -LayerId players `
                -Source unavailable `
                -Freshness (New-DuneApiFreshness -State unavailable -LastErrorCode 'db-offline') `
                -Error @{ code = 'db-offline'; message = 'Database unavailable.' }),
            (New-DuneApiLayerEnvelope `
                -LayerId bases `
                -Source unavailable `
                -Freshness (New-DuneApiFreshness -State unavailable -LastErrorCode 'cache-offline') `
                -Error @{ code = 'cache-offline'; message = 'Cache unavailable.' })
        )
        $aggregate = New-DuneApiAggregateEnvelope -RequestId 'request-failed' -Layers $failed
        $aggregate.source | Should -Be 'unavailable'
        $aggregate.freshness.state | Should -Be 'unavailable'
        @($aggregate.data.layers).Count | Should -Be 2
    }

    It 'binds opaque cursors to principal, map, layers, bbox, query, and generation' {
        $secret = 1..32
        $principal = @{ type = 'portal-account'; id = 'account:1'; role = 'owner'; account = @{ id = '1' }; session = @{ id = 's1' } }
        $arguments = @{
            Principal = $principal
            MapId = 'map-1'
            Layers = @('bases','players')
            Bbox = '1,2,3,4'
            Query = 'partition=2'
            Generation = 'generation-1'
            Secret = [byte[]]$secret
        }
        $cursor = New-DuneOpaqueCursor @arguments -Position @{ offset = 500 }
        $payload = Read-DuneOpaqueCursor -Cursor $cursor @arguments
        $payload.position.offset | Should -Be 500

        $changed = $arguments.Clone()
        $changed.MapId = 'map-2'
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'
        $changed = $arguments.Clone()
        $changed.Layers = @('players')
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'
        $changed = $arguments.Clone()
        $changed.Bbox = '0,0,1,1'
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'
        $changed = $arguments.Clone()
        $changed.Query = 'partition=3'
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'
        $changed = $arguments.Clone()
        $changed.Generation = 'generation-2'
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'
        $otherPrincipal = @{ type = 'portal-account'; id = 'account:2'; role = 'owner'; account = @{ id = '2' }; session = @{ id = 's2' } }
        $changed = $arguments.Clone()
        $changed.Principal = $otherPrincipal
        { Read-DuneOpaqueCursor -Cursor $cursor @changed } | Should -Throw '*does not match*'

        $parts = $cursor.Split('.')
        $replacement = if ($parts[1][0] -eq 'A') { 'B' } else { 'A' }
        $tampered = "$($parts[0]).$replacement$($parts[1].Substring(1))"
        { Read-DuneOpaqueCursor -Cursor $tampered @arguments } | Should -Throw '*Invalid cursor*'
    }

    It 'shares the cursor secret and immutable cache snapshot state with worker runspaces' {
        $secret = [byte[]](33..64)
        $principal = @{ type = 'local-host'; id = 'local-host'; role = 'local-host' }
        $cursor = New-DuneOpaqueCursor `
            -Principal $principal `
            -MapId 'map-1' `
            -Generation 'generation-1' `
            -Position @{ offset = 10 } `
            -Secret $secret
        {
            Read-DuneOpaqueCursor `
                -Cursor $cursor `
                -Principal $principal `
                -MapId 'map-1' `
                -Generation 'generation-1' `
                -Secret $secret
        } | Should -Not -Throw

        $serverSource = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $serverSource | Should -Match 'CursorSecret\s*=\s*\$cursorSecret'
        $serverSource | Should -Match "@\('DuneApiCursorSecret',\s*\`$ctx\.CursorSecret\)"
        $serverSource | Should -Match 'PlatformSnapshotState\s*=\s*\$script:DunePlatformSnapshotState'
        $serverSource | Should -Match "@\('DunePlatformSnapshotState',\s*\`$ctx\.PlatformSnapshotState\)"

        $workerDir = Join-Path $TestDrive 'cursor-worker'
        New-Item -ItemType Directory -Path $workerDir -Force | Out-Null
        Copy-Item (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') (Join-Path $workerDir 'HttpServer.ps1')
        $snapshotData = [Collections.Generic.Dictionary[string,object]]::new()
        $snapshotData.Add('generation', 'integration-test')
        $expectedSnapshotState = [Collections.Hashtable]::Synchronized(@{
            revision = 1L
            available = $true
            snapshot = [Collections.ObjectModel.ReadOnlyDictionary[string,object]]::new($snapshotData)
        })
        $script:DunePlatformSnapshotState = $expectedSnapshotState
        Stop-DuneHttpServer
        try {
            Initialize-DuneApiPool -ServerDir $workerDir
            $script:DuneApiCtx.CursorSecret | Should -Not -BeNullOrEmpty
            @($script:DuneApiCtx.CursorSecret).Count | Should -Be 32
            $script:DuneApiCtx.CursorSecret | Should -Be $script:DuneApiCursorSecret
            [object]::ReferenceEquals(
                $script:DuneApiCtx.PlatformSnapshotState,
                $expectedSnapshotState
            ) | Should -BeTrue
        } finally {
            Stop-DuneHttpServer
        }
    }

    It 'creates request IDs and redacts secret-shaped audit fields' {
        (New-DuneRequestId) | Should -Match '^[A-Za-z0-9_-]{22}$'
        $record = New-DuneAuditRecord `
            -RequestId 'request-1' `
            -CapabilityId 'platform.capabilities' `
            -Principal @{ type = 'portal-account'; id = 'account:1'; role = 'owner' } `
            -Action 'read' `
            -Fields @{ target = 'status'; token = 'secret-value'; nested = @{ password = 'secret-password'; safe = 'kept' } }
        $record.fields.target | Should -Be 'status'
        $record.fields.token | Should -Be '<redacted>'
        $record.fields.nested.password | Should -Be '<redacted>'
        $record.fields.nested.safe | Should -Be 'kept'
    }
}

Describe 'Capability proof route' {
    It 'returns the v1 envelope for a server-created current principal' {
        $script:DuneRoutes = [System.Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes = [System.Collections.Generic.List[object]]::new()
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\Platform.ps1')
        $route = @($script:DuneRoutes | Where-Object Path -eq '/api/v1/capabilities')[0]
        $route.SourceFile | Should -Be 'Platform.ps1'
        $response = New-PlatformTestResponse
        $principal = @{ type = 'portal-account'; id = 'account:1'; role = 'admin' }
        & $route.Handler $null $response @{ requestPrincipal = $principal; requestId = 'proof-request' } $null
        $body = [Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()) | ConvertFrom-Json

        $response.StatusCode | Should -Be 200
        $body.schemaVersion | Should -Be 1
        $body.requestId | Should -Be 'proof-request'
        $body.data.registryVersion | Should -Be 1
        @($body.data.capabilities).Count | Should -BeGreaterThan 0
    }

    It 'is dispatched with server-created principal and request metadata' {
        $script:DuneRoutes = [System.Collections.Generic.List[object]]::new()
        $script:DuneWsRoutes = [System.Collections.Generic.List[object]]::new()
        $script:DuneToken = ''
        $script:DuneApiPoolEnabled = $false
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\Platform.ps1')
        $response = New-PlatformTestResponse
        $request = [pscustomobject]@{
            Url = [uri]'http://127.0.0.1/api/v1/platform/status'
            HttpMethod = 'GET'
            IsWebSocketRequest = $false
            HasEntityBody = $false
            Headers = @{}
            QueryString = @{}
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Loopback }
        }

        Invoke-DuneContext -Ctx ([pscustomobject]@{ Request = $request; Response = $response })
        $body = [Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()) | ConvertFrom-Json

        $response.StatusCode | Should -Be 200
        $response.Headers['X-Dune-Request-Id'] | Should -Be $body.requestId
        $body.data.principal.type | Should -Be 'local-host'
        $body.data.principal.role | Should -Be 'local-host'
        $body.data.principal.isLocal | Should -BeTrue
    }
}

Describe 'Reviewed candidate matrix' {
    It 'records every approved-plan candidate with a positive acceptance target' {
        $matrix = Read-DunePlatformJson 'platform-candidate-matrix.json'
        $matrix.schemaVersion | Should -Be 1
        @($matrix.candidates).Count | Should -Be 70
        @($matrix.candidates.id | Sort-Object -Unique).Count | Should -Be @($matrix.candidates).Count
        @($matrix.candidates | Where-Object id -like 'core.*').Count | Should -Be 5
        @($matrix.candidates | Where-Object id -like 'map.*').Count | Should -Be 14
        @($matrix.candidates | Where-Object { $_.id -like 'player.*' -or $_.id -like 'inventory.*' -or $_.id -like 'grant.*' }).Count | Should -Be 8
        @($matrix.candidates | Where-Object { $_.id -like 'base.*' -or $_.id -like 'vehicle.*' }).Count | Should -Be 12
        @($matrix.candidates | Where-Object { $_.id -like 'economy.*' -or $_.id -like 'governance.*' }).Count | Should -Be 6
        @($matrix.candidates | Where-Object id -like 'operations.*').Count | Should -Be 15
        @($matrix.candidates | Where-Object id -like 'access.*').Count | Should -Be 8
        @($matrix.candidates | Where-Object id -like 'rejected.*').Count | Should -Be 2
        foreach ($candidate in @($matrix.candidates)) {
            [string]$candidate.id | Should -Match '^[a-z][a-z0-9.-]+$'
            [string]$candidate.status | Should -BeIn @('approved','deferred','rejected','already-have')
            [string]$candidate.owningEpic | Should -Not -BeNullOrEmpty
            [string]$candidate.mergeTarget | Should -Not -BeNullOrEmpty
            [string]$candidate.lifecyclePhase | Should -BeIn @('R0','R1','W1','W2','D','deferred','rejected')
            [string]$candidate.positiveAcceptanceTest | Should -Not -BeNullOrEmpty
            if ($candidate.status -in @('approved','already-have')) {
                [string]$candidate.capabilityId | Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Platform contract packaging' {
    It 'bundles platform data in Windows and Linux packages' {
        $repo = Get-DstRepoRoot
        $installer = Get-Content (Join-Path $repo 'app\installer\DuneServer.iss') -Raw
        $linux = Get-Content (Join-Path $repo 'packaging\linux\build-deb.sh') -Raw
        $installer | Should -Match 'Source:\s*"\.\.\\data\\\*"'
        $linux | Should -Match 'cp -r "\$REPO_ROOT/app/data"\s+"\$INSTALL_PREFIX/app/"'
    }

    It 'does not advertise or package the Windows-only live cache helper on Linux' {
        $repo = Get-DstRepoRoot
        $entrypoint = Get-Content (Join-Path $repo 'app\DuneServer-Linux.ps1') -Raw
        $packaging = Get-Content (Join-Path $repo 'packaging\linux\build-deb.sh') -Raw
        $project = Get-Content (Join-Path $repo 'app\tools\DunePlatformStore\DunePlatformStore.csproj') -Raw

        $entrypoint | Should -Match "\`$script:DunePlatformRuntime\s*=\s*'linux'"
        $entrypoint | Should -Not -Match 'Initialize-DunePlatformCache'
        $entrypoint | Should -Not -Match 'Start-DuneMapsPlatformStartupRefresh'
        $packaging | Should -Not -Match 'DunePlatformStore'
        $project | Should -Match '<TargetFramework>net10\.0-windows</TargetFramework>'
        (Test-DunePlatformLiveCacheSupported -RuntimePlatform linux) | Should -BeFalse
    }
}
