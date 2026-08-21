BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:PortalTestRoot = Join-Path (Get-DstRepoRoot) '.portal-auth-test-data'
    $env:APPDATA = $script:PortalTestRoot
    Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteIdentity.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\PortalAuth.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteAccess.ps1')
    function New-PortalTestRequest {
        param([string]$Cookie = '', [string]$Address = '127.0.0.1', [string]$Origin = 'https://portal.example.test')
        $cookies = @{}
        if ($Cookie) { $cookies[$script:DunePortalCookieName] = [pscustomobject]@{ Value = $Cookie } }
        return [pscustomobject]@{
            Cookies = $cookies
            Headers = @{ Host = 'portal.example.test'; Origin = $Origin }
            RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Parse($Address) }
        }
    }
}

AfterAll {
    $env:APPDATA = $script:OriginalAppData
    Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Portal account password security' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'hashes with versioned PBKDF2-HMAC-SHA256 and verifies in constant-time code' {
        $hash = New-DunePortalPasswordHash 'correct horse battery'
        $hash.algorithm | Should -Be 'PBKDF2-HMAC-SHA256'
        $hash.version | Should -Be 1
        $hash.iterations | Should -BeGreaterOrEqual 300000
        $hash.salt | Should -Not -BeNullOrEmpty
        $hash.hash | Should -Not -BeNullOrEmpty
        Test-DunePortalPassword 'correct horse battery' $hash | Should -BeTrue
        Test-DunePortalPassword 'wrong password value' $hash | Should -BeFalse
    }

    It 'normalizes usernames case-insensitively and rejects duplicates' {
        $first = New-DunePortalAccount -Username 'Coastal' -Role owner
        $first.account.normalizedUsername | Should -Be 'coastal'
        { New-DunePortalAccount -Username '  COASTAL  ' -Role admin } | Should -Throw '*already in use*'
    }

    It 'creates a one-time password without persisting plaintext and supports forced change' {
        $created = New-DunePortalAccount -Username 'owner-one' -Role owner
        $created.oneTimePassword.Length | Should -BeGreaterOrEqual 20
        $created.account.mustChangePassword | Should -BeTrue
        (Get-Content (Get-DunePortalAccountsPath) -Raw) | Should -Not -Match ([regex]::Escape($created.oneTimePassword))

        $issued = Set-DunePortalPassword -AccountId $created.account.id -CurrentPassword $created.oneTimePassword -NewPassword 'a replacement password'
        $issued.token | Should -Not -BeNullOrEmpty
        (Get-DunePortalAccountStore).accounts[0].mustChangePassword | Should -BeFalse
    }
}

Describe 'Portal account migration safety' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'requires a locally verified enabled owner before enabling' {
        $store = Get-DunePortalAccountStore
        Test-DunePortalEnablePreconditions $store | Should -BeFalse
        $created = New-DunePortalAccount -Username 'safe-owner' -Role owner
        $store = Get-DunePortalAccountStore
        Test-DunePortalEnablePreconditions $store | Should -BeFalse
        $store.accounts[0].locallyVerifiedAt = (Get-Date).ToUniversalTime().ToString('o')
        Save-DunePortalAccountStore $store
        Test-DunePortalEnablePreconditions (Get-DunePortalAccountStore) | Should -BeTrue
        Test-DunePortalPassword $created.oneTimePassword (Get-DunePortalAccountStore).accounts[0].password | Should -BeTrue
    }

    It 'defaults to disabled so legacy magic links remain active' {
        Test-DunePortalAccountModeEnabled | Should -BeFalse
    }

    It 'recovers the atomic account file from its backup' {
        $store = Get-DunePortalAccountStore
        Save-DunePortalAccountStore $store
        $store.accountLoginEnabled = $true
        Save-DunePortalAccountStore $store
        Set-Content -LiteralPath (Get-DunePortalAccountsPath) -Value '{broken' -Encoding UTF8
        (Get-DunePortalAccountStore).accountLoginEnabled | Should -BeFalse
    }
}

Describe 'Portal sessions and login defense' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'persists only a token hash and enforces absolute and idle expiry' {
        $created = New-DunePortalAccount -Username 'session-owner' -Role owner
        $session = New-DunePortalSession -AccountId $created.account.id
        $raw = Get-Content (Get-DunePortalSessionsPath) -Raw
        $raw | Should -Not -Match ([regex]::Escape($session.token))
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $session.token)).ok | Should -BeTrue

        $sessions = Get-DunePortalSessionStore
        $entry = @($sessions.sessions)[0]
        $entry['idleExpiresAt'] = (Get-Date).ToUniversalTime().AddSeconds(-1).ToString('o')
        Save-DunePortalSessionStore $sessions
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $session.token)).ok | Should -BeFalse
    }

    It 'revokes sessions and rejects disabled accounts' {
        $created = New-DunePortalAccount -Username 'disabled-owner' -Role owner
        $first = New-DunePortalSession -AccountId $created.account.id
        Revoke-DunePortalSessions -AccountId $created.account.id
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $first.token)).ok | Should -BeFalse

        $second = New-DunePortalSession -AccountId $created.account.id
        $accounts = Get-DunePortalAccountStore
        $accounts.accounts[0].enabled = $false
        Save-DunePortalAccountStore $accounts
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $second.token)).ok | Should -BeFalse
    }

    It 'locks both account and client after repeated generic failures' {
        $created = New-DunePortalAccount -Username 'rate-owner' -Role owner
        $request = New-PortalTestRequest -Address '192.0.2.10'
        1..5 | ForEach-Object {
            $result = Invoke-DunePortalLogin -Username 'RATE-OWNER' -Password 'incorrect password' -Request $request
            $result.ok | Should -BeFalse
            $result.message | Should -Be 'Invalid username or password.'
        }
        $store = Get-DunePortalAccountStore
        Test-DunePortalIsoFuture $store.accounts[0].lockoutUntil | Should -BeTrue
        Test-DunePortalIsoFuture $store.clientFailures[0].lockoutUntil | Should -BeTrue
        $created.account.id | Should -Not -BeNullOrEmpty
    }

    It 'requires a matching HTTPS origin for session-authenticated writes' {
        Test-DunePortalRequestOrigin (New-PortalTestRequest) | Should -BeTrue
        Test-DunePortalRequestOrigin (New-PortalTestRequest -Origin 'https://evil.example') | Should -BeFalse
        Test-DunePortalRequestOrigin (New-PortalTestRequest -Origin 'http://portal.example.test') | Should -BeFalse
    }

    It 'emits Secure HttpOnly SameSite Strict cookies' {
        $response = [pscustomobject]@{ Headers = @{} }
        Set-DunePortalSessionCookie -Response $response -Token 'opaque-value'
        $response.Headers['Set-Cookie'] | Should -Match 'Secure'
        $response.Headers['Set-Cookie'] | Should -Match 'HttpOnly'
        $response.Headers['Set-Cookie'] | Should -Match 'SameSite=Strict'
    }
}

Describe 'Portal auth route enforcement' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'marks every account administration route LocalOnly' {
        . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\PortalAuth.ps1')
        $adminRoutes = @($script:DuneRoutes | Where-Object { $_.Path -like '/api/remote-access/portal-account*' })
        $adminRoutes.Count | Should -BeGreaterThan 0
        @($adminRoutes | Where-Object { -not $_.LocalOnly }).Count | Should -Be 0
    }

    It 'denies the stable browser bearer path in account mode and retains rollback code' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $source | Should -Match 'Test-DuneLaunchToken'
        $source | Should -Match '\$rt -and -not \$accountMode'
        $source | Should -Match 'dune_key=; Path=/; Max-Age=0'
        $source | Should -Match 'elseif \(-not \(Test-DuneToken'
    }

    It 'caps portal authentication bodies before parsing' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $source | Should -Match "(?s)StartsWith\('/api/portal-auth/'\).*4096"
    }

    It 'never trusts a raw Cloudflare email header without a signed JWT' {
        Save-DuneRemoteAcl -Acl @{ owner = 'owner@example.test'; admins = @(); hostname = 'portal.example.test' } | Out-Null
        $request = [pscustomobject]@{ Headers = @{ 'Cf-Access-Authenticated-User-Email' = 'owner@example.test' } }
        $result = Test-DuneRemoteRequest -Request $request
        $result.ok | Should -BeFalse
        $result.status | Should -Be 401
    }
}
