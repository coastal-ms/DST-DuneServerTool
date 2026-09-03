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
        $player = Resolve-DuneInventoryPlayerId `
            -HasPlayerId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'player_id') `
            -Value (Get-DuneQ $req 'player_id')
        if (-not $player.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$player.error)
            return
        }
        $playerId = [long]$player.playerId
        $location = Resolve-DuneInventoryScope `
            -HasScopeType (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'location_type') `
            -ScopeTypeValue (Get-DuneQ $req 'location_type') `
            -HasScopeId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'location_id') `
            -ScopeIdValue (Get-DuneQ $req 'location_id') -EntityTypes $entityTypes
        if (-not $location.ok) {
            Write-DuneError -Response $res -Status 400 -Message (([string]$location.error).Replace('scope_', 'location_'))
            return
        }
        $locationType = [string]$location.scopeType
        $locationId = [long]$location.scopeId
        $grouped = (Get-DuneQ $req 'grouped').Trim() -in @('1', 'true', 'yes')
        $groupSort = Resolve-DuneInventoryGroupSort -Value (Get-DuneQ $req 'sort')
        if ($grouped -and -not $groupSort.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$groupSort.error)
            return
        }

        $limit = Get-DuneInventoryLimit -Value (Get-DuneQ $req 'limit')
        $principal = Get-DuneRouteRequestPrincipal $routeParams
        $bindingScope = "$scopeType`:$scopeId|player:$playerId|location:$locationType`:$locationId|sort:$([string]$groupSort.value)"
        $afterItemId = 0L
        $afterSortValue = ''
        $afterSortSecondary = ''
        $afterSortName = ''
        $afterTemplateId = ''
        $cacheOffset = 0
        $cacheGeneration = ''
        $cursorSource = ''
        $cursorMode = ''
        $cursor = (Get-DuneQ $req 'cursor').Trim()
        if ($cursor) {
            try {
                $cursorPayload = Read-DuneOpaqueCursor -Cursor $cursor -Principal $principal `
                    -MapId 'shared-inventory' -Layers $entityTypes -Bbox $bindingScope `
                    -Query $query -Generation $(if ($grouped) { $script:DuneInventoryGroupedCursorGeneration } else { $script:DuneInventoryCursorGeneration })
                if ($grouped) {
                    $cursorSource = [string]$cursorPayload.position.source
                    if (-not $cursorSource) { $cursorSource = 'live' }
                    if ($cursorSource -eq 'cache') {
                        $cacheOffset = [int]$cursorPayload.position.offset
                        $cacheGeneration = [string]$cursorPayload.position.cacheGeneration
                        if ($cacheOffset -le 0 -or -not $cacheGeneration) {
                            throw 'Invalid cache cursor position.'
                        }
                    } elseif ($cursorSource -eq 'live') {
                        $afterSortValue = [string]$cursorPayload.position.sortValue
                        $afterSortSecondary = [string]$cursorPayload.position.sortSecondary
                        $afterSortName = [string]$cursorPayload.position.sortName
                        $afterTemplateId = [string]$cursorPayload.position.templateId
                        if (-not $afterTemplateId) { throw 'Invalid cursor position.' }
                    } else {
                        throw 'Invalid cursor source.'
                    }
                } else {
                    $afterItemId = [long]$cursorPayload.position.itemId
                    if ($afterItemId -le 0) { throw 'Invalid cursor position.' }
                }
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
        if ($grouped) {
            $groupResult = Invoke-DuneInventoryGroupedPage -Mode ([string]$requestedMode.mode) `
                -Query $query -EntityTypes $entityTypes -ScopeType $scopeType -ScopeId $scopeId `
                -PlayerId $playerId -LocationType $locationType -LocationId $locationId `
                -Sort ([string]$groupSort.value) -AfterSortValue $afterSortValue `
                -AfterSortSecondary $afterSortSecondary `
                -AfterSortName $afterSortName -AfterTemplateId $afterTemplateId `
                -Offset $cacheOffset -Limit $limit `
                -CursorSource $cursorSource -CacheGeneration $cacheGeneration
            if (-not $groupResult.ok) {
                Write-DuneError -Response $res -Status ([int]$groupResult.status) -Message ([string]$groupResult.error)
                return
            }
            if ($playerId -gt 0 -and -not [bool]$groupResult.selectedPlayerValid) {
                Write-DuneError -Response $res -Status 400 -Message 'player_id is not available in the filtered inventory dataset.'
                return
            }
            if ($locationType -and -not [bool]$groupResult.selectedLocationValid) {
                Write-DuneError -Response $res -Status 400 -Message 'The selected location is not available for the selected player.'
                return
            }
            $groups = @($groupResult.groups)
            $truncated = if ([string]$groupResult.cursorSource -eq 'cache') {
                [bool]$groupResult.truncated
            } else {
                $groups.Count -gt $limit
            }
            $pageGroups = if ([string]$groupResult.cursorSource -eq 'cache') {
                $groups
            } else {
                @($groups | Select-Object -First $limit)
            }
            $nextCursor = ''
            if ($truncated -and $pageGroups.Count -gt 0) {
                $nextCursor = New-DuneOpaqueCursor -Principal $principal `
                    -MapId 'shared-inventory' -Layers $entityTypes -Bbox $bindingScope `
                    -Query $query -Generation $script:DuneInventoryGroupedCursorGeneration `
                    -Position $(if ([string]$groupResult.cursorSource -eq 'cache') {
                        [ordered]@{
                            offset = $cacheOffset + $limit
                            cacheGeneration = [string]$groupResult.generation
                            source = 'cache'
                            mode = [string]$requestedMode.mode
                        }
                    } else {
                        [ordered]@{
                            sortValue = [string]$pageGroups[-1].cursor.sortValue
                            sortSecondary = [string]$pageGroups[-1].cursor.sortSecondary
                            sortName = [string]$pageGroups[-1].cursor.sortName
                            templateId = [string]$pageGroups[-1].cursor.templateId
                            source = 'live'
                            mode = [string]$requestedMode.mode
                        }
                    })
            }
            $capabilities = @(Get-DuneCapabilitiesForPrincipal $principal | ForEach-Object { [string]$_.id })
            $data = [ordered]@{
                mode = [string]$requestedMode.mode
                query = $query
                playerId = if ($playerId -gt 0) { $playerId } else { $null }
                location = if ($locationType) { [ordered]@{ type = $locationType; id = $locationId } } else { $null }
                selectedPlayerValid = [bool]$groupResult.selectedPlayerValid
                selectedLocationValid = [bool]$groupResult.selectedLocationValid
                supportedEntityTypes = @('player', 'storage')
                unavailableEntityTypes = @('base', 'vehicle')
                groups = $pageGroups
                players = @($groupResult.players)
                locations = @($groupResult.locations)
            }
            $envelope = New-DuneApiV1Envelope `
                -RequestId ([string]$routeParams.requestId) -Source ([string]$groupResult.source) `
                -Freshness $groupResult.freshness `
                -Capabilities $capabilities -Data $data `
                -Page (New-DuneApiPage -Limit $limit -NextCursor $nextCursor -Truncated $truncated)
            Write-DuneJson -Response $res -Body $envelope
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

# GET /api/v1/inventory/items/occurrences?template_id={templateId}
# Lazy, bounded occurrence detail for a grouped inventory item.
$script:DuneInventoryOccurrencesHandler = {
    param($req, $res, $routeParams, $body)
    try {
        $templateId = if ([string]$routeParams.templateId) {
            [Uri]::UnescapeDataString([string]$routeParams.templateId).Trim()
        } else {
            (Get-DuneQ $req 'template_id').Trim()
        }
        if (-not $templateId -or $templateId.Length -gt 240 -or $templateId -notmatch '^[A-Za-z0-9_.:/-]+$') {
            Write-DuneError -Response $res -Status 400 -Message 'templateId is invalid.'
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
            -ScopeIdValue (Get-DuneQ $req 'scope_id') -EntityTypes $entityTypes
        if (-not $scope.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$scope.error)
            return
        }
        $player = Resolve-DuneInventoryPlayerId `
            -HasPlayerId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'player_id') `
            -Value (Get-DuneQ $req 'player_id')
        if (-not $player.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$player.error)
            return
        }
        $scopeType = [string]$scope.scopeType
        $scopeId = [long]$scope.scopeId
        $playerId = [long]$player.playerId
        $location = Resolve-DuneInventoryScope `
            -HasScopeType (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'location_type') `
            -ScopeTypeValue (Get-DuneQ $req 'location_type') `
            -HasScopeId (Test-DuneInventoryQueryParameterPresent -Request $req -Name 'location_id') `
            -ScopeIdValue (Get-DuneQ $req 'location_id') -EntityTypes $entityTypes
        if (-not $location.ok) {
            Write-DuneError -Response $res -Status 400 -Message (([string]$location.error).Replace('scope_', 'location_'))
            return
        }
        $locationType = [string]$location.scopeType
        $locationId = [long]$location.scopeId
        $occurrenceSort = Resolve-DuneInventoryOccurrenceSort -Value (Get-DuneQ $req 'sort')
        if (-not $occurrenceSort.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$occurrenceSort.error)
            return
        }
        $limit = [Math]::Min(100, (Get-DuneInventoryLimit -Value (Get-DuneQ $req 'limit')))
        $principal = Get-DuneRouteRequestPrincipal $routeParams
        $bindingScope = "$scopeType`:$scopeId|player:$playerId|location:$locationType`:$locationId|sort:$([string]$occurrenceSort.value)"
        $afterItemId = 0L
        $afterOccurrenceSortValue = ''
        $cacheOffset = 0
        $cacheGeneration = ''
        $cursorSource = ''
        $cursorMode = ''
        $cursor = (Get-DuneQ $req 'cursor').Trim()
        if ($cursor) {
            try {
                $payload = Read-DuneOpaqueCursor -Cursor $cursor -Principal $principal `
                    -MapId "shared-inventory:$templateId" -Layers $entityTypes -Bbox $bindingScope `
                    -Generation $script:DuneInventoryOccurrenceCursorGeneration
                $cursorSource = [string]$payload.position.source
                if (-not $cursorSource) { $cursorSource = 'live' }
                if ($cursorSource -eq 'cache') {
                    $cacheOffset = [int]$payload.position.offset
                    $cacheGeneration = [string]$payload.position.cacheGeneration
                    if ($cacheOffset -le 0 -or -not $cacheGeneration) {
                        throw 'Invalid cache cursor position.'
                    }
                } elseif ($cursorSource -eq 'live') {
                    $afterItemId = [long]$payload.position.itemId
                    $afterOccurrenceSortValue = [string]$payload.position.sortValue
                    if ($afterItemId -le 0) { throw 'Invalid cursor position.' }
                } else {
                    throw 'Invalid cursor source.'
                }
                $cursorMode = [string]$payload.position.mode
            } catch {
                Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
                return
            }
        }

        $requestedMode = Resolve-DuneInventoryRequestedMode `
            -DemoRequested (Test-DuneDemoRequested $req) -CursorMode $cursorMode
        if (-not $requestedMode.ok) {
            Write-DuneError -Response $res -Status 400 -Message ([string]$requestedMode.error)
            return
        }
        $result = Invoke-DuneInventoryOccurrencesPage `
            -Mode ([string]$requestedMode.mode) `
            -TemplateId $templateId `
            -EntityTypes $entityTypes `
            -ScopeType $scopeType `
            -ScopeId $scopeId `
            -PlayerId $playerId `
            -LocationType $locationType `
            -LocationId $locationId `
            -Sort ([string]$occurrenceSort.value) `
            -AfterSortValue $afterOccurrenceSortValue `
            -AfterItemId $afterItemId `
            -Offset $cacheOffset `
            -Limit $limit `
            -CursorSource $cursorSource `
            -CacheGeneration $cacheGeneration
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status ([int]$result.status) -Message ([string]$result.error)
            return
        }
        if ($playerId -gt 0 -and -not [bool]$result.selectedPlayerValid) {
            Write-DuneError -Response $res -Status 400 -Message 'player_id is not available for this item.'
            return
        }
        if ($locationType -and -not [bool]$result.selectedLocationValid) {
            Write-DuneError -Response $res -Status 400 -Message 'The selected location is not available for this player and item.'
            return
        }
        $items = @($result.items)
        $truncated = if ([string]$result.cursorSource -eq 'cache') {
            [bool]$result.truncated
        } else {
            $items.Count -gt $limit
        }
        $pageItems = if ([string]$result.cursorSource -eq 'cache') {
            $items
        } else {
            @($items | Select-Object -First $limit)
        }
        $nextCursor = ''
        if ($truncated -and $pageItems.Count -gt 0) {
            $last = $pageItems[-1]
            $sortValue = switch -Wildcard ([string]$occurrenceSort.value) {
                'player-*' { [string]$last.player.name }
                'location-*' { [string]$last.entity.label }
                'quantity-*' { [string]$last.quantity }
                'quality-*' { [string]$last.quality }
            }
            $nextCursor = New-DuneOpaqueCursor -Principal $principal `
                -MapId "shared-inventory:$templateId" -Layers $entityTypes -Bbox $bindingScope `
                -Generation $script:DuneInventoryOccurrenceCursorGeneration `
                -Position $(if ([string]$result.cursorSource -eq 'cache') {
                    [ordered]@{
                        offset = $cacheOffset + $limit
                        cacheGeneration = [string]$result.generation
                        source = 'cache'
                        mode = [string]$requestedMode.mode
                    }
                } else {
                    [ordered]@{
                        itemId = [long]$last.id
                        sortValue = $sortValue.ToLowerInvariant()
                        source = 'live'
                        mode = [string]$requestedMode.mode
                    }
                })
        }
        $envelope = New-DuneApiV1Envelope `
            -RequestId ([string]$routeParams.requestId) -Source ([string]$result.source) `
            -Freshness $result.freshness `
            -Capabilities @(Get-DuneCapabilitiesForPrincipal $principal | ForEach-Object { [string]$_.id }) `
            -Data ([ordered]@{
                mode = [string]$requestedMode.mode
                templateId = $templateId
                playerId = if ($playerId) { $playerId } else { $null }
                items = $pageItems
                players = @($result.players)
                locations = @($result.locations)
            }) `
            -Page (New-DuneApiPage -Limit $limit -NextCursor $nextCursor -Truncated $truncated)
        Write-DuneJson -Response $res -Body $envelope
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Inventory occurrence search failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/v1/inventory/items/occurrences' -Handler $script:DuneInventoryOccurrencesHandler
# Compatibility for the first grouped-explorer client build.
Register-DuneRoute -Method GET -Path '/api/v1/inventory/items/{templateId}/occurrences' -Handler $script:DuneInventoryOccurrencesHandler
