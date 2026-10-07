BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:OriginalConfigFile = $script:DuneConfigFile
    $script:PortalTestRoot = Join-Path (Get-DstRepoRoot) '.portal-auth-test-data'
    $env:APPDATA = $script:PortalTestRoot
    Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteIdentity.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\PortalAuth.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RemoteAccess.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\lib\RequestPrincipal.ps1')
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    $script:DuneConfigFile = Join-Path $script:PortalTestRoot 'dune-server.config'
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
    $script:DuneConfigFile = $script:OriginalConfigFile
    Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Portal account password security' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
    It 'requires a host-assigned character for a Player account and creates a linked-player principal' {
        { New-DunePortalAccount -Username 'player-one' -Role player } | Should -Throw '*linked game character*'
        $created = New-DunePortalAccount -Username 'player-one' -Role player -GameCharacterId '11' -GameCharacterLabel 'Own'
        $principal = New-DuneRequestPrincipal -Request (New-PortalTestRequest -Address '192.0.2.1') -AccountMode $true -PortalSessionAuth @{ ok=$true;account=$created.account;sessionId='session' }
        $principal.type | Should -Be 'linked-player'
        $principal.linkedCharacter.id | Should -Be '11'
        $public = Get-DunePortalPublicAccount $created.account
        $public.role | Should -Be 'player'
        $public.ContainsKey('password') | Should -BeFalse
    }
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

Describe 'Legacy Cloudflare ACL enablement' {
    BeforeEach { Remove-Item -LiteralPath $script:PortalTestRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'defaults legacy ACLs to disabled while preserving their re-enable metadata' {
        $aclDir = Split-Path -Parent (Get-DuneRemoteAclPath)
        New-Item -ItemType Directory -Path $aclDir -Force | Out-Null
        @{
            owner = 'OWNER@example.test'
            admins = @('Admin@example.test')
            hostname = 'portal.example.test'
            cloudflareTeamDomain = 'team.cloudflareaccess.com'
            cloudflareAudience = 'audience-value'
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-DuneRemoteAclPath) -Encoding UTF8

        $acl = Get-DuneRemoteAcl

        $acl.legacyCloudflareEnabled | Should -BeFalse
        (Test-DuneLegacyCloudflarePortalEnabled) | Should -BeFalse
        $acl.owner | Should -Be 'owner@example.test'
        $acl.admins | Should -Contain 'admin@example.test'
        $acl.hostname | Should -Be 'portal.example.test'
        $acl.cloudflareTeamDomain | Should -Be 'team.cloudflareaccess.com'
        $acl.cloudflareAudience | Should -Be 'audience-value'
    }

    It 'fails closed when the persisted enablement field is malformed' {
        $aclDir = Split-Path -Parent (Get-DuneRemoteAclPath)
        New-Item -ItemType Directory -Path $aclDir -Force | Out-Null
        @{
            owner = 'owner@example.test'
            legacyCloudflareEnabled = 'true'
        } | ConvertTo-Json | Set-Content -LiteralPath (Get-DuneRemoteAclPath) -Encoding UTF8

        $acl = Get-DuneRemoteAcl

        $acl.legacyCloudflareEnabled | Should -BeFalse
        $acl.owner | Should -Be 'owner@example.test'
    }

    It 'persists only an explicit boolean enablement setting' {
        $saved = Save-DuneRemoteAcl -Acl @{
            owner = 'owner@example.test'
            admins = @('admin@example.test')
            hostname = 'portal.example.test'
            cloudflareTeamDomain = 'team.cloudflareaccess.com'
            cloudflareAudience = 'audience-value'
            legacyCloudflareEnabled = $true
        }

        $saved.legacyCloudflareEnabled | Should -BeTrue
        (Get-DuneRemoteAcl).legacyCloudflareEnabled | Should -BeTrue
        { Save-DuneRemoteAcl -Acl @{ legacyCloudflareEnabled = 'true' } } |
            Should -Throw '*must be a boolean*'
    }

    It 'denies disabled legacy Cloudflare traffic before JWT validation' {
        Save-DuneRemoteAcl -Acl @{
            owner = 'owner@example.test'
            legacyCloudflareEnabled = $false
        } | Out-Null
        Mock Test-DuneCloudflareAccessJwt { throw 'JWT validation must not run while disabled' }

        $result = Test-DuneRemoteRequest -Request ([pscustomobject]@{ Headers = @{} })

        $result.ok | Should -BeFalse
        $result.status | Should -Be 401
        Assert-MockCalled Test-DuneCloudflareAccessJwt -Times 0 -Exactly
    }

    It 'rejects retained Cloudflare enablement without validating JWTs' {
        Save-DuneRemoteAcl -Acl @{
            owner = 'owner@example.test'
            legacyCloudflareEnabled = $true
        } | Out-Null
        Mock Test-DuneCloudflareAccessJwt { @{ ok = $true; email = 'owner@example.test' } }

        $result = Test-DuneRemoteRequest -Request ([pscustomobject]@{ Headers = @{} })

        $result.ok | Should -BeFalse
        Assert-MockCalled Test-DuneCloudflareAccessJwt -Times 0 -Exactly
    }

    It 'revokes ordinary API and WebSocket launch-token access after disablement' {
        $originalRoutes = $script:DuneRoutes
        $originalWsRoutes = $script:DuneWsRoutes
        $originalToken = $script:DuneToken
        $originalRemoteToken = $script:DuneRemoteToken
        $originalPoolState = $script:DuneApiPoolEnabled
        try {
            $script:DuneRoutes = [Collections.Generic.List[object]]::new()
            $script:DuneWsRoutes = [Collections.Generic.List[object]]::new()
            $script:DuneToken = 'legacy-launch-token'
            $script:DuneApiPoolEnabled = $false
            Register-DuneRoute -Method GET -Path '/api/legacy-token-regression' -Handler {
                param($req, $res, $routeParams, $body)
                Write-DuneJson -Response $res -Body @{
                    principal = $routeParams.requestPrincipal.type
                    transport = $routeParams.requestPrincipal.transport.kind
                }
            }

            $newRequest = {
                param([bool]$IsWebSocket = $false)
                $url = if ($IsWebSocket) {
                    'http://127.0.0.1/ws/legacy-token-regression'
                } else {
                    'http://127.0.0.1/api/legacy-token-regression'
                }
                [pscustomobject]@{
                    Url = [uri]$url
                    HttpMethod = 'GET'
                    IsWebSocketRequest = $IsWebSocket
                    HasEntityBody = $false
                    Headers = @{
                        'X-Dune-Token' = 'legacy-launch-token'
                        'Cf-Access-Authenticated-User-Email' = 'owner@example.test'
                    }
                    QueryString = [Collections.Specialized.NameValueCollection]::new()
                    RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Loopback }
                }
            }
            $newResponse = {
                [pscustomobject]@{
                    StatusCode = 0
                    ContentType = ''
                    ContentLength64 = 0L
                    Headers = @{}
                    OutputStream = [IO.MemoryStream]::new()
                }
            }

            Save-DuneRemoteAcl -Acl @{
                owner = 'owner@example.test'
                legacyCloudflareEnabled = $true
            } | Out-Null
            $enabledResponse = & $newResponse
            Invoke-DuneContext -Ctx ([pscustomobject]@{
                Request = (& $newRequest)
                Response = $enabledResponse
            })
            $enabledBody = [Text.Encoding]::UTF8.GetString($enabledResponse.OutputStream.ToArray()) | ConvertFrom-Json

            $enabledResponse.StatusCode | Should -Be 401

            Save-DuneRemoteAcl -Acl @{
                owner = 'owner@example.test'
                legacyCloudflareEnabled = $false
            } | Out-Null
            $disabledResponse = & $newResponse
            Invoke-DuneContext -Ctx ([pscustomobject]@{
                Request = (& $newRequest)
                Response = $disabledResponse
            })

            $disabledResponse.StatusCode | Should -Be 401

            $disabledWsResponse = & $newResponse
            Invoke-DuneContext -Ctx ([pscustomobject]@{
                Request = (& $newRequest $true)
                Response = $disabledWsResponse
            })

            $disabledWsResponse.StatusCode | Should -Be 401

            $desktopRequest = & $newRequest
            $desktopRequest.Headers.Remove('Cf-Access-Authenticated-User-Email')
            $desktopResponse = & $newResponse
            Invoke-DuneContext -Ctx ([pscustomobject]@{
                Request = $desktopRequest
                Response = $desktopResponse
            })

            $desktopResponse.StatusCode | Should -Be 200

            $script:DuneRemoteToken = 'paired-service-token'
            $serviceRequest = & $newRequest
            $serviceRequest.Headers['X-Dune-Token'] = 'paired-service-token'
            $serviceRequest.Headers.Remove('Cf-Access-Authenticated-User-Email')
            $serviceRequest.Headers['Cf-Ray'] = 'service-token-path'
            $serviceResponse = & $newResponse
            Invoke-DuneContext -Ctx ([pscustomobject]@{
                Request = $serviceRequest
                Response = $serviceResponse
            })

            $serviceResponse.StatusCode | Should -Be 200
        } finally {
            $script:DuneRoutes = $originalRoutes
            $script:DuneWsRoutes = $originalWsRoutes
            $script:DuneToken = $originalToken
            $script:DuneRemoteToken = $originalRemoteToken
            $script:DuneApiPoolEnabled = $originalPoolState
        }
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

    It 'uses short server limits and a session cookie by default' {
        $created = New-DunePortalAccount -Username 'short-session-owner' -Role owner
        $before = (Get-Date).ToUniversalTime()
        $issued = New-DunePortalSession -AccountId $created.account.id
        $entry = $issued.session
        $entry.persistent | Should -BeFalse
        $entry.absoluteSeconds | Should -Be 43200
        $entry.idleSeconds | Should -Be 1800
        ([datetime]$entry.expiresAt - $before).TotalHours | Should -BeLessOrEqual 12.01
        ([datetime]$entry.idleExpiresAt - $before).TotalMinutes | Should -BeLessOrEqual 30.1

        $response = [pscustomobject]@{ Headers = @{} }
        Set-DunePortalSessionCookie -Response $response -Token $issued.token
        $response.Headers['Set-Cookie'] | Should -Not -Match 'Max-Age|Expires='
    }

    It 'matches remembered cookie persistence to 30-day absolute and 7-day idle server limits' {
        $created = New-DunePortalAccount -Username 'remembered-owner' -Role owner
        $before = (Get-Date).ToUniversalTime()
        $issued = New-DunePortalSession -AccountId $created.account.id -RememberMe:$true
        $entry = $issued.session
        $entry.persistent | Should -BeTrue
        $entry.absoluteSeconds | Should -Be 2592000
        $entry.idleSeconds | Should -Be 604800
        ([datetime]$entry.expiresAt - $before).TotalDays | Should -BeLessOrEqual 30.01
        ([datetime]$entry.idleExpiresAt - $before).TotalDays | Should -BeLessOrEqual 7.01

        $response = [pscustomobject]@{ Headers = @{} }
        Set-DunePortalSessionCookie -Response $response -Token $issued.token -RememberMe:$true
        $response.Headers['Set-Cookie'] | Should -Match 'Max-Age=2592000'
        $response.Headers['Set-Cookie'] | Should -Match 'Secure; HttpOnly; SameSite=Strict'
    }

    It 'preserves remembered state while rotating a forced-change session' {
        $created = New-DunePortalAccount -Username 'remember-change-owner' -Role owner
        $old = New-DunePortalSession -AccountId $created.account.id -RememberMe:$true
        $auth = Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $old.token)
        $auth.rememberMe | Should -BeTrue
        $new = Set-DunePortalPassword -AccountId $created.account.id `
            -CurrentPassword $created.oneTimePassword -NewPassword 'a replacement password' `
            -RememberMe:$auth.rememberMe
        $new.session.persistent | Should -BeTrue
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $old.token)).ok | Should -BeFalse
        (Get-DunePortalSessionAuth (New-PortalTestRequest -Cookie $new.token)).ok | Should -BeTrue
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

    It 'rejects an already locked request before invoking PBKDF2' {
        $created = New-DunePortalAccount -Username 'locked-owner' -Role owner
        $store = Get-DunePortalAccountStore
        $store.accounts[0].lockoutUntil = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
        Save-DunePortalAccountStore $store
        Mock Test-DunePortalPassword { throw 'PBKDF2 must not run for locked traffic' }
        $result = Invoke-DunePortalLogin -Username 'locked-owner' -Password $created.oneTimePassword -Request (New-PortalTestRequest)
        $result.ok | Should -BeFalse
        Assert-MockCalled Test-DunePortalPassword -Times 0 -Exactly
    }

    It 'does not let spoofed proxy headers create a global loopback lockout bucket' {
        $created = New-DunePortalAccount -Username 'proxy-owner' -Role owner
        1..5 | ForEach-Object {
            $request = New-PortalTestRequest
            $request.Headers['X-Forwarded-For'] = "198.51.100.$_"
            $request.Headers['Cf-Connecting-Ip'] = "203.0.113.$_"
            (Invoke-DunePortalLogin -Username 'missing-user' -Password 'incorrect password' -Request $request).ok | Should -BeFalse
        }
        (Get-DunePortalAccountStore).clientFailures.Count | Should -Be 0
        (Invoke-DunePortalLogin -Username 'proxy-owner' -Password $created.oneTimePassword -Request (New-PortalTestRequest)).ok |
            Should -BeTrue
    }

    It 'uses only cryptographically verified Cloudflare identities behind loopback' {
        Mock Get-DunePortalVerifiedProxyIdentity { [string]$Request.Headers['X-Test-Verified-Email'] }
        $first = New-PortalTestRequest
        $first.Headers['X-Test-Verified-Email'] = 'one@example.test'
        $second = New-PortalTestRequest
        $second.Headers['X-Test-Verified-Email'] = 'two@example.test'
        Get-DunePortalClientKey $first | Should -Not -Be (Get-DunePortalClientKey $second)
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

    It 'keeps the legacy token usable outside account mode but cannot spoof a native exemption inside it' {
        $script:DuneToken = 'launch-token'
        $script:DuneRemoteToken = 'paired-native-token'
        $request = [pscustomobject]@{
            Headers = @{ 'X-Dune-Token'='paired-native-token'; 'User-Agent'='DuneServerMobile/retirement' }
            QueryString = @{}
            RemoteEndPoint = [pscustomobject]@{ Address=[Net.IPAddress]::Parse('192.0.2.44') }
        }
        Test-DuneToken $request | Should -BeTrue
        Test-DuneAccountModeLaunchAccess $request | Should -BeFalse
    }

    It 'caps portal authentication bodies before parsing' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $source | Should -Match "(?s)StartsWith\('/api/portal-auth/'\).*4096"
    }

    It 'never trusts a raw Cloudflare email header without a signed JWT' {
        Save-DuneRemoteAcl -Acl @{
            owner = 'owner@example.test'
            admins = @()
            hostname = 'portal.example.test'
            legacyCloudflareEnabled = $true
        } | Out-Null
        $request = [pscustomobject]@{ Headers = @{ 'Cf-Access-Authenticated-User-Email' = 'owner@example.test' } }
        $result = Test-DuneRemoteRequest -Request $request
        $result.ok | Should -BeFalse
        $result.status | Should -Be 401
    }
}
