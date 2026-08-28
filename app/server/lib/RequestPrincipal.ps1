# Server-derived request principals. Client body/query fields never participate.

function Get-DuneRequestHeaderValue {
    param($Request, [string]$Name)
    try { return [string]$Request.Headers[$Name] } catch { return '' }
}

function Get-DuneRequestTransport {
    param($Request, [bool]$IsLocalRequest)
    $forwarded = [bool](
        (Get-DuneRequestHeaderValue $Request 'Cf-Ray') -or
        (Get-DuneRequestHeaderValue $Request 'Cf-Connecting-Ip') -or
        (Get-DuneRequestHeaderValue $Request 'X-Forwarded-For')
    )
    $kind = if ($IsLocalRequest) {
        'loopback'
    } elseif (Get-DuneRequestHeaderValue $Request 'X-Dune-Bridge-Protocol') {
        'tailscale-bridge'
    } elseif (Get-DuneRequestHeaderValue $Request 'Cf-Access-Authenticated-User-Email') {
        'cloudflare-access'
    } elseif ($forwarded) {
        'forwarded'
    } else {
        'direct-remote'
    }
    return [ordered]@{
        kind = $kind
        forwarded = $forwarded
        remoteAddress = try { [string]$Request.RemoteEndPoint.Address } catch { '' }
    }
}

function New-DuneRequestPrincipal {
    param(
        [Parameter(Mandatory)]$Request,
        [bool]$IsLocalRequest,
        [bool]$AccountMode,
        [bool]$LaunchAccess,
        $PortalSessionAuth,
        $LegacyRemoteAuth,
        [string]$Authentication = ''
    )
    $account = $null
    $session = $null
    $linkedCharacter = $null
    if ($PortalSessionAuth -and $PortalSessionAuth.ok) {
        $account = [ordered]@{
            id = [string]$PortalSessionAuth.account.id
            username = [string]$PortalSessionAuth.account.username
        }
        $session = [ordered]@{ id = [string]$PortalSessionAuth.sessionId }
        if ([string]$PortalSessionAuth.account.gameCharacterId) {
            $linkedCharacter = [ordered]@{
                id = [string]$PortalSessionAuth.account.gameCharacterId
                label = [string]$PortalSessionAuth.account.gameCharacterLabel
            }
        }
    }

    $type = 'anonymous'
    $role = 'anonymous'
    $id = 'anonymous'
    if ($IsLocalRequest) {
        $type = 'local-host'
        $role = 'local-host'
        $id = 'local-host'
    } elseif ($PortalSessionAuth -and $PortalSessionAuth.ok) {
        $role = [string]$PortalSessionAuth.account.role
        $type = if ($role -eq 'player') { 'linked-player' } else { 'portal-account' }
        $id = "account:$([string]$PortalSessionAuth.account.id)"
    } elseif ($LegacyRemoteAuth -and $LegacyRemoteAuth.ok) {
        $type = 'legacy-remote'
        $role = [string]$LegacyRemoteAuth.role
        $identity = [string]$LegacyRemoteAuth.email
        $id = if ($identity) { "legacy-remote:$(Get-DuneSha256Hex $identity)" } else { 'legacy-remote' }
    } elseif ($Authentication -eq 'none') {
        $type = 'anonymous'
        $role = 'anonymous'
        $id = 'anonymous'
    } elseif (-not $AccountMode) {
        $type = 'legacy-token'
        $role = 'owner'
        $id = 'legacy-token'
    } elseif ($LaunchAccess) {
        $type = 'launch-token'
        $role = 'admin'
        $id = 'launch-token'
    }

    return [ordered]@{
        schemaVersion = 1
        type = $type
        id = $id
        role = $role
        account = $account
        session = $session
        linkedCharacter = $linkedCharacter
        scopes = @()
        transport = Get-DuneRequestTransport -Request $Request -IsLocalRequest $IsLocalRequest
        context = [ordered]@{
            isLocal = $IsLocalRequest
            isRemote = -not $IsLocalRequest
        }
        authentication = $Authentication
    }
}

function Get-DuneRouteRequestPrincipal {
    param([hashtable]$RouteParams)
    if ($RouteParams -and $RouteParams.ContainsKey('requestPrincipal')) {
        return $RouteParams.requestPrincipal
    }
    return $null
}
