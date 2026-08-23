# PlayersAdmin.ps1 — v11.5.9 player admin extras ported from the reference implementation.
# Covers §2 currency writes + §7 delete-account + shared helpers
# (faction tables, char-XP table, offline check, raw funcom-id lookup).
#
# Style mirrors lib/GameplayPlayers.ps1: every Invoke-DunePlayer* takes -Ip
# and returns @{ ok=$true|$false; message; ... }. Routes wrap via
# Invoke-DunePlayerWriteRoute from routes/GameplayPlayers.ps1.

# ----- Common helpers ------------------------------------------------------

# accounts."user" string — used by delete-account.
function Get-DuneRawFuncomId {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $sql = "SELECT ""user"" AS funcom FROM dune.accounts WHERE id = $AccountId::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $false; error = "rawFuncomID: $($r.error)" } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $false; error = "No account with id $AccountId." } }
    return @{ ok = $true; funcom_id = [string]$maps[0]['funcom'] }
}

# checkPlayerOffline(pawn) — nil player_state row is treated as offline.
function Test-DunePlayerOffline {
    param([string]$Ip, [long]$PawnId)
    $sql = "SELECT online_status::text AS status FROM dune.player_state WHERE player_pawn_id = $PawnId::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $true; reason = $null } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $true; reason = $null } }
    $status = [string]$maps[0]['status']
    if ($status -eq 'LoggingOut') {
        return @{ ok = $false; reason = "player is mid-logout - the pod still owns their state in memory and will flush on logout, overwriting any DB write. Grace timer is ~30s on Hagga / Arrakeen / Harkonnen / etc., ~5 min in Deep Desert. Wait until status shows Offline, then retry." }
    }
    if ($status -ne 'Offline') {
        return @{ ok = $false; reason = "player is currently $status - log out first, then apply the edit" }
    }
    return @{ ok = $true; reason = $null }
}

# Same offline check as Test-DunePlayerOffline but resolved from the controller
# (actor) id instead of the pawn id. Lets writes that only know the controller
# (e.g. award-intel, which the UI calls with controller_id) still reject an
# online player. A missing player_state row is treated as offline.
function Test-DunePlayerOfflineByController {
    param([string]$Ip, [long]$ControllerId)
    $sql = "SELECT online_status::text AS status FROM dune.player_state WHERE player_controller_id = $ControllerId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $true; reason = $null } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $true; reason = $null } }
    $status = [string]$maps[0]['status']
    if ($status -eq 'LoggingOut') {
        return @{ ok = $false; reason = "player is mid-logout - the pod still owns their state in memory and will flush on logout, overwriting any DB write. Grace timer is ~30s on Hagga / Arrakeen / Harkonnen / etc., ~5 min in Deep Desert. Wait until status shows Offline, then retry." }
    }
    if ($status -ne 'Offline') {
        return @{ ok = $false; reason = "player is currently $status - log out first, then apply the edit" }
    }
    return @{ ok = $true; reason = $null }
}

# Same offline check as Test-DunePlayerOffline but resolved from the account id.
# Lets writes that only know the account (e.g. unlock-trainer) still reject an
# online player. A missing player_state row is treated as offline.
#
# Same offline check as Test-DunePlayerOffline but resolved from the account id.
# Lets writes that only know the account (e.g. unlock-trainer) still reject an
# online player. A missing player_state row is treated as offline.
function Test-DunePlayerOfflineByAccount {
    param([string]$Ip, [long]$AccountId)
    $sql = "SELECT online_status::text AS status FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $true; reason = $null } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $true; reason = $null } }
    $status = [string]$maps[0]['status']
    if ($status -eq 'LoggingOut') {
        return @{ ok = $false; reason = "player is mid-logout — the pod still owns their character in memory and will flush on logout, overwriting skill grants. Grace timer is ~30s on Hagga / Arrakeen / Harkonnen / etc., ~5 min in Deep Desert. Wait until status shows Offline, then retry." }
    }
    if ($status -ne 'Offline') {
        return @{ ok = $false; reason = "player is currently $status — skill grants write to the character's FLevelComponent, which the pod will overwrite when they log out. Have them log out first, then apply." }
    }
    return @{ ok = $true; reason = $null }
}

# ----- Faction reputation tables (verbatim from db.go) ---------------------

$script:DuneFactionTierThresholds = @(
    0, 99, 249, 499, 999, 1999, 2224, 2524, 2899, 3349, 3874,
    4474, 5149, 5899, 6724, 7624, 8599, 9649, 10774, 11974, 12474
)
$script:DuneFactionRepCap = 12474

function Get-DuneFactionDisplayName {
    param([int]$Id)
    switch ($Id) {
        1 { 'Atreides' }
        2 { 'Harkonnen' }
        3 { 'None' }
        4 { 'Smuggler' }
        default { "Faction$Id" }
    }
}

function Get-DuneFactionTierName {
    param([int]$FactionId, [int]$Tier)
    if ($Tier -eq 20) {
        if ($FactionId -eq 1) { return 'Envoy' }
        if ($FactionId -eq 2) { return 'Enforcer' }
    }
    switch ($Tier) {
        0 { 'Outsider' }
        1 { 'Mercenary' }
        2 { 'Recruit' }
        3 { 'Contractor' }
        4 { 'Agent' }
        5 { 'House Operator' }
        default { "Tier $Tier" }
    }
}

function Convert-DuneRepToTier {
    param([int]$Rep)
    $tier = 0
    for ($i = 1; $i -le 20; $i++) {
        if ($Rep -ge $script:DuneFactionTierThresholds[$i]) { $tier = $i }
        else { break }
    }
    return $tier
}

# Updates ReputationAmount inside actors.properties.FactionPlayerComponent.
# {0}=actor_id, {1}=faction name, {2}=rep amount.
$script:DuneFactionComponentRepSqlTpl = @'
UPDATE dune.actors a
SET properties = jsonb_set(
    a.properties,
    ARRAY['FactionPlayerComponent','m_FactionDataArray', (sub.idx - 1)::text, 'ReputationAmount'],
    to_jsonb({2}::int))
FROM (
    SELECT ord AS idx
    FROM dune.actors aa,
         jsonb_array_elements(aa.properties->'FactionPlayerComponent'->'m_FactionDataArray')
             WITH ORDINALITY AS arr(elem, ord)
    WHERE aa.id = {0}::bigint AND elem->'Faction'->>'Name' = '{1}'
) sub
WHERE a.id = {0}::bigint;
'@

function Invoke-DunePlayerGiveFactionRep {
    param([string]$Ip, [long]$ActorId, [int]$FactionId, [int]$Delta)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    if ($FactionId -ne 1 -and $FactionId -ne 2) {
        return @{ ok = $false; error = 'Faction standing can only be set for Atreides or Harkonnen.' }
    }
    # actor_id here is the player_controller_id (webui sends p.controller_id).
    $accSql = "SELECT COALESCE(account_id, 0)::text AS aid FROM dune.player_state WHERE player_controller_id = $ActorId::bigint LIMIT 1;"
    $ar = Invoke-DuneSqlQuery -Ip $Ip -Sql $accSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $ar.ok) { return @{ ok = $false; error = "lookup account: $($ar.error)" } }
    $amaps = ConvertTo-DuneRowMaps -Result $ar
    $accountID = if ($amaps.Count -ge 1) { [int64](ConvertTo-DuneInt $amaps[0]['aid']) } else { 0 }
    if ($accountID -le 0) { return @{ ok = $false; error = "no account for controller $ActorId." } }

    $aligned = Get-DunePlayerAlignedFaction -Ip $Ip -ControllerId $ActorId

    # Cross-faction case is the only real problem: switching factions mid-stream
    # would leave the old faction's tags / journey-node state behind. Force a
    # Reset Faction first so the switch goes through the recruitment ceremony
    # cleanly on the next Give Faction Rep call.
    if ($aligned -ne 0 -and $aligned -ne $FactionId) {
        $an = Get-DuneFactionDisplayName $aligned
        return @{ ok = $false; error = "This character is already a member of $an. Use Players -> Progression -> Reset Faction first, then set the standing again." }
    }

    if ($aligned -eq $FactionId) {
        # Already in the target faction — this is a delta bump on an existing
        # membership. Read current rep, add Delta (allowing negative for a
        # tactical drop), clamp to [0..cap], then write BOTH the reputation
        # table and the runtime-read FactionPlayerComponent so the change is
        # visible on next login (matches Reset Faction's dual-write pattern).
        # No journey-node / tag ceremony — those are already applied.
        $factionName = Get-DuneFactionDisplayName $FactionId
        $curSql = "SELECT COALESCE(reputation_amount, 0)::text AS rep FROM dune.player_faction_reputation WHERE actor_id = $ActorId::bigint AND faction_id = $FactionId::smallint LIMIT 1;"
        $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $curSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if (-not $cr.ok) { return @{ ok = $false; error = "lookup current rep: $($cr.error)" } }
        $cmaps = ConvertTo-DuneRowMaps -Result $cr
        $current = if ($cmaps.Count -ge 1) { [int](ConvertTo-DuneInt $cmaps[0]['rep']) } else { 0 }
        $newRep = $current + $Delta
        if ($newRep -lt 0) { $newRep = 0 }
        if ($newRep -gt $script:DuneFactionRepCap) { $newRep = $script:DuneFactionRepCap }
        $compSql = Get-DuneFactionComponentUpsertSql -ActorId $ActorId -FactionName $factionName -Rep $newRep
        $tx = @"
BEGIN;
SELECT dune.set_player_faction_reputation($ActorId::bigint, $FactionId::smallint, $newRep::integer);
$compSql
COMMIT;
"@
        $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $tx -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r.ok) {
            Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
            return @{ ok = $false; error = "give-faction-rep tx: $($r.error)" }
        }
        $tier = Convert-DuneRepToTier $newRep
        $tierName = Get-DuneFactionTierName $FactionId $tier
        return @{
            ok = $true
            faction = $factionName; faction_id = $FactionId
            rep = $newRep; previous_rep = $current; delta = ($newRep - $current)
            tier = $tier; tier_name = $tierName
            controller_id = $ActorId
            message = "Adjusted $factionName rep by $($newRep - $current) ($current -> $newRep, tier $tier / $tierName) - takes effect on next login."
        }
    }

    # Unaligned: establish full membership at the requested standing (Delta from 0).
    $newRep = $Delta
    if ($newRep -lt 0) { $newRep = 0 }
    if ($newRep -gt $script:DuneFactionRepCap) { $newRep = $script:DuneFactionRepCap }
    return Invoke-DuneEstablishFactionMembership -Ip $Ip -ControllerId $ActorId -AccountId $accountID -FactionId $FactionId -Rep $newRep
}

# ----- Set Faction Tier ----------------------------------------------------
function Invoke-DunePlayerSetFactionTier {
    param([string]$Ip, [long]$ActorId, [int]$FactionId, [int]$Tier)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    if ($Tier -lt 0 -or $Tier -gt 20) { return @{ ok = $false; error = 'tier must be 0..20.' } }
    if ($FactionId -ne 1 -and $FactionId -ne 2) {
        return @{ ok = $false; error = 'Faction standing can only be set for Atreides or Harkonnen.' }
    }
    $accSql = "SELECT COALESCE(account_id, 0)::text AS aid FROM dune.player_state WHERE player_controller_id = $ActorId::bigint LIMIT 1;"
    $ar = Invoke-DuneSqlQuery -Ip $Ip -Sql $accSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $ar.ok) { return @{ ok = $false; error = "lookup account: $($ar.error)" } }
    $amaps = ConvertTo-DuneRowMaps -Result $ar
    $accountID = if ($amaps.Count -ge 1) { [int64](ConvertTo-DuneInt $amaps[0]['aid']) } else { 0 }
    if ($accountID -le 0) { return @{ ok = $false; error = "no account for controller $ActorId." } }

    $aligned = Get-DunePlayerAlignedFaction -Ip $Ip -ControllerId $ActorId

    if ($aligned -ne 0 -and $aligned -ne $FactionId) {
        $an = Get-DuneFactionDisplayName $aligned
        return @{ ok = $false; error = "This character is already a member of $an. Use Players -> Progression -> Reset Faction first, then set the tier again." }
    }

    $rep = $script:DuneFactionTierThresholds[$Tier]
    if ($Tier -gt 0) { $rep = $rep + 1 }

    if ($aligned -eq $FactionId) {
        # Already in the target faction — Set Faction Tier is an absolute
        # write, so just update the rep table + FactionPlayerComponent to the
        # tier threshold. No recruitment ceremony (nodes / tags / alignment
        # are already applied).
        $factionName = Get-DuneFactionDisplayName $FactionId
        $compSql = Get-DuneFactionComponentUpsertSql -ActorId $ActorId -FactionName $factionName -Rep $rep
        $tx = @"
BEGIN;
SELECT dune.set_player_faction_reputation($ActorId::bigint, $FactionId::smallint, $rep::integer);
$compSql
COMMIT;
"@
        $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $tx -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r.ok) {
            Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
            return @{ ok = $false; error = "set-faction-tier tx: $($r.error)" }
        }
        $tierName = Get-DuneFactionTierName $FactionId $Tier
        return @{
            ok = $true
            faction = $factionName; faction_id = $FactionId
            rep = $rep; tier = $Tier; tier_name = $tierName
            controller_id = $ActorId
            message = "Set $factionName tier to $Tier ($tierName), rep $rep - takes effect on next login."
        }
    }

    return Invoke-DuneEstablishFactionMembership -Ip $Ip -ControllerId $ActorId -AccountId $accountID -FactionId $FactionId -Rep $rep
}

# ----- Landsraad scrip (auto-resolve non-Solari currency) ------------------
#
# The game's virtual-currency catalog is a fixed enum: id 0 = Solaris,
# id 1 = Landsraad Scrip. dune.get_solaris_id() returns 0, and there is no
# matching get_landsraad_scrip_id() routine in the DB, so we resolve scrip by
# (a) scanning existing non-Solaris balances and (b) falling back to the
# documented default of 1 when the table has no scrip rows yet (fresh server,
# no player has earned scrip). The override parameter still wins.

$script:DuneScripCurrencyIdCache = $null
$script:DuneScripCurrencyIdDefault = 1

function Resolve-DuneScripCurrencyId {
    param([string]$Ip)
    if ($null -ne $script:DuneScripCurrencyIdCache) { return $script:DuneScripCurrencyIdCache }
    $sql = @'
SELECT currency_id, COALESCE(SUM(balance), 0) AS total
FROM dune.player_virtual_currency_balances
WHERE currency_id <> dune.get_solaris_id()
GROUP BY currency_id
ORDER BY total DESC, currency_id;
'@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 50 -TimeoutSec 15
    if (-not $res.ok) {
        return $script:DuneScripCurrencyIdDefault
    }
    $rows = ConvertTo-DuneRowMaps -Result $res
    if ($rows.Count -eq 0) {
        return $script:DuneScripCurrencyIdDefault
    }
    if ($rows.Count -eq 1) {
        $id = [int](ConvertTo-DuneInt $rows[0]['currency_id'])
        $script:DuneScripCurrencyIdCache = $id
        return $id
    }
    return $null
}

function Invoke-DunePlayerGiveScrip {
    param([string]$Ip, [long]$ActorId, [long]$Delta, [int]$CurrencyIdOverride = 0)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $currencyId = if ($CurrencyIdOverride -gt 0) { $CurrencyIdOverride } else { Resolve-DuneScripCurrencyId -Ip $Ip }
    if ($null -eq $currencyId) {
        return @{ ok = $false; error = 'Could not auto-resolve scrip currency id (2+ non-Solaris balances on this server). Pass currency_id explicitly.' }
    }
    $sql = "SELECT dune.adjust_player_virtual_currency_balance($ActorId::bigint, $currencyId::smallint, $Delta::bigint);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $balSql = "SELECT balance FROM dune.player_virtual_currency_balances WHERE player_controller_id = $ActorId::bigint AND currency_id = $currencyId::smallint;"
    $bal = Invoke-DuneSqlQuery -Ip $Ip -Sql $balSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $balance = $null
    if ($bal.ok) {
        $maps = ConvertTo-DuneRowMaps -Result $bal
        if ($maps.Count -ge 1) { $balance = [int64](ConvertTo-DuneInt $maps[0]['balance']) }
    }
    return @{
        ok = $true
        message = "Added $Delta scrip (currency $currencyId) to player $ActorId - new balance $balance."
        balance = $balance; currency_id = $currencyId
    }
}

# ----- Base water ---------------------------------------------------------
#
# Cisterns are map-owned world entities. A write made while a map pod is live
# gets overwritten when that pod next saves or shuts down. The durable sequence
# is therefore backup -> stop BG -> write -> verify -> start BG. This was
# field-proven against the in-game cistern UI.
#
# Scope is either one selected player's rank-1-owned totems or every rank-1
# owner. Match the three exact cistern classes because blood-water extractors
# and windtraps also carry an FWaterStorageComponent but must not be filled.

$script:DuneBaseWaterFillRunning = $false

function New-DunePlayerBaseCisternCteSql {
    param([long]$ControllerId, [switch]$AllPlayers)
    if (-not $AllPlayers -and $ControllerId -le 0) { throw 'controller_id is required.' }
    $ownerWhere = if ($AllPlayers) {
        'rank = 1'
    } else {
        "player_id = $ControllerId::bigint`n    AND rank = 1"
    }

    return @"
WITH player_totems AS (
  SELECT player_id AS controller_id,
         permission_actor_id AS totem_id
  FROM dune.permission_actor_rank
  WHERE $ownerWhere
),
player_cisterns AS (
  SELECT DISTINCT ON (afe.entity_id)
         pt.controller_id,
         a.id AS actor_id,
         a.class,
         afe.entity_id,
         CASE a.class
           WHEN '/Game/Dune/Systems/Building/Pieces/BP_WaterCistern.BP_WaterCistern_C' THEN 5000
           WHEN '/Game/Dune/Systems/Building/Pieces/BP_MediumWaterCistern.BP_MediumWaterCistern_C' THEN 25000
           WHEN '/Game/Dune/Systems/Building/Pieces/BP_LargeWaterCistern.BP_LargeWaterCistern_C' THEN 100000
         END AS capacity,
         COALESCE((fe.components #>> '{FWaterStorageComponent,1,m_WaterStored}')::int, 0) AS current_water
  FROM player_totems pt
  JOIN dune.actor_fgl_entities totem_fgl
    ON totem_fgl.actor_id = pt.totem_id
   AND totem_fgl.slot_name = 'Actor'
  JOIN dune.placeables p
    ON p.owner_entity_id = totem_fgl.entity_id
  JOIN dune.actors a
    ON a.id = p.id
  JOIN dune.actor_fgl_entities afe
    ON afe.actor_id = a.id
   AND afe.slot_name = 'Actor'
  JOIN dune.fgl_entities fe
    ON fe.entity_id = afe.entity_id
   AND fe.components ? 'FWaterStorageComponent'
  WHERE a.class IN (
    '/Game/Dune/Systems/Building/Pieces/BP_WaterCistern.BP_WaterCistern_C',
    '/Game/Dune/Systems/Building/Pieces/BP_MediumWaterCistern.BP_MediumWaterCistern_C',
    '/Game/Dune/Systems/Building/Pieces/BP_LargeWaterCistern.BP_LargeWaterCistern_C'
  )
  ORDER BY afe.entity_id, pt.controller_id
)
"@
}

function Get-DunePlayerBaseCisternSummary {
    param([string]$Ip, [long]$ControllerId, [switch]$AllPlayers)
    if (-not $AllPlayers -and $ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }

    $sql = (New-DunePlayerBaseCisternCteSql -ControllerId $ControllerId -AllPlayers:$AllPlayers) + @"
SELECT COUNT(*)::text AS total,
       COUNT(DISTINCT controller_id)::text AS owner_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_WaterCistern.BP_WaterCistern_C')::text AS small_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_MediumWaterCistern.BP_MediumWaterCistern_C')::text AS medium_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_LargeWaterCistern.BP_LargeWaterCistern_C')::text AS large_n,
       COUNT(*) FILTER (WHERE current_water >= capacity)::text AS full_n,
       COALESCE(SUM(GREATEST(capacity - current_water, 0)), 0)::text AS missing_water
FROM player_cisterns;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "Base cistern read failed: $($r.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    if ($rows.Count -lt 1) { return @{ ok = $false; error = 'Base cistern read returned no summary row.' } }
    $row = $rows[0]
    return @{
        ok           = $true
        controllerId = $ControllerId
        allPlayers   = [bool]$AllPlayers
        owners       = [int](ConvertTo-DuneInt $row['owner_n'])
        total        = [int](ConvertTo-DuneInt $row['total'])
        small        = [int](ConvertTo-DuneInt $row['small_n'])
        medium       = [int](ConvertTo-DuneInt $row['medium_n'])
        large        = [int](ConvertTo-DuneInt $row['large_n'])
        full         = [int](ConvertTo-DuneInt $row['full_n'])
        missingWater = [int64](ConvertTo-DuneInt $row['missing_water'])
    }
}

function Set-DunePlayerBaseCisternsFull {
    param([string]$Ip, [long]$ControllerId, [switch]$AllPlayers)
    if (-not $AllPlayers -and $ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }

    $sql = (New-DunePlayerBaseCisternCteSql -ControllerId $ControllerId -AllPlayers:$AllPlayers) + @"
, updated AS (
  UPDATE dune.fgl_entities fe
  SET components = jsonb_set(
    fe.components,
    '{FWaterStorageComponent,1,m_WaterStored}',
    to_jsonb(pc.capacity),
    false
  )
  FROM player_cisterns pc
  WHERE fe.entity_id = pc.entity_id
  RETURNING pc.controller_id, pc.actor_id, pc.class, pc.capacity,
            (fe.components #>> '{FWaterStorageComponent,1,m_WaterStored}')::int AS water
)
SELECT COUNT(*)::text AS total,
       COUNT(DISTINCT controller_id)::text AS owner_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_WaterCistern.BP_WaterCistern_C')::text AS small_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_MediumWaterCistern.BP_MediumWaterCistern_C')::text AS medium_n,
       COUNT(*) FILTER (WHERE class = '/Game/Dune/Systems/Building/Pieces/BP_LargeWaterCistern.BP_LargeWaterCistern_C')::text AS large_n,
       COUNT(*) FILTER (WHERE water = capacity)::text AS verified_n
FROM updated;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 45
    if (-not $r.ok) { return @{ ok = $false; error = "Base cistern write failed: $($r.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    if ($rows.Count -lt 1) { return @{ ok = $false; error = 'Base cistern write returned no summary row.' } }
    $row = $rows[0]
    $total = [int](ConvertTo-DuneInt $row['total'])
    $verified = [int](ConvertTo-DuneInt $row['verified_n'])
    if ($total -ne $verified) {
        return @{ ok = $false; error = "Base cistern verification failed: $verified of $total rows reached capacity." }
    }
    return @{
        ok       = $true
        owners   = [int](ConvertTo-DuneInt $row['owner_n'])
        total    = $total
        small    = [int](ConvertTo-DuneInt $row['small_n'])
        medium   = [int](ConvertTo-DuneInt $row['medium_n'])
        large    = [int](ConvertTo-DuneInt $row['large_n'])
        verified = $verified
    }
}

function Invoke-DuneBaseWaterBgCommand {
    param(
        [string]$Ip,
        [Parameter(Mandatory)][ValidateSet('backup','stop','start')][string]$Command
    )
    if (-not (Get-Command Invoke-DuneBackupShell -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; error = 'Battlegroup shell helper is unavailable.' }
    }
    $timeout = if ($Command -eq 'backup') { 700 } elseif ($Command -eq 'stop') { 180 } else { 120 }
    try {
        $r = Invoke-DuneBackupShell -Ip $Ip -Script "/home/dune/.dune/bin/battlegroup $Command" -TimeoutSec $timeout
    } catch {
        return @{ ok = $false; error = "Battlegroup $Command failed: $($_.Exception.Message)" }
    }
    if ($null -eq $r -or [int]$r.rc -ne 0) {
        $rc = if ($null -eq $r) { -1 } else { [int]$r.rc }
        $out = if ($null -eq $r) { '' } else { ([string]$r.out).Trim() }
        return @{ ok = $false; error = "Battlegroup $Command exited $rc. $out".Trim() }
    }
    $out = ([string]$r.out).Trim()
    $backupPath = ''
    if ($Command -eq 'backup') {
        $m = [regex]::Match($out, 'Backup file \(on this host\):\s*(\S+)')
        if ($m.Success) { $backupPath = $m.Groups[1].Value }
    }
    return @{ ok = $true; command = $Command; output = $out; backupPath = $backupPath }
}

function Invoke-DuneFillPlayerBaseWaterCore {
    param([string]$Ip, [long]$ControllerId, [switch]$AllPlayers)

    $before = Get-DunePlayerBaseCisternSummary -Ip $Ip -ControllerId $ControllerId -AllPlayers:$AllPlayers
    if (-not $before.ok) { return $before }
    if ($before.total -le 0) {
        $scope = if ($AllPlayers) { 'any player-owned bases' } else { "player $ControllerId's owned bases" }
        return @{ ok = $false; error = "No supported cisterns were found on $scope." }
    }

    $backup = Invoke-DuneBaseWaterBgCommand -Ip $Ip -Command 'backup'
    if (-not $backup.ok) {
        return @{ ok = $false; error = "No changes made because the safety backup failed. $($backup.error)" }
    }

    $stop = Invoke-DuneBaseWaterBgCommand -Ip $Ip -Command 'stop'
    if (-not $stop.ok) {
        $recoveryStart = Invoke-DuneBaseWaterBgCommand -Ip $Ip -Command 'start'
        $recoveryMessage = if ($recoveryStart.ok) {
            'A recovery start command was launched.'
        } else {
            "$($recoveryStart.error) Start the battlegroup manually."
        }
        return @{
            ok         = $false
            error      = "No cisterns changed because the battlegroup did not stop cleanly. $($stop.error) $recoveryMessage"
            backupPath = $backup.backupPath
        }
    }

    $fill = $null
    $verify = $null
    $operationError = ''
    $start = $null
    try {
        $fill = Set-DunePlayerBaseCisternsFull -Ip $Ip -ControllerId $ControllerId -AllPlayers:$AllPlayers
        if (-not $fill.ok) {
            $operationError = $fill.error
        } else {
            $verify = Get-DunePlayerBaseCisternSummary -Ip $Ip -ControllerId $ControllerId -AllPlayers:$AllPlayers
            if (-not $verify.ok) {
                $operationError = $verify.error
            } elseif ($verify.total -ne $fill.total -or $verify.full -ne $verify.total) {
                $operationError = "Post-write verification failed: $($verify.full) of $($verify.total) cisterns are full."
            }
        }
    } catch {
        $operationError = "Base cistern operation failed: $($_.Exception.Message)"
    } finally {
        $start = Invoke-DuneBaseWaterBgCommand -Ip $Ip -Command 'start'
    }

    if (-not $start.ok) {
        $prefix = if ($operationError) { "$operationError " } else { "Cisterns were filled, but " }
        return @{
            ok         = $false
            error      = "$prefix$($start.error) Start the battlegroup manually."
            backupPath = $backup.backupPath
            fill       = $fill
        }
    }
    if ($operationError) {
        return @{
            ok         = $false
            error      = "$operationError The battlegroup start command was launched."
            backupPath = $backup.backupPath
        }
    }

    return @{
        ok         = $true
        controller = $ControllerId
        allPlayers = [bool]$AllPlayers
        owners     = $fill.owners
        total      = $fill.total
        small      = $fill.small
        medium     = $fill.medium
        large      = $fill.large
        backupPath = $backup.backupPath
        message    = if ($AllPlayers) {
            "Filled $($fill.total) base cistern(s) across $($fill.owners) owner(s) ($($fill.small) small, $($fill.medium) medium, $($fill.large) large). Safety backup completed; battlegroup start launched."
        } else {
            "Filled $($fill.total) owned base cistern(s) ($($fill.small) small, $($fill.medium) medium, $($fill.large) large). Safety backup completed; battlegroup start launched."
        }
    }
}

function Invoke-DuneFillPlayerBaseWater {
    param([string]$Ip, [long]$ControllerId, [switch]$AllPlayers)
    if (-not $AllPlayers -and $ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    if ($script:DuneBaseWaterFillRunning) {
        return @{ ok = $false; error = 'Another Fill Base Water operation is already running.' }
    }
    $script:DuneBaseWaterFillRunning = $true
    try {
        return Invoke-DuneFillPlayerBaseWaterCore -Ip $Ip -ControllerId $ControllerId -AllPlayers:$AllPlayers
    } finally {
        $script:DuneBaseWaterFillRunning = $false
    }
}



# ----- Character XP table (verbatim from db.go) ----------------------------

$script:DuneMaxCharXp = 344440L
# Most intel a character can hold (cumulative through max level). Mirrors the
# reference tool's maxIntelPoints headroom clamp (#208).
$script:DuneMaxIntelPoints = 2779
$script:DuneCumulativeXpByLevel = @(
    0, 40, 215, 440, 740, 1240, 1790, 2390, 2990, 3590, 4190,
    4790, 5390, 5990, 6590, 7190, 7790, 8390, 8990, 9590, 10190,
    10790, 11390, 11990, 12590, 13190, 13790, 14390, 14990, 15590, 16190,
    16790, 17390, 17990, 18590, 19190, 19790, 20390, 20990, 21590, 22190,
    22790, 23390, 23990, 24590, 25190, 25790, 26390, 26990, 27590, 28190,
    28790, 29390, 29990, 30590, 31190, 31790, 32390, 32990, 33590, 34190,
    34790, 35390, 35990, 36590, 37190, 37790, 38390, 38990, 39590, 40190,
    40790, 41390, 41990, 42590, 43190, 43790, 44390, 44990, 45590, 46190,
    46790, 47390, 47990, 48590, 49190, 49790, 50390, 50990, 51590, 52190,
    52790, 53390, 53990, 54590, 55190, 55790, 56390, 56990, 57590, 58190,
    58840, 59490, 60140, 60790, 61440, 62090, 62740, 63390, 64040, 64690,
    65340, 65990, 66640, 67290, 67940, 68590, 69240, 69890, 70540, 71190,
    71840, 72490, 73140, 73790, 74440, 75090, 75740, 76391, 77044, 77699,
    78357, 79018, 79683, 80353, 81030, 81714, 82407, 83110, 83825, 84554,
    85298, 86060, 86842, 87646, 88475, 89332, 90220, 91141, 92100, 93099,
    94143, 95235, 96380, 97582, 98845, 100175, 101576, 103054, 104614, 106263,
    108006, 109849, 111799, 113862, 116046, 118358, 120806, 123397, 126139, 129041,
    132112, 135360, 138795, 142426, 146263, 150316, 154596, 159114, 163880, 168906,
    174203, 179784, 185661, 191846, 198353, 205195, 212385, 219938, 227868, 236190,
    244918, 254069, 263657, 273700, 284213, 295214, 306719, 318746, 331314, 344440
)

function Convert-DuneXpToLevel {
    param([long]$Xp)
    if ($Xp -le 0) { return 0 }
    $lo = 1; $hi = 200
    while ($lo -lt $hi) {
        $mid = [int](($lo + $hi + 1) / 2)
        if ($script:DuneCumulativeXpByLevel[$mid] -le $Xp) { $lo = $mid }
        else { $hi = $mid - 1 }
    }
    return $lo
}

function Get-DuneIntelAtLevel {
    param([int]$Level)
    if ($Level -le 0) { return 0 }
    if ($Level -eq 1) { return 4 }
    if ($Level -le 3) { return 4 + ($Level - 1) * 2 }
    if ($Level -le 15) { return 8 + ($Level - 3) * 3 }
    if ($Level -le 30) { return 44 + ($Level - 15) * 5 }
    if ($Level -le 50) { return 119 + ($Level - 30) * 10 }
    if ($Level -le 69) { return 319 + ($Level - 50) * 20 }
    if ($Level -le 85) { return 699 + ($Level - 69) * 30 }
    if ($Level -le 125) { return 1179 + ($Level - 85) * 40 }
    return 2779
}

function Get-DuneKeystoneSpBonus {
    param([int[]]$Ids)
    if (-not $Ids) { return 0 }
    $bonus = 0
    foreach ($id in $Ids) {
        if ($id -eq 7 -or $id -eq 14 -or $id -eq 21) { $bonus++ }
    }
    return $bonus
}

# ----- Character XP / Intel cascade ---------------------------------------
# the reference implementation keeps this strictly OFFLINE — the in-memory FLevelComponent
# overwrites the DB row at logout, so changes applied to an online char get
# silently reverted. We mirror that contract.

function Get-DunePlayerLevelComponentRow {
    param([string]$Ip, [long]$ActorId)
    $sql = @"
SELECT fge.entity_id::text AS entity_id,
       fge.components->'FLevelComponent'->1->>'TotalXPEarned' AS xp_text,
       fge.components->'FLevelComponent'->1->>'UnspentSkillPoints' AS sp_unspent_text,
       fge.components->'FLevelComponent'->1->>'TotalSkillPoints' AS sp_total_text
FROM dune.actor_fgl_entities afe
JOIN dune.fgl_entities fge ON fge.entity_id = afe.entity_id
WHERE afe.actor_id = $ActorId::bigint AND afe.slot_name = 'DuneCharacter'
LIMIT 1;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $false; error = "No DuneCharacter FLevelComponent found for actor $ActorId." } }
    $row = $maps[0]
    $unspent = [int](ConvertTo-DuneInt $row['sp_unspent_text'])
    $total   = [int](ConvertTo-DuneInt $row['sp_total_text'])
    return @{
        ok = $true
        entity_id = [string]$row['entity_id']
        xp = [int64](ConvertTo-DuneInt $row['xp_text'])
        sp_spent = [int]($total - $unspent)
        sp_total = $total
        sp_unspent = $unspent
    }
}

function Get-DunePlayerControllerFromPawn {
    param([string]$Ip, [long]$PawnId)
    $sql = "SELECT player_controller_id::text AS cid FROM dune.player_state WHERE player_pawn_id = $PawnId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return $null }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return $null }
    return [int64](ConvertTo-DuneInt $maps[0]['cid'])
}

function Get-DunePlayerPawnFromController {
    param([string]$Ip, [long]$ControllerId)
    $sql = "SELECT player_pawn_id::text AS pid FROM dune.player_state WHERE player_controller_id = $ControllerId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return $null }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return $null }
    return [int64](ConvertTo-DuneInt $maps[0]['pid'])
}

function Get-DunePlayerKeystoneIds {
    param([string]$Ip, [long]$ActorId)
    $sql = "SELECT COALESCE(properties->'KeystonePlayerComponent'->'m_PurchasedKeystoneIDs', '[]'::jsonb) AS ids FROM dune.actors WHERE id = $ActorId::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @() }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @() }
    $raw = [string]$maps[0]['ids']
    if (-not $raw) { return @() }
    try {
        $arr = $raw | ConvertFrom-Json
        if ($null -eq $arr) { return @() }
        return @($arr | ForEach-Object { [int]$_ })
    } catch { return @() }
}

function Invoke-DunePlayerGetCharXp {
    param([string]$Ip, [long]$ActorId)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $row = Get-DunePlayerLevelComponentRow -Ip $Ip -ActorId $ActorId
    if (-not $row.ok) { return @{ ok = $false; error = $row.error } }
    $lvl = Convert-DuneXpToLevel $row.xp
    return @{
        ok = $true
        actor_id = $ActorId
        xp = $row.xp
        level = $lvl
        skill_points_spent = $row.sp_spent
        skill_points_total = $row.sp_total
    }
}

# Cascade: writes XP + TotalSkillPoints + UnspentSkillPoints into
# FLevelComponent[1], and Intel (TechKnowledgePoints) into actors.properties.
# {0}=entity_id {1}=xp {2}=total_sp {3}=unspent_sp.
$script:DuneAwardCharXpFglSqlTpl = @'
UPDATE dune.fgl_entities
SET components = jsonb_set(
    jsonb_set(
        jsonb_set(components,
            '{{FLevelComponent,1,TotalXPEarned}}', to_jsonb({1}::bigint)),
        '{{FLevelComponent,1,TotalSkillPoints}}', to_jsonb({2}::int)),
    '{{FLevelComponent,1,UnspentSkillPoints}}', to_jsonb({3}::int))
WHERE entity_id = {0}::bigint;
'@

# {0}=actor_id {1}=intel
# COALESCE + jsonb_build_object so a missing TechKnowledgePlayerComponent parent
# is created (plain jsonb_set leaves the JSON unchanged when the parent path is
# absent, which silently no-ops the write). Existing sibling keys are preserved.
$script:DuneSetIntelSqlTpl = @'
UPDATE dune.actors
SET properties = jsonb_set(
    COALESCE(properties, '{{}}'::jsonb),
    '{{TechKnowledgePlayerComponent}}',
    COALESCE(properties->'TechKnowledgePlayerComponent', '{{}}'::jsonb)
        || jsonb_build_object('m_TechKnowledgePoints', to_jsonb({1}::int)))
WHERE id = {0}::bigint;
'@

function Invoke-DunePlayerAwardCharXp {
    param(
        [string]$Ip,
        [long]$PawnId,
        [long]$XpDelta
    )
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }

    # All character progression data - FLevelComponent (XP/SP), KeystonePlayerComponent,
    # and TechKnowledgePlayerComponent (intel) - lives on the player's PAWN actor (the
    # DuneCharacter), NOT the controller. The reference tool keys cmdAwardCharXP entirely
    # on the pawn (readCharXPState / fetchKeystoneBonusForPawn / intel update). Writing to
    # the controller reads an empty FLevelComponent and lands the grant on a junk actor the
    # game never reads, so offline char-xp silently no-ops.
    $cur = Get-DunePlayerLevelComponentRow -Ip $Ip -ActorId $PawnId
    if (-not $cur.ok) { return @{ ok = $false; error = $cur.error } }

    $newXp = $cur.xp + $XpDelta
    if ($newXp -lt 0) { $newXp = 0 }
    if ($newXp -gt $script:DuneMaxCharXp) { $newXp = $script:DuneMaxCharXp }

    $newLevel = Convert-DuneXpToLevel $newXp
    $keystoneIds = Get-DunePlayerKeystoneIds -Ip $Ip -ActorId $PawnId
    $keystoneBonus = Get-DuneKeystoneSpBonus -Ids $keystoneIds
    $totalSp = $newLevel + $keystoneBonus
    $unspent = $totalSp - $cur.sp_spent
    if ($unspent -lt 0) { $unspent = 0 }
    $newIntel = Get-DuneIntelAtLevel $newLevel

    $sqlFgl = [string]::Format($script:DuneAwardCharXpFglSqlTpl, $cur.entity_id, $newXp, $totalSp, $unspent)
    $r1 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sqlFgl -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r1.ok) { return @{ ok = $false; error = "update FLevelComponent: $($r1.error)" } }

    $sqlIntel = [string]::Format($script:DuneSetIntelSqlTpl, $PawnId, $newIntel)
    $r2 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sqlIntel -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r2.ok) { return @{ ok = $false; error = "update Intel: $($r2.error)" } }

    return @{
        ok = $true
        message = "Awarded $XpDelta XP - now $newXp XP / level $newLevel ($totalSp SP, $unspent unspent, intel $newIntel)."
        xp = $newXp; level = $newLevel
        skill_points_total = $totalSp
        skill_points_unspent = $unspent
        intel = $newIntel
    }
}

function Invoke-DunePlayerAwardIntel {
    param(
        [string]$Ip,
        [long]$PawnId,
        [long]$ActorId,
        [int]$IntelDelta
    )
    # Intel (TechKnowledgePlayerComponent.m_TechKnowledgePoints) lives on the
    # player's PAWN actor - the same actor that holds the backpack inventory - NOT
    # the controller. Writing it to the controller creates a junk component the
    # game never reads, so the grant silently no-ops (shows nothing in-game). This
    # matches the reference tool, which keys awardIntel on player_pawn_id, and our
    # own working give-item path, which writes to the pawn. Prefer the pawn id the
    # UI sends; fall back to resolving it from the controller id.
    $pawn = $PawnId
    if ($pawn -le 0 -and $ActorId -gt 0) {
        $pawn = Get-DunePlayerPawnFromController -Ip $Ip -ControllerId $ActorId
    }
    if ($null -eq $pawn -or $pawn -le 0) { return @{ ok = $false; error = 'pawn_id (or actor_id) is required.' } }
    # Reject online players: the game server holds the actor's intel in memory
    # while online and flushes on logout, so a direct DB write here would be
    # silently clobbered (no live RMQ command exists to set tech knowledge).
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $pawn
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }
    $readSql = "SELECT COALESCE((properties->'TechKnowledgePlayerComponent'->>'m_TechKnowledgePoints')::int, 0) AS intel FROM dune.actors WHERE id = $pawn::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $readSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $cur = 0
    if ($r.ok) {
        $maps = ConvertTo-DuneRowMaps -Result $r
        if ($maps.Count -ge 1) { $cur = [int](ConvertTo-DuneInt $maps[0]['intel']) }
    }
    $newIntel = $cur + $IntelDelta
    if ($newIntel -lt 0) { $newIntel = 0 }
    if ($newIntel -gt $script:DuneMaxIntelPoints) { $newIntel = $script:DuneMaxIntelPoints }
    $sql = [string]::Format($script:DuneSetIntelSqlTpl, $pawn, $newIntel)
    $w = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $w.ok) { return @{ ok = $false; error = $w.error } }
    return @{
        ok = $true
        message = "Set Intel to $newIntel (was $cur, delta $IntelDelta) for player $pawn."
        intel = $newIntel
    }
}

# ----- Delete Account (DESTRUCTIVE) --------------------------------------
# ----- Delete Account (matches Funcom's in-game delete + purge) -------------
# Live comparison with Funcom's character purge (2026-07-04) established its
# base behavior: mark encrypted_player_state Deleted and remove the active
# character's rank-1 ownership rows while preserving physical objects.
#
# DST Full Delete adds stricter permission cleanup. It removes every permission
# held by current/historical actors on the account, plus every remaining rank on
# objects where those actors held rank 1. This prevents deleted co-owner actors
# and ownerless objects with retained co-owners from blocking Claim Ownership.
# Physical totems, actors, buildings, accounts, and per-player state persist.
function Invoke-DunePlayerDeleteAccount {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $sql = @"
DO `$`$
DECLARE
    v_account_id bigint := $AccountId;
    v_wiped int := 0;
BEGIN
    -- Step 1: identify every current or historical actor on the account and
    -- each object they own. Including already-Deleted rows repairs permission
    -- residue left by older Full Delete runs.
    WITH deleted_character_actors AS (
        SELECT DISTINCT actor_id
        FROM dune.encrypted_player_state eps
        CROSS JOIN LATERAL unnest(ARRAY[
            eps.player_controller_id,
            eps.player_pawn_id,
            eps.player_state_id
        ]) AS deleted_actor(actor_id)
        WHERE eps.account_id = v_account_id
    ),
    owned_permission_actors AS (
        SELECT DISTINCT par.permission_actor_id
        FROM dune.permission_actor_rank par
        JOIN deleted_character_actors deleted_actor
          ON deleted_actor.actor_id = par.player_id
        WHERE par.rank = 1
    ),
    deleted AS (
        DELETE FROM dune.permission_actor_rank par
        WHERE par.player_id IN (
                  SELECT actor_id FROM deleted_character_actors
              )
           OR par.permission_actor_id IN (
                  SELECT permission_actor_id FROM owned_permission_actors
              )
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_wiped FROM deleted;

    -- Step 2: soft-delete the character via the game's own characterstate
    -- enum. The dune.player_state view filters on Active so this hides the
    -- character from every game query without deleting any rows.
    UPDATE dune.encrypted_player_state
       SET character_state = 'Deleted'::dune.characterstate
     WHERE account_id = v_account_id
       AND character_state = 'Active'::dune.characterstate;
END
`$`$;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{
        ok = $true
        message = "Deleted account $AccountId's character: active character marked Deleted, every permission held by all current/historical account actors removed, and every remaining rank cleared from objects they owned. Former vehicles/bases/fiefs are fully claimable; physical objects persist in the world."
    }
}
