BeforeAll {
    $fixturePath = Join-Path $PSScriptRoot 'fixtures\platform-baseline.json'
    $script:baseline = Get-Content $fixturePath -Raw | ConvertFrom-Json
    $routeDir = Join-Path $PSScriptRoot '..\app\server\routes'
    $script:routes = @(
        Get-ChildItem $routeDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
            $file = $_
            $text = Get-Content $file.FullName -Raw
            [regex]::Matches(
                $text,
                "Register-DuneRoute\s+-Method\s+(?<method>[A-Z]+)\s+-Path\s+'(?<path>[^']+)'"
            ) | ForEach-Object {
                [pscustomobject]@{
                    File = $file.Name
                    Method = $_.Groups['method'].Value
                    Path = $_.Groups['path'].Value
                }
            }
        }
    )
    $script:webSockets = @(
        Get-ChildItem $routeDir -Filter '*.ps1' | ForEach-Object {
            [regex]::Matches((Get-Content $_.FullName -Raw), "Register-DuneWebSocket\s+-Path\s+'[^']+'")
        }
    )
}

Describe 'Next-generation platform route baseline' -Tag 'Baseline' {
    It 'pins the HTTP and WebSocket registration counts' {
        $script:routes.Count | Should -Be $script:baseline.backendRoutes.httpCount
        $script:webSockets.Count | Should -Be $script:baseline.backendRoutes.webSocketCount
    }

    It 'pins the method-based read and write-like classification' {
        foreach ($property in $script:baseline.backendRoutes.byMethod.PSObject.Properties) {
            @($script:routes | Where-Object Method -eq $property.Name).Count |
                Should -Be $property.Value -Because "the $($property.Name) route count changed"
        }
        @($script:routes | Where-Object Method -eq 'GET').Count |
            Should -Be $script:baseline.backendRoutes.classification.readByMethod
        @($script:routes | Where-Object Method -ne 'GET').Count |
            Should -Be $script:baseline.backendRoutes.classification.writeLikeByMethod
    }

    It 'pins the namespace inventory' {
        $actual = @{}
        foreach ($route in $script:routes) {
            $namespace = ($route.Path -split '/')[2]
            if (-not $namespace) { $namespace = 'root' }
            $actual[$namespace] = 1 + [int]($actual[$namespace])
        }
        foreach ($property in $script:baseline.backendRoutes.byNamespace.PSObject.Properties) {
            $actual[$property.Name] | Should -Be $property.Value -Because "the $($property.Name) namespace changed"
        }
        $actual.Keys.Count | Should -Be @($script:baseline.backendRoutes.byNamespace.PSObject.Properties).Count
    }

    It 'pins every existing Maps and Coriolis compatibility route' {
        $actual = @($script:routes | ForEach-Object { "$($_.Method) $($_.Path)" })
        foreach ($route in $script:baseline.backendRoutes.mapCompatibilityRoutes) {
            $actual | Should -Contain "$($route.method) $($route.path)"
        }
        @($script:baseline.backendRoutes.mapCompatibilityRoutes | Where-Object class -eq 'read').Count | Should -Be 4
        @($script:baseline.backendRoutes.mapCompatibilityRoutes | Where-Object class -eq 'write').Count | Should -Be 11
    }
}

Describe 'Maps response compatibility baseline' -Tag 'Baseline' {
    BeforeAll {
        $mapsSource = Get-Content (Join-Path $PSScriptRoot '..\app\server\lib\Maps.ps1') -Raw
        $start = $mapsSource.IndexOf('function Get-DuneOnDemandMapState')
        $end = $mapsSource.IndexOf('function Start-DuneOnDemandMap', $start)
        $script:desktopStateSource = $mapsSource.Substring($start, $end - $start)

        $global:PlatformBaselineRoutes = @{}
        function global:Register-DuneRoute {
            param($Method, $Path, $Handler, [switch] $Inline, [switch] $LocalOnly)
            $global:PlatformBaselineRoutes["$Method $Path"] = $Handler
        }
        $script:DuneOnDemandMaps = @(
            [pscustomobject]@{ Key = 'deepdesert'; Label = 'Deep Desert' }
        )
        . (Join-Path $PSScriptRoot '..\app\server\routes\Remote.ps1')
        $script:remoteMapsHandler = $global:PlatformBaselineRoutes['GET /api/remote/maps']
        Remove-Item function:global:Register-DuneRoute -ErrorAction SilentlyContinue
        Remove-Variable PlatformBaselineRoutes -Scope Global -ErrorAction SilentlyContinue
    }

    It 'keeps the desktop map-state response fields' {
        foreach ($key in $script:baseline.backendRoutes.mapResponseRequiredKeys.desktopState) {
            $script:desktopStateSource | Should -Match "(?m)^\s*$([regex]::Escape($key))\s*="
        }
    }

    It 'returns the remote Maps envelope and entry fields from the specific handler' {
        $script:capturedRemoteMapsBody = $null
        function global:Get-DuneOnDemandMapState {
            return @{
                ok = $true
                running = $true
                present = $true
                totalReplicas = 2
                playersOnline = 3
                hasDisabledPart = $false
                missingPartitionBinding = $false
                stuckDedicatedScaling = $false
            }
        }
        function global:Write-DuneJson {
            param($Response, $Body)
            $script:capturedRemoteMapsBody = $Body
        }
        function global:Write-DuneError {
            param($Response, $Status, $Message)
            throw "Unexpected remote Maps error $Status`: $Message"
        }
        try {
            & $script:remoteMapsHandler $null ([pscustomobject]@{}) ([pscustomobject]@{
                remoteRole = 'owner'
                remoteEmail = 'fixture@example.invalid'
            }) $null
        } finally {
            Remove-Item function:global:Get-DuneOnDemandMapState -ErrorAction SilentlyContinue
            Remove-Item function:global:Write-DuneJson -ErrorAction SilentlyContinue
            Remove-Item function:global:Write-DuneError -ErrorAction SilentlyContinue
        }

        $body = $script:capturedRemoteMapsBody
        $body | Should -Not -BeNullOrEmpty
        @($body.maps).Count | Should -Be 1
        @($body.Keys | Sort-Object) |
            Should -Be @($script:baseline.backendRoutes.mapResponseRequiredKeys.remoteEnvelope | Sort-Object)
        @($body.maps[0].Keys | Sort-Object) |
            Should -Be @($script:baseline.backendRoutes.mapResponseRequiredKeys.remoteMap | Sort-Object)
        $body.maps[0].key | Should -Be 'deepdesert'
        $body.maps[0].playersOnline | Should -Be 3
    }
}

Describe 'Direct game database source-call cost model' -Tag 'Baseline' {
    BeforeAll {
        $dbTransport = Get-Content (Join-Path $PSScriptRoot '..\app\lib\Db-Postgres.ps1') -Raw
        $database = Get-Content (Join-Path $PSScriptRoot '..\app\server\lib\Database.ps1') -Raw
    }

    It 'records the 120-second database-pod cache as static architecture evidence' {
        $dbTransport | Should -Match 'TotalSeconds -lt 120'
    }

    It 'executes two SSH transports cold and one warm with kubectl exec and psql' {
        . (Join-Path $PSScriptRoot '..\app\lib\Db-Postgres.ps1')
        . (Join-Path $PSScriptRoot '..\app\server\lib\Database.ps1')
        $script:V6DbPodCache = $null
        $script:V6DbPodCacheTime = [datetime]::MinValue
        $script:platformTransportCalls = [System.Collections.Generic.List[string]]::new()

        function Get-V6DbPort { return 15432 }
        function Invoke-V6Ssh {
            param([string] $Ip, [string] $Cmd, [int] $TimeoutSec, [string] $StdinData)
            $script:platformTransportCalls.Add($Cmd)
            if ($Cmd -match 'kubectl get pods') {
                return 'fixture-ns fixture-db-dbdepl-sts-0 1/1 Running 0 1m'
            }
            return @('value', '1')
        }

        $cold = Invoke-DuneSqlQuery -Ip '192.0.2.1' -Sql 'SELECT 1' -ReadOnly $true -MaxRows 1
        $warm = Invoke-DuneSqlQuery -Ip '192.0.2.1' -Sql 'SELECT 1' -ReadOnly $true -MaxRows 1

        $cold.ok | Should -BeTrue
        $warm.ok | Should -BeTrue
        $script:platformTransportCalls.Count | Should -Be 3
        $script:platformTransportCalls[0] |
            Should -Be "sudo kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep 'db-dbdepl-sts.*Running'"

        $queryCalls = @($script:platformTransportCalls | Select-Object -Skip 1)
        $queryCalls.Count | Should -Be 2
        foreach ($command in $queryCalls) {
            $match = [regex]::Match(
                $command,
                '^echo (?<sql>[A-Za-z0-9+/=]+) \| base64 -d \| sudo kubectl exec -i -n fixture-ns fixture-db-dbdepl-sts-0 -- psql -U dune -d dune -p 15432 -v ON_ERROR_STOP=1 -X --csv 2>&1$'
            )
            $match.Success | Should -BeTrue
            $effectiveSql = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups['sql'].Value))
            $effectiveSql | Should -Be "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;`nSELECT 1;`nROLLBACK;"
        }
    }

    It 'wraps read-only queries in a PostgreSQL read-only transaction' {
        $database | Should -Match 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY'
        $database | Should -Match 'ROLLBACK;'
    }

    It 'records conservative DB concurrency below the HTTP handler ceiling' {
        $cost = $script:baseline.recordedMeasurements.databaseSourceCost
        $cost.recommendedBackgroundReadConcurrency | Should -BeLessOrEqual $cost.recommendedHardLiveDbConcurrency
        $cost.recommendedHardLiveDbConcurrency | Should -BeLessThan $cost.backendHandlerConcurrency
    }
}
