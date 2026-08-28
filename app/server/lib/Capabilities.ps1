# Backend-owned capability registry and exact route classification.

$script:DuneCapabilityRegistry = $null
$script:DuneRoutePolicyManifest = $null

function Get-DunePlatformDataPath {
    param([Parameter(Mandatory)][string]$Name)
    $serverDir = Split-Path -Parent $PSScriptRoot
    $appDir = Split-Path -Parent $serverDir
    $candidates = @((Join-Path (Join-Path $appDir 'data') $Name))
    if ($script:AppDir) {
        $candidates += (Join-Path (Join-Path ([string]$script:AppDir) 'data') $Name)
    }
    foreach ($candidate in $candidates) {
        try { return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    }
    throw "Required platform data file not found: $Name"
}

function Read-DunePlatformJson {
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-DunePlatformDataPath $Name
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Assert-DuneCapabilityRegistry {
    param([Parameter(Mandatory)]$Registry)
    if ([int]$Registry.schemaVersion -ne 1) { throw 'Unsupported capability registry schema.' }
    $knownLifecycles = @('read','reversible-write','transactional-write','destructive')
    $knownPrincipals = @('local-host','owner','admin','linked-player','api-key','discord')
    $knownRollouts = @('unavailable','read-only','preview','guarded-write','stable')
    $knownGuards = @($Registry.knownGuards | ForEach-Object { [string]$_ })
    $ids = @{}
    $endpointIds = @{}
    foreach ($capability in @($Registry.capabilities)) {
        $id = [string]$capability.id
        if (-not $id -or $id -notmatch '^[a-z][a-z0-9.-]+$') { throw "Invalid capability ID '$id'." }
        if ($ids.ContainsKey($id)) { throw "Duplicate capability ID '$id'." }
        $ids[$id] = $true
        if ([string]$capability.lifecycle -notin $knownLifecycles) { throw "Unknown lifecycle for '$id'." }
        if ([string]$capability.rolloutState -notin $knownRollouts) { throw "Unknown rollout state for '$id'." }
        foreach ($principal in @($capability.allowedPrincipals)) {
            if ([string]$principal -notin $knownPrincipals) { throw "Unknown principal '$principal' for '$id'." }
        }
        foreach ($guard in @($capability.guards)) {
            if ([string]$guard -notin $knownGuards) { throw "Unknown guard '$guard' for '$id'." }
        }
        foreach ($endpointId in @($capability.endpointIds)) {
            $endpoint = [string]$endpointId
            if (-not $endpoint) { throw "Capability '$id' has an empty endpoint ID." }
            if ($endpointIds.ContainsKey($endpoint)) { throw "Duplicate endpoint ID '$endpoint'." }
            $endpointIds[$endpoint] = $id
        }
    }
    return $ids
}

function Get-DuneCapabilityRegistry {
    if (-not $script:DuneCapabilityRegistry) {
        $registry = Read-DunePlatformJson 'platform-capabilities.json'
        [void](Assert-DuneCapabilityRegistry $registry)
        $script:DuneCapabilityRegistry = $registry
    }
    return $script:DuneCapabilityRegistry
}

function Get-DuneRoutePolicyManifest {
    if (-not $script:DuneRoutePolicyManifest) {
        $manifest = Read-DunePlatformJson 'platform-route-policies.json'
        if ([int]$manifest.schemaVersion -ne 1) { throw 'Unsupported route policy schema.' }
        $capabilityIds = Assert-DuneCapabilityRegistry (Get-DuneCapabilityRegistry)
        $sources = @{}
        foreach ($group in @($manifest.groups)) {
            $source = [string]$group.source
            if (-not $source -or $sources.ContainsKey($source)) { throw "Duplicate or empty route policy source '$source'." }
            if (-not $capabilityIds.ContainsKey([string]$group.capabilityId)) {
                throw "Route policy '$source' references an unknown capability."
            }
            if ([int]$group.routeCount -lt 1 -or [string]$group.sha256 -notmatch '^[0-9a-f]{64}$') {
                throw "Route policy '$source' has an invalid route fingerprint."
            }
            $sources[$source] = $true
        }
        $knownLifecycles = @('read','reversible-write','transactional-write','destructive')
        foreach ($property in $manifest.writeLifecycleBySource.PSObject.Properties) {
            if (-not $sources.ContainsKey($property.Name)) {
                throw "Write lifecycle references unknown route source '$($property.Name)'."
            }
            if ([string]$property.Value -notin $knownLifecycles) {
                throw "Write lifecycle for '$($property.Name)' is invalid."
            }
        }
        foreach ($property in $manifest.routeLifecycleOverrides.PSObject.Properties) {
            if ([string]$property.Value -notin $knownLifecycles) {
                throw "Route lifecycle override '$($property.Name)' is invalid."
            }
        }
        foreach ($property in $manifest.routeCapabilityOverrides.PSObject.Properties) {
            if (-not $capabilityIds.ContainsKey([string]$property.Value)) {
                throw "Route capability override '$($property.Name)' references an unknown capability."
            }
        }
        $script:DuneRoutePolicyManifest = $manifest
    }
    return $script:DuneRoutePolicyManifest
}

function Get-DuneRegisteredRouteKey {
    param([Parameter(Mandatory)]$Route)
    $protocol = if ($Route.PSObject.Properties.Name -contains 'Method') { 'http' } else { 'ws' }
    $method = if ($protocol -eq 'http') { [string]$Route.Method } else { 'CONNECT' }
    return "$protocol $method $([string]$Route.Path)"
}

function Get-DuneRouteFingerprint {
    param([Parameter(Mandatory)][object[]]$Routes)
    [string[]]$keys = @($Routes | ForEach-Object { Get-DuneRegisteredRouteKey $_ })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    return Get-DuneSha256Hex ($keys -join "`n")
}

function Get-DuneRouteLifecycle {
    param(
        [Parameter(Mandatory)]$Route,
        [Parameter(Mandatory)]$PolicyGroup
    )
    $manifest = Get-DuneRoutePolicyManifest
    $key = Get-DuneRegisteredRouteKey $Route
    $override = $manifest.routeLifecycleOverrides.PSObject.Properties[$key]
    if ($override) { return [string]$override.Value }
    if ($Route.PSObject.Properties.Name -contains 'Method' -and [string]$Route.Method -eq 'GET') {
        return 'read'
    }
    if ($Route.PSObject.Properties.Name -contains 'Method' -and [string]$Route.Method -eq 'DELETE') {
        return 'destructive'
    }
    $source = [string]$PolicyGroup.source
    $writeLifecycle = $manifest.writeLifecycleBySource.PSObject.Properties[$source]
    if (-not $writeLifecycle) { throw "Route source '$source' has no reviewed write lifecycle." }
    return [string]$writeLifecycle.Value
}

function Get-DuneRouteCapabilityId {
    param(
        [Parameter(Mandatory)]$Route,
        [Parameter(Mandatory)]$PolicyGroup
    )
    $manifest = Get-DuneRoutePolicyManifest
    $key = Get-DuneRegisteredRouteKey $Route
    $override = $manifest.routeCapabilityOverrides.PSObject.Properties[$key]
    if ($override) { return [string]$override.Value }
    return [string]$PolicyGroup.capabilityId
}

function Test-DuneRouteCapabilityCompatibility {
    param([Parameter(Mandatory)]$Classification)
    $ranks = @{ read = 0; 'reversible-write' = 1; 'transactional-write' = 2; destructive = 3 }
    $capability = @((Get-DuneCapabilityRegistry).capabilities | Where-Object {
        [string]$_.id -eq [string]$Classification.capabilityId
    })[0]
    if (-not $capability) { return $false }
    if ($ranks[[string]$Classification.lifecycle] -gt $ranks[[string]$capability.lifecycle]) {
        return $false
    }
    $requiredPrincipals = switch ([string]$Classification.currentAccess) {
        'local-only' { @('local-host') }
        'owner' { @('local-host','owner') }
        'owner-admin' { @('local-host','owner','admin') }
        'authenticated' { @('local-host','owner','admin') }
        default { @() }
    }
    foreach ($principal in $requiredPrincipals) {
        if ($principal -notin @($capability.allowedPrincipals)) { return $false }
    }
    return $true
}

function Get-DuneRouteCurrentAccess {
    param([Parameter(Mandatory)]$Route)
    if ([bool]$Route.LocalOnly) { return 'local-only' }
    $path = [string]$Route.Path
    if ($path -in @('/api/portal-auth/status','/api/portal-auth/login')) { return 'public' }
    if ($Route.PSObject.Properties.Name -contains 'Method' -and
        (Test-DunePortalOwnerOrAdminPath -Path $path -Method ([string]$Route.Method))) {
        return 'owner-admin'
    }
    if ($Route.PSObject.Properties.Name -contains 'Method' -and
        (Test-DunePortalOwnerOnlyPath -Path $path -Method ([string]$Route.Method))) {
        return 'owner'
    }
    return 'authenticated'
}

function Get-DuneAllowedPrincipalTypesForAccess {
    param([Parameter(Mandatory)][string]$Access)
    switch ($Access) {
        'public' { return @('anonymous','local-host','portal-account','legacy-token','legacy-remote','launch-token') }
        'local-only' { return @('local-host') }
        'owner' { return @('local-host','portal-account','legacy-token') }
        'owner-admin' { return @('local-host','portal-account','legacy-token') }
        default { return @('local-host','portal-account','legacy-token','legacy-remote','launch-token') }
    }
}

function Update-DuneRouteClassifications {
    $manifest = Get-DuneRoutePolicyManifest
    $allRoutes = @($script:DuneRoutes) + @($script:DuneWsRoutes)
    foreach ($route in $allRoutes) { $route.Classification = $null }
    foreach ($group in @($manifest.groups)) {
        $routes = @($allRoutes | Where-Object { [string]$_.SourceFile -eq [string]$group.source })
        $valid = (
            $routes.Count -eq [int]$group.routeCount -and
            (Get-DuneRouteFingerprint $routes) -ceq [string]$group.sha256
        )
        if (-not $valid) { continue }
        $lifecycles = @{}
        try {
            foreach ($route in $routes) {
                $lifecycles[(Get-DuneRegisteredRouteKey $route)] = Get-DuneRouteLifecycle -Route $route -PolicyGroup $group
            }
        } catch {
            continue
        }
        foreach ($route in $routes) {
            $access = Get-DuneRouteCurrentAccess $route
            $classification = [ordered]@{
                schemaVersion = 1
                classified = $true
                capabilityId = Get-DuneRouteCapabilityId -Route $route -PolicyGroup $group
                lifecycle = [string]$lifecycles[(Get-DuneRegisteredRouteKey $route)]
                currentAccess = $access
                allowedPrincipalTypes = @(Get-DuneAllowedPrincipalTypesForAccess $access)
                source = [string]$group.source
            }
            if (Test-DuneRouteCapabilityCompatibility $classification) {
                $route.Classification = $classification
            }
        }
    }
}

function Get-DuneRouteClassification {
    param([Parameter(Mandatory)]$Route)
    if (-not $Route.Classification) { Update-DuneRouteClassifications }
    if ($Route.Classification) { return $Route.Classification }
    return [ordered]@{
        schemaVersion = 1
        classified = $false
        capabilityId = $null
        lifecycle = 'destructive'
        currentAccess = 'unclassified'
        allowedPrincipalTypes = @()
        source = [string]$Route.SourceFile
    }
}

function Get-DuneCapabilityPrincipalName {
    param($Principal)
    if (-not $Principal) { return '' }
    switch ([string]$Principal.type) {
        'local-host' { return 'local-host' }
        'linked-player' { return 'linked-player' }
        'api-key' { return 'api-key' }
        'discord' { return 'discord' }
        default {
            if ([string]$Principal.role -in @('owner','admin')) { return [string]$Principal.role }
            return ''
        }
    }
}

function Test-DuneRoutePrincipalAccess {
    param([Parameter(Mandatory)]$Route, [Parameter(Mandatory)]$Principal)
    $type = [string]$Principal.type
    if ($type -eq 'portal-account') {
        $classification = Get-DuneRouteClassification $Route
        if ([string]$classification.currentAccess -eq 'owner-admin') {
            return ([string]$Principal.role -in @('owner','admin'))
        }
    }
    if ($type -in @('local-host','portal-account','legacy-token','legacy-remote','launch-token')) {
        return $true
    }
    $classification = Get-DuneRouteClassification $Route
    if (-not $classification.classified) { return $false }
    if ($type -eq 'anonymous') { return ([string]$classification.currentAccess -eq 'public') }
    if ($type -notin @($classification.allowedPrincipalTypes)) { return $false }
    $principalName = Get-DuneCapabilityPrincipalName $Principal
    $capability = @((Get-DuneCapabilityRegistry).capabilities | Where-Object { $_.id -eq $classification.capabilityId })[0]
    return (
        $capability -and
        [string]$capability.rolloutState -ne 'unavailable' -and
        $principalName -in @($capability.allowedPrincipals)
    )
}

function Get-DuneCapabilitiesForPrincipal {
    param(
        [Parameter(Mandatory)]$Principal,
        [ValidateSet('windows','linux','macos','unknown')]
        [string]$RuntimePlatform
    )
    $principalName = Get-DuneCapabilityPrincipalName $Principal
    if (-not $principalName) { return @() }
    return @((Get-DuneCapabilityRegistry).capabilities | Where-Object {
        [string]$_.rolloutState -ne 'unavailable' -and
        (
            [string]$_.id -ne 'map.live-cache' -or
            (Test-DunePlatformLiveCacheSupported -RuntimePlatform $RuntimePlatform)
        ) -and
        $principalName -in @($_.allowedPrincipals)
    } | ForEach-Object {
        [ordered]@{
            id = [string]$_.id
            domain = [string]$_.domain
            label = [string]$_.label
            description = [string]$_.description
            lifecycle = [string]$_.lifecycle
            guards = @($_.guards)
            endpointIds = @($_.endpointIds)
            commandIds = @($_.commandIds)
            navigation = $_.navigation
            auditCategory = [string]$_.auditCategory
            rolloutState = [string]$_.rolloutState
        }
    })
}
