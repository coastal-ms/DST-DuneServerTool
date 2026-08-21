BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:PortalRouteTestRoot = Join-Path (Get-DstRepoRoot) '.portal-auth-route-test-data'
    $env:APPDATA = $script:PortalRouteTestRoot
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteIdentity.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\PortalAuth.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\routes\PortalAuth.ps1')

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
        @($script:DuneRoutes | Where-Object { $_.Method -eq $Method -and $_.Path -eq $Path })[0].Handler
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
