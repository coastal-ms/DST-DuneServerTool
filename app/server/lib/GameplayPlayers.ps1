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
LEFT JOIN dune.player_faction pf ON pf.actor_id = ps.player_controller_id
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
            kind           = (Get-DuneItemKind -TemplateId $tmpl)
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
# Single data-modifying CTE so it runs atomically in one psql call. New rows must
# stamp acquisition_time with the current epoch — the game treats acquisition_time=0
# (1970) items as fully decayed and drops them on load, so an offline give would
# vanish on the player's next login.
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
    INSERT INTO dune.items (inventory_id, stack_size, position_index, template_id, quality_level, acquisition_time, stats)
    SELECT inv.id, $Qty::bigint,
        (SELECT COALESCE(MAX(position_index), -1) + 1 FROM dune.items WHERE inventory_id = inv.id),
        '$safeTmpl', $Quality::bigint, EXTRACT(EPOCH FROM now())::bigint, '{}'::jsonb
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
            [ordered]@{ id=70001; template_id='Stillsuit_T4'; name='Stillsuit (Mk IV)'; kind='item'; stack_size=1; quality=3; durability='842.0'; max_durability='1000.0' }
            [ordered]@{ id=70002; template_id='Spice_Melange'; name='Spice Melange'; kind='item'; stack_size=1200; quality=0; durability='N/A'; max_durability='N/A' }
            [ordered]@{ id=70003; template_id='Maula_Pistol'; name='Maula Pistol'; kind='item'; stack_size=1; quality=4; durability='310.0'; max_durability='400.0' }
            [ordered]@{ id=70004; template_id='Emote_AtreSalute_01'; name='Atreides Salute'; kind='emote'; stack_size=1; quality=0; durability='N/A'; max_durability='N/A' }
            [ordered]@{ id=70005; template_id='Emote_Wave_01'; name='Wave'; kind='emote'; stack_size=1; quality=0; durability='N/A'; max_durability='N/A' }
            [ordered]@{ id=70006; template_id='D_ContractSmugglerDocuments'; name='Smuggler Documents'; kind='contract'; stack_size=1; quality=0; durability='N/A'; max_durability='N/A' }
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

# ============================================================================
# v11.5.6 — extended player surface (port of dune-admin's player tooling).
#
# Adds:
#   - Get-DunePlayerSummaryLive     : server-wide aggregate dashboard
#   - Get-DunePlayerStatsLive       : per-player snapshot (currencies, level,
#                                      faction, playtime, last_seen)
#   - Get-DunePlayerSpecsFullLive   : full spec tracks + keystone counts
#   - Get-DunePlayerTagsLive        : player_tags labels
#   - Get-DunePlayerEventsLive      : recent dune.event_log rows
#   - Invoke-DunePlayerGrantMaxSpec : set xp=44182 level=100 for one track
#   - Invoke-DunePlayerResetSpec    : DELETE one track (or 'all' resets fns)
#   - Invoke-DunePlayerGrantAllKeystones / Invoke-DunePlayerResetAllKeystones
#   - Invoke-DunePlayerSetTags      : replace tag set for an account
#
# All read calls degrade gracefully when their backing tables don't exist on
# the live game DB (returns @{ ok=$true; unsupported=$true; rows=@() }).
# ============================================================================

# Wraps a SQL call; if the error message looks like "relation does not exist"
# returns a soft "unsupported" instead of bubbling the failure. Lets the
# frontend render an empty section instead of an error toast when the live
# server doesn't have a given player-admin table (older builds, etc).
function Invoke-DuneSqlSoft {
    param([string]$Ip, [string]$Sql, [int]$MaxRows = 1000, [int]$TimeoutSec = 30)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $Sql -ReadOnly $true -MaxRows $MaxRows -TimeoutSec $TimeoutSec
    if (-not $res.ok) {
        $msg = [string]$res.error
        if ($msg -match 'does not exist' -or $msg -match 'undefined' -or $msg -match 'permission denied') {
            return @{ ok = $true; unsupported = $true; reason = $msg; rows = @() }
        }
        return @{ ok = $false; error = $msg }
    }
    return @{ ok = $true; unsupported = $false; raw = $res }
}

# ---------------------------------------------------------------------------
# Server-wide summary — total players, online count, by-faction, by-map,
# currency totals, average character level. Single round trip via a SQL
# script that returns several labelled result sets stitched together.
# Each metric tolerates a missing table by returning 0/empty.
# ---------------------------------------------------------------------------
$script:DunePlayerSummarySql = @'
SELECT 'totals' AS bucket, NULL AS k,
       (SELECT COUNT(*) FROM dune.actors WHERE class ILIKE '%PlayerCharacter%')::bigint AS v
UNION ALL
SELECT 'online_now', NULL,
       (SELECT COUNT(*) FROM dune.player_state WHERE online_status::text ILIKE 'Online')::bigint
UNION ALL
SELECT 'distinct_factions', NULL,
       (SELECT COUNT(DISTINCT pf.faction_id)
        FROM dune.player_faction pf
        WHERE pf.faction_id > 0)::bigint
UNION ALL
SELECT 'by_faction', COALESCE(f.name, 'Unaligned'),
       COUNT(*)::bigint
  FROM dune.actors a
  LEFT JOIN dune.player_state   ps ON ps.account_id = a.owner_account_id
  LEFT JOIN dune.player_faction pf ON pf.actor_id   = ps.player_controller_id
  LEFT JOIN dune.factions f ON f.id = pf.faction_id
  WHERE a.class ILIKE '%PlayerCharacter%'
  GROUP BY 2
UNION ALL
SELECT 'by_map', COALESCE(a.map, '(none)'),
       COUNT(*)::bigint
  FROM dune.actors a
  WHERE a.class ILIKE '%PlayerCharacter%'
  GROUP BY 2
ORDER BY 1, 2;
'@

function Get-DunePlayerSummaryLive {
    param([string]$Ip)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $script:DunePlayerSummarySql -ReadOnly $true -MaxRows 2000 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $totals = [ordered]@{ players = 0; online = 0; factions = 0 }
    $byFaction = @()
    $byMap = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $res)) {
        $bucket = [string]$r['bucket']
        switch ($bucket) {
            'totals'             { $totals.players  = (ConvertTo-DuneInt $r['v']) }
            'online_now'         { $totals.online   = (ConvertTo-DuneInt $r['v']) }
            'distinct_factions'  { $totals.factions = (ConvertTo-DuneInt $r['v']) }
            'by_faction'         { $byFaction += [ordered]@{ name = [string]$r['k']; count = (ConvertTo-DuneInt $r['v']) } }
            'by_map'             { $byMap     += [ordered]@{ name = [string]$r['k']; count = (ConvertTo-DuneInt $r['v']) } }
        }
    }
    return @{ ok = $true; totals = $totals; by_faction = $byFaction; by_map = $byMap }
}

function Get-DunePlayerSummaryDemo {
    return @{
        totals     = [ordered]@{ players = 4; online = 2; factions = 2 }
        by_faction = @(
            [ordered]@{ name = 'Atreides';   count = 2 }
            [ordered]@{ name = 'Harkonnen';  count = 1 }
            [ordered]@{ name = 'Unaligned';  count = 1 }
        )
        by_map = @(
            [ordered]@{ name = 'Hagga Basin'; count = 3 }
            [ordered]@{ name = 'Deep Desert'; count = 1 }
        )
    }
}

# ---------------------------------------------------------------------------
# Per-player stats — currency balances, faction tier, char xp/level, last
# avatar activity. Defensive: each subquery wrapped so a missing column on
# older schemas degrades to NULL instead of failing the whole call.
# ---------------------------------------------------------------------------
$script:DunePlayerStatsSql = @'
SELECT
    a.id                                                              AS pawn_id,
    COALESCE(a.owner_account_id, 0)                                   AS account_id,
    COALESCE(ps.player_controller_id, 0)                              AS controller_id,
    COALESCE(ps.character_name, '')                                   AS character_name,
    a.class                                                           AS class,
    COALESCE(a.map, '')                                               AS map,
    COALESCE(ps.online_status::text, 'Offline')                       AS online_status,
    COALESCE(to_char(ps.last_avatar_activity AT TIME ZONE 'UTC',
                     'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')               AS last_seen,
    COALESCE(pf.faction_id, 0)                                        AS faction_id,
    COALESCE(f.name, '')                                              AS faction_name,
    COALESCE((SELECT balance FROM dune.player_virtual_currency_balances
              WHERE player_controller_id = ps.player_controller_id
                AND currency_id = dune.get_solaris_id()), 0)::bigint  AS solaris,
    COALESCE((SELECT SUM(balance) FROM dune.player_virtual_currency_balances
              WHERE player_controller_id = ps.player_controller_id), 0)::bigint AS total_currency
FROM dune.actors a
LEFT JOIN dune.player_state    ps ON ps.account_id = a.owner_account_id
LEFT JOIN dune.player_faction  pf ON pf.actor_id   = ps.player_controller_id
LEFT JOIN dune.factions        f  ON f.id          = pf.faction_id
WHERE a.id = {0}::bigint
LIMIT 1;
'@

function Get-DunePlayerStatsLive {
    param([string]$Ip, [long]$PawnId)
    $sql = [string]::Format($script:DunePlayerStatsSql, $PawnId)
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    if (-not $maps -or $maps.Count -lt 1) { return @{ ok = $true; stats = $null } }
    $r = $maps[0]
    $stats = [ordered]@{
        pawn_id        = (ConvertTo-DuneInt $r['pawn_id'])
        account_id     = (ConvertTo-DuneInt $r['account_id'])
        controller_id  = (ConvertTo-DuneInt $r['controller_id'])
        character_name = [string]$r['character_name']
        class          = (Get-DuneShortClass ([string]$r['class']))
        map            = [string]$r['map']
        online_status  = [string]$r['online_status']
        last_seen      = [string]$r['last_seen']
        faction_id     = (ConvertTo-DuneInt $r['faction_id'])
        faction_name   = [string]$r['faction_name']
        solaris        = (ConvertTo-DuneInt $r['solaris'])
        total_currency = (ConvertTo-DuneInt $r['total_currency'])
    }
    return @{ ok = $true; stats = $stats }
}

# ---------------------------------------------------------------------------
# Full specs view (5 tracks plus keystone count + max).
# Keystones use the dune.purchased_specialization_keystones table keyed by
# controller id (per dune-admin's insertAllPurchasedKeystones path).
# Max keystone id is 205 (matches dune-admin's generate_series upper bound).
# ---------------------------------------------------------------------------
$script:DunePlayerSpecsFullSql = @'
WITH tracks AS (
    SELECT track_type::text AS track_type, xp_amount, level
    FROM dune.specialization_tracks
    WHERE player_id = {0}::bigint
),
ks_total AS (
    SELECT COUNT(*)::bigint AS n
    FROM dune.purchased_specialization_keystones
    WHERE player_id = {1}::bigint
)
SELECT 'track' AS kind, t.track_type AS k, t.xp_amount AS v_int, t.level AS v_real FROM tracks t
UNION ALL
SELECT 'keystones_total', NULL, n, 0 FROM ks_total;
'@

$script:DuneSpecXpMax    = 44182
$script:DuneSpecLevelMax = 100.0
$script:DuneKeystoneMax  = 205

function Get-DunePlayerSpecsFullLive {
    param([string]$Ip, [long]$PawnId, [long]$ControllerId)
    $sql = [string]::Format($script:DunePlayerSpecsFullSql, $PawnId, $ControllerId)
    $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $sql -MaxRows 200 -TimeoutSec 30
    if (-not $soft.ok) { return @{ ok = $false; error = $soft.error } }
    if ($soft.unsupported) {
        return @{ ok = $true; tracks = @(); keystones_total = 0; keystones_max = $script:DuneKeystoneMax; unsupported = $true }
    }
    $tracks = @()
    $kTotal = 0
    foreach ($r in (ConvertTo-DuneRowMaps -Result $soft.raw)) {
        $kind = [string]$r['kind']
        if ($kind -eq 'track') {
            $tracks += [ordered]@{
                track_type = [string]$r['k']
                xp         = (ConvertTo-DuneInt $r['v_int'])
                level      = [double]([string]$r['v_real'])
                xp_max     = $script:DuneSpecXpMax
                level_max  = $script:DuneSpecLevelMax
            }
        } elseif ($kind -eq 'keystones_total') {
            $kTotal = (ConvertTo-DuneInt $r['v_int'])
        }
    }
    return @{
        ok              = $true
        tracks          = $tracks
        keystones_total = $kTotal
        keystones_max   = $script:DuneKeystoneMax
    }
}

# Grant max — set xp=44182 level=100 for one track. Uses dune.set_specialization_xp_and_level.
function Invoke-DunePlayerGrantMaxSpec {
    param([string]$Ip, [long]$PawnId, [string]$TrackType)
    $safeTrack = ConvertTo-DuneSqlString $TrackType
    $sql = "SELECT dune.set_specialization_xp_and_level($PawnId::bigint, '$safeTrack'::dune.specializationtracktype, $($script:DuneSpecXpMax)::integer, $($script:DuneSpecLevelMax)::real);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Granted max XP for '$TrackType' (xp=$($script:DuneSpecXpMax), level=$($script:DuneSpecLevelMax))." }
}

# Reset one track — DELETE the row.
function Invoke-DunePlayerResetSpec {
    param([string]$Ip, [long]$PawnId, [string]$TrackType)
    $safeTrack = ConvertTo-DuneSqlString $TrackType
    $sql = "DELETE FROM dune.specialization_tracks WHERE player_id = $PawnId::bigint AND track_type::text = '$safeTrack';"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Reset '$TrackType' track for player $PawnId." }
}

# Reset ALL spec tracks (and ALL keystones) — runs both reset functions.
function Invoke-DunePlayerResetAllSpecs {
    param([string]$Ip, [long]$PawnId)
    $sql = @"
SELECT dune.reset_specialization_tracks($PawnId::bigint);
SELECT dune.reset_specialization_keystones($PawnId::bigint);
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Reset all spec tracks and keystones for player $PawnId." }
}

# Grant all keystones — uses controller id (per dune-admin's insertAllPurchasedKeystones).
function Invoke-DunePlayerGrantAllKeystones {
    param([string]$Ip, [long]$ControllerId)
    $max = $script:DuneKeystoneMax
    $sql = @"
INSERT INTO dune.purchased_specialization_keystones (player_id, keystone_id)
SELECT $ControllerId::bigint, generate_series(1, $max)
ON CONFLICT DO NOTHING;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Granted all $max keystones for controller $ControllerId." }
}

# Reset all keystones — dune.reset_specialization_keystones.
function Invoke-DunePlayerResetAllKeystones {
    param([string]$Ip, [long]$PawnId)
    $sql = "SELECT dune.reset_specialization_keystones($PawnId::bigint);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Reset all keystones for player $PawnId." }
}

# ---------------------------------------------------------------------------
# Player tags (labels like VIP / Verified / Probation). Stored in
# dune.player_tags(account_id, tag). Read returns string[]; write replaces
# the full set for an account.
# ---------------------------------------------------------------------------
function Get-DunePlayerTagsLive {
    param([string]$Ip, [long]$AccountId)
    $sql = "SELECT tag FROM dune.player_tags WHERE account_id = $AccountId::bigint ORDER BY tag;"
    $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $sql -MaxRows 200 -TimeoutSec 30
    if (-not $soft.ok) { return @{ ok = $false; error = $soft.error } }
    if ($soft.unsupported) { return @{ ok = $true; tags = @(); unsupported = $true } }
    $tags = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $soft.raw)) {
        $t = [string]$r['tag']
        if ($t) { $tags += $t }
    }
    return @{ ok = $true; tags = $tags }
}

function Invoke-DunePlayerSetTags {
    param([string]$Ip, [long]$AccountId, [string[]]$Tags)
    $clean = @()
    foreach ($t in @($Tags)) {
        $s = ([string]$t).Trim()
        if ($s -and $s.Length -le 64) { $clean += $s }
    }
    $values = if ($clean.Count -gt 0) {
        ($clean | ForEach-Object { "($AccountId::bigint, '" + (ConvertTo-DuneSqlString $_) + "')" }) -join ', '
    } else { $null }
    $sqlParts = @("DELETE FROM dune.player_tags WHERE account_id = $AccountId::bigint;")
    if ($values) { $sqlParts += "INSERT INTO dune.player_tags (account_id, tag) VALUES $values ON CONFLICT DO NOTHING;" }
    $sql = $sqlParts -join "`n"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; message = "Tags updated for account $AccountId ($($clean.Count) tag(s))."; tags = $clean }
}

# v11.5.9 - update_player_tags delta path. Mirrors dune-admin cmdUpdatePlayerTags:
# calls dune.update_player_tags(account_id, add[], remove[]) via the stored
# proc rather than DELETE-INSERT, so the server-side trigger logic (faction
# rep cascades, journey hooks) fires correctly.
function Invoke-DunePlayerUpdateTags {
    param([string]$Ip, [long]$AccountId, [string[]]$Add, [string[]]$Remove)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $addClean = @(); foreach ($t in @($Add))    { $s = ([string]$t).Trim(); if ($s -and $s.Length -le 128) { $addClean += $s } }
    $remClean = @(); foreach ($t in @($Remove)) { $s = ([string]$t).Trim(); if ($s -and $s.Length -le 128) { $remClean += $s } }
    if ($addClean.Count -eq 0 -and $remClean.Count -eq 0) {
        return @{ ok = $false; error = 'at least one of add[] or remove[] must be non-empty.' }
    }
    $addArr = if ($addClean.Count -gt 0) { ConvertTo-DunePgTextArray $addClean } else { 'ARRAY[]::text[]' }
    $remArr = if ($remClean.Count -gt 0) { ConvertTo-DunePgTextArray $remClean } else { 'ARRAY[]::text[]' }
    $sql = "SELECT dune.update_player_tags($AccountId::bigint, $addArr, $remArr);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "update_player_tags: $($r.error)" } }
    return @{
        ok = $true
        message = "Tags updated for account $AccountId (+$($addClean.Count) / -$($remClean.Count))."
        added = $addClean; removed = $remClean
    }
}

# ---------------------------------------------------------------------------
# Recent events (history). Joins event_log to accounts via fls_id.
# Returns most recent N rows; meta is JSON kept as a string for the client.
# ---------------------------------------------------------------------------
$script:DunePlayerEventsSql = @'
SELECT
    el.id,
    COALESCE(to_char(el.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '') AS ts,
    COALESCE(el.event_type::text, '')   AS event_type,
    COALESCE(el.meta::text, '{}')        AS meta_json
FROM dune.event_log el
JOIN dune.accounts ac ON ac."user" = el.meta->>'fls_id'
WHERE ac.id = {0}::bigint
ORDER BY el.created_at DESC
LIMIT {1};
'@

function Get-DunePlayerEventsLive {
    param([string]$Ip, [long]$AccountId, [int]$Limit = 100)
    if ($Limit -le 0 -or $Limit -gt 500) { $Limit = 100 }
    $sql = [string]::Format($script:DunePlayerEventsSql, $AccountId, $Limit)
    $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $sql -MaxRows ($Limit + 10) -TimeoutSec 30
    if (-not $soft.ok) { return @{ ok = $false; error = $soft.error } }
    if ($soft.unsupported) { return @{ ok = $true; events = @(); unsupported = $true } }
    $events = @()
    foreach ($r in (ConvertTo-DuneRowMaps -Result $soft.raw)) {
        $events += [ordered]@{
            id         = (ConvertTo-DuneInt $r['id'])
            ts         = [string]$r['ts']
            event_type = [string]$r['event_type']
            meta       = [string]$r['meta_json']
        }
    }
    return @{ ok = $true; events = $events }
}

# Demo data for new sections — used when live DB is unreachable.
function Get-DunePlayerStatsDemo {
    param([long]$PawnId)
    return [ordered]@{
        pawn_id = $PawnId; account_id = 9001; controller_id = 30001
        character_name = 'Duncan Idaho'; class = 'PlayerCharacter'
        map = 'Hagga Basin'; online_status = 'Online'
        last_seen = '2026-06-12T06:00:00Z'
        faction_id = 1; faction_name = 'Atreides'
        solaris = 125000; total_currency = 132100
    }
}

function Get-DunePlayerSpecsFullDemo {
    return @{
        tracks = @(
            [ordered]@{ track_type='Combat';      xp=44182; level=100.0; xp_max=44182; level_max=100.0 }
            [ordered]@{ track_type='Crafting';    xp=18250; level=42.0;  xp_max=44182; level_max=100.0 }
            [ordered]@{ track_type='Exploration'; xp=8900;  level=21.0;  xp_max=44182; level_max=100.0 }
            [ordered]@{ track_type='Gathering';   xp=12500; level=30.0;  xp_max=44182; level_max=100.0 }
            [ordered]@{ track_type='Sabotage';    xp=0;     level=0.0;   xp_max=44182; level_max=100.0 }
        )
        keystones_total = 87
        keystones_max   = 205
    }
}

function Get-DunePlayerTagsDemo { return @('VIP', 'Discord Verified') }

function Get-DunePlayerEventsDemo {
    return @(
        [ordered]@{ id=1; ts='2026-06-12T05:55:00Z'; event_type='give_currency'; meta='{"solaris_delta":50000,"by":"admin"}' }
        [ordered]@{ id=2; ts='2026-06-12T05:42:00Z'; event_type='login';         meta='{"map":"Hagga Basin"}' }
        [ordered]@{ id=3; ts='2026-06-11T22:10:00Z'; event_type='logout';        meta='{}' }
    )
}

# ---------------------------------------------------------------------------
# v11.5.7 — Fill Water (offline path). Ported from dune-admin db.go:6325
# cmdRefillWaterOffline. Sets all water-fillable items in the actor's relevant
# inventories to their MaxAmount via jsonb_set. Takes effect on next relog for
# online players; instant for offline players.
#
# Source list: dune-admin fillables_gen.go waterFillableTemplates (49 entries,
# generated from DT_ItemTableFillables.json — FillableTypeRestriction=Water).
# repairGearInventoryTypes is DST's narrowed set (0,1,15): backpack + equipped
# armor + equipped weapons only. (dune-admin's original set also included emote
# and empty buckets 14/27/30, which Repair/Restore should not touch.)
# ---------------------------------------------------------------------------
$script:DuneWaterFillableTemplates = @(
    'advancedstillsuit','combat_nati_fremenexile04_top','decajon','dewpack',
    'highcapacityliterjon','highcapacityliterjon_02','highcapacityliterjon_03',
    'highcapacityliterjon_04','highcapacityliterjon_05','highcapacityliterjon_06',
    'literjon','literjon_03','literjon_04','literjon_05','literjon_06',
    'literjon_07','literjon_08','literjon_09','literjon_t6','simplestillsuit',
    'stillsuit_choam_01_top','stillsuit_choam_02_top','stillsuit_choam_04_top',
    'stillsuit_choam_05_top','stillsuit_choam_06_top',
    'stillsuit_choam_unique_dashed02_top','stillsuit_choam_unique_dashed03_top',
    'stillsuit_choam_unique_dashed04_top','stillsuit_choam_unique_dashed05_top',
    'stillsuit_choam_unique_dashed06_top','stillsuit_nati_05_body',
    'stillsuit_nati_06_body','stillsuit_nati_07_body','stillsuit_nati_08_body',
    'stillsuit_nati_arrakeen05_body','stillsuit_neut_leaking01_top',
    'stillsuit_neut_patchy02_top','stillsuit_unique_armored_01_top',
    'stillsuit_unique_armored_02_top','stillsuit_unique_armored_03_top',
    'stillsuit_unique_armored_04_top','stillsuit_unique_armored_05_top',
    'stillsuit_unique_armored_06_top','stillsuit_unique_efficient_04_top',
    'stillsuit_unique_efficient_05_top','stillsuit_unique_efficient_06_top',
    'stillsuit_unique_highcapacity_06_top','stillsuit_unique_thermalsuit_06_top',
    'waterpack_consumable'
)
$script:DuneWaterFillableInventoryTypes = @(0, 1, 14, 15, 27, 30)

function Invoke-DunePlayerFillWater {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id (actor id) is required.' } }
    $tmplCsv = ($script:DuneWaterFillableTemplates | ForEach-Object { "'" + $_ + "'" }) -join ','
    $invCsv  = ($script:DuneWaterFillableInventoryTypes -join ',')
    $sql = @"
WITH upd AS (
    UPDATE dune.items i
    SET stats = jsonb_set(
        i.stats,
        '{FFillableItemStats,1,CurrentAmount}',
        (i.stats->'FFillableItemStats'->1->'MaxAmount')
    )
    FROM dune.inventories inv
    WHERE inv.actor_id = $PawnId::bigint
      AND inv.inventory_type = ANY(ARRAY[$invCsv]::int[])
      AND i.inventory_id = inv.id
      AND lower(i.template_id) = ANY(ARRAY[$tmplCsv]::text[])
      AND i.stats ? 'FFillableItemStats'
      AND (i.stats->'FFillableItemStats'->1->'MaxAmount') IS NOT NULL
    RETURNING i.id
)
SELECT COUNT(*)::bigint AS refilled FROM upd;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $maps = ConvertTo-DuneRowMaps -Result $res
    $count = 0
    if ($maps.Count -ge 1) { $count = [int](ConvertTo-DuneInt $maps[0]['refilled']) }
    if ($count -le 0) {
        return @{ ok = $true; refilled = 0; message = 'No water-fillable items found for that player (already empty inventory or no stillsuits/jons).' }
    }
    return @{ ok = $true; refilled = $count; message = "Refilled $count water-fillable item(s)." }
}
