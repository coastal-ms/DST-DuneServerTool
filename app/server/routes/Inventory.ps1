# GET /api/v1/inventory/items
# Read-only shared projection for proven player and storage inventory scopes.
Register-DuneRoute -Method GET -Path '/api/v1/inventory/items' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $query = (Get-DuneQ $req 'q').Trim()
        if ($query.Length -gt 200) {
            Write-DuneError -Response $res -Status 400 -Message 'q must be 200 characters or fewer.'
            return
        }

        try {
            $entityTypes = @(Get-DuneInventoryEntityTypes -Value (Get-DuneQ $req 'types'))
        } catch {
            Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
            return
        }

        $scope = Resolve-DuneInventoryScope `
            -HasScopeType (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'scope_type') `
            -ScopeTypeValue (Get-DuneQ $req 'scope_type') `
            -HasScopeId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'scope_id') `
            -ScopeIdValue (Get-DuneQ $req 'scope_id') `
            -EntityTypes $entityTypes
        if (-not $scope.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$scope.error)
            return
        }
        $scopeType = [string]$scope.scopeType
        $scopeId = [long]$scope.scopeId

        $limit = Get-DuneInventoryLimit -Value (Get-DuneQ $req 'limit')
        $principal = Get-DuneRouteRequestPrincipal $routeParams
        $bindingScope = "$scopeType`:$scopeId"
        $afterItemId = 0L
        $cursorMode = ''
        $cursor = (Get-DuneQ $req 'cursor').Trim()
        if ($cursor) {
            try {
                $cursorPayload = Read-DuneOpaqueCursor -Cursor $cursor -Principal $principal `
                    -MapId 'shared-inventory' -Layers $entityTypes -Bbox $bindingScope `
                    -Query $query -Generation $script:DuneInventoryCursorGeneration
                $afterItemId = [long]$cursorPayload.position.itemId
                if ($afterItemId -le 0) { throw 'Invalid cursor position.' }
                $cursorMode = [string]$cursorPayload.position.mode
                if ($cursorMode -notin @('live', 'demo')) { throw 'Invalid cursor source.' }
            } catch {
                Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
                return
            }
        }

        $demoRequested = Test-DuneDemoRequested $req
        $requestedMode = Resolve-DuneInventoryRequestedMode -DemoRequested $demoRequested -CursorMode $cursorMode
        if (-not $requestedMode.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$requestedMode.error)
            return
        }
        $pageResult = Invoke-DuneInventoryRequestedPage -Mode ([string]$requestedMode.mode) `
            -Query $query -EntityTypes $entityTypes -ScopeType $scopeType -ScopeId $scopeId `
            -AfterItemId $afterItemId -Limit ($limit + 1)
        if (-not $pageResult.ok) {
            Write-DuneError -Response $res -Status ([int]$pageResult.status) -Message ([string]$pageResult.error)
            return
        }
        $source = [string]$pageResult.source
        $items = @($pageResult.items)

        $truncated = $items.Count -gt $limit
        $pageItems = @($items | Select-Object -First $limit)
        $nextCursor = ''
        if ($truncated -and $pageItems.Count -gt 0) {
            $nextCursor = New-DuneOpaqueCursor -Principal $principal `
                -MapId 'shared-inventory' -Layers $entityTypes -Bbox $bindingScope `
                -Query $query -Generation $script:DuneInventoryCursorGeneration `
                -Position ([ordered]@{
                    itemId = [long]$pageItems[-1].id
                    mode = [string]$requestedMode.mode
                })
        }
        $observedAt = (Get-Date).ToUniversalTime().ToString('o')
        $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal | ForEach-Object { [string]$_.id })
        $data = [ordered]@{
            mode = [string]$requestedMode.mode
            query = $query
            supportedEntityTypes = @('player', 'storage')
            unavailableEntityTypes = @('base', 'vehicle')
            items = $pageItems
        }
        $envelope = New-DuneApiV1Envelope `
            -RequestId ([string]$routeParams.requestId) `
            -Source $source `
            -Freshness (New-DuneApiFreshness -State fresh -ObservedAt $observedAt) `
            -Capabilities $capabilities `
            -Data $data `
            -Page (New-DuneApiPage -Limit $limit -NextCursor $nextCursor -Truncated $truncated)
        Write-DuneJson -Response $res -Body $envelope
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Inventory search failed: $($_.Exception.Message)"
    }
}
