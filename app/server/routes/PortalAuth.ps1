# Browser Portal account authentication and host-local account administration.

function Get-DunePortalBodyValue {
    param($Body, [string]$Name)
    if ($Body -is [hashtable] -and $Body.ContainsKey($Name)) { return $Body[$Name] }
    if ($Body -and $Body.PSObject.Properties.Name -contains $Name) { return $Body.$Name }
    return $null
}

Register-DuneRoute -Method GET -Path '/api/portal-auth/status' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    $enabled = Test-DunePortalAccountModeEnabled
    $auth = if ($enabled) { Get-DunePortalSessionAuth -Request $req } else { @{ ok = $false } }
    $localLaunch = $false
    try { $localLaunch = Test-DuneAccountModeLaunchAccess -Request $req } catch {}
    Write-DuneJson -Response $res -Body @{
        accountLoginEnabled = $enabled
        authenticated = ([bool]$auth.ok -or $localLaunch)
        mustChangePassword = [bool]$auth.mustChangePassword
        account = if ($auth.ok) { Get-DunePortalPublicAccount $auth.account } else { $null }
    }
}

Register-DuneRoute -Method POST -Path '/api/portal-auth/login' -Handler {
    param($req, $res, $routeParams, $body)
    if (-not (Test-DunePortalAccountModeEnabled)) {
        Write-DuneError -Response $res -Status 404 -Message 'Not found.'
        return
    }
    $username = [string](Get-DunePortalBodyValue $body 'username')
    $password = [string](Get-DunePortalBodyValue $body 'password')
    $rememberValue = Get-DunePortalBodyValue $body 'rememberMe'
    if ($null -ne $rememberValue -and $rememberValue -isnot [bool]) {
        Write-DuneError -Response $res -Status 400 -Message 'Invalid request.'
        return
    }
    $rememberMe = if ($null -eq $rememberValue) { $false } else { [bool]$rememberValue }
    if ($username.Length -gt 64 -or $password.Length -gt 128) {
        Write-DuneError -Response $res -Status 400 -Message 'Invalid request.'
        return
    }
    $result = Invoke-DunePortalLogin -Username $username -Password $password -Request $req -RememberMe:$rememberMe
    if (-not $result.ok) {
        Write-DuneError -Response $res -Status 401 -Message 'Invalid username or password.'
        return
    }
    Revoke-DunePortalSessionToken -Token (Get-DunePortalCookieToken $req)
    Set-DunePortalSessionCookie -Response $res -Token $result.token -RememberMe:$rememberMe
    Write-DuneJson -Response $res -Body @{
        ok = $true
        accountLoginEnabled = $true
        authenticated = $true
        mustChangePassword = [bool]$result.account.mustChangePassword
        account = Get-DunePortalPublicAccount $result.account
    }
}

Register-DuneRoute -Method POST -Path '/api/portal-auth/logout' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    $token = Get-DunePortalCookieToken $req
    if ($token) { Revoke-DunePortalSessionToken -Token $token }
    Clear-DunePortalSessionCookie $res
    Write-DuneJson -Response $res -Body @{ ok = $true }
}

Register-DuneRoute -Method POST -Path '/api/portal-auth/change-password' -Inline -Handler {
    param($req, $res, $routeParams, $body)
    $auth = Get-DunePortalSessionAuth -Request $req
    if (-not $auth.ok) {
        Clear-DunePortalSessionCookie $res
        Write-DuneError -Response $res -Status 401 -Message 'Authentication required.'
        return
    }
    try {
        $issued = Set-DunePortalPassword `
            -AccountId ([string]$auth.account.id) `
            -CurrentPassword ([string](Get-DunePortalBodyValue $body 'currentPassword')) `
            -NewPassword ([string](Get-DunePortalBodyValue $body 'newPassword')) `
            -RememberMe:([bool]$auth.rememberMe)
        Set-DunePortalSessionCookie -Response $res -Token $issued.token -RememberMe:([bool]$auth.rememberMe)
        Write-DuneJson -Response $res -Body @{ ok = $true; mustChangePassword = $false }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/remote-access/portal-accounts' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $store = Get-DunePortalAccountStore
    Write-DuneJson -Response $res -Body @{
        accountLoginEnabled = [bool]$store.accountLoginEnabled
        nativeAppsBlockedInAccountMode = $true
        accounts = @($store.accounts | ForEach-Object { Get-DunePortalPublicAccount $_ })
        roles = @('owner','admin')
    }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/portal-accounts' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $result = New-DunePortalAccount `
            -Username ([string](Get-DunePortalBodyValue $body 'username')) `
            -Role ([string](Get-DunePortalBodyValue $body 'role')) `
            -Password ([string](Get-DunePortalBodyValue $body 'password')) `
            -GameCharacterId ([string](Get-DunePortalBodyValue $body 'gameCharacterId')) `
            -GameCharacterLabel ([string](Get-DunePortalBodyValue $body 'gameCharacterLabel'))
        Write-DuneJson -Response $res -Status 201 -Body @{
            account = Get-DunePortalPublicAccount $result.account
            oneTimePassword = $result.oneTimePassword
            generated = $result.generated
        }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/remote-access/portal-accounts/{id}' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $updated = Invoke-DunePortalAuthLock {
            $store = Get-DunePortalAccountStore
            $account = Get-DunePortalAccountById $store ([string]$routeParams.id)
            if (-not $account) { throw 'Account not found.' }
            $enabledValue = Get-DunePortalBodyValue $body 'enabled'
            if ($null -ne $enabledValue) { $account.enabled = [bool]$enabledValue }
            $role = [string](Get-DunePortalBodyValue $body 'role')
            if ($role) {
                if ($role -notin @('owner','admin')) { throw 'Invalid role.' }
                $account.role = $role
            }
            $characterId = Get-DunePortalBodyValue $body 'gameCharacterId'
            if ($null -ne $characterId) {
                if (([string]$characterId).Length -gt 128 -or ([string](Get-DunePortalBodyValue $body 'gameCharacterLabel')).Length -gt 128) {
                    throw 'Character linkage is too long.'
                }
                $account.gameCharacterId = ([string]$characterId).Trim()
                $account.gameCharacterLabel = ([string](Get-DunePortalBodyValue $body 'gameCharacterLabel')).Trim()
            }
            $remainingOwners = @($store.accounts | Where-Object { $_.enabled -and $_.role -eq 'owner' })
            if ($store.accountLoginEnabled -and $remainingOwners.Count -lt 1) {
                throw 'Account login needs at least one enabled owner.'
            }
            $account.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            Save-DunePortalAccountStore $store
            if (-not $account.enabled) { Revoke-DunePortalSessions -AccountId ([string]$account.id) }
            return $account
        }
        if (-not $updated.enabled) { Clear-DunePortalSessionCookie $res }
        Write-DuneJson -Response $res -Body @{ account = Get-DunePortalPublicAccount $updated }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method DELETE -Path '/api/remote-access/portal-accounts/{id}' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Invoke-DunePortalAuthLock {
            $store = Get-DunePortalAccountStore
            $account = Get-DunePortalAccountById $store ([string]$routeParams.id)
            if (-not $account) { throw 'Account not found.' }
            $remainingOwners = @($store.accounts | Where-Object {
                $_.id -ne $account.id -and $_.enabled -and $_.role -eq 'owner'
            })
            if ($store.accountLoginEnabled -and $account.enabled -and $account.role -eq 'owner' -and $remainingOwners.Count -lt 1) {
                throw 'Cannot delete the last enabled owner while account login is enabled.'
            }
            $store.accounts = @($store.accounts | Where-Object { $_.id -ne $account.id })
            Save-DunePortalAccountStore $store
            Revoke-DunePortalSessions -AccountId ([string]$account.id)
        }
        Clear-DunePortalSessionCookie $res
        Write-DuneJson -Response $res -Body @{ ok = $true }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/portal-accounts/{id}/reset-password' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $password = Reset-DunePortalAccountPassword -AccountId ([string]$routeParams.id)
        Clear-DunePortalSessionCookie $res
        Write-DuneJson -Response $res -Body @{ ok = $true; oneTimePassword = $password }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/portal-accounts/{id}/revoke-sessions' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    Revoke-DunePortalSessions -AccountId ([string]$routeParams.id)
    Clear-DunePortalSessionCookie $res
    Write-DuneJson -Response $res -Body @{ ok = $true }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/portal-accounts/revoke-all-sessions' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    Revoke-DunePortalSessions
    Clear-DunePortalSessionCookie $res
    Write-DuneJson -Response $res -Body @{ ok = $true }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/portal-accounts/verify-owner' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $username = [string](Get-DunePortalBodyValue $body 'username')
    $password = [string](Get-DunePortalBodyValue $body 'password')
    try {
        $account = Invoke-DunePortalAuthLock {
            $store = Get-DunePortalAccountStore
            $found = Get-DunePortalAccountByUsername $store $username
            if (-not $found -or -not $found.enabled -or $found.role -ne 'owner' -or -not (Test-DunePortalPassword $password $found.password)) {
                throw 'Owner verification failed.'
            }
            $found.locallyVerifiedAt = (Get-Date).ToUniversalTime().ToString('o')
            $found.updatedAt = $found.locallyVerifiedAt
            Save-DunePortalAccountStore $store
            return $found
        }
        Write-DuneJson -Response $res -Body @{ ok = $true; account = Get-DunePortalPublicAccount $account }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message 'Owner verification failed.'
    }
}

Register-DuneRoute -Method PUT -Path '/api/remote-access/portal-account-mode' -LocalOnly -Handler {
    param($req, $res, $routeParams, $body)
    $enabled = [bool](Get-DunePortalBodyValue $body 'enabled')
    $nativeRetirementAcknowledged = ((Get-DunePortalBodyValue $body 'acknowledgeNativeAppRetirement') -eq $true)
    try {
        $state = Invoke-DunePortalAuthLock {
            $store = Get-DunePortalAccountStore
            if ($enabled -and -not (Test-DunePortalEnablePreconditions $store)) {
                throw 'Create an enabled owner and verify its password locally before enabling account login.'
            }
            if ($enabled -and -not $nativeRetirementAcknowledged) {
                throw 'Acknowledge that paired native apps stop working while account login is enabled.'
            }
            $store.accountLoginEnabled = $enabled
            Save-DunePortalAccountStore $store
            if (-not $enabled) { Revoke-DunePortalSessions }
            return $store
        }
        if (-not $state.accountLoginEnabled) { Clear-DunePortalSessionCookie $res }
        Write-DuneJson -Response $res -Body @{ accountLoginEnabled = [bool]$state.accountLoginEnabled }
    } catch {
        Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
    }
}
