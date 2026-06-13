# Gameplay — World (Bases, Storage, Blueprints). Read-only native port of
# the reference implementation's list views. SQL ported verbatim from the reference implementation db.go. Each
# getter returns @{ ok; ... }; the routes apply the live/demo + `source`
# convention. Helpers reused from Gameplay.ps1 / GameplayPlayers.ps1.

# ----------------------------------------------------------------------------
# BASES — list (id, name, pieces, placeables). the reference implementation has no delete handler
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
       COALESCE(NULLIF(ps_acct.character_name, ''), NULLIF(ps_pawn.character_name, ''), ps_plac.owner_name, '') AS owner_name,
       COALESCE(bb.item_id, 0)         AS item_id,
       COALESCE(inst.cnt, 0)           AS pieces,
       COALESCE(plac.cnt, 0)           AS placeables,
       COALESCE(i.stats->'FBuildingBlueprintItemStats'->1->>'BuildingBlueprintName', '') AS name
FROM dune.building_blueprints bb
LEFT JOIN dune.items i ON i.id = bb.item_id
LEFT JOIN dune.inventories inv ON inv.id = i.inventory_id
LEFT JOIN dune.actors a ON a.id = inv.actor_id
-- Owner resolution: the legacy join (ps.player_pawn_id = a.id) only matches a
-- player whose pawn is currently spawned/loaded, so offline players' blueprints
-- render with a blank owner. Resolve primarily by the persistent account link,
-- falling back to the live-pawn link. CRITICAL THIRD FALLBACK: most blueprints'
-- copy-device items live INSIDE a storage container (placeable), not a player's
-- character inventory — so `a` is the container actor, whose owner_account_id is
-- NULL and the first two joins yield nothing (this made every container-held
-- blueprint show a blank owner, looking like "only one player has blueprints").
-- The ps_plac lateral resolves the container's owner via the same placeable
-- ownership chain the Storage view uses (placeable -> fgl entity -> permission
-- rank -> player -> account), picking the lowest rank (base owner) on shared bases.
LEFT JOIN dune.player_state ps_acct ON ps_acct.account_id = a.owner_account_id
LEFT JOIN dune.player_state ps_pawn ON ps_pawn.player_pawn_id = a.id
LEFT JOIN dune.placeables pl ON pl.id = a.id
LEFT JOIN LATERAL (
    SELECT ps_p.character_name AS owner_name
    FROM dune.actor_fgl_entities afe
    JOIN dune.permission_actor_rank par ON par.permission_actor_id = afe.actor_id
    JOIN dune.actors pa_p ON pa_p.id = par.player_id
    JOIN dune.player_state ps_p ON ps_p.account_id = pa_p.owner_account_id
    WHERE afe.entity_id = pl.owner_entity_id AND pl.owner_entity_id <> 0
      AND NULLIF(ps_p.character_name, '') IS NOT NULL
    ORDER BY par.rank ASC, par.player_id ASC
    LIMIT 1
) ps_plac ON true
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

# ----------------------------------------------------------------------------
# BLUEPRINT EXPORT / IMPORT — native port of the reference implementation handlers_blueprints.go.
# Export reads instances/placeables/pentashields into a portable JSON file
# (field names match the reference implementation exactly for cross-tool compatibility). Import
# recreates the blueprint as a BuildingBlueprint_CopyDevice in a player's
# backpack via one atomic PL/pgSQL DO block (the SQL bridge runs each call as a
# separate psql invocation, so a single statement is the only way to stay
# transactional). Imports require a live DB and an offline player.
# ----------------------------------------------------------------------------

# building_type values game-saved blueprints commonly mark provides_stability=true.
# Used only as a fallback when importing legacy JSON without the per-instance flag;
# fresh exports always carry the exact bool. Mirrors the reference implementation's structuralBuildingTypes.
$script:DuneStructuralBuildingTypes = @{
    'Atreides_Outpost_Column'                  = $true
    'Atreides_Outpost_Column_Corner'           = $true
    'Atreides_Outpost_Foundation'              = $true
    'Atreides_Outpost_Foundation_Round_Corner' = $true
    'Atreides_Outpost_Foundation_Wedge'        = $true
    'Atreides_Outpost_Pillar_Bottom'           = $true
    'Atreides_Outpost_Pillar_Middle'           = $true
    'Atreides_Outpost_Pillar_Top'              = $true
    'Choam_Level2_Column'                      = $true
    'Choam_Level2_Foundation'                  = $true
    'Choam_Level2_Pillar_Bottom'               = $true
    'Choam_Shelter_Column_Corner_New'          = $true
    'Choam_Shelter_Column_New'                 = $true
    'Harkonnen_Outpost_Column'                 = $true
    'Harkonnen_Outpost_Foundation'             = $true
    'MTX_Neut_DesertMechanic_Center_Column'    = $true
    'MTX_Neut_DesertMechanic_Corner_Column'    = $true
    'MTX_Neut_DesertMechanic_Foundation'       = $true
    'MTX_Smug_Foundation'                      = $true
}

function Test-DuneStructuralBuilding {
    param([string]$BuildingType)
    return [bool]$script:DuneStructuralBuildingTypes[$BuildingType]
}

# Read a field from a blueprint object that may be a hashtable (JSON body parsed
# with -AsHashtable) or a PSCustomObject.
function Get-DuneBpField {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

# Parse a value to double using invariant culture (DB text + JSON numbers).
function ConvertTo-DuneFloat {
    param($Value, [double]$Default = 0.0)
    $d = 0.0
    $styles = [System.Globalization.NumberStyles]::Float
    if ([double]::TryParse([string]$Value, $styles, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $Default
}

# Format a value as a Postgres real literal element (invariant, single-precision
# shortest round-trip — matches the float32 cast the reference implementation uses).
function Format-DuneReal {
    param($Value)
    return ([float](ConvertTo-DuneFloat $Value)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# Suggested download filename: sanitized in-game name, else blueprint_<id>.json.
function Get-DuneBlueprintFilename {
    param([string]$Name, [long]$Id)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Name.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 0x20 -or $code -eq 0x7f) { continue }
        if ('/','\',':','*','?','"','<','>','|' -contains $ch) { [void]$sb.Append('_') }
        else { [void]$sb.Append($ch) }
    }
    $clean = $sb.ToString().Trim()
    if (-not $clean) { return "blueprint_$Id.json" }
    return "$clean.json"
}

function Get-DuneBlueprintExportLive {
    param([string]$Ip, [long]$BlueprintId)

    $nameSql = @"
SELECT COALESCE(i.stats->'FBuildingBlueprintItemStats'->1->>'BuildingBlueprintName', '') AS name
FROM dune.building_blueprints bb
JOIN dune.items i ON i.id = bb.item_id
WHERE bb.id = $BlueprintId::bigint
"@
    $nres = Invoke-DuneSqlQuery -Ip $Ip -Sql $nameSql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $nres.ok) { return @{ ok = $false; error = $nres.error } }
    $nmaps = ConvertTo-DuneRowMaps -Result $nres
    $name = if ($nmaps.Count -ge 1) { [string]$nmaps[0]['name'] } else { '' }

    $instSql = @"
SELECT instance_id, building_type,
       array_to_string(transform, ',') AS transform,
       provides_stability
FROM dune.building_blueprint_instances
WHERE building_blueprint_id = $BlueprintId::bigint
ORDER BY instance_id
"@
    $ires = Invoke-DuneSqlQuery -Ip $Ip -Sql $instSql -ReadOnly $true -MaxRows 200000 -TimeoutSec 90
    if (-not $ires.ok) { return @{ ok = $false; error = $ires.error } }
    $instances = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $ires)) {
        $p = @(([string]$r['transform']) -split ',')
        if ($p.Count -lt 4) { continue }
        $instances += [ordered]@{
            instance_id        = (ConvertTo-DuneInt $r['instance_id'])
            building_type      = [string]$r['building_type']
            x                  = (ConvertTo-DuneFloat $p[0])
            y                  = (ConvertTo-DuneFloat $p[1])
            z                  = (ConvertTo-DuneFloat $p[2])
            rotation           = (ConvertTo-DuneFloat $p[3])
            provides_stability = (Test-DuneTruthy $r['provides_stability'])
        }
    }

    $placSql = @"
SELECT placeable_id, building_type,
       array_to_string(transform, ',') AS transform
FROM dune.building_blueprint_placeables
WHERE building_blueprint_id = $BlueprintId::bigint
ORDER BY placeable_id
"@
    $pres = Invoke-DuneSqlQuery -Ip $Ip -Sql $placSql -ReadOnly $true -MaxRows 200000 -TimeoutSec 90
    if (-not $pres.ok) { return @{ ok = $false; error = $pres.error } }
    $placeables = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $pres)) {
        $p = @(([string]$r['transform']) -split ',')
        if ($p.Count -lt 6) { continue }
        $placeables += [ordered]@{
            placeable_id  = (ConvertTo-DuneInt $r['placeable_id'])
            building_type = [string]$r['building_type']
            x             = (ConvertTo-DuneFloat $p[0])
            y             = (ConvertTo-DuneFloat $p[1])
            z             = (ConvertTo-DuneFloat $p[2])
            rx            = (ConvertTo-DuneFloat $p[3])
            ry            = (ConvertTo-DuneFloat $p[4])
            rz            = (ConvertTo-DuneFloat $p[5])
        }
    }

    $pentSql = @"
SELECT placeable_id, array_to_string(scale, ',') AS scale
FROM dune.building_blueprint_pentashields
WHERE building_blueprint_id = $BlueprintId::bigint
ORDER BY placeable_id
"@
    $ptres = Invoke-DuneSqlQuery -Ip $Ip -Sql $pentSql -ReadOnly $true -MaxRows 200000 -TimeoutSec 60
    if (-not $ptres.ok) { return @{ ok = $false; error = $ptres.error } }
    $pentashields = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $ptres)) {
        $p = @(([string]$r['scale']) -split ',')
        if ($p.Count -lt 3) { continue }
        $pentashields += [ordered]@{
            placeable_id = (ConvertTo-DuneInt $r['placeable_id'])
            scale        = @([int](ConvertTo-DuneInt $p[0]), [int](ConvertTo-DuneInt $p[1]), [int](ConvertTo-DuneInt $p[2]))
        }
    }

    $bp = [ordered]@{
        name         = $name
        instances    = @($instances)
        placeables   = @($placeables)
        pentashields = @($pentashields)
    }
    return @{ ok = $true; blueprint = $bp; name = $name }
}

function Get-DuneBlueprintExportDemo {
    param([long]$BlueprintId)
    return [ordered]@{
        name         = 'Compact Base'
        instances    = @(
            [ordered]@{ instance_id=1; building_type='Atreides_Outpost_Foundation'; x=1000.0; y=2000.0; z=50.0; rotation=0.0; provides_stability=$true }
            [ordered]@{ instance_id=2; building_type='Atreides_Outpost_Wall';        x=1000.0; y=2400.0; z=50.0; rotation=90.0; provides_stability=$false }
            [ordered]@{ instance_id=3; building_type='Atreides_Outpost_Pillar_Bottom'; x=1400.0; y=2000.0; z=50.0; rotation=0.0; provides_stability=$true }
        )
        placeables   = @(
            [ordered]@{ placeable_id=1; building_type='StorageContainer_Placeable'; x=1100.0; y=2100.0; z=60.0; rx=0.0; ry=0.0; rz=0.0 }
        )
        pentashields = @()
    }
}

function Import-DuneBlueprintLive {
    param([string]$Ip, [long]$PlayerPawnId, $Blueprint)

    $instancesRaw    = @(Get-DuneBpField $Blueprint 'instances')
    $placeablesRaw   = @(Get-DuneBpField $Blueprint 'placeables')
    $pentashieldsRaw = @(Get-DuneBpField $Blueprint 'pentashields')
    $name            = [string](Get-DuneBpField $Blueprint 'name')

    if ($instancesRaw.Count -eq 0 -and $placeablesRaw.Count -eq 0) {
        return @{ ok = $false; error = 'Blueprint has no instances or placeables.' }
    }

    # Player must be offline (no player_state row also counts as offline).
    $offSql = "SELECT online_status::text AS s FROM dune.player_state WHERE player_pawn_id = $PlayerPawnId::bigint"
    $ores = Invoke-DuneSqlQuery -Ip $Ip -Sql $offSql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $ores.ok) { return @{ ok = $false; error = $ores.error } }
    $omaps = ConvertTo-DuneRowMaps -Result $ores
    if ($omaps.Count -ge 1) {
        $st = [string]$omaps[0]['s']
        if ($st -and $st -ne 'Offline') {
            return @{ ok = $false; error = "Player is currently $st — log out first, then import." }
        }
    }

    # Resolve instance rows (instance_id + stability fall back per the reference implementation).
    $instRows = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $instancesRaw.Count; $i++) {
        $inst = $instancesRaw[$i]
        $bt   = ConvertTo-DuneSqlString ([string](Get-DuneBpField $inst 'building_type'))
        $x    = Format-DuneReal (Get-DuneBpField $inst 'x')
        $y    = Format-DuneReal (Get-DuneBpField $inst 'y')
        $z    = Format-DuneReal (Get-DuneBpField $inst 'z')
        $rot  = Format-DuneReal (Get-DuneBpField $inst 'rotation')
        $iidV = Get-DuneBpField $inst 'instance_id'
        $iid  = if ($null -ne $iidV -and "$iidV" -ne '') { [long](ConvertTo-DuneInt $iidV) } else { $i + 1 }
        $stabV = Get-DuneBpField $inst 'provides_stability'
        if ($null -ne $stabV -and "$stabV" -ne '') {
            $stab = if (Test-DuneTruthy $stabV) { 'true' } else { 'false' }
        } else {
            $stab = if (Test-DuneStructuralBuilding ([string](Get-DuneBpField $inst 'building_type'))) { 'true' } else { 'false' }
        }
        [void]$instRows.Add("(v_bp, $iid, '$bt', '{$x,$y,$z,$rot}'::real[], true, $stab, 0)")
    }

    # Resolve placeable rows.
    $placRows = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $placeablesRaw.Count; $i++) {
        $pl  = $placeablesRaw[$i]
        $bt  = ConvertTo-DuneSqlString ([string](Get-DuneBpField $pl 'building_type'))
        $x   = Format-DuneReal (Get-DuneBpField $pl 'x')
        $y   = Format-DuneReal (Get-DuneBpField $pl 'y')
        $z   = Format-DuneReal (Get-DuneBpField $pl 'z')
        $rx  = Format-DuneReal (Get-DuneBpField $pl 'rx')
        $ry  = Format-DuneReal (Get-DuneBpField $pl 'ry')
        $rz  = Format-DuneReal (Get-DuneBpField $pl 'rz')
        $pidV = Get-DuneBpField $pl 'placeable_id'
        $placId  = if ($null -ne $pidV -and "$pidV" -ne '') { [long](ConvertTo-DuneInt $pidV) } else { $i + 1 }
        [void]$placRows.Add("(v_bp, $placId, '$bt', '{$x,$y,$z,$rx,$ry,$rz}'::real[], true)")
    }

    # Resolve pentashield rows.
    $pentRows = [System.Collections.Generic.List[string]]::new()
    foreach ($ps in $pentashieldsRaw) {
        $scale = @(Get-DuneBpField $ps 'scale')
        if ($scale.Count -lt 3) { continue }
        $w = [int](ConvertTo-DuneInt $scale[0]); $h = [int](ConvertTo-DuneInt $scale[1]); $d = [int](ConvertTo-DuneInt $scale[2])
        $plId = [long](ConvertTo-DuneInt (Get-DuneBpField $ps 'placeable_id'))
        [void]$pentRows.Add("(v_bp, $plId, ARRAY[$w,$h,$d]::smallint[])")
    }

    $instSql = Join-DuneBlueprintInserts -Prefix 'INSERT INTO dune.building_blueprint_instances (building_blueprint_id, instance_id, building_type, transform, hologram, provides_stability, health) VALUES' -Rows $instRows
    $placSql = Join-DuneBlueprintInserts -Prefix 'INSERT INTO dune.building_blueprint_placeables (building_blueprint_id, placeable_id, building_type, transform, hologram) VALUES' -Rows $placRows
    $pentSql = Join-DuneBlueprintInserts -Prefix 'INSERT INTO dune.building_blueprint_pentashields (building_blueprint_id, placeable_id, scale) VALUES' -Rows $pentRows

    $nameLit = ConvertTo-DuneSqlString $name
    $placeholder = '{"FCustomizationStats":[[], {}],"FBuildingBlueprintItemStats":[[], {"PlayerBlueprintId":"!!bbp#0"}],"FItemStackAndDurabilityStats":[[], {"DecayedMaxDurability":0.0}]}'

    $do = @"
DO `$DST`$
DECLARE
    v_inv      bigint;
    v_pos      bigint;
    v_item     bigint;
    v_bp       bigint;
    v_name     text := '$nameLit';
    v_namejson text := '';
BEGIN
    SELECT id INTO v_inv FROM dune.inventories
    WHERE actor_id = $PlayerPawnId::bigint AND inventory_type = 0
    ORDER BY id LIMIT 1;
    IF v_inv IS NULL THEN
        RAISE EXCEPTION 'No backpack inventory found for that player.';
    END IF;

    SELECT COALESCE(MAX(position_index), -1) + 1 INTO v_pos
    FROM dune.items WHERE inventory_id = v_inv;

    INSERT INTO dune.items (inventory_id, stack_size, position_index, template_id, quality_level, acquisition_time, stats)
    VALUES (v_inv, 1, v_pos, 'BuildingBlueprint_CopyDevice', 0, EXTRACT(EPOCH FROM now())::bigint, '$placeholder'::jsonb)
    RETURNING id INTO v_item;

    INSERT INTO dune.building_blueprints (item_id, player_id, building_blueprint_map)
    VALUES (v_item, null, '')
    RETURNING id INTO v_bp;

    IF v_name <> '' THEN
        v_namejson := ',"BuildingBlueprintName":' || to_json(v_name)::text;
    END IF;
    UPDATE dune.items SET stats = (
        '{"FCustomizationStats":[[], {}],"FBuildingBlueprintItemStats":[[], {"PlayerBlueprintId":"!!bbp#' || v_bp::text || '"' || v_namejson || '}],"FItemStackAndDurabilityStats":[[], {"DecayedMaxDurability":0.0}]}'
    )::jsonb WHERE id = v_item;

$instSql$placSql$pentSql
    RAISE NOTICE 'DST_BP_RESULT bp=% item=%', v_bp, v_item;
END
`$DST`$;
"@

    $raw = Invoke-DuneSqlRaw -Ip $Ip -Sql $do -TimeoutSec 180
    if (Test-DunePsqlError -Output $raw) {
        return @{ ok = $false; error = (Get-DunePsqlErrorMessage -Output $raw) }
    }
    $bpId = 0L; $itemId = 0L
    $m = [regex]::Match($raw, 'DST_BP_RESULT bp=(\d+) item=(\d+)')
    if ($m.Success) { $bpId = [long]$m.Groups[1].Value; $itemId = [long]$m.Groups[2].Value }
    $msg = "Imported $($instancesRaw.Count) pieces + $($placeablesRaw.Count) placeables + $($pentashieldsRaw.Count) pentashields -> blueprint #$bpId (item $itemId) in player inventory"
    return @{ ok = $true; message = $msg; blueprint_id = $bpId; item_id = $itemId }
}

# Chunk VALUES rows into multiple INSERT statements (bounded statement size for
# large blueprints) sharing one prefix. Returns '' when there are no rows.
function Join-DuneBlueprintInserts {
    param([string]$Prefix, [System.Collections.Generic.List[string]]$Rows, [int]$ChunkSize = 500)
    if (-not $Rows -or $Rows.Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    for ($s = 0; $s -lt $Rows.Count; $s += $ChunkSize) {
        $cnt = [Math]::Min($ChunkSize, $Rows.Count - $s)
        $chunk = $Rows.GetRange($s, $cnt)
        [void]$sb.Append('    ')
        [void]$sb.AppendLine($Prefix)
        [void]$sb.Append('    ')
        [void]$sb.AppendLine(($chunk -join ",`n    ") + ';')
    }
    return $sb.ToString()
}

# ----------------------------------------------------------------------------
# STORAGE WRITE — add items to / remove items from a container. Native port of
# the reference implementation's give-item / give-items / delete-item. Items added or removed
# only become visible to other players after a server zone restart (the game
# caches container contents); the UI surfaces that warning. All require a live
# DB. the reference implementation inserts each item fresh (no stacking merge) with minimal valid
# stats; the capacity check + insert run as one atomic CTE here.
# ----------------------------------------------------------------------------
function Invoke-DuneStorageGiveItem {
    param([string]$Ip, [long]$ContainerId, [string]$Template, [long]$Qty, [long]$Quality)
    if ($Qty -le 0) { $Qty = 1 }
    $safeTmpl = ConvertTo-DuneSqlString $Template
    # acquisition_time must be the current epoch: the game treats acquisition_time=0
    # (1970) items as fully decayed and drops them from the container on zone load,
    # so they show in DST but never appear in-game even after a restart.
    $sql = @"
WITH inv AS (
    SELECT id, COALESCE(max_item_count, 0) AS maxc
    FROM dune.inventories
    WHERE actor_id = $ContainerId::bigint
    ORDER BY id LIMIT 1
),
cur AS (
    SELECT inv.id AS inv_id, inv.maxc, COUNT(i.id) AS cnt
    FROM inv LEFT JOIN dune.items i ON i.inventory_id = inv.id
    GROUP BY inv.id, inv.maxc
),
ins AS (
    INSERT INTO dune.items (inventory_id, template_id, stack_size, quality_level, position_index, acquisition_time, stats)
    SELECT cur.inv_id, '$safeTmpl', $Qty::bigint, $Quality::bigint,
           COALESCE((SELECT MAX(position_index) + 1 FROM dune.items WHERE inventory_id = cur.inv_id), 0),
           EXTRACT(EPOCH FROM now())::bigint,
           '{"FCustomizationStats":[[],{}],"FItemStackAndDurabilityStats":[[],{}]}'::jsonb
    FROM cur
    WHERE cur.maxc = 0 OR cur.cnt < cur.maxc
    RETURNING id
)
SELECT (SELECT id FROM ins)  AS item_id,
       (SELECT cnt FROM cur)  AS cnt,
       (SELECT maxc FROM cur) AS maxc;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    $itemId = if ($maps.Count -ge 1) { [string]$maps[0]['item_id'] } else { '' }
    if ($itemId) {
        return @{ ok = $true; message = "Added $Qty x $Template (quality $Quality) to container $ContainerId."; item_id = (ConvertTo-DuneInt $itemId) }
    }
    $cntStr = if ($maps.Count -ge 1) { [string]$maps[0]['cnt'] } else { '' }
    if (-not $cntStr) {
        return @{ ok = $false; error = "No inventory found for container $ContainerId." }
    }
    $cnt = ConvertTo-DuneInt $cntStr
    $maxc = ConvertTo-DuneInt ($maps[0]['maxc'])
    return @{ ok = $false; error = "Container inventory full ($cnt/$maxc)." }
}

# Batch add — loops Invoke-DuneStorageGiveItem, collecting given/skipped (mirrors
# the reference implementation's give-items). Each item is a hashtable/PSObject { template, qty, quality }.
function Invoke-DuneStorageGiveItems {
    param([string]$Ip, [long]$ContainerId, $Items)
    $given = @(); $skipped = @()
    foreach ($it in @($Items)) {
        $tmpl = [string](Get-DuneBpField $it 'template')
        $qty  = [long](ConvertTo-DuneInt (Get-DuneBpField $it 'qty'))
        $qual = [long](ConvertTo-DuneInt (Get-DuneBpField $it 'quality'))
        if (-not $tmpl) { $skipped += [ordered]@{ template = $tmpl; reason = 'missing template' }; continue }
        if ($qty -le 0) { $qty = 1 }
        $r = Invoke-DuneStorageGiveItem -Ip $Ip -ContainerId $ContainerId -Template $tmpl -Qty $qty -Quality $qual
        if ($r.ok) { $given += $tmpl } else { $skipped += [ordered]@{ template = $tmpl; reason = $r.error } }
    }
    if ($given.Count -eq 0 -and $skipped.Count -gt 0) {
        return @{ ok = $false; error = "No items added. First error: $($skipped[0].reason)"; given = $given; skipped = $skipped }
    }
    $msg = "Added $($given.Count) item type(s) to container $ContainerId."
    if ($skipped.Count -gt 0) { $msg += " Skipped $($skipped.Count)." }
    return @{ ok = $true; message = $msg; given = $given; skipped = $skipped }
}

# Remove a single item from a container (dune.delete_item, same as player inventory).
function Invoke-DuneStorageDeleteItem {
    param([string]$Ip, [long]$ItemId)
    $sql = "SELECT dune.delete_item($ItemId::bigint);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Removed item $ItemId from container." }
}

# ----------------------------------------------------------------------------
# BASE EXPORT — native port of the reference implementation handlers_bases.go. Reads a base's
# building_instances (7-element transform: x,y,z + quaternion) and its
# placeables, recenters everything on the base centroid, converts quaternions
# to yaw (instances) / euler (placeables), and extracts pentashield scale from
# placeable properties. Produces the same blueprintFile shape as a blueprint
# export so the JSON can be re-imported as a blueprint.
# ----------------------------------------------------------------------------
function ConvertTo-DuneYaw {
    param([double]$Qx, [double]$Qy, [double]$Qz, [double]$Qw)
    return [Math]::Atan2(2 * ($Qw * $Qz + $Qx * $Qy), 1 - 2 * ($Qy * $Qy + $Qz * $Qz)) * 180.0 / [Math]::PI
}

function ConvertTo-DuneEuler {
    param([double]$Qx, [double]$Qy, [double]$Qz, [double]$Qw)
    $rx = [Math]::Atan2(2 * ($Qw * $Qx + $Qy * $Qz), 1 - 2 * ($Qx * $Qx + $Qy * $Qy)) * 180.0 / [Math]::PI
    $sinp = 2 * ($Qw * $Qy - $Qz * $Qx)
    if ($sinp -ge 1)      { $ry = 90.0 }
    elseif ($sinp -le -1) { $ry = -90.0 }
    else                  { $ry = [Math]::Asin($sinp) * 180.0 / [Math]::PI }
    $rz = [Math]::Atan2(2 * ($Qw * $Qz + $Qx * $Qy), 1 - 2 * ($Qy * $Qy + $Qz * $Qz)) * 180.0 / [Math]::PI
    return @($rx, $ry, $rz)
}

# Parse a Postgres composite vector rendered as text, e.g. "(x,y,z)" or
# "(x,y,z,w)". Returns an array of doubles.
function ConvertFrom-DuneVecText {
    param([string]$Text)
    $t = ([string]$Text).Trim().Trim('(', ')')
    if (-not $t) { return @() }
    return @($t -split ',' | ForEach-Object { ConvertTo-DuneFloat $_ })
}

function Get-DuneBaseExportLive {
    param([string]$Ip, [long]$BaseId)

    $instSql = @"
SELECT building_type,
       array_to_string(transform, ',') AS transform,
       COALESCE(owner_entity_id, 0)    AS owner_entity_id
FROM dune.building_instances
WHERE building_id = $BaseId::bigint
"@
    $ires = Invoke-DuneSqlQuery -Ip $Ip -Sql $instSql -ReadOnly $true -MaxRows 200000 -TimeoutSec 90
    if (-not $ires.ok) { return @{ ok = $false; error = $ires.error } }

    $raws = @()
    $ownerEntityId = 0L
    foreach ($r in (ConvertTo-DuneRowMaps -Result $ires)) {
        $t = @(([string]$r['transform']) -split ',' | ForEach-Object { ConvertTo-DuneFloat $_ })
        if ($t.Count -lt 7) { continue }
        if ($ownerEntityId -eq 0L) { $ownerEntityId = [long](ConvertTo-DuneInt $r['owner_entity_id']) }
        $raws += [ordered]@{ building_type = [string]$r['building_type']; t = $t }
    }
    if ($raws.Count -eq 0) {
        return @{ ok = $false; error = "Building $BaseId not found or empty." }
    }

    # Centroid (recenter the blueprint on its own origin).
    $cx = 0.0; $cy = 0.0; $cz = 0.0
    foreach ($ri in $raws) { $cx += $ri.t[0]; $cy += $ri.t[1]; $cz += $ri.t[2] }
    $n = [double]$raws.Count
    $cx /= $n; $cy /= $n; $cz /= $n

    $instances = @()
    foreach ($ri in $raws) {
        $qx = $ri.t[3]; $qy = $ri.t[4]; $qz = $ri.t[5]; $qw = $ri.t[6]
        $instances += [ordered]@{
            building_type = $ri.building_type
            x             = ($ri.t[0] - $cx)
            y             = ($ri.t[1] - $cy)
            z             = ($ri.t[2] - $cz)
            rotation      = (ConvertTo-DuneYaw -Qx $qx -Qy $qy -Qz $qz -Qw $qw)
        }
    }

    # Placeables (decorations, storage, pentashields) owned by the same entity.
    $placeables = @()
    $pentashields = @()
    if ($ownerEntityId -ne 0L) {
        $placSql = @"
SELECT p.building_type,
       (a.transform).location::text AS location,
       (a.transform).rotation::text AS rotation,
       COALESCE(a.properties::text, '') AS properties
FROM dune.placeables p
JOIN dune.actors a ON a.id = p.id
WHERE p.owner_entity_id = $ownerEntityId::bigint
"@
        $pres = Invoke-DuneSqlQuery -Ip $Ip -Sql $placSql -ReadOnly $true -MaxRows 200000 -TimeoutSec 90
        if (-not $pres.ok) { return @{ ok = $false; error = $pres.error } }
        foreach ($r in (ConvertTo-DuneRowMaps -Result $pres)) {
            $bt = [string]$r['building_type']
            if ($bt -eq 'Totem_Placeable') { continue }
            $loc = ConvertFrom-DuneVecText ([string]$r['location'])
            $rot = ConvertFrom-DuneVecText ([string]$r['rotation'])
            if ($loc.Count -lt 3 -or $rot.Count -lt 4) { continue }
            $e = ConvertTo-DuneEuler -Qx $rot[0] -Qy $rot[1] -Qz $rot[2] -Qw $rot[3]
            $nextId = $placeables.Count
            $placeables += [ordered]@{
                building_type = $bt
                x             = ($loc[0] - $cx)
                y             = ($loc[1] - $cy)
                z             = ($loc[2] - $cz)
                rx            = $e[0]
                ry            = $e[1]
                rz            = $e[2]
            }
            if ($bt -like '*PentashieldSurface*') {
                $scale = Get-DunePentashieldScale -BuildingType $bt -PropertiesJson ([string]$r['properties'])
                if ($scale) {
                    $pentashields += [ordered]@{ placeable_id = $nextId; scale = $scale }
                }
            }
        }
    }

    $bp = [ordered]@{
        name         = ''
        instances    = @($instances)
        placeables   = @($placeables)
        pentashields = @($pentashields)
    }
    return @{ ok = $true; blueprint = $bp }
}

# Extract a pentashield's [width,height,depth] scale from a placeable's
# properties JSON: properties[<buildingType minus _Placeable>_C]["m_Scale"][0..2].
function Get-DunePentashieldScale {
    param([string]$BuildingType, [string]$PropertiesJson)
    if (-not $PropertiesJson) { return $null }
    try { $props = $PropertiesJson | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $props) { return $null }
    $key = ($BuildingType -replace '_Placeable$', '') + '_C'
    $inner = $null
    if ($props.PSObject.Properties[$key]) { $inner = $props.$key }
    if ($null -eq $inner) { return $null }
    $scaleVals = $null
    if ($inner.PSObject.Properties['m_Scale']) { $scaleVals = $inner.'m_Scale' }
    $arr = @($scaleVals)
    if ($arr.Count -lt 3) { return $null }
    return @([int](ConvertTo-DuneInt $arr[0]), [int](ConvertTo-DuneInt $arr[1]), [int](ConvertTo-DuneInt $arr[2]))
}

function Get-DuneBaseExportDemo {
    param([long]$BaseId)
    return [ordered]@{
        name         = ''
        instances    = @(
            [ordered]@{ building_type='Atreides_Outpost_Foundation'; x=0.0; y=0.0; z=0.0; rotation=0.0 }
            [ordered]@{ building_type='Atreides_Outpost_Wall'; x=0.0; y=400.0; z=0.0; rotation=90.0 }
            [ordered]@{ building_type='Atreides_Outpost_Foundation'; x=400.0; y=0.0; z=0.0; rotation=0.0 }
        )
        placeables   = @(
            [ordered]@{ building_type='StorageContainer_Placeable'; x=100.0; y=100.0; z=10.0; rx=0.0; ry=0.0; rz=0.0 }
        )
        pentashields = @()
    }
}
