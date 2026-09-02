# Shared Inventory Explorer read model. This file only projects proven player
# inventories and inventory_type=4 storage placeables.

$script:DuneInventoryDefaultLimit = 100
$script:DuneInventoryMaxLimit = 500
$script:DuneInventoryCursorGeneration = 'inventory-v1'

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
