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

        $scopeType = (Get-DuneQ $req 'scope_type').Trim().ToLowerInvariant()
        $scopeId = 0L
        [void][Int64]::TryParse((Get-DuneQ $req 'scope_id'), [ref]$scopeId)
        if ($scopeType) {
            if ($scopeType -notin @('player', 'storage') -or $scopeType -notin $entityTypes) {
                Write-DuneError -Response $res -Status 400 -Message 'scope_type must be one of the requested supported types.'
                return
            }
            if ($scopeId -le 0) {
                Write-DuneError -Response $res -Status 400 -Message 'scope_id must be a positive integer when scope_type is set.'
                return
            }
        } elseif ($scopeId -gt 0) {
            Write-DuneError -Response $res -Status 400 -Message 'scope_type is required when scope_id is set.'
            return
        }

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
        if ($demoRequested -and $cursorMode -eq 'live') {
            Write-DuneError -Response $res -Status 400 -Message 'Cursor source does not match demo mode.'
            return
        }
        $source = 'static'
        $freshnessState = 'fresh'
        $liveError = ''
        $items = $null
        if (-not $demoRequested -and $cursorMode -ne 'demo') {
            $ctx = Get-DuneDbContext
            if ($ctx.ok) {
                $live = Invoke-DuneInventorySearchLive -Ip $ctx.ip -Query $query -EntityTypes $entityTypes `
                    -ScopeType $scopeType -ScopeId $scopeId -AfterItemId $afterItemId -Limit ($limit + 1)
                if ($live.ok) {
                    $items = @($live.items)
                    $source = 'live'
                } else {
                    $liveError = [string]$live.error
                }
            } else {
                $liveError = [string]$ctx.message
            }
        }
        if ($null -eq $items) {
            if ($cursorMode -eq 'live') {
                Write-DuneError -Response $res -Status 503 -Message "Inventory page could not be read from the live database: $liveError"
                return
            }
            $items = @(Select-DuneInventoryDemoItems -Items (Get-DuneInventoryDemoItems) `
                -Query $query -EntityTypes $entityTypes -ScopeType $scopeType -ScopeId $scopeId `
                -AfterItemId $afterItemId -Limit ($limit + 1))
            if ($liveError) { $freshnessState = 'partial' }
        }

        $truncated = $items.Count -gt $limit
        $pageItems = @($items | Select-Object -First $limit)
        $nextCursor = ''
        if ($truncated -and $pageItems.Count -gt 0) {
            $nextCursor = New-DuneOpaqueCursor -Principal $principal `
                -MapId 'shared-inventory' -Layers $entityTypes -Bbox $bindingScope `
                -Query $query -Generation $script:DuneInventoryCursorGeneration `
                -Position ([ordered]@{
                    itemId = [long]$pageItems[-1].id
                    mode = if ($source -eq 'live') { 'live' } else { 'demo' }
                })
        }
        $observedAt = (Get-Date).ToUniversalTime().ToString('o')
        $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal | ForEach-Object { [string]$_.id })
        $data = [ordered]@{
            mode = if ($source -eq 'live') { 'live' } else { 'demo' }
            query = $query
            supportedEntityTypes = @('player', 'storage')
            unavailableEntityTypes = @('base', 'vehicle')
            items = $pageItems
        }
        if ($liveError) { $data.liveError = $liveError }
        $envelope = New-DuneApiV1Envelope `
            -RequestId ([string]$routeParams.requestId) `
            -Source $source `
            -Freshness (New-DuneApiFreshness -State $freshnessState -ObservedAt $observedAt -LastErrorCode $(if ($liveError) { 'inventory-live-unavailable' } else { '' })) `
            -Capabilities $capabilities `
            -Data $data `
            -Page (New-DuneApiPage -Limit $limit -NextCursor $nextCursor -Truncated $truncated)
        Write-DuneJson -Response $res -Body $envelope
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Inventory search failed: $($_.Exception.Message)"
    }
}
