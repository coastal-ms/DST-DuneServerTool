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

    # An already-aligned member must be reset before re-applying standing — otherwise
    # we would stack a fresh recruitment on top of an existing membership.
    $aligned = Get-DunePlayerAlignedFaction -Ip $Ip -ControllerId $ActorId
    if ($aligned -ne 0) {
        $an = Get-DuneFactionDisplayName $aligned
        return @{ ok = $false; error = "This character is already a member of $an. Use Players -> Progression -> Reset Faction first, then set the standing again." }
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
    if ($aligned -ne 0) {
        $an = Get-DuneFactionDisplayName $aligned
        return @{ ok = $false; error = "This character is already a member of $an. Use Players -> Progression -> Reset Faction first, then set the tier again." }
    }

    $rep = $script:DuneFactionTierThresholds[$Tier]
    if ($Tier -gt 0) { $rep = $rep + 1 }
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

# ----- Base water removed -------------------------------------------------
#
# Fill Base Water was investigated for v12.1.2 and removed before release.
# The map pod loads cistern water into RAM on cistern spawn and writes back
# to dune.fgl_entities.components on its periodic save tick, which means
# any DB UPDATE we make to FWaterStorageComponent.m_WaterStored gets
# overwritten before a player ever sees it. We verified end-to-end against
# the live VM: drained four cisterns to 250-331, ran the DB UPDATE to
# 100000, restarted the deepdesert pod, and the pod wrote the old in-RAM
# values straight back to the DB on shutdown. The legacy RMQ
# UpdateAllWaterFillables ServerCommand only refills carried fillables
# (Decker's original complaint), so there is no working path today.
#
# Leaving the placeable->totem->permission_actor_rank chain notes here for
# the next attempt: if a future game build exposes a per-cistern RPC, the
# scope query is permission_actor_rank.player_id=<controller> AND rank=1.



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
       fge.components->'FLevelComponent'->1->>'TotalSkillPointsEarned' AS sp_total_text
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

# Cascade: writes XP + TotalSkillPointsEarned + UnspentSkillPoints into
# FLevelComponent[1], and Intel (TechKnowledgePoints) into actors.properties.
# {0}=entity_id {1}=xp {2}=total_sp {3}=unspent_sp.
$script:DuneAwardCharXpFglSqlTpl = @'
UPDATE dune.fgl_entities
SET components = jsonb_set(
    jsonb_set(
        jsonb_set(components,
            '{{FLevelComponent,1,TotalXPEarned}}', to_jsonb({1}::bigint)),
        '{{FLevelComponent,1,TotalSkillPointsEarned}}', to_jsonb({2}::int)),
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
# Mirrors db.go cmdDeleteAccount: nukes characters, actors, fgl entities,
# RMQ traces, and the accounts row in dependency order.
function Invoke-DunePlayerDeleteAccount {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $resolve = Get-DuneRawFuncomId -Ip $Ip -AccountId $AccountId
    if (-not $resolve.ok) { return @{ ok = $false; error = $resolve.error } }
    $funcom = ConvertTo-DuneSqlString $resolve.funcom_id

    $sql = @"
DO `$`$
DECLARE
    v_account_id bigint := $AccountId;
    v_funcom text := '$funcom';
BEGIN
    -- Ownership cleanup. Three-rule split (runs BEFORE the actor cascade so
    -- permission_actor_id FKs still resolve to the deleted account's rows):
    --
    -- Rule 1: identify every world actor where the deleted account is the
    -- HIGHEST-ranked player (i.e. the owner). Wipe the ENTIRE ACL on those
    -- actors (owner + co-owners + associates), and blank the custom name.
    -- Net effect: those actors are truly ownerless and anyone can Claim
    -- Ownership normally. Old co-owners lose access - the new claimant will
    -- have to re-grant if they want them back.
    --
    -- Rule 2: for every OTHER actor where the deleted account had a rank row
    -- (i.e. deleted account was a co-owner, not owner), remove ONLY the
    -- deleted account's rank row. The real owner + other co-owners keep their
    -- access untouched.
    --
    -- "Highest rank" = the numeric MIN(rank) on the actor. DB ranks are
    -- INVERTED from the game UI: DB rank 1 = game Owner (UI rank 5), DB
    -- rank 2 = game Co-Owner (UI rank 4), higher DB numbers = lesser roles.
    -- If two players tie at the lowest DB rank, both are treated as owners
    -- and the actor's ACL is wiped.

    -- Enumerate rank rows the deleted account owns via any of its actors
    -- (usually the character's controller_id, but this covers any owner-linked
    -- actor id belonging to the account).
    CREATE TEMP TABLE _deleted_ranks ON COMMIT DROP AS
    SELECT par.permission_actor_id AS aid, par.player_id AS pid, par.rank AS r
    FROM dune.permission_actor_rank par
    JOIN dune.actors owner_actor ON owner_actor.id = par.player_id
    WHERE owner_actor.owner_account_id = v_account_id;

    -- Actors where deleted account was the highest-ranked holder.
    CREATE TEMP TABLE _owned_actors ON COMMIT DROP AS
    SELECT DISTINCT dr.aid
    FROM _deleted_ranks dr
    WHERE dr.r = (
        SELECT MIN(rank) FROM dune.permission_actor_rank
        WHERE permission_actor_id = dr.aid
    );

    -- Rule 1: wipe the entire ACL on those owned actors.
    DELETE FROM dune.permission_actor_rank
    WHERE permission_actor_id IN (SELECT aid FROM _owned_actors);

    -- Rule 1 (cont): blank the custom name so the actor renders under its
    -- default class name (##LightOrnithopterChoam etc.) once someone else
    -- claims it.
    DELETE FROM dune.permission_actor
    WHERE actor_id IN (SELECT aid FROM _owned_actors);

    -- Rule 2: on every OTHER actor the deleted account had a rank row for,
    -- remove ONLY the deleted account's row. (The _owned_actors already had
    -- their entire ACL wiped above, so this DELETE only affects co-owner rows
    -- on actors owned by SOMEONE ELSE.)
    DELETE FROM dune.permission_actor_rank par
    USING dune.actors owner_actor
    WHERE par.player_id = owner_actor.id
      AND owner_actor.owner_account_id = v_account_id;

    -- ------------------------------------------------------------------
    -- Per-player state wipes. Every FK that points at either
    -- (a) an actor (usually a controller_id) owned by this account, OR
    -- (b) an encrypted_player_state.id row for a character on this account.
    -- Comprehensive - net effect is the account leaves NO trace behind.
    -- ------------------------------------------------------------------

    -- (a) FKs keyed by actor id (player_id, sender_player_id, player_controller_id, etc.)
    DELETE FROM dune.player_markers                          WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.journey_tracked_cards                    WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.dialogue_met_npcs                        WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.dialogue_taken_nodes                     WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.consumed_per_player_lore                 WHERE actor_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.consumed_temporary_per_player_lore       WHERE actor_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.base_backups                             WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.building_blueprints                      WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.dungeon_completion_players               WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.dune_exchange_orders                     WHERE owner_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.dune_exchange_users                      WHERE owner_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.landsraad_decree_votes                   WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.landsraad_house_rewards                  WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.landsraad_task_player_contributions      WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.landsraad_task_progress_player           WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.overmap_players                          WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.purchased_specialization_keystones       WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.specialization_refund_id                 WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.specialization_tracks                    WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.travel_return_info                       WHERE player_controller_id IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.tutorial_per_player                      WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.vendor_stock_cycle                       WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.vendor_stock_state                       WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.player_faction                           WHERE actor_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.player_faction_reputation                WHERE actor_id             IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.player_virtual_currency_balances         WHERE player_controller_id IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    -- guild / party membership: the deleted account leaves, remaining members are unaffected.
    DELETE FROM dune.guild_invites                            WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id)
                                                                 OR sender_player_id     IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.guild_members                            WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.party_invites                            WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id)
                                                                 OR sender_player_id     IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.party_members                            WHERE player_id            IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);
    DELETE FROM dune.parties                                  WHERE party_leader_id      IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);

    -- (b) FKs keyed by encrypted_player_state.id (character rows)
    DELETE FROM dune.map_areas                                WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.mnemonic_recall                          WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.player_access_codes                      WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.player_respawn_locations                 WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.player_tags                              WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.journey_story_node                       WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.journey_story_node_cooldown              WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.building_favorites                       WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.building_progression                     WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.communinet_player                        WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.communinet_player_channels               WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.recovered_vehicles                       WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);
    DELETE FROM dune.backup_vehicles                          WHERE character_id         IN (SELECT id FROM dune.encrypted_player_state WHERE account_id = v_account_id);

    -- character actors (must run AFTER the per-player wipes above since some
    -- of them join through actors.owner_account_id)
    DELETE FROM dune.actor_fgl_entities afe
    USING dune.actors a
    WHERE afe.actor_id = a.id AND a.owner_account_id = v_account_id;

    DELETE FROM dune.fgl_entities fge
    WHERE fge.entity_id IN (
        SELECT afe.entity_id FROM dune.actor_fgl_entities afe
        JOIN dune.actors a ON a.id = afe.actor_id
        WHERE a.owner_account_id = v_account_id
    );

    DELETE FROM dune.player_state
    WHERE player_pawn_id IN (SELECT id FROM dune.actors WHERE owner_account_id = v_account_id);

    DELETE FROM dune.actors WHERE owner_account_id = v_account_id;

    DELETE FROM dune.accounts WHERE id = v_account_id OR "user" = v_funcom;
END
`$`$;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 120
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; message = "Deleted account $AccountId (funcom $($resolve.funcom_id)) and every trace on the server: characters, world actor ownership (owned actors are now claimable, co-ownership on others' actors is stripped), fog of war, tags, journey, respawn locations, keystones, tracks, guild/party membership, vendor state, exchange orders, and account row itself." }
}
