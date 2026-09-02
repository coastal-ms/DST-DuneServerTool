# Shared Inventory Explorer read model. This file only projects proven player
# inventories and inventory_type=4 storage placeables.

$script:DuneInventoryDefaultLimit = 100
$script:DuneInventoryMaxLimit = 500
$script:DuneInventoryCursorGeneration = 'inventory-v1'
$script:DuneInventoryGroupedCursorGeneration = 'inventory-groups-v1'
$script:DuneInventoryOccurrenceCursorGeneration = 'inventory-occurrences-v1'

function Get-DuneInventoryLimit {
    param([string]$Value)
    $limit = $script:DuneInventoryDefaultLimit
    $parsed = 0
    if ($Value -and [Int32]::TryParse($Value, [ref]$parsed)) {
        $limit = $parsed
    }
    return [Math]::Max(1, [Math]::Min($script:DuneInventoryMaxLimit, $limit))
}

function Get-DuneInventoryEntityTypes {
    param([string]$Value)
    if (-not $Value) { return @('player', 'storage') }
    $types = @($Value.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($types.Count -eq 0) { return @('player', 'storage') }
    foreach ($type in $types) {
        if ($type -notin @('player', 'storage')) {
            throw "Unsupported inventory entity type '$type'."
        }
    }
    return $types
}

function Resolve-DuneInventoryScope {
    param(
        [bool]$HasScopeType,
        [string]$ScopeTypeValue,
        [bool]$HasScopeId,
        [string]$ScopeIdValue,
        [string[]]$EntityTypes
    )
    if (-not $HasScopeType -and -not $HasScopeId) {
        return @{ ok = $true; scopeType = ''; scopeId = 0L }
    }
    if (-not $HasScopeType) {
        return @{ ok = $false; error = 'scope_type is required when scope_id is set.' }
    }
    if (-not $HasScopeId) {
        return @{ ok = $false; error = 'scope_id is required when scope_type is set.' }
    }

    $scopeType = $ScopeTypeValue.Trim().ToLowerInvariant()
    if ($scopeType -notin @('player', 'storage') -or $scopeType -notin $EntityTypes) {
        return @{ ok = $false; error = 'scope_type must be one of the requested supported types.' }
    }
    $scopeId = 0L
    if (-not [Int64]::TryParse($ScopeIdValue, [ref]$scopeId) -or $scopeId -le 0) {
        return @{ ok = $false; error = 'scope_id must be a positive integer.' }
    }
    return @{ ok = $true; scopeType = $scopeType; scopeId = $scopeId }
}

function Resolve-DuneInventoryRequestedMode {
    param([bool]$DemoRequested, [string]$CursorMode = '')
    $mode = if ($DemoRequested) { 'demo' } else { 'live' }
    if ($CursorMode -and $CursorMode -ne $mode) {
        return @{ ok = $false; error = "Cursor source does not match requested $mode mode." }
    }
    return @{ ok = $true; mode = $mode }
}

function Test-DuneInventoryQueryParameterPresent {
    param($Request, [string]$Name)
    $queryString = $Request.QueryString
    if ($null -eq $queryString) { return $false }
    if ($queryString -is [Collections.IDictionary]) {
        return $queryString.Contains($Name)
    }
    return @($queryString.AllKeys) -contains $Name
}

function Get-DuneInventoryMetadataMatches {
    param([string]$Query)
    if (-not $Query) { return @() }
    Initialize-DuneGameplayItemData
    $needle = $Query.Trim()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $catalogIds = @(
        @($script:DuneGameplayItemNames.Keys) + @($script:DuneGameplayItemRules.Keys) |
            Sort-Object -Unique
    )
    foreach ($id in $catalogIds) {
        $name = Get-DuneGameplayItemName -TemplateId ([string]$id)
        if ($name.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            [void]$ids.Add([string]$id)
        }
    }
    return @($ids | Sort-Object)
}

function Get-DuneInventoryStorageClassSql {
    return @"
CASE
    WHEN strpos(lower(COALESCE(p.building_type, '')), 'developer_storagecontainer') = 1
      OR strpos(lower(COALESCE(p.building_type, '')), 'developer_storage_container') = 1
    THEN 'Developer Storage Container'
    ELSE trim(replace(
        regexp_replace(
            regexp_replace(COALESCE(p.building_type, ''), '^.*[./]', ''),
            '(^BP_|_C$)', '', 'g'
        ),
        '_', ' '
    ))
END
"@
}

function Get-DuneInventorySearchSql {
    param(
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$AfterItemId = 0,
        [int]$Limit = 101
    )
    $typeSql = @($EntityTypes | ForEach-Object { "'$(ConvertTo-DuneSqlString $_)'" }) -join ','
    $where = @("entity_type IN ($typeSql)", "item_id > $AfterItemId")
    if ($ScopeType) {
        $where += "entity_type = '$(ConvertTo-DuneSqlString $ScopeType)'"
        $where += "entity_id = $ScopeId"
    }
    if ($Query) {
        $safe = ConvertTo-DuneSqlString $Query.Trim()
        $search = @(
            'template_id',
            'entity_label',
            'owner_name',
            'map',
            'entity_type',
            "CASE WHEN entity_type = 'storage' THEN 'container storage' ELSE 'player character' END"
        ) | ForEach-Object {
            "strpos(lower(COALESCE($_, '')), lower('$safe')) > 0"
        }
        $metadataIds = @(Get-DuneInventoryMetadataMatches -Query $Query)
        if ($metadataIds.Count -gt 0) {
            $metadataSql = @($metadataIds | ForEach-Object { "'$(ConvertTo-DuneSqlString $_)'" }) -join ','
            $search += "template_id IN ($metadataSql)"
        }
        $where += "($($search -join ' OR '))"
    }
    $storageClassSql = Get-DuneInventoryStorageClassSql

    return @"
WITH inventory_rows AS (
    SELECT i.id::bigint AS item_id,
           i.template_id,
           i.stack_size,
           COALESCE(i.quality_level, 0) AS quality_level,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A') AS max_durability,
           COALESCE((i.stats->'FFillableItemStats'->1->>'CurrentAmount'), 'N/A') AS water_amount,
           COALESCE((i.stats->'FFillableItemStats'->1->>'FillableType'), '') AS water_type,
           inv.id::bigint AS inventory_id,
           inv.inventory_type,
           'player'::text AS entity_type,
           ps.player_pawn_id::bigint AS entity_id,
           COALESCE(ps.character_name, '') AS entity_label,
           COALESCE(ps.character_name, '') AS owner_name,
           COALESCE(a.map, '') AS map,
           ''::text AS entity_class
    FROM dune.items i
    JOIN dune.inventories inv ON inv.id = i.inventory_id
    JOIN dune.player_state ps ON ps.player_pawn_id = inv.actor_id
    LEFT JOIN dune.actors a ON a.id = ps.player_pawn_id

    UNION ALL

    SELECT i.id::bigint AS item_id,
           i.template_id,
           i.stack_size,
           COALESCE(i.quality_level, 0) AS quality_level,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A') AS max_durability,
           COALESCE((i.stats->'FFillableItemStats'->1->>'CurrentAmount'), 'N/A') AS water_amount,
           COALESCE((i.stats->'FFillableItemStats'->1->>'FillableType'), '') AS water_type,
           inv.id::bigint AS inventory_id,
           inv.inventory_type,
           'storage'::text AS entity_type,
           p.id::bigint AS entity_id,
           COALESCE(NULLIF((
               SELECT MAX(CASE
                   WHEN pa.actor_name NOT LIKE '##%' AND pa.actor_name <> 'None'
                   THEN pa.actor_name
               END)
               FROM dune.permission_actor pa
               WHERE pa.actor_id = p.id
           ), ''), NULLIF(($storageClassSql), ''), 'Storage container') AS entity_label,
           COALESCE(owner.character_name, '') AS owner_name,
           COALESCE(a.map, '') AS map,
           COALESCE(p.building_type, '') AS entity_class
    FROM dune.items i
    JOIN dune.inventories inv ON inv.id = i.inventory_id AND inv.inventory_type = 4
    JOIN dune.placeables p ON p.id = inv.actor_id
    LEFT JOIN dune.actors a ON a.id = p.id
    LEFT JOIN LATERAL (
        SELECT ps.character_name
        FROM dune.actor_fgl_entities afe
        JOIN dune.permission_actor_rank par ON par.permission_actor_id = afe.actor_id
        JOIN dune.actors player_a ON player_a.id = par.player_id
        JOIN dune.player_state ps ON ps.account_id = player_a.owner_account_id
        WHERE afe.entity_id = p.owner_entity_id
        ORDER BY par.rank ASC, ps.character_name ASC
        LIMIT 1
    ) owner ON true
    WHERE p.is_hologram = false
      AND p.owner_entity_id IS NOT NULL
      AND p.owner_entity_id <> 0
)
SELECT item_id, template_id, stack_size, quality_level, durability, max_durability,
       water_amount, water_type, inventory_id, inventory_type, entity_type,
       entity_id, entity_label, owner_name, map, entity_class
FROM inventory_rows
WHERE $($where -join "`n  AND ")
ORDER BY item_id ASC
LIMIT $Limit;
"@
}

function ConvertTo-DuneInventoryItem {
    param([Parameter(Mandatory)]$Row)
    Assert-DuneInventoryDatabaseRow -Row $Row -Kind item
    $templateId = [string]$Row['template_id']
    $rule = Get-DuneGameplayItemRule -TemplateId $templateId
    $entityType = [string]$Row['entity_type']
    $entityId = ConvertTo-DuneInt $Row['entity_id']
    $entityClass = [string]$Row['entity_class']
    $entityLabel = [string]$Row['entity_label']
    if ($entityType -eq 'storage' -and -not $entityLabel) {
        $entityLabel = Get-DuneStorageDisplayClass $entityClass
    }
    $workspacePath = if ($entityType -eq 'player') {
        "/players?view=inventory&scope_type=player&scope_id=$entityId"
    } else {
        "/bases?view=inventory&scope_type=storage&scope_id=$entityId"
    }
    return [ordered]@{
        id = ConvertTo-DuneInt $Row['item_id']
        templateId = $templateId
        displayName = Get-DuneGameplayItemName -TemplateId $templateId
        kind = Get-DuneItemKind -TemplateId $templateId
        quantity = ConvertTo-DuneInt $Row['stack_size']
        quality = ConvertTo-DuneInt $Row['quality_level']
        durability = [string]$Row['durability']
        maxDurability = [string]$Row['max_durability']
        waterAmount = [string]$Row['water_amount']
        waterType = [string]$Row['water_type']
        metadata = [ordered]@{
            category = [string]$rule.category
            tier = [int]$rule.tier
            rarity = [string]$rule.rarity
            icon = [string]$rule.icon
            stackMaximum = [int]$rule.stack_max
            volume = [double]$rule.volume
            vendorPrice = [int]$rule.vendor_price
            isGradeable = [bool]$rule.is_gradeable
        }
        entity = [ordered]@{
            type = $entityType
            id = $entityId
            label = $entityLabel
            owner = [string]$Row['owner_name']
            map = [string]$Row['map']
            class = $entityClass
            inventoryId = ConvertTo-DuneInt $Row['inventory_id']
            inventoryType = [int](ConvertTo-DuneInt $Row['inventory_type'])
            workspacePath = $workspacePath
        }
    }
}

function Invoke-DuneInventorySearchLive {
    param(
        [string]$Ip,
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$AfterItemId = 0,
        [int]$Limit = 101
    )
    $sql = Get-DuneInventorySearchSql -Query $Query -EntityTypes $EntityTypes `
        -ScopeType $ScopeType -ScopeId $ScopeId -AfterItemId $AfterItemId -Limit $Limit
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows $Limit -TimeoutSec 45 -Bulk
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    $items = @()
    foreach ($row in (ConvertTo-DuneRowMaps -Result $result)) {
        $items += ConvertTo-DuneInventoryItem -Row $row
    }
    return @{ ok = $true; items = $items }
}

function Get-DuneInventoryDemoItems {
    $items = @()
    $players = @(Get-DunePlayersDemo)
    foreach ($player in $players | Select-Object -First 2) {
        foreach ($item in @((Get-DunePlayerDetailDemo -PawnId ([long]$player.id)).inventory | Select-Object -First 3)) {
            $row = @{
                item_id = ([long]$item.id + ([long]$player.id - 20001L) * 100L)
                template_id = $item.template_id
                stack_size = $item.stack_size
                quality_level = $item.quality
                durability = $item.durability
                max_durability = $item.max_durability
                water_amount = $item.water_amount
                water_type = $item.water_type
                inventory_id = ([long]$player.id + 100000L)
                inventory_type = 0
                entity_type = 'player'
                entity_id = $player.id
                entity_label = $player.name
                owner_name = $player.name
                map = $player.map
                entity_class = $player.class
            }
            $items += ConvertTo-DuneInventoryItem -Row $row
        }
    }
    $containers = @(Get-DuneStorageDemo)
    foreach ($container in $containers | Select-Object -First 2) {
        foreach ($item in @((Get-DuneStorageItemsDemo -ContainerId ([long]$container.id)).items)) {
            $row = @{
                item_id = ([long]$item.id + ([long]$container.id - 50001L) * 100L + 10000L)
                template_id = $item.template_id
                stack_size = $item.stack_size
                quality_level = $item.quality
                durability = $item.durability
                max_durability = $item.max_durability
                water_amount = 'N/A'
                water_type = ''
                inventory_id = ([long]$container.id + 100000L)
                inventory_type = 4
                entity_type = 'storage'
                entity_id = $container.id
                entity_label = if ($container.name) { $container.name } else { $container.class }
                owner_name = $container.owner_name
                map = $container.map
                entity_class = $container.raw_class
            }
            $items += ConvertTo-DuneInventoryItem -Row $row
        }
    }
    return @($items | Sort-Object id)
}

function Select-DuneInventoryDemoItems {
    param(
        [object[]]$Items,
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$AfterItemId = 0,
        [int]$Limit = 101
    )
    $needle = $Query.Trim()
    return @($Items | Where-Object {
        $entitySearchLabel = if ([string]$_.entity.type -eq 'storage') {
            'container storage'
        } else {
            'player character'
        }
        $matchesQuery = -not $needle -or @(
            $_.displayName,
            $_.templateId,
            $_.entity.label,
            $_.entity.owner,
            $_.entity.type,
            $_.entity.map,
            $entitySearchLabel
        ).Where({
            ([string]$_).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }, 'First').Count -gt 0
        [long]$_.id -gt $AfterItemId -and
        [string]$_.entity.type -in $EntityTypes -and
        (-not $ScopeType -or ([string]$_.entity.type -eq $ScopeType -and [long]$_.entity.id -eq $ScopeId)) -and
        $matchesQuery
    } | Sort-Object id | Select-Object -First $Limit)
}

function Invoke-DuneInventoryRequestedPage {
    param(
        [ValidateSet('live', 'demo')][string]$Mode,
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$AfterItemId = 0,
        [int]$Limit = 101
    )
    if ($Mode -eq 'demo') {
        $items = @(Select-DuneInventoryDemoItems -Items (Get-DuneInventoryDemoItems) `
            -Query $Query -EntityTypes $EntityTypes -ScopeType $ScopeType -ScopeId $ScopeId `
            -AfterItemId $AfterItemId -Limit $Limit)
        foreach ($item in $items) {
            $item.entity.workspacePath = "$($item.entity.workspacePath)&demo=1"
        }
        return @{ ok = $true; source = 'static'; mode = 'demo'; items = $items }
    }

    $context = Get-DuneDbContext
    if (-not $context.ok) {
        return @{ ok = $false; status = 503; error = "Inventory database unavailable: $([string]$context.message)" }
    }
    $live = Invoke-DuneInventorySearchLive -Ip $context.ip -Query $Query -EntityTypes $EntityTypes `
        -ScopeType $ScopeType -ScopeId $ScopeId -AfterItemId $AfterItemId -Limit $Limit
    if (-not $live.ok) {
        return @{ ok = $false; status = 503; error = "Inventory database read failed: $([string]$live.error)" }
    }
    return @{ ok = $true; source = 'live'; mode = 'live'; items = @($live.items) }
}

function Resolve-DuneInventoryPlayerId {
    param([bool]$HasPlayerId, [string]$Value)
    if (-not $HasPlayerId) { return @{ ok = $true; playerId = 0L } }
    $playerId = 0L
    if (-not [Int64]::TryParse($Value, [ref]$playerId) -or $playerId -le 0) {
        return @{ ok = $false; error = 'player_id must be a positive integer.' }
    }
    return @{ ok = $true; playerId = $playerId }
}

function Resolve-DuneInventoryGroupSort {
        param([string]$Value)
        $sort = if ($Value) { $Value.Trim().ToLowerInvariant() } else { 'name-asc' }
        $map = @{
            'name-asc' = @{ sql='grouped.sort_name ASC, grouped.template_id ASC'; primary='sort_name'; type='text'; direction='asc' }
            'name-desc' = @{ sql='grouped.sort_name DESC, grouped.template_id ASC'; primary='sort_name'; type='text'; direction='desc' }
            'quantity-desc' = @{ sql='grouped.total_quantity DESC, grouped.sort_name ASC, grouped.template_id ASC'; primary='total_quantity'; type='number'; direction='desc' }
            'quantity-asc' = @{ sql='grouped.total_quantity ASC, grouped.sort_name ASC, grouped.template_id ASC'; primary='total_quantity'; type='number'; direction='asc' }
            'unit-volume-desc' = @{ sql='grouped.unit_volume DESC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='unit_volume'; type='number'; direction='desc' }
            'unit-volume-asc' = @{ sql='grouped.unit_volume ASC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='unit_volume'; type='number'; direction='asc' }
            'total-volume-desc' = @{ sql='grouped.total_volume DESC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='total_volume'; type='number'; direction='desc' }
            'total-volume-asc' = @{ sql='grouped.total_volume ASC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='total_volume'; type='number'; direction='asc' }
            'tier-desc' = @{ sql='grouped.item_tier DESC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='item_tier'; type='number'; direction='desc' }
            'tier-asc' = @{ sql='grouped.item_tier ASC NULLS LAST, grouped.sort_name ASC, grouped.template_id ASC'; primary='item_tier'; type='number'; direction='asc' }
            'quality-desc' = @{ sql='grouped.quality_max DESC, grouped.quality_min DESC, grouped.sort_name ASC, grouped.template_id ASC'; primary='quality_max'; secondary='quality_min'; type='number'; direction='desc' }
            'quality-asc' = @{ sql='grouped.quality_max ASC, grouped.quality_min ASC, grouped.sort_name ASC, grouped.template_id ASC'; primary='quality_max'; secondary='quality_min'; type='number'; direction='asc' }
            'occurrences-desc' = @{ sql='grouped.occurrence_count DESC, grouped.sort_name ASC, grouped.template_id ASC'; primary='occurrence_count'; type='number'; direction='desc' }
            'occurrences-asc' = @{ sql='grouped.occurrence_count ASC, grouped.sort_name ASC, grouped.template_id ASC'; primary='occurrence_count'; type='number'; direction='asc' }
            'locations-desc' = @{ sql='grouped.location_count DESC, grouped.sort_name ASC, grouped.template_id ASC'; primary='location_count'; type='number'; direction='desc' }
            'locations-asc' = @{ sql='grouped.location_count ASC, grouped.sort_name ASC, grouped.template_id ASC'; primary='location_count'; type='number'; direction='asc' }
        }
        if (-not $map.ContainsKey($sort)) { return @{ ok = $false; error = "Unsupported inventory sort '$sort'." } }
        return @{
            ok = $true; value = $sort; sql = $map[$sort].sql; primary = $map[$sort].primary
            secondary = [string]$map[$sort].secondary; type = $map[$sort].type; direction = $map[$sort].direction
        }
    }

function Resolve-DuneInventoryOccurrenceSort {
        param([string]$Value)
        $sort = if ($Value) { $Value.Trim().ToLowerInvariant() } else { 'player-asc' }
        $map = @{
            'player-asc' = @{ sql='lower(r.player_name) ASC NULLS LAST, r.item_id ASC'; primary='lower(r.player_name)'; type='text'; direction='asc' }
            'player-desc' = @{ sql='lower(r.player_name) DESC NULLS LAST, r.item_id ASC'; primary='lower(r.player_name)'; type='text'; direction='desc' }
            'location-asc' = @{ sql='lower(r.entity_label) ASC NULLS LAST, r.item_id ASC'; primary='lower(r.entity_label)'; type='text'; direction='asc' }
            'location-desc' = @{ sql='lower(r.entity_label) DESC NULLS LAST, r.item_id ASC'; primary='lower(r.entity_label)'; type='text'; direction='desc' }
            'quantity-desc' = @{ sql='r.stack_size DESC NULLS LAST, r.item_id ASC'; primary='r.stack_size'; type='number'; direction='desc' }
            'quantity-asc' = @{ sql='r.stack_size ASC NULLS LAST, r.item_id ASC'; primary='r.stack_size'; type='number'; direction='asc' }
            'quality-desc' = @{ sql='r.quality_level DESC NULLS LAST, r.item_id ASC'; primary='r.quality_level'; type='number'; direction='desc' }
            'quality-asc' = @{ sql='r.quality_level ASC NULLS LAST, r.item_id ASC'; primary='r.quality_level'; type='number'; direction='asc' }
        }
        if (-not $map.ContainsKey($sort)) { return @{ ok = $false; error = "Unsupported occurrence sort '$sort'." } }
        return @{ ok = $true; value = $sort; sql = $map[$sort].sql; primary = $map[$sort].primary; type = $map[$sort].type; direction = $map[$sort].direction }
    }
function Test-DuneInventoryVisibleItem {
    param([Parameter(Mandatory)]$Item)
    $templateId = [string]$Item.templateId
    $rule = Get-DuneGameplayItemRule -TemplateId $templateId
    if ([string]$rule.category) { return $true }
    return [string]$Item.kind -ne 'emote' -and $templateId -notmatch '(?i)Emote|Gesture'
}

function New-DuneInventoryParameterizedSql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][hashtable]$ParameterTypes
    )
    $token = '/*__DST_PARAMETERS__*/'
    if (-not $Sql.Contains($token)) { throw "Parameterized inventory SQL is missing the $token token." }
    $allowedTypes = @('text', 'integer', 'bigint', 'boolean')
    $payload = [ordered]@{}
    $definitions = @()
    foreach ($name in @($Parameters.Keys | Sort-Object)) {
        if ([string]$name -notmatch '^[a-z][a-z0-9_]*$') { throw "Invalid inventory SQL parameter name '$name'." }
        if (-not $ParameterTypes.ContainsKey($name)) { throw "Inventory SQL parameter '$name' has no declared PostgreSQL type." }
        $type = ([string]$ParameterTypes[$name]).ToLowerInvariant()
        if ($allowedTypes -notcontains $type) { throw "Inventory SQL parameter '$name' uses unsupported PostgreSQL type '$type'." }
        $payload[$name] = $Parameters[$name]
        $definitions += '"' + $name + '" ' + $type
    }
    $json = $payload | ConvertTo-Json -Compress -Depth 5
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $cte = "_dst_parameters AS (SELECT * FROM jsonb_to_record(convert_from(decode('$encoded', 'base64'), 'UTF8')::jsonb) AS p($($definitions -join ', ')))"
    return $Sql.Replace($token, $cte)
}

function Get-DuneInventoryCatalogIdsJson {
    Initialize-DuneGameplayItemData
    $ids = @($script:DuneGameplayItemRules.Keys | Where-Object {
        [string](Get-DuneGameplayItemRule -TemplateId $_).category
    } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { return '[]' }
    return (ConvertTo-Json -InputObject $ids -Compress)
}

function Get-DuneInventoryCatalogMetadataJson {
    Initialize-DuneGameplayItemData
    $metadata = [ordered]@{}
    $catalogIds = @(
        @($script:DuneGameplayItemNames.Keys) + @($script:DuneGameplayItemRules.Keys) |
            Sort-Object -Unique
    )
    foreach ($id in $catalogIds) {
        $hasRule = $script:DuneGameplayItemRules.ContainsKey($id)
        $rule = if ($hasRule) { Get-DuneGameplayItemRule -TemplateId $id } else { $null }
        $metadata[([string]$id).ToLowerInvariant()] = [ordered]@{
            name = Get-DuneGameplayItemName -TemplateId $id
            tier = if ($hasRule -and $null -ne $rule.tier) { [int]$rule.tier } else { $null }
            volume = if ($hasRule -and $null -ne $rule.volume) { [double]$rule.volume } else { $null }
        }
    }
    return ($metadata | ConvertTo-Json -Compress -Depth 4)
}

function Get-DuneInventoryMetadataMatchesJson {
    param([string]$Query)
    $ids = @(Get-DuneInventoryMetadataMatches -Query $Query)
    if ($ids.Count -eq 0) { return '[]' }
    return (ConvertTo-Json -InputObject $ids -Compress)
}

function Get-DuneInventoryFilteredCteSql {
    $storageClassSql = Get-DuneInventoryStorageClassSql
    return @"
/*__DST_PARAMETERS__*/,
inventory_rows AS (
    SELECT i.id::bigint AS item_id, i.template_id, i.stack_size,
           COALESCE(i.quality_level, 0) AS quality_level,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A') AS max_durability,
           COALESCE((i.stats->'FFillableItemStats'->1->>'CurrentAmount'), 'N/A') AS water_amount,
           COALESCE((i.stats->'FFillableItemStats'->1->>'FillableType'), '') AS water_type,
           inv.id::bigint AS inventory_id, inv.inventory_type,
           'player'::text AS entity_type, ps.player_pawn_id::bigint AS entity_id,
           ps.player_pawn_id::bigint AS player_id, COALESCE(ps.character_name, '') AS player_name,
           COALESCE(ps.character_name, '') AS entity_label, COALESCE(ps.character_name, '') AS owner_name,
           COALESCE(a.map, '') AS map, ''::text AS entity_class
    FROM dune.items i
    JOIN dune.inventories inv ON inv.id = i.inventory_id
    JOIN dune.player_state ps ON ps.player_pawn_id = inv.actor_id
    LEFT JOIN dune.actors a ON a.id = ps.player_pawn_id
    UNION ALL
    SELECT i.id::bigint AS item_id, i.template_id, i.stack_size,
           COALESCE(i.quality_level, 0) AS quality_level,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
           COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A') AS max_durability,
           COALESCE((i.stats->'FFillableItemStats'->1->>'CurrentAmount'), 'N/A') AS water_amount,
           COALESCE((i.stats->'FFillableItemStats'->1->>'FillableType'), '') AS water_type,
           inv.id::bigint AS inventory_id, inv.inventory_type,
           'storage'::text AS entity_type, p.id::bigint AS entity_id,
           owner.player_pawn_id::bigint AS player_id, COALESCE(owner.character_name, '') AS player_name,
           COALESCE(NULLIF((SELECT MAX(CASE WHEN pa.actor_name NOT LIKE '##%' AND pa.actor_name <> 'None' THEN pa.actor_name END)
               FROM dune.permission_actor pa WHERE pa.actor_id = p.id), ''), NULLIF(($storageClassSql), ''), 'Storage container') AS entity_label,
           COALESCE(owner.character_name, '') AS owner_name, COALESCE(a.map, '') AS map,
           COALESCE(p.building_type, '') AS entity_class
    FROM dune.items i
    JOIN dune.inventories inv ON inv.id = i.inventory_id AND inv.inventory_type = 4
    JOIN dune.placeables p ON p.id = inv.actor_id
    LEFT JOIN dune.actors a ON a.id = p.id
    LEFT JOIN LATERAL (
        SELECT ps.player_pawn_id, ps.character_name
        FROM dune.actor_fgl_entities afe
        JOIN dune.permission_actor_rank par ON par.permission_actor_id = afe.actor_id
        JOIN dune.actors player_a ON player_a.id = par.player_id
        JOIN dune.player_state ps ON ps.account_id = player_a.owner_account_id
        WHERE afe.entity_id = p.owner_entity_id
        ORDER BY par.rank ASC, ps.character_name ASC, ps.player_pawn_id ASC LIMIT 1
    ) owner ON true
    WHERE p.is_hologram = false AND p.owner_entity_id IS NOT NULL AND p.owner_entity_id <> 0
),
visible_rows AS (
    SELECT r.*
    FROM inventory_rows r CROSS JOIN _dst_parameters p
    WHERE r.entity_type = ANY(string_to_array(p.entity_types, ','))
      AND (p.scope_type = '' OR (r.entity_type = p.scope_type AND r.entity_id = p.scope_id))
      AND (
          r.template_id IN (SELECT jsonb_array_elements_text(p.catalog_ids::jsonb))
          OR r.template_id !~* 'Emote|Gesture'
      )
),
searched_rows AS (
    SELECT r.*
    FROM visible_rows r CROSS JOIN _dst_parameters p
    WHERE p.query = ''
       OR strpos(lower(COALESCE(r.template_id, '')), lower(p.query)) > 0
       OR strpos(lower(COALESCE(r.entity_label, '')), lower(p.query)) > 0
       OR strpos(lower(COALESCE(r.owner_name, '')), lower(p.query)) > 0
       OR strpos(lower(COALESCE(r.map, '')), lower(p.query)) > 0
       OR strpos(lower(COALESCE(r.entity_type, '')), lower(p.query)) > 0
       OR strpos(lower(CASE WHEN r.entity_type = 'storage' THEN 'container storage' ELSE 'player character' END), lower(p.query)) > 0
       OR r.template_id IN (SELECT jsonb_array_elements_text(p.metadata_ids::jsonb))
)
"@
}

function Get-DuneInventoryQueryParameters {
    param(
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$PlayerId = 0,
        [string]$LocationType = '',
        [long]$LocationId = 0,
        [string]$AfterGroupKey = '',
        [long]$AfterItemId = 0,
        [string]$TemplateId = '',
        [string]$AfterSortValue = '',
        [string]$AfterSortSecondary = '',
        [string]$AfterSortName = '',
        [string]$AfterTemplateId = '',
        [int]$Limit = 101
    )
    return @{
        values = @{
            query = $Query.Trim()
            entity_types = ($EntityTypes -join ',')
            scope_type = $ScopeType
            scope_id = $ScopeId
            player_id = $PlayerId
            location_type = $LocationType
            location_id = $LocationId
            after_group_key = $AfterGroupKey
            after_item_id = $AfterItemId
            template_id = $TemplateId
            row_limit = $Limit
            after_sort_value = $AfterSortValue
            after_sort_secondary = $AfterSortSecondary
            after_sort_name = $AfterSortName
            after_template_id = $AfterTemplateId
            catalog_ids = Get-DuneInventoryCatalogIdsJson
            catalog_metadata = Get-DuneInventoryCatalogMetadataJson
            metadata_ids = Get-DuneInventoryMetadataMatchesJson -Query $Query
        }
        types = @{
            query = 'text'; entity_types = 'text'; scope_type = 'text'; scope_id = 'bigint'
            player_id = 'bigint'; after_group_key = 'text'; after_item_id = 'bigint'
            location_type = 'text'; location_id = 'bigint'
            template_id = 'text'; row_limit = 'integer'; after_sort_value = 'text'
            after_sort_secondary = 'text'; after_sort_name = 'text'; after_template_id = 'text'
            catalog_ids = 'text'; catalog_metadata = 'text'; metadata_ids = 'text'
        }
    }
}

function ConvertTo-DuneInventoryPlayerFacet {
    param([Parameter(Mandatory)]$Row)
    Assert-DuneInventoryDatabaseRow -Row $Row -Kind playerFacet
    return [ordered]@{
        id = ConvertTo-DuneInt $Row['player_id']
        name = [string]$Row['player_name']
        occurrenceCount = ConvertTo-DuneInt $Row['occurrence_count']
    }
}

function ConvertTo-DuneInventoryBoolean {
    param($Value)
    return $Value -eq $true -or [string]$Value -in @('1', 't', 'true')
}

function Assert-DuneInventoryDatabaseRow {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)]
        [ValidateSet('item', 'group', 'playerFacet', 'locationFacet', 'validity')]
        [string]$Kind
    )
    if ($Row -isnot [Collections.IDictionary]) {
        throw "Malformed inventory database $Kind row: expected a name-keyed row."
    }

    $requiredText = switch ($Kind) {
        'item' { @('template_id', 'entity_type') }
        'group' { @('group_key', 'template_id', 'sort_name') }
        'playerFacet' { @('player_name') }
        'locationFacet' { @('entity_type', 'entity_label') }
        default { @('player_valid', 'location_valid') }
    }
    foreach ($name in $requiredText) {
        if (-not $Row.Contains($name) -or [string]::IsNullOrWhiteSpace([string]$Row[$name])) {
            throw "Malformed inventory database $Kind row: '$name' is missing or blank."
        }
    }

    $requiredPositive = switch ($Kind) {
        'item' { @('item_id', 'inventory_id', 'entity_id') }
        'playerFacet' { @('player_id') }
        'locationFacet' { @('entity_id') }
        default { @() }
    }
    foreach ($name in $requiredPositive) {
        $value = 0L
        if (-not $Row.Contains($name) -or
            -not [Int64]::TryParse([string]$Row[$name], [ref]$value) -or $value -le 0) {
            throw "Malformed inventory database $Kind row: '$name' must be a positive integer."
        }
    }

    $requiredNonNegative = switch ($Kind) {
        'item' { @('stack_size', 'quality_level', 'inventory_type') }
        'group' { @('total_quantity', 'occurrence_count', 'location_count', 'quality_min', 'quality_max') }
        'playerFacet' { @('occurrence_count') }
        'locationFacet' { @('occurrence_count') }
        default { @() }
    }
    foreach ($name in $requiredNonNegative) {
        $value = 0L
        if (-not $Row.Contains($name) -or
            -not [Int64]::TryParse([string]$Row[$name], [ref]$value) -or $value -lt 0) {
            throw "Malformed inventory database $Kind row: '$name' must be a non-negative integer."
        }
    }

    if ($Kind -eq 'item' -and [string]$Row['entity_type'] -notin @('player', 'storage')) {
        throw "Malformed inventory database item row: 'entity_type' is unsupported."
    }
    if ($Kind -eq 'locationFacet' -and [string]$Row['entity_type'] -notin @('player', 'storage')) {
        throw "Malformed inventory database locationFacet row: 'entity_type' is unsupported."
    }
}

function ConvertTo-DuneInventoryGroup {
    param([Parameter(Mandatory)]$Row)
    Assert-DuneInventoryDatabaseRow -Row $Row -Kind group
    $templateId = [string]$Row['template_id']
    $rule = Get-DuneGameplayItemRule -TemplateId $templateId
    $qualityMin = ConvertTo-DuneInt $Row['quality_min']
    $qualityMax = ConvertTo-DuneInt $Row['quality_max']
    return [ordered]@{
        groupKey = [string]$Row['group_key']
        templateId = $templateId
        displayName = Get-DuneGameplayItemName -TemplateId $templateId
        totalQuantity = ConvertTo-DuneInt $Row['total_quantity']
        occurrenceCount = ConvertTo-DuneInt $Row['occurrence_count']
        locationCount = ConvertTo-DuneInt $Row['location_count']
        quality = [ordered]@{ min = $qualityMin; max = $qualityMax; mixed = $qualityMin -ne $qualityMax }
        cursor = [ordered]@{
            sortValue = [string]$Row['sort_value']
            sortSecondary = [string]$Row['sort_secondary']
            sortName = [string]$Row['sort_name']
            templateId = $templateId
        }
        metadata = [ordered]@{
            category = [string]$rule.category; tier = [int]$rule.tier; rarity = [string]$rule.rarity
            icon = [string]$rule.icon; stackMaximum = [int]$rule.stack_max; volume = [double]$rule.volume
            vendorPrice = [int]$rule.vendor_price; isGradeable = [bool]$rule.is_gradeable
        }
    }
}

function ConvertTo-DuneInventoryLocationFacet {
    param([Parameter(Mandatory)]$Row)
    Assert-DuneInventoryDatabaseRow -Row $Row -Kind locationFacet
    return [ordered]@{
        type = [string]$Row['entity_type']; id = ConvertTo-DuneInt $Row['entity_id']
        label = [string]$Row['entity_label']; owner = [string]$Row['owner_name']
        playerId = ConvertTo-DuneInt $Row['player_id']; playerName = [string]$Row['player_name']
        occurrenceCount = ConvertTo-DuneInt $Row['occurrence_count']
    }
}

function Select-DuneInventoryDemoFiltered {
    param(
        [object[]]$Items,
        [string]$Query,
        [string[]]$EntityTypes,
        [string]$ScopeType = '',
        [long]$ScopeId = 0,
        [long]$PlayerId = 0,
        [string]$LocationType = '',
        [long]$LocationId = 0
    )
    return @(Select-DuneInventoryDemoItems -Items $Items -Query $Query -EntityTypes $EntityTypes `
        -ScopeType $ScopeType -ScopeId $ScopeId -Limit $script:DuneInventoryMaxLimit | Where-Object {
        (Test-DuneInventoryVisibleItem -Item $_) -and
        (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) -and
        (-not $LocationType -or ([string]$_.entity.type -eq $LocationType -and [long]$_.entity.id -eq $LocationId))
    })
}

function Get-DuneInventoryDemoPlayerId {
    param([Parameter(Mandatory)]$Item)
    if ($Item.PSObject.Properties.Name -contains 'player' -and $Item.player) { return [long]$Item.player.id }
    if ([string]$Item.entity.type -eq 'player') { return [long]$Item.entity.id }
    $owner = [string]$Item.entity.owner
    $player = @(Get-DunePlayersDemo | Where-Object { [string]$_.name -eq $owner } | Select-Object -First 1)
    if ($player.Count) { return [long]$player[0].id }
    return 0L
}

function Add-DuneInventoryDemoPlayer {
    param([Parameter(Mandatory)]$Item)
    $playerId = Get-DuneInventoryDemoPlayerId -Item $Item
    $playerName = if ([string]$Item.entity.type -eq 'player') { [string]$Item.entity.label } else { [string]$Item.entity.owner }
    $Item['player'] = [ordered]@{ id = $playerId; name = $playerName }
    return $Item
}

function Get-DuneInventoryGroupedDemo {
    param(
        [string]$Query, [string[]]$EntityTypes, [string]$ScopeType = '', [long]$ScopeId = 0,
        [long]$PlayerId = 0, [string]$LocationType = '', [long]$LocationId = 0,
        [string]$Sort = 'name-asc', [string]$AfterTemplateId = '', [int]$Limit = 101
    )
    $all = @(Get-DuneInventoryDemoItems | ForEach-Object { Add-DuneInventoryDemoPlayer -Item $_ })
    $visibleBase = @(Select-DuneInventoryDemoFiltered -Items $all -EntityTypes $EntityTypes `
        -ScopeType $ScopeType -ScopeId $ScopeId)
    $base = @(Select-DuneInventoryDemoFiltered -Items $visibleBase -Query $Query -EntityTypes $EntityTypes)
    $facets = @($base | Where-Object { [long]$_.player.id -gt 0 } | Group-Object { [long]$_.player.id } | ForEach-Object {
        [ordered]@{ id = [long]$_.Name; name = [string]$_.Group[0].player.name; occurrenceCount = $_.Count }
    } | Sort-Object name, id)
    $locations = @($base | Where-Object { (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) } |
        Group-Object { "$($_.entity.type):$($_.entity.id)" } | ForEach-Object {
            $first = $_.Group[0]
            [ordered]@{
                type = [string]$first.entity.type; id = [long]$first.entity.id
                label = if ([string]$first.entity.type -eq 'player') { 'Backpack' } else { [string]$first.entity.label }
                owner = [string]$first.entity.owner; playerId = [long]$first.player.id
                playerName = [string]$first.player.name; occurrenceCount = $_.Count
            }
        } | Sort-Object type, label, id)
    if ($PlayerId -and -not @($facets | Where-Object { [long]$_.id -eq $PlayerId }).Count) {
        $activePlayerRows = @($visibleBase | Where-Object { [long]$_.player.id -eq $PlayerId })
        if ($activePlayerRows.Count) {
            $facets += [ordered]@{
                id = $PlayerId; name = [string]$activePlayerRows[0].player.name
                occurrenceCount = $activePlayerRows.Count
            }
        }
    }
    if ($LocationType -and -not @($locations | Where-Object {
        [string]$_.type -eq $LocationType -and [long]$_.id -eq $LocationId
    }).Count) {
        $activeLocationRows = @($visibleBase | Where-Object {
            (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) -and
            [string]$_.entity.type -eq $LocationType -and [long]$_.entity.id -eq $LocationId
        })
        if ($activeLocationRows.Count) {
            $first = $activeLocationRows[0]
            $locations += [ordered]@{
                type = [string]$first.entity.type; id = [long]$first.entity.id
                label = if ([string]$first.entity.type -eq 'player') { 'Backpack' } else { [string]$first.entity.label }
                owner = [string]$first.entity.owner; playerId = [long]$first.player.id
                playerName = [string]$first.player.name; occurrenceCount = $activeLocationRows.Count
            }
        }
    }
    $filtered = @($base | Where-Object {
        (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) -and
        (-not $LocationType -or ([string]$_.entity.type -eq $LocationType -and [long]$_.entity.id -eq $LocationId))
    })
    $groups = @($filtered | Group-Object { ([string]$_.templateId).Trim().ToLowerInvariant() } | ForEach-Object {
        $rows = @($_.Group)
        $first = $rows[0]
        $qualities = @($rows | ForEach-Object { [int]$_.quality })
        $group = [ordered]@{
            groupKey = [string]$_.Name; templateId = [string]$first.templateId
            displayName = [string]$first.displayName
            totalQuantity = [long](($rows | Measure-Object quantity -Sum).Sum)
            occurrenceCount = $rows.Count
            locationCount = @($rows | ForEach-Object { "$($_.entity.type):$($_.entity.id)" } | Sort-Object -Unique).Count
            quality = [ordered]@{ min = ($qualities | Measure-Object -Minimum).Minimum; max = ($qualities | Measure-Object -Maximum).Maximum; mixed = (($qualities | Sort-Object -Unique).Count -gt 1) }
            metadata = $first.metadata
        }
        $group
    })
    $sortSpec = Resolve-DuneInventoryGroupSort -Value $Sort
    $descending = $Sort.EndsWith('-desc')
    $primary = switch -Wildcard ($Sort) {
        'name-*' { 'displayName' }
        'quantity-*' { 'totalQuantity' }
        'unit-volume-*' { { $_.metadata.volume } }
        'total-volume-*' { { [double]$_.metadata.volume * [long]$_.totalQuantity } }
        'tier-*' { { $_.metadata.tier } }
        'quality-*' { { $_.quality.max } }
        'occurrences-*' { 'occurrenceCount' }
        'locations-*' { 'locationCount' }
    }
    $sortedGroups = @($groups | Sort-Object -Property @(
        @{ Expression = $primary; Descending = $descending },
        @{ Expression = 'displayName'; Descending = $false },
        @{ Expression = 'templateId'; Descending = $false }
    ))
    $skip = 0
    if ($AfterTemplateId) {
        for ($index = 0; $index -lt $sortedGroups.Count; $index++) {
            if ([string]$sortedGroups[$index].templateId -eq $AfterTemplateId) {
                $skip = $index + 1
                break
            }
        }
    }
    $groups = @($sortedGroups | Select-Object -Skip $skip -First $Limit)
    foreach ($group in $groups) {
        $sortValue = switch -Wildcard ($Sort) {
            'name-*' { [string]$group.displayName }
            'quantity-*' { [string]$group.totalQuantity }
            'unit-volume-*' { [string]$group.metadata.volume }
            'total-volume-*' { [string]([double]$group.metadata.volume * [long]$group.totalQuantity) }
            'tier-*' { [string]$group.metadata.tier }
            'quality-*' { [string]$group.quality.max }
            'occurrences-*' { [string]$group.occurrenceCount }
            'locations-*' { [string]$group.locationCount }
        }
        $sortSecondary = if ($Sort -like 'quality-*') { [string]$group.quality.min } else { '' }
        $group['cursor'] = [ordered]@{
            sortValue = $sortValue; sortSecondary = $sortSecondary
            sortName = [string]$group.displayName; templateId = [string]$group.templateId
        }
    }
    $selectedPlayerValid = -not $PlayerId -or @($visibleBase | Where-Object { [long]$_.player.id -eq $PlayerId }).Count -gt 0
    $selectedLocationValid = -not $LocationType -or @($visibleBase | Where-Object {
        (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) -and
        [string]$_.entity.type -eq $LocationType -and [long]$_.entity.id -eq $LocationId
    }).Count -gt 0
    return @{
        ok = $true; source = 'static'; groups = $groups; players = $facets; locations = $locations
        selectedPlayerValid = $selectedPlayerValid; selectedLocationValid = $selectedLocationValid
    }
}

function Invoke-DuneInventoryGroupedLive {
    param(
        [string]$Ip, [string]$Query, [string[]]$EntityTypes, [string]$ScopeType = '', [long]$ScopeId = 0,
        [long]$PlayerId = 0, [string]$LocationType = '', [long]$LocationId = 0,
        [string]$Sort = 'name-asc', [string]$AfterSortValue = '', [string]$AfterSortSecondary = '',
        [string]$AfterSortName = '',
        [string]$AfterTemplateId = '', [int]$Limit = 101
    )
    $binding = Get-DuneInventoryQueryParameters -Query $Query -EntityTypes $EntityTypes -ScopeType $ScopeType `
        -ScopeId $ScopeId -PlayerId $PlayerId -LocationType $LocationType -LocationId $LocationId `
        -AfterSortValue $AfterSortValue -AfterSortSecondary $AfterSortSecondary `
        -AfterSortName $AfterSortName -AfterTemplateId $AfterTemplateId -Limit $Limit
    $sortSpec = Resolve-DuneInventoryGroupSort -Value $Sort
    if (-not $sortSpec.ok) { return @{ ok = $false; error = $sortSpec.error } }
    $cte = Get-DuneInventoryFilteredCteSql
    $primary = [string]$sortSpec.primary
    if ($sortSpec.type -eq 'text') {
        $comparison = if ($sortSpec.direction -eq 'asc') { '>' } else { '<' }
        $pageWhere = "(p.after_template_id = '' OR grouped.$primary $comparison p.after_sort_value OR (grouped.$primary = p.after_sort_value AND grouped.template_id > p.after_template_id))"
    } else {
        $comparison = if ($sortSpec.direction -eq 'asc') { '>' } else { '<' }
        if ($sortSpec.secondary) {
            $secondary = [string]$sortSpec.secondary
            $pageWhere = @"
(p.after_template_id = '' OR
 (p.after_sort_value = '' AND grouped.$primary IS NULL AND (grouped.sort_name > p.after_sort_name OR (grouped.sort_name = p.after_sort_name AND grouped.template_id > p.after_template_id))) OR
 (p.after_sort_value <> '' AND (
   grouped.$primary IS NULL OR grouped.$primary $comparison p.after_sort_value::double precision OR
   (grouped.$primary = p.after_sort_value::double precision AND (
     grouped.$secondary $comparison p.after_sort_secondary::double precision OR
     (grouped.$secondary = p.after_sort_secondary::double precision AND (grouped.sort_name > p.after_sort_name OR (grouped.sort_name = p.after_sort_name AND grouped.template_id > p.after_template_id)))
   ))
 )))
"@
        } else {
            $pageWhere = @"
(p.after_template_id = '' OR
 (p.after_sort_value = '' AND grouped.$primary IS NULL AND (grouped.sort_name > p.after_sort_name OR (grouped.sort_name = p.after_sort_name AND grouped.template_id > p.after_template_id))) OR
 (p.after_sort_value <> '' AND (
   grouped.$primary IS NULL OR grouped.$primary $comparison p.after_sort_value::double precision OR
   (grouped.$primary = p.after_sort_value::double precision AND (grouped.sort_name > p.after_sort_name OR (grouped.sort_name = p.after_sort_name AND grouped.template_id > p.after_template_id)))
 )))
"@
        }
    }
    $sql = @"
WITH $cte,
player_facets AS (
    SELECT player_id, MAX(player_name) AS player_name, COUNT(*)::bigint AS occurrence_count
    FROM searched_rows WHERE player_id IS NOT NULL AND player_id > 0 GROUP BY player_id
),
grouped AS (
    SELECT lower(trim(r.template_id)) AS group_key, MIN(r.template_id) AS template_id,
           SUM(r.stack_size)::bigint AS total_quantity, COUNT(*)::bigint AS occurrence_count,
           COUNT(DISTINCT r.entity_type || ':' || r.entity_id::text)::bigint AS location_count,
           MIN(r.quality_level)::integer AS quality_min, MAX(r.quality_level)::integer AS quality_max,
           MIN(COALESCE(meta.value->>'name', r.template_id)) AS sort_name,
           MAX((meta.value->>'tier')::integer) AS item_tier,
           MAX((meta.value->>'volume')::double precision) AS unit_volume,
           MAX((meta.value->>'volume')::double precision) * SUM(r.stack_size)::double precision AS total_volume
    FROM searched_rows r CROSS JOIN _dst_parameters p
    LEFT JOIN LATERAL jsonb_each(p.catalog_metadata::jsonb) meta ON meta.key = lower(trim(r.template_id))
    WHERE (p.player_id = 0 OR r.player_id = p.player_id)
      AND (p.location_type = '' OR (r.entity_type = p.location_type AND r.entity_id = p.location_id))
    GROUP BY lower(trim(r.template_id))
)
SELECT 'group'::text AS row_kind, grouped.group_key, grouped.template_id, grouped.total_quantity, grouped.occurrence_count,
       grouped.location_count, grouped.quality_min, grouped.quality_max, NULL::bigint AS player_id, NULL::text AS player_name,
       grouped.sort_name, COALESCE((grouped.$primary)::text, '') AS sort_value,
       $(if ($sortSpec.secondary) { "COALESCE((grouped.$([string]$sortSpec.secondary))::text, '')" } else { "''::text" }) AS sort_secondary
FROM grouped CROSS JOIN _dst_parameters p
WHERE $pageWhere
ORDER BY $($sortSpec.sql) LIMIT (SELECT row_limit FROM _dst_parameters)
"@
    $effectiveSql = New-DuneInventoryParameterizedSql -Sql $sql -Parameters $binding.values -ParameterTypes $binding.types
    $groupResult = Invoke-DuneSqlQuery -Ip $Ip -Sql $effectiveSql -ReadOnly $true -MaxRows $Limit -TimeoutSec 45 -Bulk
    if (-not $groupResult.ok) { return @{ ok = $false; error = $groupResult.error } }

    $facetSql = @"
WITH $cte,
search_facets AS (
    SELECT player_id, MAX(player_name) AS player_name, COUNT(*)::bigint AS occurrence_count
    FROM searched_rows WHERE player_id IS NOT NULL AND player_id > 0 GROUP BY player_id
),
active_facet AS (
    SELECT r.player_id, MAX(r.player_name) AS player_name, COUNT(*)::bigint AS occurrence_count
    FROM visible_rows r CROSS JOIN _dst_parameters p
    WHERE p.player_id > 0 AND r.player_id = p.player_id GROUP BY r.player_id
)
SELECT player_id, player_name, occurrence_count FROM search_facets
UNION ALL
SELECT a.player_id, a.player_name, a.occurrence_count FROM active_facet a
WHERE NOT EXISTS (SELECT 1 FROM search_facets s WHERE s.player_id = a.player_id)
ORDER BY player_name, player_id LIMIT 50000
"@
    $effectiveFacetSql = New-DuneInventoryParameterizedSql -Sql $facetSql -Parameters $binding.values -ParameterTypes $binding.types
    $facetResult = Invoke-DuneSqlQuery -Ip $Ip -Sql $effectiveFacetSql -ReadOnly $true -MaxRows 50000 -TimeoutSec 45 -Bulk
    if (-not $facetResult.ok) { return @{ ok = $false; error = $facetResult.error } }
    $locationSql = @"
WITH $cte,
search_locations AS (
    SELECT r.entity_type, r.entity_id, MAX(CASE WHEN r.entity_type = 'player' THEN 'Backpack' ELSE r.entity_label END) AS entity_label,
           MAX(r.owner_name) AS owner_name, MAX(r.player_id)::bigint AS player_id, MAX(r.player_name) AS player_name,
           COUNT(*)::bigint AS occurrence_count
    FROM searched_rows r CROSS JOIN _dst_parameters p
    WHERE (p.player_id = 0 OR r.player_id = p.player_id)
    GROUP BY r.entity_type, r.entity_id
),
active_location AS (
    SELECT r.entity_type, r.entity_id, MAX(CASE WHEN r.entity_type = 'player' THEN 'Backpack' ELSE r.entity_label END) AS entity_label,
           MAX(r.owner_name) AS owner_name, MAX(r.player_id)::bigint AS player_id, MAX(r.player_name) AS player_name,
           COUNT(*)::bigint AS occurrence_count
    FROM visible_rows r CROSS JOIN _dst_parameters p
    WHERE p.location_type <> '' AND r.entity_type = p.location_type AND r.entity_id = p.location_id
      AND (p.player_id = 0 OR r.player_id = p.player_id)
    GROUP BY r.entity_type, r.entity_id
)
SELECT * FROM search_locations
UNION ALL
SELECT a.* FROM active_location a
WHERE NOT EXISTS (
    SELECT 1 FROM search_locations s WHERE s.entity_type = a.entity_type AND s.entity_id = a.entity_id
)
ORDER BY entity_type, entity_label, entity_id LIMIT 50000
"@
    $effectiveLocationSql = New-DuneInventoryParameterizedSql -Sql $locationSql -Parameters $binding.values -ParameterTypes $binding.types
    $locationResult = Invoke-DuneSqlQuery -Ip $Ip -Sql $effectiveLocationSql -ReadOnly $true -MaxRows 50000 -TimeoutSec 45 -Bulk
    if (-not $locationResult.ok) { return @{ ok = $false; error = $locationResult.error } }
    $validitySql = @"
WITH $cte
SELECT
    (p.player_id = 0 OR EXISTS (
        SELECT 1 FROM visible_rows r WHERE r.player_id = p.player_id
    )) AS player_valid,
    (p.location_type = '' OR EXISTS (
        SELECT 1 FROM visible_rows r
        WHERE (p.player_id = 0 OR r.player_id = p.player_id)
          AND r.entity_type = p.location_type AND r.entity_id = p.location_id
    )) AS location_valid
FROM _dst_parameters p
"@
    $validityResult = Invoke-DuneSqlQuery -Ip $Ip `
        -Sql (New-DuneInventoryParameterizedSql -Sql $validitySql -Parameters $binding.values -ParameterTypes $binding.types) `
        -ReadOnly $true -MaxRows 1 -TimeoutSec 45 -Bulk
    if (-not $validityResult.ok) { return @{ ok = $false; error = $validityResult.error } }
    try {
        $validityRows = ConvertTo-DuneRowMaps -Result $validityResult
        if ($validityRows.Count -ne 1) {
            throw "Malformed inventory database validity result: expected one row, received $($validityRows.Count)."
        }
        $validity = $validityRows[0]
        Assert-DuneInventoryDatabaseRow -Row $validity -Kind validity
        $groups = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $groupResult)) {
            ConvertTo-DuneInventoryGroup -Row $row
        })
        $players = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $facetResult)) {
            ConvertTo-DuneInventoryPlayerFacet -Row $row
        })
        $locations = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $locationResult)) {
            ConvertTo-DuneInventoryLocationFacet -Row $row
        })
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
    return @{
        ok = $true
        groups = $groups
        players = $players
        locations = $locations
        selectedPlayerValid = ConvertTo-DuneInventoryBoolean $validity['player_valid']
        selectedLocationValid = ConvertTo-DuneInventoryBoolean $validity['location_valid']
    }
}

function Invoke-DuneInventoryGroupedPage {
    param(
        [ValidateSet('live', 'demo')][string]$Mode, [string]$Query, [string[]]$EntityTypes,
        [string]$ScopeType = '', [long]$ScopeId = 0, [long]$PlayerId = 0,
        [string]$LocationType = '', [long]$LocationId = 0,
        [string]$Sort = 'name-asc', [string]$AfterSortValue = '', [string]$AfterSortSecondary = '',
        [string]$AfterSortName = '',
        [string]$AfterTemplateId = '', [int]$Limit = 101
    )
    if ($Mode -eq 'demo') {
        return Get-DuneInventoryGroupedDemo -Query $Query -EntityTypes $EntityTypes -ScopeType $ScopeType `
            -ScopeId $ScopeId -PlayerId $PlayerId -LocationType $LocationType -LocationId $LocationId `
            -Sort $Sort -AfterTemplateId $AfterTemplateId -Limit $Limit
    }
    $context = Get-DuneDbContext
    if (-not $context.ok) { return @{ ok = $false; status = 503; error = "Inventory database unavailable: $([string]$context.message)" } }
    $result = Invoke-DuneInventoryGroupedLive -Ip $context.ip -Query $Query -EntityTypes $EntityTypes `
        -ScopeType $ScopeType -ScopeId $ScopeId -PlayerId $PlayerId -LocationType $LocationType `
        -LocationId $LocationId -Sort $Sort -AfterSortValue $AfterSortValue `
        -AfterSortSecondary $AfterSortSecondary -AfterSortName $AfterSortName `
        -AfterTemplateId $AfterTemplateId -Limit $Limit
    if (-not $result.ok) { return @{ ok = $false; status = 503; error = "Inventory database read failed: $([string]$result.error)" } }
    $result.source = 'live'
    return $result
}

function Get-DuneInventoryOccurrencesDemo {
    param(
        [string]$TemplateId, [string[]]$EntityTypes, [string]$ScopeType = '', [long]$ScopeId = 0,
        [long]$PlayerId = 0, [string]$LocationType = '', [long]$LocationId = 0,
        [string]$Sort = 'player-asc', [long]$AfterItemId = 0, [int]$Limit = 51
    )
    $all = @(Get-DuneInventoryDemoItems | ForEach-Object { Add-DuneInventoryDemoPlayer -Item $_ })
    $base = @(Select-DuneInventoryDemoFiltered -Items $all -EntityTypes $EntityTypes -ScopeType $ScopeType `
        -ScopeId $ScopeId | Where-Object {
        [string]::Equals([string]$_.templateId, $TemplateId, [StringComparison]::OrdinalIgnoreCase)
    })
    $players = @($base | Where-Object { [long]$_.player.id -gt 0 } | Group-Object { [long]$_.player.id } | ForEach-Object {
        [ordered]@{ id = [long]$_.Name; name = [string]$_.Group[0].player.name; occurrenceCount = $_.Count }
    } | Sort-Object name, id)
    $locations = @($base | Where-Object { -not $PlayerId -or [long]$_.player.id -eq $PlayerId } |
        Group-Object { "$($_.entity.type):$($_.entity.id)" } | ForEach-Object {
            $first = $_.Group[0]
            [ordered]@{
                type = [string]$first.entity.type; id = [long]$first.entity.id
                label = if ([string]$first.entity.type -eq 'player') { 'Backpack' } else { [string]$first.entity.label }
                owner = [string]$first.entity.owner; playerId = [long]$first.player.id
                playerName = [string]$first.player.name; occurrenceCount = $_.Count
            }
        } | Sort-Object type, label, id)
    $items = @($base | Where-Object {
        (-not $PlayerId -or [long]$_.player.id -eq $PlayerId) -and
        (-not $LocationType -or ([string]$_.entity.type -eq $LocationType -and [long]$_.entity.id -eq $LocationId))
    })
    $descending = $Sort.EndsWith('-desc')
    $primary = switch -Wildcard ($Sort) {
        'player-*' { { $_.player.name } }
        'location-*' { { $_.entity.label } }
        'quantity-*' { 'quantity' }
        'quality-*' { 'quality' }
    }
    $sortedItems = @($items | Sort-Object -Property @(
        @{ Expression = $primary; Descending = $descending },
        @{ Expression = 'id'; Descending = $false }
    ))
    $skip = 0
    if ($AfterItemId) {
        for ($index = 0; $index -lt $sortedItems.Count; $index++) {
            if ([long]$sortedItems[$index].id -eq $AfterItemId) { $skip = $index + 1; break }
        }
    }
    $items = @($sortedItems | Select-Object -Skip $skip -First $Limit)
    foreach ($item in $items) { $item.entity.workspacePath = "$($item.entity.workspacePath)&demo=1" }
    return @{ ok = $true; source = 'static'; items = $items; players = $players; locations = $locations }
}

function Invoke-DuneInventoryOccurrencesLive {
    param(
        [string]$Ip, [string]$TemplateId, [string[]]$EntityTypes, [string]$ScopeType = '', [long]$ScopeId = 0,
        [long]$PlayerId = 0, [string]$LocationType = '', [long]$LocationId = 0,
        [string]$Sort = 'player-asc', [string]$AfterSortValue = '', [long]$AfterItemId = 0, [int]$Limit = 51
    )
    $binding = Get-DuneInventoryQueryParameters -EntityTypes $EntityTypes -ScopeType $ScopeType -ScopeId $ScopeId `
        -PlayerId $PlayerId -LocationType $LocationType -LocationId $LocationId `
        -AfterSortValue $AfterSortValue -AfterItemId $AfterItemId -TemplateId $TemplateId -Limit $Limit
    $sortSpec = Resolve-DuneInventoryOccurrenceSort -Value $Sort
    if (-not $sortSpec.ok) { return @{ ok = $false; error = $sortSpec.error } }
    $primary = [string]$sortSpec.primary
    $comparison = if ($sortSpec.direction -eq 'asc') { '>' } else { '<' }
    if ($sortSpec.type -eq 'text') {
        $pageWhere = "(p.after_item_id = 0 OR $primary $comparison p.after_sort_value OR ($primary = p.after_sort_value AND r.item_id > p.after_item_id))"
    } else {
        $pageWhere = "(p.after_item_id = 0 OR $primary IS NULL OR $primary $comparison p.after_sort_value::double precision OR ($primary = p.after_sort_value::double precision AND r.item_id > p.after_item_id))"
    }
    $cte = Get-DuneInventoryFilteredCteSql
    $sql = @"
WITH $cte
SELECT r.item_id, r.template_id, r.stack_size, r.quality_level, r.durability, r.max_durability,
       r.water_amount, r.water_type, r.inventory_id, r.inventory_type, r.entity_type, r.entity_id,
       r.entity_label, r.owner_name, r.map, r.entity_class, r.player_id, r.player_name
FROM searched_rows r CROSS JOIN _dst_parameters p
WHERE lower(trim(r.template_id)) = lower(trim(p.template_id))
  AND (p.player_id = 0 OR r.player_id = p.player_id)
  AND (p.location_type = '' OR (r.entity_type = p.location_type AND r.entity_id = p.location_id))
  AND $pageWhere
ORDER BY $($sortSpec.sql) LIMIT (SELECT row_limit FROM _dst_parameters)
"@
    $effectiveSql = New-DuneInventoryParameterizedSql -Sql $sql -Parameters $binding.values -ParameterTypes $binding.types
    $result = Invoke-DuneSqlQuery -Ip $Ip -Sql $effectiveSql -ReadOnly $true -MaxRows $Limit -TimeoutSec 45 -Bulk
    if (-not $result.ok) { return @{ ok = $false; error = $result.error } }
    try {
        $items = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $result)) {
            $item = ConvertTo-DuneInventoryItem -Row $row
            $playerIdValue = ConvertTo-DuneInt $row['player_id']
            $playerName = [string]$row['player_name']
            $hasPlayerId = $playerIdValue -gt 0
            $hasPlayerName = -not [string]::IsNullOrWhiteSpace($playerName)
            if ([string]$item.entity.type -eq 'player' -and (-not $hasPlayerId -or -not $hasPlayerName)) {
                throw "Malformed inventory database item row: player identity is missing."
            }
            if ([string]$item.entity.type -eq 'storage' -and $hasPlayerId -ne $hasPlayerName) {
                throw "Malformed inventory database item row: storage player identity is incomplete."
            }
            if ($hasPlayerId) {
                $item['player'] = [ordered]@{ id = $playerIdValue; name = $playerName }
            }
            if (Test-DuneInventoryVisibleItem -Item $item) { $item }
        })
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
    $facetSql = @"
WITH $cte,
template_rows AS (
    SELECT r.* FROM searched_rows r CROSS JOIN _dst_parameters p
    WHERE lower(trim(r.template_id)) = lower(trim(p.template_id))
)
SELECT player_id, MAX(player_name) AS player_name, COUNT(*)::bigint AS occurrence_count
FROM template_rows WHERE player_id IS NOT NULL AND player_id > 0
GROUP BY player_id ORDER BY player_name, player_id LIMIT 500
"@
    $facetResult = Invoke-DuneSqlQuery -Ip $Ip `
        -Sql (New-DuneInventoryParameterizedSql -Sql $facetSql -Parameters $binding.values -ParameterTypes $binding.types) `
        -ReadOnly $true -MaxRows 500 -TimeoutSec 45 -Bulk
    if (-not $facetResult.ok) { return @{ ok = $false; error = $facetResult.error } }
    $locationSql = @"
WITH $cte,
template_rows AS (
    SELECT r.* FROM searched_rows r CROSS JOIN _dst_parameters p
    WHERE lower(trim(r.template_id)) = lower(trim(p.template_id))
)
SELECT t.entity_type, t.entity_id, MAX(CASE WHEN t.entity_type = 'player' THEN 'Backpack' ELSE t.entity_label END) AS entity_label,
       MAX(t.owner_name) AS owner_name, MAX(t.player_id)::bigint AS player_id, MAX(t.player_name) AS player_name,
       COUNT(*)::bigint AS occurrence_count
FROM template_rows t CROSS JOIN _dst_parameters p
WHERE (p.player_id = 0 OR t.player_id = p.player_id)
GROUP BY t.entity_type, t.entity_id ORDER BY t.entity_type, entity_label, t.entity_id LIMIT 1000
"@
    $locationResult = Invoke-DuneSqlQuery -Ip $Ip `
        -Sql (New-DuneInventoryParameterizedSql -Sql $locationSql -Parameters $binding.values -ParameterTypes $binding.types) `
        -ReadOnly $true -MaxRows 1000 -TimeoutSec 45 -Bulk
    if (-not $locationResult.ok) { return @{ ok = $false; error = $locationResult.error } }
    try {
        $players = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $facetResult)) {
            ConvertTo-DuneInventoryPlayerFacet -Row $row
        })
        $locations = @(foreach ($row in (ConvertTo-DuneRowMaps -Result $locationResult)) {
            ConvertTo-DuneInventoryLocationFacet -Row $row
        })
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
    return @{ ok = $true; items = $items; players = $players; locations = $locations }
}
