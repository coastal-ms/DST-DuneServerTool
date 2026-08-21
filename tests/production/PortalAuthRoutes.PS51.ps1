$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$oldAppData = $env:APPDATA
$testRoot = Join-Path $repo '.portal-auth-ps51-test-data'

function Assert-Seam {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $env:APPDATA = $testRoot
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    . (Join-Path $repo 'app\server\lib\RemoteIdentity.ps1')
    . (Join-Path $repo 'app\server\lib\PortalAuth.ps1')
    . (Join-Path $repo 'app\server\HttpServer.ps1')
    . (Join-Path $repo 'app\server\routes\PortalAuth.ps1')

    function New-SeamRequest {
        param([string]$Cookie = '')
        $cookies = @{}
        if ($Cookie) { $cookies[$script:DunePortalCookieName] = [pscustomobject]@{ Value=$Cookie } }
        [pscustomobject]@{
            Cookies=$cookies
            Headers=@{ Host='portal.example.test'; Origin='https://portal.example.test' }
            RemoteEndPoint=[pscustomobject]@{ Address=[Net.IPAddress]::Loopback }
        }
    }
    function New-SeamResponse {
        [pscustomobject]@{
            StatusCode=0
            ContentType=''
            ContentLength64=0L
            Headers=@{}
            OutputStream=New-Object IO.MemoryStream
        }
    }

    $created = New-DunePortalAccount -Username 'ps51-owner' -Role owner
    $store = Get-DunePortalAccountStore
    $store.accountLoginEnabled = $true
    Save-DunePortalAccountStore $store

    $login = @($script:DuneRoutes | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/api/portal-auth/login' })[0]
    $logout = @($script:DuneRoutes | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/api/portal-auth/logout' })[0]
    Assert-Seam ($null -ne $login -and $null -ne $logout) 'Production login/logout routes were not registered.'

    $loginResponse = New-SeamResponse
    & $login.Handler (New-SeamRequest) $loginResponse @{} @{
        username='PS51-OWNER'
        password=$created.oneTimePassword
    }
    Assert-Seam ($loginResponse.StatusCode -eq 200) 'Production login handler did not return 200.'
    $cookie = [string]$loginResponse.Headers['Set-Cookie']
    $match = [regex]::Match($cookie, '^dune_portal_session=([^;]+);')
    Assert-Seam $match.Success 'Production login handler did not issue the session cookie.'
    $token = $match.Groups[1].Value
    Assert-Seam ([bool](Get-DunePortalSessionAuth (New-SeamRequest -Cookie $token)).ok) 'Issued session was not valid.'

    $logoutResponse = New-SeamResponse
    & $logout.Handler (New-SeamRequest -Cookie $token) $logoutResponse @{} $null
    Assert-Seam ($logoutResponse.StatusCode -eq 200) 'Production logout handler did not return 200.'
    Assert-Seam ([string]$logoutResponse.Headers['Set-Cookie'] -match 'Max-Age=0') 'Logout did not clear the cookie.'
    Assert-Seam (-not [bool](Get-DunePortalSessionAuth (New-SeamRequest -Cookie $token)).ok) 'Logout did not revoke the session.'
    'PS51 portal route seam passed.'
} finally {
    $env:APPDATA = $oldAppData
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
