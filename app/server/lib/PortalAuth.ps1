# PortalAuth.ps1 - opt-in local accounts for the existing Browser Portal.

$script:DunePortalAuthIterations = 310000
$script:DunePortalSessionHours = 12
$script:DunePortalIdleMinutes = 30
$script:DunePortalCookieName = 'dune_portal_session'

function Get-DunePortalAuthDirectory {
    $dir = Join-Path $env:APPDATA 'DuneServer\portal-auth'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-DunePortalAccountsPath { return (Join-Path (Get-DunePortalAuthDirectory) 'accounts.json') }
function Get-DunePortalSessionsPath { return (Join-Path (Get-DunePortalAuthDirectory) 'sessions.json') }
function Get-DunePortalAuditPath { return (Join-Path (Get-DunePortalAuthDirectory) 'audit.log') }

function Invoke-DunePortalAuthLock {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $path = (Get-DunePortalAuthDirectory).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))) -replace '-', '').Substring(0, 20)
    } finally { $sha.Dispose() }
    $mutex = New-Object System.Threading.Mutex($false, "Local\DunePortalAuth_$id")
    $held = $false
    try {
        try { $held = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Portal account store is busy.' }
        return (& $Action)
    } finally {
        if ($held) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function ConvertTo-DunePortalHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $Value.Keys) { $out[[string]$key] = ConvertTo-DunePortalHashtable $Value[$key] }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = @{}
        foreach ($p in $Value.PSObject.Properties) { $out[$p.Name] = ConvertTo-DunePortalHashtable $p.Value }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return ,@($Value | ForEach-Object { ConvertTo-DunePortalHashtable $_ })
    }
    return $Value
}

function Read-DunePortalJson {
    param([string]$Path, [Parameter(Mandatory)]$Default)
    foreach ($candidate in @($Path, "$Path.bak")) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $raw = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            return (ConvertTo-DunePortalHashtable ($raw | ConvertFrom-Json -ErrorAction Stop))
        } catch {}
    }
    return $Default
}

function Write-DunePortalJson {
    param([string]$Path, [Parameter(Mandatory)]$Value)
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
        if (Test-Path -LiteralPath $Path) {
            $preserve = $false
            try {
                $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($existing)) {
                    $null = $existing | ConvertFrom-Json -ErrorAction Stop
                    $preserve = $true
                }
            } catch {}
            if ($preserve) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-DunePortalAccountStore {
    return (Read-DunePortalJson -Path (Get-DunePortalAccountsPath) -Default @{
        version = 1
        accountLoginEnabled = $false
        accounts = @()
        clientFailures = @()
    })
}

function Save-DunePortalAccountStore {
    param([Parameter(Mandatory)][hashtable]$Store)
    Write-DunePortalJson -Path (Get-DunePortalAccountsPath) -Value $Store
}

function Get-DunePortalSessionStore {
    return (Read-DunePortalJson -Path (Get-DunePortalSessionsPath) -Default @{ version = 1; sessions = @() })
}

function Save-DunePortalSessionStore {
    param([Parameter(Mandatory)][hashtable]$Store)
    Write-DunePortalJson -Path (Get-DunePortalSessionsPath) -Value $Store
}

function Normalize-DunePortalUsername {
    param([string]$Username)
    if ($null -eq $Username) { return '' }
    return $Username.Trim().ToLowerInvariant()
}

function Test-DunePortalUsername {
    param([string]$Username)
    $u = Normalize-DunePortalUsername $Username
    return ($u.Length -ge 3 -and $u.Length -le 64 -and $u -match '^[a-z0-9][a-z0-9._ -]*[a-z0-9]$')
}

function Test-DunePortalPasswordPolicy {
    param([string]$Password)
    return ($null -ne $Password -and $Password.Length -ge 12 -and $Password.Length -le 128)
}

function New-DunePortalOneTimePassword {
    return (New-DuneRandomToken -Bytes 18)
}

function Get-DunePbkdf2Sha256 {
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][byte[]]$Salt,
        [Parameter(Mandatory)][int]$Iterations,
        [int]$Length = 32
    )
    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        [Text.Encoding]::UTF8.GetBytes($Password),
        $Salt,
        $Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try { return $derive.GetBytes($Length) } finally { $derive.Dispose() }
}

function New-DunePortalPasswordHash {
    param([Parameter(Mandatory)][string]$Password, [int]$Iterations = $script:DunePortalAuthIterations)
    if (-not (Test-DunePortalPasswordPolicy $Password)) {
        throw 'Password must be 12 to 128 characters.'
    }
    $salt = [byte[]]::new(16)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
    $hash = Get-DunePbkdf2Sha256 -Password $Password -Salt $salt -Iterations $Iterations
    return @{
        algorithm = 'PBKDF2-HMAC-SHA256'
        version = 1
        iterations = $Iterations
        salt = [Convert]::ToBase64String($salt)
        hash = [Convert]::ToBase64String($hash)
    }
}

function Test-DunePortalFixedTimeEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $diff = $Left.Length -bxor $Right.Length
    $max = [Math]::Max($Left.Length, $Right.Length)
    for ($i = 0; $i -lt $max; $i++) {
        $a = if ($i -lt $Left.Length) { $Left[$i] } else { 0 }
        $b = if ($i -lt $Right.Length) { $Right[$i] } else { 0 }
        $diff = $diff -bor ($a -bxor $b)
    }
    return ($diff -eq 0)
}

function Test-DunePortalPassword {
    param([Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)]$Metadata)
    try {
        if ([string]$Metadata.algorithm -ne 'PBKDF2-HMAC-SHA256' -or [int]$Metadata.version -ne 1) { return $false }
        $expected = [Convert]::FromBase64String([string]$Metadata.hash)
        $actual = Get-DunePbkdf2Sha256 -Password $Password -Salt ([Convert]::FromBase64String([string]$Metadata.salt)) -Iterations ([int]$Metadata.iterations) -Length $expected.Length
        return (Test-DunePortalFixedTimeEqual -Left $actual -Right $expected)
    } catch { return $false }
}

function Get-DunePortalSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) } finally { $sha.Dispose() }
}

function Write-DunePortalAudit {
    param([string]$Event, [string]$Result, [string]$ClientKey = '')
    try {
        $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date).ToUniversalTime().ToString('o'), $Event, $Result, $(if ($ClientKey) { $ClientKey.Substring(0, [Math]::Min(12, $ClientKey.Length)) } else { '-' })
        Add-Content -LiteralPath (Get-DunePortalAuditPath) -Value $line -Encoding UTF8
    } catch {}
}

function Get-DunePortalVerifiedProxyIdentity {
    param($Request)
    try {
        $assertion = [string]$Request.Headers['Cf-Access-Jwt-Assertion']
        if ($assertion -and
            (Get-Command Get-DuneRemoteAcl -ErrorAction SilentlyContinue) -and
            (Get-Command Test-DuneCloudflareAccessJwt -ErrorAction SilentlyContinue)) {
            $identity = Test-DuneCloudflareAccessJwt -Request $Request -Acl (Get-DuneRemoteAcl)
            if ($identity.ok -and $identity.email) {
                return ([string]$identity.email).Trim().ToLowerInvariant()
            }
        }
    } catch {}
    return ''
}

function Get-DunePortalClientKey {
    param($Request)
    $address = 'unknown'
    try { $address = [string]$Request.RemoteEndPoint.Address } catch {}
    $isLoopback = $false
    try { $isLoopback = [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($address)) } catch {}
    if (-not $isLoopback) {
        return (Get-DunePortalSha256 -Value "socket:$address")
    }

    # A loopback socket is shared by Funnel, cloudflared, and the local bridge.
    # Arbitrary forwarding headers are not identities. Only a Cloudflare Access
    # JWT that passes the existing signature/issuer/audience validation can split
    # this proxy bucket into logical clients. Funnel/bridge traffic deliberately
    # has no client bucket; account lockout and the PBKDF2 cost still apply.
    $verifiedIdentity = Get-DunePortalVerifiedProxyIdentity -Request $Request
    if ($verifiedIdentity) {
        return (Get-DunePortalSha256 -Value "cloudflare:$verifiedIdentity")
    }
    return ''
}

function Get-DunePortalAccountByUsername {
    param([hashtable]$Store, [string]$Username)
    $normalized = Normalize-DunePortalUsername $Username
    return @($Store.accounts | Where-Object { [string]$_.normalizedUsername -eq $normalized } | Select-Object -First 1)[0]
}

function Get-DunePortalAccountById {
    param([hashtable]$Store, [string]$AccountId)
    return @($Store.accounts | Where-Object { [string]$_.id -eq $AccountId } | Select-Object -First 1)[0]
}

function New-DunePortalAccount {
    param(
        [Parameter(Mandatory)][string]$Username,
        [ValidateSet('owner','admin')][string]$Role = 'admin',
        [string]$Password = '',
        [string]$GameCharacterId = '',
        [string]$GameCharacterLabel = ''
    )
    if (-not (Test-DunePortalUsername $Username)) { throw 'Username must be 3-64 characters using letters, numbers, spaces, dot, underscore, or hyphen.' }
    if ($GameCharacterId.Length -gt 128 -or $GameCharacterLabel.Length -gt 128) { throw 'Character linkage is too long.' }
    $oneTime = $Password
    $generated = $false
    if (-not $oneTime) { $oneTime = New-DunePortalOneTimePassword; $generated = $true }
    if (-not (Test-DunePortalPasswordPolicy $oneTime)) { throw 'Password must be 12 to 128 characters.' }
    return Invoke-DunePortalAuthLock {
        $store = Get-DunePortalAccountStore
        if (Get-DunePortalAccountByUsername -Store $store -Username $Username) { throw 'That username is already in use.' }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $account = @{
            id = [guid]::NewGuid().ToString('N')
            username = $Username.Trim()
            normalizedUsername = Normalize-DunePortalUsername $Username
            gameCharacterId = $GameCharacterId.Trim()
            gameCharacterLabel = $GameCharacterLabel.Trim()
            role = $Role
            enabled = $true
            password = New-DunePortalPasswordHash -Password $oneTime
            mustChangePassword = $true
            createdAt = $now
            updatedAt = $now
            passwordChangedAt = $now
            lastLoginAt = ''
            locallyVerifiedAt = ''
            failedCount = 0
            lockoutUntil = ''
        }
        $store.accounts = @($store.accounts) + @($account)
        Save-DunePortalAccountStore $store
        return @{ account = $account; oneTimePassword = $oneTime; generated = $generated }
    }
}

function Get-DunePortalPublicAccount {
    param($Account)
    return @{
        id = [string]$Account.id
        username = [string]$Account.username
        gameCharacterId = [string]$Account.gameCharacterId
        gameCharacterLabel = [string]$Account.gameCharacterLabel
        role = [string]$Account.role
        enabled = [bool]$Account.enabled
        mustChangePassword = [bool]$Account.mustChangePassword
        createdAt = [string]$Account.createdAt
        updatedAt = [string]$Account.updatedAt
        passwordChangedAt = [string]$Account.passwordChangedAt
        lastLoginAt = [string]$Account.lastLoginAt
        locallyVerified = -not [string]::IsNullOrWhiteSpace([string]$Account.locallyVerifiedAt)
    }
}

function Test-DunePortalAccountModeEnabled {
    try { return [bool](Get-DunePortalAccountStore).accountLoginEnabled } catch { return $false }
}

function Get-DunePortalLockSeconds {
    param([int]$Failures)
    if ($Failures -lt 5) { return 0 }
    return [Math]::Min(900, [int](30 * [Math]::Pow(2, [Math]::Min(5, $Failures - 5))))
}

function Test-DunePortalIsoFuture {
    param($Value, [datetime]$Now = (Get-Date).ToUniversalTime())
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    if ($Value -is [datetime]) {
        return ($Value.ToUniversalTime() -gt $Now.ToUniversalTime())
    }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Value, [ref]$parsed)) { return $false }
    return ($parsed.UtcDateTime -gt $Now.ToUniversalTime())
}

function Register-DunePortalLoginFailure {
    param([hashtable]$Store, $Account, [string]$ClientKey)
    $now = (Get-Date).ToUniversalTime()
    if ($Account) {
        $Account.failedCount = [int]$Account.failedCount + 1
        $seconds = Get-DunePortalLockSeconds $Account.failedCount
        if ($seconds -gt 0) { $Account.lockoutUntil = $now.AddSeconds($seconds).ToString('o') }
        $Account.updatedAt = $now.ToString('o')
    }
    if (-not $ClientKey) { return }
    $client = @($Store.clientFailures | Where-Object { $_.key -eq $ClientKey } | Select-Object -First 1)[0]
    if (-not $client) {
        $client = @{ key = $ClientKey; count = 0; windowStart = $now.ToString('o'); lockoutUntil = '' }
        $Store.clientFailures = @($Store.clientFailures) + @($client)
    }
    $window = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$client.windowStart, [ref]$window) -or $window.ToUniversalTime() -lt $now.AddMinutes(-15)) {
        $client.count = 0; $client.windowStart = $now.ToString('o'); $client.lockoutUntil = ''
    }
    $client.count = [int]$client.count + 1
    $seconds = Get-DunePortalLockSeconds $client.count
    if ($seconds -gt 0) { $client.lockoutUntil = $now.AddSeconds($seconds).ToString('o') }
}

function New-DunePortalSession {
    param([Parameter(Mandatory)][string]$AccountId)
    $token = New-DuneRandomToken -Bytes 32
    $now = (Get-Date).ToUniversalTime()
    $session = @{
        tokenHash = Get-DunePortalSha256 $token
        accountId = $AccountId
        createdAt = $now.ToString('o')
        expiresAt = $now.AddHours($script:DunePortalSessionHours).ToString('o')
        lastSeenAt = $now.ToString('o')
        idleExpiresAt = $now.AddMinutes($script:DunePortalIdleMinutes).ToString('o')
    }
    $store = Get-DunePortalSessionStore
    $store.sessions = @($store.sessions | Where-Object {
        (Test-DunePortalIsoFuture $_.expiresAt $now) -and (Test-DunePortalIsoFuture $_.idleExpiresAt $now)
    }) + @($session)
    Save-DunePortalSessionStore $store
    return @{ token = $token; session = $session }
}

function Revoke-DunePortalSessions {
    param([string]$AccountId = '')
    Invoke-DunePortalAuthLock {
        $store = Get-DunePortalSessionStore
        if ($AccountId) { $store.sessions = @($store.sessions | Where-Object { $_.accountId -ne $AccountId }) }
        else { $store.sessions = @() }
        Save-DunePortalSessionStore $store
    }

}

function Revoke-DunePortalSessionToken {
    param([string]$Token)
    if (-not $Token) { return }
    Invoke-DunePortalAuthLock {
        $hash = Get-DunePortalSha256 $Token
        $store = Get-DunePortalSessionStore
        $store.sessions = @($store.sessions | Where-Object { $_.tokenHash -ne $hash })
        Save-DunePortalSessionStore $store
    }
}

function Get-DunePortalCookieToken {
    param($Request)
    try {
        $cookie = $Request.Cookies[$script:DunePortalCookieName]
        if ($cookie) { return [string]$cookie.Value }
    } catch {}
    return ''
}

function Set-DunePortalSessionCookie {
    param($Response, [string]$Token)
    $maxAge = $script:DunePortalSessionHours * 3600
    $Response.Headers['Set-Cookie'] = "$($script:DunePortalCookieName)=$Token; Path=/; Max-Age=$maxAge; Secure; HttpOnly; SameSite=Strict"
}

function Clear-DunePortalSessionCookie {
    param($Response)
    $Response.Headers['Set-Cookie'] = "$($script:DunePortalCookieName)=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure; HttpOnly; SameSite=Strict"
}

function Get-DunePortalSessionAuth {
    param($Request)
    $token = Get-DunePortalCookieToken $Request
    if (-not $token) { return @{ ok = $false } }
    return Invoke-DunePortalAuthLock {
        $now = (Get-Date).ToUniversalTime()
        $hash = Get-DunePortalSha256 $token
        $sessions = Get-DunePortalSessionStore
        $match = @($sessions.sessions | Where-Object { Test-DunePortalFixedTimeEqual ([Convert]::FromBase64String([string]$_.tokenHash)) ([Convert]::FromBase64String($hash)) } | Select-Object -First 1)[0]
        $sessions.sessions = @($sessions.sessions | Where-Object {
            (Test-DunePortalIsoFuture $_.expiresAt $now) -and (Test-DunePortalIsoFuture $_.idleExpiresAt $now)
        })
        if (-not $match -or -not (Test-DunePortalIsoFuture $match.expiresAt $now) -or -not (Test-DunePortalIsoFuture $match.idleExpiresAt $now)) {
            Save-DunePortalSessionStore $sessions
            return @{ ok = $false }
        }
        $accounts = Get-DunePortalAccountStore
        $account = Get-DunePortalAccountById $accounts ([string]$match.accountId)
        if (-not $account -or -not [bool]$account.enabled) {
            $sessions.sessions = @($sessions.sessions | Where-Object { $_.tokenHash -ne $match.tokenHash })
            Save-DunePortalSessionStore $sessions
            return @{ ok = $false }
        }
        $match.lastSeenAt = $now.ToString('o')
        $match.idleExpiresAt = $now.AddMinutes($script:DunePortalIdleMinutes).ToString('o')
        Save-DunePortalSessionStore $sessions
        return @{ ok = $true; account = $account; mustChangePassword = [bool]$account.mustChangePassword }
    }
}

function Test-DunePortalRequestOrigin {
    param($Request)
    $origin = ''
    try { $origin = [string]$Request.Headers['Origin'] } catch {}
    if (-not $origin) { return $false }
    try {
        $originUri = [uri]$origin
        $requestHost = [string]$Request.Headers['Host']
        return ($originUri.Authority -eq $requestHost -and $originUri.Scheme -eq 'https')
    } catch { return $false }
}

function Invoke-DunePortalLogin {
    param([string]$Username, [string]$Password, $Request)
    $clientKey = Get-DunePortalClientKey $Request
    return Invoke-DunePortalAuthLock {
        $store = Get-DunePortalAccountStore
        $account = Get-DunePortalAccountByUsername $store $Username
        $client = if ($clientKey) {
            @($store.clientFailures | Where-Object { $_.key -eq $clientKey } | Select-Object -First 1)[0]
        } else { $null }
        $clientLocked = if ($client) { Test-DunePortalIsoFuture $client.lockoutUntil } else { $false }
        $accountLocked = if ($account) { Test-DunePortalIsoFuture $account.lockoutUntil } else { $false }
        $locked = ($clientLocked -or $accountLocked)

        $metadata = if ($account) { $account.password } else {
            @{
                algorithm = 'PBKDF2-HMAC-SHA256'; version = 1; iterations = $script:DunePortalAuthIterations
                salt = 'AAAAAAAAAAAAAAAAAAAAAA=='; hash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
            }
        }
        $passwordOk = Test-DunePortalPassword $Password $metadata
        if ($locked -or -not $account -or -not [bool]$account.enabled -or -not $passwordOk) {
            Register-DunePortalLoginFailure -Store $store -Account $account -ClientKey $clientKey
            Save-DunePortalAccountStore $store
            Write-DunePortalAudit -Event 'login' -Result 'denied' -ClientKey $clientKey
            return @{ ok = $false; status = 401; message = 'Invalid username or password.' }
        }
        $account.failedCount = 0
        $account.lockoutUntil = ''
        $account.lastLoginAt = (Get-Date).ToUniversalTime().ToString('o')
        if ($client) { $client.count = 0; $client.lockoutUntil = '' }
        Save-DunePortalAccountStore $store
        $issued = New-DunePortalSession -AccountId ([string]$account.id)
        Write-DunePortalAudit -Event 'login' -Result 'success' -ClientKey $clientKey
        return @{ ok = $true; account = $account; token = $issued.token }
    }
}

function Set-DunePortalPassword {
    param([string]$AccountId, [string]$CurrentPassword, [string]$NewPassword)
    if ($CurrentPassword.Length -gt 128) { throw 'Current password is incorrect.' }
    if (-not (Test-DunePortalPasswordPolicy $NewPassword)) { throw 'Password must be 12 to 128 characters.' }
    return Invoke-DunePortalAuthLock {
        $store = Get-DunePortalAccountStore
        $account = Get-DunePortalAccountById $store $AccountId
        if (-not $account -or -not (Test-DunePortalPassword $CurrentPassword $account.password)) { throw 'Current password is incorrect.' }
        $account.password = New-DunePortalPasswordHash $NewPassword
        $account.mustChangePassword = $false
        $account.passwordChangedAt = (Get-Date).ToUniversalTime().ToString('o')
        $account.updatedAt = $account.passwordChangedAt
        Save-DunePortalAccountStore $store
        Revoke-DunePortalSessions -AccountId $AccountId
        return (New-DunePortalSession -AccountId $AccountId)
    }
}

function Reset-DunePortalAccountPassword {
    param([string]$AccountId)
    $password = New-DunePortalOneTimePassword
    Invoke-DunePortalAuthLock {
        $store = Get-DunePortalAccountStore
        $account = Get-DunePortalAccountById $store $AccountId
        if (-not $account) { throw 'Account not found.' }
        $account.password = New-DunePortalPasswordHash $password
        $account.mustChangePassword = $true
        $account.locallyVerifiedAt = ''
        $account.passwordChangedAt = (Get-Date).ToUniversalTime().ToString('o')
        $account.updatedAt = $account.passwordChangedAt
        Save-DunePortalAccountStore $store
        Revoke-DunePortalSessions -AccountId $AccountId
    }
    return $password
}

function Test-DunePortalEnablePreconditions {
    param([hashtable]$Store)
    $owners = @($Store.accounts | Where-Object { $_.enabled -and $_.role -eq 'owner' -and $_.locallyVerifiedAt })
    return ($owners.Count -gt 0)
}

function Get-DunePortalDiagnosticState {
    $store = Get-DunePortalAccountStore
    return @{
        accountLoginEnabled = [bool]$store.accountLoginEnabled
        accountCount = @($store.accounts).Count
        enabledAccountCount = @($store.accounts | Where-Object { $_.enabled }).Count
        lockedAccountCount = @($store.accounts | Where-Object { Test-DunePortalIsoFuture $_.lockoutUntil }).Count
    }
}
