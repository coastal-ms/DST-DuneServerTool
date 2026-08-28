# Additive v1 platform contract proof routes.

Register-DuneRoute -Method GET -Path '/api/v1/capabilities' -Handler {
    param($req, $res, $routeParams, $body)
    $principal = Get-DuneRouteRequestPrincipal $routeParams
    $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal)
    $ids = @($capabilities | ForEach-Object { [string]$_.id })
    $requestId = [string]$routeParams.requestId
    $envelope = New-DuneApiV1Envelope `
        -RequestId $requestId `
        -Source static `
        -Freshness (New-DuneApiFreshness -State fresh) `
        -Capabilities $ids `
        -Data ([ordered]@{
            registryVersion = [int](Get-DuneCapabilityRegistry).schemaVersion
            capabilities = $capabilities
        })
    Write-DuneJson -Response $res -Body $envelope
}

Register-DuneRoute -Method GET -Path '/api/v1/platform/status' -Handler {
    param($req, $res, $routeParams, $body)
    $principal = Get-DuneRouteRequestPrincipal $routeParams
    $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal)
    $ids = @($capabilities | ForEach-Object { [string]$_.id })
    $envelope = New-DuneApiV1Envelope `
        -RequestId ([string]$routeParams.requestId) `
        -Source static `
        -Freshness (New-DuneApiFreshness -State fresh) `
        -Capabilities $ids `
        -Data ([ordered]@{
            apiSchemaVersion = 1
            capabilityRegistryVersion = [int](Get-DuneCapabilityRegistry).schemaVersion
            routePolicyVersion = [int](Get-DuneRoutePolicyManifest).schemaVersion
            principal = [ordered]@{
                type = [string]$principal.type
                role = [string]$principal.role
                linkedCharacter = [bool]($null -ne $principal.linkedCharacter)
                transport = [string]$principal.transport.kind
                isLocal = [bool]$principal.context.isLocal
            }
        })
    Write-DuneJson -Response $res -Body $envelope
}
