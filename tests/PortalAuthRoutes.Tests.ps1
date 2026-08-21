BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:PortalRouteTestRoot = Join-Path (Get-DstRepoRoot) '.portal-auth-route-test-data'
    $env:APPDATA = $script:PortalRouteTestRoot
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteIdentity.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\PortalAuth.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\routes\PortalAuth.ps1')
    $script:PortalLoginRoute = @($script:DuneRoutes | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/api/portal-auth/login' })[0]
    $script:PortalLogoutRoute = @($script:DuneRoutes | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/api/portal-auth/logout' })[0]
    $script:PortalModeRoute = @($script:DuneRoutes | Where-Object { $_.Method -eq 'PUT' -and $_.Path -eq '/api/remote-access/portal-account-mode' })[0]

    function New-RouteRequest {
        param([string]$Cookie = '')
        $cookies = @{}
        if ($Cookie) { $cookies[$script:DunePortalCookieName] = [pscustomobject]@{ Value=$Cookie } }
        [pscustomobject]@{
            Cookies=$cookies
            Headers=@{ Host='portal.example.test'; Origin='https://portal.example.test' }
            RemoteEndPoint=[pscustomobject]@{ Address=[Net.IPAddress]::Loopback }
        }
    }
    function New-RouteResponse {
        [pscustomobject]@{
            StatusCode=0
            ContentType=''
            ContentLength64=0L
            Headers=@{}
            OutputStream=[IO.MemoryStream]::new()
        }
    }
    function Get-RegisteredHandler {
        param([string]$Method, [string]$Path)
        if ($Method -eq 'POST' -and $Path -eq '/api/portal-auth/login') { return $script:PortalLoginRoute.Handler }
        if ($Method -eq 'POST' -and $Path -eq '/api/portal-auth/logout') { return $script:PortalLogoutRoute.Handler }
        if ($Method -eq 'PUT' -and $Path -eq '/api/remote-access/portal-account-mode') { return $script:PortalModeRoute.Handler }
    }
}

AfterAll {
    $env:APPDATA = $script:OriginalAppData
    Remove-Item -LiteralPath $script:PortalRouteTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Registered portal login/logout production handlers' {
    BeforeEach {
        Remove-Item -LiteralPath $script:PortalRouteTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Describe 'Portal login worker permit completion' {
        BeforeEach {
            Stop-DuneHttpServer
            $workerDir = Join-Path $TestDrive 'worker-server'
            New-Item -ItemType Directory -Path $workerDir -Force | Out-Null
            Copy-Item (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') (Join-Path $workerDir 'HttpServer.ps1')
            $script:DuneToolVersion = '14.0.0'
            Initialize-DuneApiPool -ServerDir $workerDir
        }

        AfterEach {
            Stop-DuneHttpServer
        }

        It 'returns both permits after more than two sequential successful and failed logins' {
            $waitForCompletion = {
                $deadline = (Get-Date).AddSeconds(10)
                do {
                    Clear-DuneApiCompleted
                    if (-not $script:DuneApiInFlight -or $script:DuneApiInFlight.Count -eq 0) { return }
                    Start-Sleep -Milliseconds 20
                } while ((Get-Date) -lt $deadline)
                throw 'Worker did not complete before timeout.'
            }
            $newRequest = {
                [pscustomobject]@{
                    Url=[uri]'https://portal.example.test/api/portal-auth/login'
                    HttpMethod='POST'
                    HasEntityBody=$false
                }
            }

            1..5 | ForEach-Object {
                Invoke-DuneApiHandlerAsync -Handler { param($req, $res) $res.StatusCode = 200 } `
                    -Request (& $newRequest) -Response (New-RouteResponse) -RouteParams @{}
                & $waitForCompletion
                $script:DunePortalLoginGate.CurrentCount | Should -Be 2
                $script:DuneApiGate.CurrentCount | Should -Be $script:DuneApiMax
            }

            Invoke-DuneApiHandlerAsync -Handler { throw 'expected worker failure' } `
                -Request (& $newRequest) -Response (New-RouteResponse) -RouteParams @{}
            & $waitForCompletion
            $script:DunePortalLoginGate.CurrentCount | Should -Be 2
            $script:DuneApiGate.CurrentCount | Should -Be $script:DuneApiMax
        }

        It 'uses only the centralized idempotent completion helper for release objects' {
            $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
            $workerStart = $source.IndexOf('param($handlerText, $req, $res')
            $workerEnd = $source.IndexOf('}).AddArgument', $workerStart)
            $workerFinally = $source.Substring($workerStart, $workerEnd - $workerStart)
            $workerFinally | Should -Match 'Complete-DuneApiRelease -Release \$release'
            $workerFinally | Should -Not -Match '\$release\.Done\s*='
            $release = [pscustomobject]@{
                Gate=[Threading.SemaphoreSlim]::new(0, 1)
                LoginGate=[Threading.SemaphoreSlim]::new(0, 1)
                Done=$false
            }
            { Complete-DuneApiRelease -Release $release; Complete-DuneApiRelease -Release $release } | Should -Not -Throw
            $release.Gate.CurrentCount | Should -Be 1
            $release.LoginGate.CurrentCount | Should -Be 1
        }
    }

    It 'issues a session cookie on login and revokes and clears it on logout' {
        $created = New-DunePortalAccount -Username 'route-owner' -Role owner
        $store = Get-DunePortalAccountStore
        $store.accountLoginEnabled = $true
        Save-DunePortalAccountStore $store

        $loginResponse = New-RouteResponse
        & (Get-RegisteredHandler POST '/api/portal-auth/login') `
            (New-RouteRequest) $loginResponse @{} @{
                username='ROUTE-OWNER'
                password=$created.oneTimePassword
            }

        $loginResponse.StatusCode | Should -Be 200
        $setCookie = [string]$loginResponse.Headers['Set-Cookie']
        $setCookie | Should -Match '^dune_portal_session=([^;]+);'
        $token = [regex]::Match($setCookie, '^dune_portal_session=([^;]+);').Groups[1].Value
        (Get-DunePortalSessionAuth (New-RouteRequest -Cookie $token)).ok | Should -BeTrue

        $logoutResponse = New-RouteResponse
        & (Get-RegisteredHandler POST '/api/portal-auth/logout') `
            (New-RouteRequest -Cookie $token) $logoutResponse @{} $null

        $logoutResponse.StatusCode | Should -Be 200
        $logoutResponse.Headers['Set-Cookie'] | Should -Match 'Max-Age=0'
        (Get-DunePortalSessionAuth (New-RouteRequest -Cookie $token)).ok | Should -BeFalse
    }

    It 'registers login on the bounded worker path instead of the listener thread' {
        $script:PortalLoginRoute.Inline | Should -BeFalse
    }

    It 'reserves only two worker admissions for anonymous login traffic' {
        $script:DunePortalLoginGate = [Threading.SemaphoreSlim]::new(0, 2)
        $script:DuneApiGate = [Threading.SemaphoreSlim]::new(1, 1)
        $response = New-RouteResponse
        $request = [pscustomobject]@{
            Url=[uri]'https://portal.example.test/api/portal-auth/login'
            HttpMethod='POST'
        }
        Invoke-DuneApiHandlerAsync -Handler {} -Request $request -Response $response -RouteParams @{}
        $response.StatusCode | Should -Be 429
        $script:DuneApiGate.CurrentCount | Should -Be 1
    }

    It 'requires explicit native-app retirement acknowledgement before enabling mode' {
        $created = New-DunePortalAccount -Username 'safe-route-owner' -Role owner
        $store = Get-DunePortalAccountStore
        $store.accounts[0].locallyVerifiedAt = (Get-Date).ToUniversalTime().ToString('o')
        Save-DunePortalAccountStore $store
        $handler = Get-RegisteredHandler PUT '/api/remote-access/portal-account-mode'

        $denied = New-RouteResponse
        & $handler (New-RouteRequest) $denied @{} @{ enabled=$true }
        $denied.StatusCode | Should -Be 400
        (Get-DunePortalAccountStore).accountLoginEnabled | Should -BeFalse

        $accepted = New-RouteResponse
        & $handler (New-RouteRequest) $accepted @{} @{
            enabled=$true
            acknowledgeNativeAppRetirement=$true
        }
        $accepted.StatusCode | Should -Be 200
        (Get-DunePortalAccountStore).accountLoginEnabled | Should -BeTrue
        $created.account.id | Should -Not -BeNullOrEmpty
    }
}
