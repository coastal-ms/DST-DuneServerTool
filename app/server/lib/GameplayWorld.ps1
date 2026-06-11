# Gameplay — World (Bases, Storage, Blueprints). Read-only native port of
# dune-admin's list views. SQL ported verbatim from dune-admin db.go. Each
# getter returns @{ ok; ... }; the routes apply the live/demo + `source`
# convention. Helpers reused from Gameplay.ps1 / GameplayPlayers.ps1.

# ----------------------------------------------------------------------------
# BASES — list (id, name, pieces, placeables). dune-admin has no delete handler
# so this is read-only by design.
# ----------------------------------------------------------------------------
$script:DuneBasesListSql = @'
SELECT b.id,
       COALESCE(pa.actor_name, '') AS name,
       COALESCE(inst.cnt, 0)       AS pieces,
       COALESCE(plac.cnt, 0)       AS placeables
FROM dune.buildings b
LEFT JOIN (
    SELECT building_id, MIN(owner_entity_id) AS owner_entity_id, COUNT(*) AS cnt
    FROM dune.building_instances
    GROUP BY building_id
) inst ON inst.building_id = b.id
LEFT JOIN dune.actor_fgl_entities afe ON afe.entity_id = inst.owner_entity_id
LEFT JOIN dune.actors t ON t.id = afe.actor_id AND t.class ILIKE '%Totem%'
LEFT JOIN dune.permission_actor pa ON pa.actor_id = t.id
LEFT JOIN (
    SELECT bi.building_id, COUNT(*) AS cnt
    FROM dune.building_instances bi
    JOIN dune.placeables p ON p.owner_entity_id = bi.owner_entity_id
    GROUP BY bi.building_id
) plac ON plac.building_id = b.id
ORDER BY b.id
'@

function Get-DuneBasesLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneBasesListSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 45
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $bases = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $bases += [ordered]@{
            id         = (ConvertTo-DuneInt $r['id'])
            name       = [string]$r['name']
            pieces     = (ConvertTo-DuneInt $r['pieces'])
            placeables = (ConvertTo-DuneInt $r['placeables'])
        }
    }
    return @{ ok = $true; bases = $bases }
}

function Get-DuneBasesDemo {
    return @(
        [ordered]@{ id=40001; name="Arrakeen Keep"; pieces=842; placeables=131 }
        [ordered]@{ id=40002; name="Sietch Tabr"; pieces=512; placeables=88 }
        [ordered]@{ id=40003; name=""; pieces=64; placeables=9 }
    )
}

# ----------------------------------------------------------------------------
# STORAGE — container list + per-container item contents.
# ----------------------------------------------------------------------------
$script:DuneStorageListSql = @'
SELECT p.id,
       COALESCE(MAX(CASE
           WHEN pa.actor_name NOT LIKE '##%' AND pa.actor_name <> 'None'
           THEN pa.actor_name
       END), '') AS name,
       p.building_type AS class,
       COALESCE(a.map, '') AS map,
       COUNT(i.id) AS item_count,
       COALESCE(array_to_string(array_agg(DISTINCT i.template_id) FILTER (WHERE i.template_id IS NOT NULL), ','), '') AS item_templates,
       COALESCE(MAX(ps.character_name), '') AS owner_name
FROM dune.placeables p
LEFT JOIN dune.actors a                  ON a.id = p.id
LEFT JOIN dune.permission_actor pa       ON pa.actor_id = p.id
LEFT JOIN dune.inventories inv           ON inv.actor_id = p.id
LEFT JOIN dune.items i                   ON i.inventory_id = inv.id
LEFT JOIN dune.actor_fgl_entities afe    ON afe.entity_id = p.owner_entity_id
LEFT JOIN dune.permission_actor_rank par ON par.permission_actor_id = afe.actor_id
LEFT JOIN dune.actors player_a           ON player_a.id = par.player_id
LEFT JOIN dune.player_state ps           ON ps.account_id = player_a.owner_account_id
WHERE p.building_type IN (
    'SpiceSilo_Placeable',
    'GenericContainer_Placeable',
    'StorageContainer_Placeable',
    'MediumStorageContainer_Placeable'
  )
  AND p.is_hologram = false
  AND p.owner_entity_id IS NOT NULL
  AND p.owner_entity_id != 0
GROUP BY p.id, p.building_type, a.map
ORDER BY p.id
'@

# Item contents for one container actor id ($1).
$script:DuneStorageItemsSql = @'
SELECT i.id, i.template_id, i.stack_size, COALESCE(i.quality_level, 0) AS quality_level,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A')     AS max_durability
FROM dune.items i
JOIN dune.inventories inv ON i.inventory_id = inv.id
WHERE inv.actor_id = {0}::bigint
ORDER BY i.template_id
'@

function Get-DuneStorageLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneStorageListSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 45
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $containers = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $templatesRaw = [string]$r['item_templates']
        $templates = @()
        if ($templatesRaw) { $templates = @($templatesRaw -split ',' | Where-Object { $_ }) }
        $names = @($templates | ForEach-Object { Get-DuneGameplayItemName -TemplateId $_ })
        $containers += [ordered]@{
            id             = (ConvertTo-DuneInt $r['id'])
            name           = [string]$r['name']
            class          = (Get-DuneShortClass ([string]$r['class']))
            raw_class      = [string]$r['class']
            map            = [string]$r['map']
            item_count     = (ConvertTo-DuneInt $r['item_count'])
            item_templates = $templates
            item_names     = $names
            owner_name     = [string]$r['owner_name']
        }
    }
    return @{ ok = $true; containers = $containers }
}

function Get-DuneStorageItemsLive {
    param([string]$Ip, [long]$ContainerId)
    $sql = [string]::Format($script:DuneStorageItemsSql, $ContainerId)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $items = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $tmpl = [string]$r['template_id']
        $items += [ordered]@{
            id             = (ConvertTo-DuneInt $r['id'])
            template_id    = $tmpl
            name           = (Get-DuneGameplayItemName -TemplateId $tmpl)
            stack_size     = (ConvertTo-DuneInt $r['stack_size'])
            quality        = (ConvertTo-DuneInt $r['quality_level'])
            durability     = [string]$r['durability']
            max_durability = [string]$r['max_durability']
        }
    }
    return @{ ok = $true; items = $items }
}

function Get-DuneStorageDemo {
    return @(
        [ordered]@{ id=50001; name='Spice Vault'; class='Spice Silo'; raw_class='SpiceSilo_Placeable'; map='Hagga Basin'; item_count=3; item_templates=@('Spice_Melange'); item_names=@('Spice Melange'); owner_name='Stilgar' }
        [ordered]@{ id=50002; name='Armoury'; class='Storage Container'; raw_class='StorageContainer_Placeable'; map='Hagga Basin'; item_count=12; item_templates=@('Maula_Pistol','Stillsuit_T4'); item_names=@('Maula Pistol','Stillsuit (Mk IV)'); owner_name='Gurney Halleck' }
        [ordered]@{ id=50003; name=''; class='Generic Container'; raw_class='GenericContainer_Placeable'; map='Deep Desert'; item_count=5; item_templates=@('Plasteel_Plate'); item_names=@('Plasteel Plate'); owner_name='Duncan Idaho' }
    )
}

function Get-DuneStorageItemsDemo {
    param([long]$ContainerId)
    return @{
        ok = $true
        items = @(
            [ordered]@{ id=80001; template_id='Spice_Melange'; name='Spice Melange'; stack_size=4200; quality=0; durability='N/A'; max_durability='N/A' }
            [ordered]@{ id=80002; template_id='Plasteel_Plate'; name='Plasteel Plate'; stack_size=180; quality=1; durability='N/A'; max_durability='N/A' }
        )
    }
}

# ----------------------------------------------------------------------------
# BLUEPRINTS — list (id, owner, item id, pieces, placeables, name). Read-only.
# ----------------------------------------------------------------------------
$script:DuneBlueprintsListSql = @'
SELECT bb.id,
       COALESCE(ps.character_name, '') AS owner_name,
       COALESCE(bb.item_id, 0)         AS item_id,
       COALESCE(inst.cnt, 0)           AS pieces,
       COALESCE(plac.cnt, 0)           AS placeables,
       COALESCE(i.stats->'FBuildingBlueprintItemStats'->1->>'BuildingBlueprintName', '') AS name
FROM dune.building_blueprints bb
LEFT JOIN dune.items i ON i.id = bb.item_id
LEFT JOIN dune.inventories inv ON inv.id = i.inventory_id
LEFT JOIN dune.actors a ON a.id = inv.actor_id
LEFT JOIN dune.player_state ps ON ps.player_pawn_id = a.id
LEFT JOIN (
    SELECT building_blueprint_id, COUNT(*) AS cnt
    FROM dune.building_blueprint_instances
    GROUP BY building_blueprint_id
) inst ON inst.building_blueprint_id = bb.id
LEFT JOIN (
    SELECT building_blueprint_id, COUNT(*) AS cnt
    FROM dune.building_blueprint_placeables
    GROUP BY building_blueprint_id
) plac ON plac.building_blueprint_id = bb.id
ORDER BY bb.id
'@

function Get-DuneBlueprintsLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DuneBlueprintsListSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 45
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $blueprints = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $blueprints += [ordered]@{
            id         = (ConvertTo-DuneInt $r['id'])
            owner_name = [string]$r['owner_name']
            item_id    = (ConvertTo-DuneInt $r['item_id'])
            pieces     = (ConvertTo-DuneInt $r['pieces'])
            placeables = (ConvertTo-DuneInt $r['placeables'])
            name       = [string]$r['name']
        }
    }
    return @{ ok = $true; blueprints = $blueprints }
}

function Get-DuneBlueprintsDemo {
    return @(
        [ordered]@{ id=60001; owner_name='Duncan Idaho'; item_id=70010; pieces=128; placeables=14; name='Compact Base' }
        [ordered]@{ id=60002; owner_name='Gurney Halleck'; item_id=70011; pieces=64; placeables=6; name='Watchtower' }
        [ordered]@{ id=60003; owner_name=''; item_id=70012; pieces=312; placeables=42; name='' }
    )
}
