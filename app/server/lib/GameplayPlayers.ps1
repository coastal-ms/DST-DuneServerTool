# Gameplay — Players (native port of dune-admin's player tooling).
#
# Reads the live game Postgres through the same Invoke-DuneSqlQuery bridge the
# Market features use, so dune-admin's SQL ports verbatim. Every getter returns
# @{ ok; ... } and the routes wrap them with the live/demo + `source` convention.
#
# Write actions (give solari, award spec XP, rename, give/delete/repair item)
# call the SAME server-side stored procedures and statements dune-admin uses,
# run with -ReadOnly:$false. They are surfaced behind explicit confirm UI.
#
# Helpers reused from Gameplay.ps1: ConvertTo-DuneRowMaps, ConvertTo-DuneInt,
# Test-DuneTruthy, Get-DuneGameplayItemName.

# ----------------------------------------------------------------------------
# Shorten a UE class path to something readable: strip path, leading BP_,
# trailing _C. e.g. "/Game/.../BP_Sandbike_CHOAM_C.BP_Sandbike_CHOAM_C" -> "Sandbike CHOAM".
# ----------------------------------------------------------------------------
function Get-DuneShortClass {
    param([string]$Class)
    if (-not $Class) { return '' }
    $c = [string]$Class
    $dot = $c.LastIndexOf('.')
    if ($dot -ge 0) { $c = $c.Substring($dot + 1) }
    $slash = $c.LastIndexOf('/')
    if ($slash -ge 0) { $c = $c.Substring($slash + 1) }
    if ($c.StartsWith('BP_')) { $c = $c.Substring(3) }
    if ($c.EndsWith('_C')) { $c = $c.Substring(0, $c.Length - 2) }
    return ($c -replace '_', ' ').Trim()
}

# ----------------------------------------------------------------------------
# SQL — Players (ported from dune-admin db.go). All read-only.
# ----------------------------------------------------------------------------
$script:DunePlayersListSql = @'
SELECT a.id,
       COALESCE(a.owner_account_id, 0)                  AS account_id,
       COALESCE(ps.player_controller_id, 0)             AS controller_id,
       COALESCE(ps.character_name, '')                  AS name,
       a.class                                          AS class,
       COALESCE(a.map, '')                              AS map,
       COALESCE(pf.faction_id, 0)                       AS faction_id,
       COALESCE(f.name, '')                             AS faction_name,
       COALESCE(ps.online_status::text, 'Offline')      AS online_status
FROM dune.actors a
LEFT JOIN dune.player_state ps  ON ps.account_id = a.owner_account_id
LEFT JOIN dune.player_faction pf ON pf.actor_id = a.id
LEFT JOIN dune.factions f        ON f.id = pf.faction_id
WHERE a.class ILIKE '%PlayerCharacter%'
ORDER BY a.id
'@

# Inventory for one pawn actor id ($1).
$script:DunePlayerInventorySql = @'
SELECT i.id, i.template_id, i.stack_size, COALESCE(i.quality_level, 0) AS quality_level,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability'), 'N/A') AS durability,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability'), 'N/A')     AS max_durability
FROM dune.items i
JOIN dune.inventories inv ON i.inventory_id = inv.id
WHERE inv.actor_id = {0}::bigint
ORDER BY i.template_id
'@

# Currency balances for one controller id ($1).
$script:DunePlayerCurrencySql = @'
SELECT currency_id, balance
FROM dune.player_virtual_currency_balances
WHERE player_controller_id = {0}::bigint
ORDER BY currency_id
'@

# Specialization tracks for one pawn id ($1).
$script:DunePlayerSpecsSql = @'
SELECT track_type::text AS track_type, xp_amount, level
FROM dune.specialization_tracks
WHERE player_id = {0}::bigint
ORDER BY track_type
'@

function Get-DunePlayersLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DunePlayersListSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $players = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $players += [ordered]@{
            id            = (ConvertTo-DuneInt $r['id'])
            account_id    = (ConvertTo-DuneInt $r['account_id'])
            controller_id = (ConvertTo-DuneInt $r['controller_id'])
            name          = [string]$r['name']
            class         = (Get-DuneShortClass ([string]$r['class']))
            map           = [string]$r['map']
            faction_id    = (ConvertTo-DuneInt $r['faction_id'])
            faction_name  = [string]$r['faction_name']
            online_status = [string]$r['online_status']
        }
    }
    return @{ ok = $true; players = $players }
}

function Get-DunePlayerDetailLive {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId)
    $invSql  = [string]::Format($script:DunePlayerInventorySql, $PawnId)
    $specSql = [string]::Format($script:DunePlayerSpecsSql, $PawnId)
    $curSql  = [string]::Format($script:DunePlayerCurrencySql, $ControllerId)

    $invRes  = Invoke-DuneSqlQuery -Ip $Ip -Sql $invSql  -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $invRes.ok) { return @{ ok = $false; error = $invRes.error } }
    $specRes = Invoke-DuneSqlQuery -Ip $Ip -Sql $specSql -ReadOnly $true -MaxRows 500 -TimeoutSec 30
    if (-not $specRes.ok) { return @{ ok = $false; error = $specRes.error } }
    $curRes  = Invoke-DuneSqlQuery -Ip $Ip -Sql $curSql  -ReadOnly $true -MaxRows 500 -TimeoutSec 30
    if (-not $curRes.ok) { return @{ ok = $false; error = $curRes.error } }

    $inventory = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $invRes)) {
        $tmpl = [string]$r['template_id']
        $inventory += [ordered]@{
            id             = (ConvertTo-DuneInt $r['id'])
            template_id    = $tmpl
            name           = (Get-DuneGameplayItemName -TemplateId $tmpl)
            stack_size     = (ConvertTo-DuneInt $r['stack_size'])
            quality        = (ConvertTo-DuneInt $r['quality_level'])
            durability     = [string]$r['durability']
            max_durability = [string]$r['max_durability']
        }
    }
    $specs = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $specRes)) {
        $specs += [ordered]@{
            track_type = [string]$r['track_type']
            xp         = (ConvertTo-DuneInt $r['xp_amount'])
            level      = [double]([string]$r['level'])
        }
    }
    $currency = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $curRes)) {
        $currency += [ordered]@{
            currency_id = (ConvertTo-DuneInt $r['currency_id'])
            balance     = (ConvertTo-DuneInt $r['balance'])
        }
    }
    return @{ ok = $true; inventory = $inventory; specs = $specs; currency = $currency }
}

# ----------------------------------------------------------------------------
# WRITE actions. SQL escaping: numeric args are cast to bigint, strings are
# single-quote-doubled. All run with -ReadOnly:$false.
# ----------------------------------------------------------------------------
function ConvertTo-DuneSqlString {
    param($Value)
    return ([string]$Value) -replace "'", "''"
}

# Give Solari (give-currency): dune.adjust_player_virtual_currency_balance.
function Invoke-DunePlayerGiveSolari {
    param([string]$Ip, [long]$ControllerId, [long]$Amount)
    $sql = "SELECT dune.adjust_player_virtual_currency_balance($ControllerId::bigint, dune.get_solaris_id(), $Amount::bigint) AS new_balance;"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    $bal = if ($maps.Count -ge 1) { ConvertTo-DuneInt $maps[0]['new_balance'] } else { $null }
    return @{ ok = $true; message = "Added $Amount Solari — new balance $bal."; new_balance = $bal }
}

# Rename character (rename): dune.set_character_name(account_id, name).
function Invoke-DunePlayerRename {
    param([string]$Ip, [long]$AccountId, [string]$Name)
    $safe = ConvertTo-DuneSqlString $Name
    $sql = "SELECT dune.set_character_name($AccountId::bigint, '$safe');"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Renamed character to '$Name'." }
}

# Award specialization XP (award-xp): UPDATE, INSERT if no row. Hard cap 44182.
function Invoke-DunePlayerAwardXp {
    param([string]$Ip, [long]$PawnId, [string]$TrackType, [int]$Delta)
    $safeTrack = ConvertTo-DuneSqlString $TrackType
    $cap = 44182
    $updSql = @"
UPDATE dune.specialization_tracks
SET xp_amount = GREATEST(LEAST(xp_amount + ($Delta)::integer, $cap::integer), 0)
WHERE player_id = $PawnId::bigint AND track_type::text = '$safeTrack';
"@
    $upd = Invoke-DuneSqlQuery -Ip $Ip -Sql $updSql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $upd.ok) { return @{ ok = $false; error = $upd.error } }
    if (([string]$upd.message) -match 'UPDATE\s+0') {
        $start = [Math]::Max(0, [Math]::Min($Delta, $cap))
        $insSql = @"
INSERT INTO dune.specialization_tracks (player_id, track_type, xp_amount, level)
VALUES ($PawnId::bigint, '$safeTrack'::dune.specializationtracktype, $start::integer, 0::real);
"@
        $ins = Invoke-DuneSqlQuery -Ip $Ip -Sql $insSql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $ins.ok) { return @{ ok = $false; error = $ins.error } }
        return @{ ok = $true; message = "Created '$TrackType' track with $start XP." }
    }
    return @{ ok = $true; message = "Adjusted '$TrackType' XP by $Delta (capped at $cap)." }
}

# Delete item (delete-item): dune.delete_item(id).
function Invoke-DunePlayerDeleteItem {
    param([string]$Ip, [long]$ItemId)
    $sql = "SELECT dune.delete_item($ItemId::bigint);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Deleted item $ItemId." }
}

# Repair item (repair-item): restore CurrentDurability/DecayedMaxDurability to MaxDurability.
function Invoke-DunePlayerRepairItem {
    param([string]$Ip, [long]$ItemId)
    $sql = @"
UPDATE dune.items i
SET stats = jsonb_set(
    jsonb_set(i.stats,
        '{FItemStackAndDurabilityStats,1,CurrentDurability}',
        to_jsonb(t.val), true),
    '{FItemStackAndDurabilityStats,1,DecayedMaxDurability}',
    to_jsonb(t.val), true)
FROM (
    SELECT COALESCE(
        (stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8,
        100.0
    ) AS val
    FROM dune.items
    WHERE id = $ItemId::bigint
      AND stats ? 'FItemStackAndDurabilityStats'
) AS t
WHERE i.id = $ItemId::bigint;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Repaired item $ItemId to full durability." }
}

# Give item (give-item): stack onto a matching backpack stack or insert a new one.
# Single data-modifying CTE so it runs atomically in one psql call.
function Invoke-DunePlayerGiveItem {
    param([string]$Ip, [long]$PawnId, [string]$Template, [long]$Qty, [long]$Quality)
    $safeTmpl = ConvertTo-DuneSqlString $Template
    $sql = @"
WITH inv AS (
    SELECT id FROM dune.inventories
    WHERE actor_id = $PawnId::bigint AND inventory_type = 0
    ORDER BY id LIMIT 1
),
existing AS (
    SELECT i.id FROM dune.items i, inv
    WHERE i.inventory_id = inv.id
      AND i.template_id = '$safeTmpl'
      AND COALESCE(i.quality_level, 0) = $Quality::bigint
    ORDER BY i.id LIMIT 1
),
upd AS (
    UPDATE dune.items SET stack_size = stack_size + $Qty::bigint
    WHERE id = (SELECT id FROM existing)
    RETURNING id
),
ins AS (
    INSERT INTO dune.items (inventory_id, stack_size, position_index, template_id, quality_level, stats)
    SELECT inv.id, $Qty::bigint,
        (SELECT COALESCE(MAX(position_index), -1) + 1 FROM dune.items WHERE inventory_id = inv.id),
        '$safeTmpl', $Quality::bigint, '{}'::jsonb
    FROM inv
    WHERE NOT EXISTS (SELECT 1 FROM existing)
    RETURNING id
)
SELECT COALESCE((SELECT id FROM upd), (SELECT id FROM ins)) AS item_id;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    $itemId = if ($maps.Count -ge 1) { [string]$maps[0]['item_id'] } else { '' }
    if (-not $itemId) {
        return @{ ok = $false; error = 'No backpack inventory found for that player.' }
    }
    return @{ ok = $true; message = "Gave $Qty x $Template (quality $Quality) to player (item $itemId)."; item_id = (ConvertTo-DuneInt $itemId) }
}

# ----------------------------------------------------------------------------
# Demo data — used when the live DB is unreachable or ?demo=1 is requested.
# ----------------------------------------------------------------------------
function Get-DunePlayersDemo {
    return @(
        [ordered]@{ id=20001; account_id=9001; controller_id=30001; name='Duncan Idaho'; class='PlayerCharacter'; map='Hagga Basin'; faction_id=1; faction_name='Atreides'; online_status='Online' }
        [ordered]@{ id=20002; account_id=9002; controller_id=30002; name='Gurney Halleck'; class='PlayerCharacter'; map='Hagga Basin'; faction_id=1; faction_name='Atreides'; online_status='Offline' }
        [ordered]@{ id=20003; account_id=9003; controller_id=30003; name='Stilgar'; class='PlayerCharacter'; map='Deep Desert'; faction_id=0; faction_name=''; online_status='Online' }
        [ordered]@{ id=20004; account_id=9004; controller_id=30004; name='Feyd-Rautha'; class='PlayerCharacter'; map='Hagga Basin'; faction_id=2; faction_name='Harkonnen'; online_status='Offline' }
    )
}

function Get-DunePlayerDetailDemo {
    param([long]$PawnId)
    return @{
        ok = $true
        inventory = @(
            [ordered]@{ id=70001; template_id='Stillsuit_T4'; name='Stillsuit (Mk IV)'; stack_size=1; quality=3; durability='842.0'; max_durability='1000.0' }
            [ordered]@{ id=70002; template_id='Spice_Melange'; name='Spice Melange'; stack_size=1200; quality=0; durability='N/A'; max_durability='N/A' }
            [ordered]@{ id=70003; template_id='Maula_Pistol'; name='Maula Pistol'; stack_size=1; quality=4; durability='310.0'; max_durability='400.0' }
        )
        specs = @(
            [ordered]@{ track_type='Trooper'; xp=44182; level=100.0 }
            [ordered]@{ track_type='Mentat'; xp=18250; level=42.0 }
        )
        currency = @(
            [ordered]@{ currency_id=1; balance=125000 }
            [ordered]@{ currency_id=2; balance=860 }
        )
    }
}
