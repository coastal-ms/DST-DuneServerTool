# PlayersWrites.ps1 — v11.5.9 player write actions ported from dune-admin.
# Covers Phases C, D, E, F of the v11.5.9 port (37 endpoints across):
#   §3 items, §4 vehicles, §5 teleport (offline), §6 progression/journey/
#   contracts/jobs/codex, §10 storage owner debug.
#
# Style mirrors lib/PlayersAdmin.ps1: every Invoke-Dune* takes -Ip and returns
# @{ ok=$true|$false; message; ... }. Routes wrap via Invoke-DunePlayerWriteRoute
# from routes/GameplayPlayers.ps1.
#
# Schema notes (verified against dune-admin db.go):
#   * fgl_entities is keyed by `entity_id` (NOT id), and game components live in
#     the `components` jsonb column (NOT properties).
#   * actor_fgl_entities joins via `entity_id` (NOT fgl_entity_id).
#   * FLevelComponent is an array — access via `->'FLevelComponent'->1->...`.
# Anywhere PlayersAdmin.ps1 uses the older `properties` / `fgl_entity_id` form
# it is a pre-existing bug; the canonical form here matches GameplayWorld.ps1.

# Extract rows-affected count from an Invoke-DuneSqlQuery result. Psql with -A
# emits "UPDATE 5" / "INSERT 0 3" / "DELETE 12" as the message tag for DML
# statements; this helper parses the trailing integer. Returns 0 for SELECTs
# or any unparseable tag.
function Get-DuneSqlAffected {
    param($Result)
    if (-not $Result -or -not $Result.ok) { return 0 }
    $msg = [string]$Result.message
    if (-not $msg) { return 0 }
    $m = [regex]::Match($msg, '^(INSERT|UPDATE|DELETE|MERGE|SELECT|COPY)\s+(?:\d+\s+)?(\d+)\s*$')
    if ($m.Success) { return [int]$m.Groups[2].Value }
    return 0
}

# ---------------------------------------------------------------------------
# Catalog: progression nodes (climb-the-ranks + landsraad + starter abilities)
# ---------------------------------------------------------------------------

$script:DuneProgressionNodesCatalog = $null

function _Load-DuneProgressionNodesCatalog {
    if ($null -ne $script:DuneProgressionNodesCatalog) { return }
    $empty = @{
        climbTheRanksNodes              = @()
        climbTheRanksStoryNodes         = @()
        climbTheRanksStoryNodesAtreides = @()
        climbTheRanksStoryNodesHarkonnen= @()
        landsraadMissionNodesAtreides   = @()
        landsraadMissionNodesHarkonnen  = @()
        starterAbilityByJob             = @{}
        repairGearInventoryTypes        = @(0, 1, 15)
    }
    $p = _Resolve-DuneCatalog 'dune-progression-nodes.json'
    if (-not $p) { $script:DuneProgressionNodesCatalog = $empty; return }
    try {
        $json = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $cat = @{
            climbTheRanksNodes              = @($json.climb_the_ranks_nodes              | ForEach-Object { [string]$_ })
            climbTheRanksStoryNodes         = @($json.climb_the_ranks_story_nodes         | ForEach-Object { [string]$_ })
            climbTheRanksStoryNodesAtreides = @($json.climb_the_ranks_story_nodes_atreides | ForEach-Object { [string]$_ })
            climbTheRanksStoryNodesHarkonnen= @($json.climb_the_ranks_story_nodes_harkonnen | ForEach-Object { [string]$_ })
            landsraadMissionNodesAtreides   = @($json.landsraad_mission_nodes_atreides   | ForEach-Object { [string]$_ })
            landsraadMissionNodesHarkonnen  = @($json.landsraad_mission_nodes_harkonnen  | ForEach-Object { [string]$_ })
            starterAbilityByJob             = @{}
            repairGearInventoryTypes        = @(0, 1, 15)
        }
        if ($json.starter_ability_by_job) {
            foreach ($prop in $json.starter_ability_by_job.PSObject.Properties) {
                $cat.starterAbilityByJob[$prop.Name] = [string]$prop.Value
            }
        }
        if ($json.repair_gear_inventory_types) {
            $cat.repairGearInventoryTypes = @($json.repair_gear_inventory_types | ForEach-Object { [int]$_ })
        }
        $script:DuneProgressionNodesCatalog = $cat
    } catch {
        $script:DuneProgressionNodesCatalog = $empty
    }
}

function Get-DuneNodesForPreset {
    param([string]$Faction, [string]$Preset)
    _Load-DuneProgressionNodesCatalog
    $c = $script:DuneProgressionNodesCatalog
    $nodes = @()
    $nodes += $c.climbTheRanksNodes
    $nodes += $c.climbTheRanksStoryNodes
    switch ($Faction) {
        'atreides'  { $nodes += $c.climbTheRanksStoryNodesAtreides }
        'harkonnen' { $nodes += $c.climbTheRanksStoryNodesHarkonnen }
    }
    if ($Preset -eq 'rank19_eligible') {
        switch ($Faction) {
            'atreides'  { $nodes += $c.landsraadMissionNodesAtreides }
            'harkonnen' { $nodes += $c.landsraadMissionNodesHarkonnen }
        }
    }
    return @($nodes)
}

# ---------------------------------------------------------------------------
# Helpers — pawn / account / faction lookups (matching dune-admin behaviour)
# ---------------------------------------------------------------------------

function Get-DunePlayerPawnFromAccount {
    param([string]$Ip, [long]$AccountId)
    $sql = "SELECT player_pawn_id::text AS pid FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return 0L }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return 0L }
    return [int64](ConvertTo-DuneInt $maps[0]['pid'])
}

function Get-DunePlayerControllerFromAccount {
    param([string]$Ip, [long]$AccountId)
    $sql = "SELECT player_controller_id::text AS cid FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return 0L }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return 0L }
    return [int64](ConvertTo-DuneInt $maps[0]['cid'])
}

function Get-DuneAccountIdFromActor {
    param([string]$Ip, [long]$ActorId)
    $sql = "SELECT COALESCE(owner_account_id, 0)::text AS aid FROM dune.actors WHERE id = $ActorId::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return 0L }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return 0L }
    return [int64](ConvertTo-DuneInt $maps[0]['aid'])
}

function Resolve-DuneFactionIdByName {
    param([string]$Name)
    switch ($Name) {
        'Atreides'  { return 1 }
        'Harkonnen' { return 2 }
        'None'      { return 3 }
        'Smuggler'  { return 4 }
        default     { return 0 }
    }
}

# Postgres text[] literal: ARRAY[$1, $2, ...]::text[]
function ConvertTo-DunePgTextArray {
    param([string[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return "ARRAY[]::text[]" }
    $parts = @()
    foreach ($v in $Values) {
        $safe = ConvertTo-DuneSqlString ([string]$v)
        $parts += "'$safe'"
    }
    return "ARRAY[" + ($parts -join ',') + "]::text[]"
}

# ---------------------------------------------------------------------------
# Tags helpers (port of applyTagsWithTierBump / tierBumpFromTags /
# tagsForJourneyNodeSubtree / allJourneyTags / resolveContractTags)
# ---------------------------------------------------------------------------

function Get-DuneTagsForJourneyNodeSubtree {
    param([string]$NodeId)
    _Load-DuneTagsData
    $jn = $script:DuneTagsData.journeyNodeTags
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $prefix = $NodeId + '.'

    $add = {
        param($arr)
        if ($null -eq $arr) { return }
        foreach ($t in $arr) {
            $s = [string]$t
            if (-not $seen.ContainsKey($s)) { $seen[$s] = $true; [void]$out.Add($s) }
        }
    }

    if ($jn.ContainsKey($NodeId)) { & $add $jn[$NodeId] }
    foreach ($id in $jn.Keys) {
        if ($id.StartsWith($prefix)) { & $add $jn[$id] }
    }
    return @($out)
}

function Get-DuneAllJourneyTags {
    _Load-DuneTagsData
    $jn = $script:DuneTagsData.journeyNodeTags
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($tags in $jn.Values) {
        foreach ($t in $tags) {
            $s = [string]$t
            if (-not $seen.ContainsKey($s)) { $seen[$s] = $true; [void]$out.Add($s) }
        }
    }
    return @($out)
}

function Resolve-DuneContractTagsForId {
    param([string]$ContractId)
    _Load-DuneTagsData
    $name = $ContractId
    if ($script:DuneTagsData.contractAliases.ContainsKey($ContractId)) {
        $name = [string]$script:DuneTagsData.contractAliases[$ContractId]
    }
    if (-not $script:DuneTagsData.contractTags.ContainsKey($name)) {
        return @{ ok = $false; error = "unknown contract '$ContractId' (check dune-tags.json)" }
    }
    $tags = @($script:DuneTagsData.contractTags[$name] | ForEach-Object { [string]$_ })
    if ($tags.Count -eq 0) {
        return @{ ok = $false; error = "contract '$name' has no AddedFlagsOnCompletion" }
    }
    return @{ ok = $true; name = $name; tags = $tags }
}

# Returns hashtable: faction-name -> highest implied rep value.
function Get-DuneTierBumpFromTags {
    param([string[]]$Tags)
    $out = @{}
    foreach ($t in $Tags) {
        if (-not $t.StartsWith('Faction.')) { continue }
        $rest = $t.Substring(8)
        $dot = $rest.IndexOf('.')
        if ($dot -le 0) { continue }
        $faction = $rest.Substring(0, $dot)
        $tail = $rest.Substring($dot + 1)
        if (-not $tail.StartsWith('Tier')) { continue }
        $nStr = $tail.Substring(4)
        $n = 0
        if (-not [int]::TryParse($nStr, [ref]$n)) { continue }
        if ($n -lt 0 -or $n -gt 5) { continue }
        $rep = $script:DuneFactionTierThresholds[$n]
        if ($n -gt 0) { $rep++ }
        if (-not $out.ContainsKey($faction) -or $rep -gt $out[$faction]) {
            $out[$faction] = $rep
        }
    }
    return $out
}

# Writes tags via dune.update_player_tags + tier-bump cascade. Returns
# @{ ok=$true; extra="<message fragment>" }.
function Invoke-DuneApplyTagsWithTierBump {
    param([string]$Ip, [long]$AccountId, [string[]]$Tags)
    if (-not $Tags -or $Tags.Count -eq 0) { return @{ ok = $true; extra = '' } }

    $tagsArr = ConvertTo-DunePgTextArray $Tags
    $sql = "SELECT dune.update_player_tags($AccountId::bigint, $tagsArr, ARRAY[]::text[]);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "apply tags: $($r.error)" } }

    $extra = ", +$($Tags.Count) tag(s)"

    $bumps = Get-DuneTierBumpFromTags -Tags $Tags
    if ($bumps.Count -eq 0) { return @{ ok = $true; extra = $extra } }

    $controllerSql = "SELECT player_controller_id::text AS cid FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1;"
    $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $controllerSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $controllerID = 0L
    if ($cr.ok) {
        $maps = ConvertTo-DuneRowMaps -Result $cr
        if ($maps.Count -ge 1) { $controllerID = [int64](ConvertTo-DuneInt $maps[0]['cid']) }
    }
    if ($controllerID -le 0) {
        return @{ ok = $true; extra = ($extra + ', rep bump skipped (no controller yet)') }
    }

    $bumped = 0
    foreach ($faction in $bumps.Keys) {
        $fid = Resolve-DuneFactionIdByName $faction
        if ($fid -eq 0) { continue }
        $rep = [int]$bumps[$faction]
        $curSql = "SELECT COALESCE(reputation_amount, 0)::text AS rep FROM dune.player_faction_reputation WHERE actor_id = $controllerID::bigint AND faction_id = $fid::smallint;"
        $cur = Invoke-DuneSqlQuery -Ip $Ip -Sql $curSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        $current = 0
        if ($cur.ok) {
            $cmaps = ConvertTo-DuneRowMaps -Result $cur
            if ($cmaps.Count -ge 1) { $current = [int](ConvertTo-DuneInt $cmaps[0]['rep']) }
        }
        if ($current -ge $rep) { continue }

        $sql1 = "SELECT dune.set_player_faction_reputation($controllerID::bigint, $fid::smallint, $rep::integer);"
        $r1 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql1 -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r1.ok) { return @{ ok = $false; error = "bump $faction rep: $($r1.error)" } }

        $safeName = ConvertTo-DuneSqlString $faction
        $sql2 = [string]::Format($script:DuneFactionComponentRepSqlTpl, $controllerID, $safeName, $rep)
        $r2 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql2 -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r2.ok) { return @{ ok = $false; error = "bump $faction FactionPlayerComponent: $($r2.error)" } }

        $bumped++
    }
    if ($bumped -gt 0) { $extra += ", bumped rep for $bumped faction(s)" }
    return @{ ok = $true; extra = $extra }
}

# ---------------------------------------------------------------------------
# Skill blocks (port of grantSkillBlocks)
# ---------------------------------------------------------------------------

function Invoke-DuneGrantSkillBlocks {
    param([string]$Ip, [long]$AccountId, [string[]]$SkillKeys)
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $true; extra = ', skill grants skipped (no pawn yet)' } }

    $granted = 0
    foreach ($sk in $SkillKeys) {
        $key = "(TagName=`"$sk`")"
        $safeKey = ConvertTo-DuneSqlString $key
        $sql = @"
UPDATE dune.fgl_entities fe
SET components = jsonb_set(
    fe.components,
    ARRAY['FLevelComponent','1','ModuleData','$safeKey'],
    '{"SkillPointsSpent": 1}'::jsonb,
    true)
WHERE fe.entity_id = (
    SELECT entity_id FROM dune.actor_fgl_entities
    WHERE actor_id = $pawnID::bigint AND slot_name = 'DuneCharacter'
)
AND COALESCE(
    (fe.components->'FLevelComponent'->1->'ModuleData'->'$safeKey'->>'SkillPointsSpent')::int,
    0
) < 1;
"@
        $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $r.ok) { return @{ ok = $false; error = "grant $sk : $($r.error)" } }
        if ((Get-DuneSqlAffected $r) -gt 0) { $granted++ }
    }
    if ($granted -eq 0) {
        return @{ ok = $true; extra = ', no skill blocks needed (all already unlocked)' }
    }
    return @{ ok = $true; extra = ", unlocked $granted skill block(s)" }
}

# Port of dismissActiveContracts.
function Invoke-DuneDismissActiveContracts {
    param([string]$Ip, [long]$AccountId, [string[]]$ShortNames)
    if (-not $ShortNames -or $ShortNames.Count -eq 0) { return @{ ok = $true; extra = '' } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $true; extra = '' } }

    $arr = ConvertTo-DunePgTextArray $ShortNames
    $sql = @"
DELETE FROM dune.items
WHERE template_id = 'ContractItem'
  AND inventory_id IN (
      SELECT id FROM dune.inventories
      WHERE actor_id = $pawnID::bigint AND inventory_type = 29
  )
  AND stats->'FContractItemStats'->1->'ContractName'->>'Name' = ANY($arr);
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "dismiss active contracts: $($r.error)" } }
    $n = (Get-DuneSqlAffected $r)
    if ($n -le 0) { return @{ ok = $true; extra = '' } }
    return @{ ok = $true; extra = ", dismissed $n active contract(s)" }
}

# ---------------------------------------------------------------------------
# §3 — Items / inventory
# ---------------------------------------------------------------------------

# Bulk give: loops the existing single-template give. Items is an array of
# @{ template = '...'; qty = N; quality = M }.
function Invoke-DunePlayerGiveItemsBulk {
    param([string]$Ip, [long]$PawnId, $Items)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    if (-not $Items -or @($Items).Count -eq 0) {
        return @{ ok = $false; error = 'items[] is required.' }
    }
    $results = New-Object System.Collections.Generic.List[object]
    $failures = 0
    foreach ($it in $Items) {
        $tmpl = [string](Get-DuneBodyValue -Body $it -Name 'template')
        $qty = [int64](Get-DuneBodyInt -Body $it -Name 'qty')
        $qlevel = Get-DuneBodyInt -Body $it -Name 'quality'
        if ($null -eq $qlevel) { $qlevel = 0L }
        if (-not $tmpl) {
            $results.Add(@{ ok = $false; error = 'template missing' })
            $failures++; continue
        }
        if ($qty -le 0) { $qty = 1 }
        $r = Invoke-DunePlayerGiveItem -Ip $Ip -PawnId $PawnId -Template $tmpl -Qty $qty -Quality ([int64]$qlevel)
        $results.Add($r)
        if (-not $r.ok) { $failures++ }
    }
    $total = @($Items).Count
    $ok = $failures -lt $total
    $msg = if ($failures -eq 0) {
        "Gave $total item template(s) to pawn $PawnId."
    } else {
        "$($total - $failures)/$total item templates gave OK; $failures failed."
    }
    return @{ ok = $ok; message = $msg; results = @($results); failures = $failures; total = $total }
}

# Repair equipped gear — OFFLINE only. Sets every durability item in the gear
# inventory types to the HIGHEST of its own three durability fields
# (Max/Current/DecayedMax) and makes all three match. The item's own
# MaxDurability already bakes in that player's stat/perk durability bonuses
# (which differ per player), so it — not the catalog — is the source of truth.
function Invoke-DunePlayerRepairGear {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }

    _Load-DuneProgressionNodesCatalog
    $invTypes = $script:DuneProgressionNodesCatalog.repairGearInventoryTypes
    $invTypesArr = '(' + (($invTypes | ForEach-Object { "$_::int" }) -join ',') + ')'

    $sql = @"
WITH tgt AS (
    SELECT i.id AS item_id,
           GREATEST(
               COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8, 0),
               COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, 0),
               COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'DecayedMaxDurability')::float8, 0)
           ) AS val
    FROM dune.items i
    JOIN dune.inventories inv ON inv.id = i.inventory_id
    WHERE inv.actor_id = $PawnId::bigint
      AND inv.inventory_type IN $invTypesArr
      AND i.stats ? 'FItemStackAndDurabilityStats'
)
UPDATE dune.items i
SET stats = jsonb_set(jsonb_set(jsonb_set(i.stats,
        '{FItemStackAndDurabilityStats,1,MaxDurability}',        to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,CurrentDurability}',    to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,DecayedMaxDurability}', to_jsonb(tgt.val), true)
FROM tgt
WHERE i.id = tgt.item_id AND tgt.val > 0
RETURNING i.id::text AS item_id;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 5000 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = "repair gear: $($r.error)" } }
    $repaired = @(ConvertTo-DuneRowMaps -Result $r).Count
    if ($repaired -eq 0) {
        return @{ ok = $true; message = 'No gear with durability stats — nothing to repair.'; repaired = 0 }
    }
    return @{
        ok = $true
        message = "Repaired $repaired item(s) to full durability on pawn $PawnId."
        repaired = $repaired
    }
}

# Restore destroyed gear — OFFLINE only. Targets items where CurrentDurability
# is 0 or NULL (Chopper's "completely dead" case the standard Repair didn't
# obviously cover). Same inventory_type scope as RepairGear. For items that
# still have the FItemStackAndDurabilityStats stats block we just re-seed
# CurrentDurability + DecayedMaxDurability to the catalog max. For items
# missing the block we (re)build it inline so the game treats the item as
# whole again. Returns counts so the UI can report exactly what happened.
function Invoke-DunePlayerRestoreDestroyedGear {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }

    _Load-DuneProgressionNodesCatalog
    $invTypes = $script:DuneProgressionNodesCatalog.repairGearInventoryTypes
    $invTypesArr = '(' + (($invTypes | ForEach-Object { "$_::int" }) -join ',') + ')'

    # Select EVERY item in the gear inventory types, regardless of whether the
    # durability stats block is present — we want both the "dead but stats
    # still there" case AND the "stats block gone" case. We then decide per
    # row what update to run.
    $sql = @"
SELECT i.id::text AS item_id,
       i.template_id AS template,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, -1)::text AS cur,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8, 0)::text     AS stat_max,
       (i.stats ? 'FItemStackAndDurabilityStats')::text AS has_block
FROM dune.items i
JOIN dune.inventories inv ON inv.id = i.inventory_id
WHERE inv.actor_id = $PawnId::bigint
  AND inv.inventory_type IN $invTypesArr;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1000 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "list gear: $($r.error)" } }
    $items = ConvertTo-DuneRowMaps -Result $r
    if ($items.Count -eq 0) {
        return @{ ok = $true; message = 'No gear in equipped/backpack slots — nothing to restore.'; restored = 0; skipped = 0 }
    }

    $restored = 0; $skipped = 0; $alreadyOk = 0
    foreach ($row in $items) {
        $itemId  = [int64](ConvertTo-DuneInt $row['item_id'])
        $tmpl    = [string]$row['template']
        $hasBlk  = ([string]$row['has_block']) -eq 't'
        $curVal  = 0.0; [double]::TryParse([string]$row['cur'], [ref]$curVal) | Out-Null
        $rule    = Get-DuneGameplayItemRule -TemplateId $tmpl
        $max     = [double]$rule.max_durability
        if ($max -le 0) {
            $statMax = 0.0
            [double]::TryParse([string]$row['stat_max'], [ref]$statMax) | Out-Null
            if ($statMax -gt 0) { $max = $statMax } else { $max = 100.0 }
        }

        # Only act on truly destroyed items: cur < 0 means the stats key was
        # missing entirely (our COALESCE substituted -1); cur == 0 means it
        # was present but the durability is zeroed. Anything > 0 is fine,
        # leave it for the regular Repair button.
        if ($curVal -gt 0) { $alreadyOk++; continue }

        if ($hasBlk) {
            # Stats block is present but durability is zeroed — re-seed all three
            # fields to the HIGHEST of the item's own Max/Current/DecayedMax
            # (which already include this player's stat/perk durability bonuses),
            # with the catalog max only as a floor in case every field was zeroed.
            $upd = @"
UPDATE dune.items i
SET stats = jsonb_set(jsonb_set(jsonb_set(i.stats,
        '{FItemStackAndDurabilityStats,1,MaxDurability}',        to_jsonb(t.val), true),
        '{FItemStackAndDurabilityStats,1,CurrentDurability}',    to_jsonb(t.val), true),
        '{FItemStackAndDurabilityStats,1,DecayedMaxDurability}', to_jsonb(t.val), true)
FROM (
    SELECT GREATEST(
        COALESCE((stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8, 0),
        COALESCE((stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, 0),
        COALESCE((stats->'FItemStackAndDurabilityStats'->1->>'DecayedMaxDurability')::float8, 0),
        $max::float8
    ) AS val
    FROM dune.items WHERE id = $itemId::bigint
) AS t
WHERE i.id = $itemId::bigint AND t.val > 0;
"@
        } else {
            # Stats block missing entirely — graft a fresh one in. The shape
            # mirrors what live items look like ([[<descriptor array>], {<stats>}])
            # — we leave the descriptor array empty since the game backfills it
            # on next interaction. CurrentDurability + DecayedMaxDurability +
            # MaxDurability all get the catalog max so the item shows full.
            $block = @"
'{"FItemStackAndDurabilityStats":[[], {"CurrentDurability":$max,"DecayedMaxDurability":$max,"MaxDurability":$max}]}'::jsonb
"@
            $upd = @"
UPDATE dune.items
SET stats = COALESCE(stats, '{}'::jsonb) || $block
WHERE id = $itemId::bigint;
"@
        }

        $ur = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $ur.ok) { $skipped++; continue }
        $restored++
    }
    return @{
        ok = $true
        message = "Restored $restored destroyed item(s) on pawn $PawnId (already ok: $alreadyOk, skipped: $skipped)."
        restored = $restored
        skipped = $skipped
        already_ok = $alreadyOk
    }
}

# ---------------------------------------------------------------------------
# §4 — Vehicles
# ---------------------------------------------------------------------------

function Invoke-DuneVehicleRepair {
    param([string]$Ip, [long]$VehicleId)
    if ($VehicleId -le 0) { return @{ ok = $false; error = 'vehicle_id is required.' } }

    $sql = @"
SELECT vm.id::text AS module_id,
       vm.template_id AS template,
       COALESCE((vm.stats->'FVehicleModuleDurabilityStats'->1->>'MaxDurability')::float8, 0)::text AS stat_max
FROM dune.vehicle_modules vm
WHERE vm.vehicle_id = $VehicleId::bigint;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 200 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = "list vehicle modules: $($r.error)" } }
    $mods = ConvertTo-DuneRowMaps -Result $r
    if ($mods.Count -eq 0) {
        return @{ ok = $true; message = "Vehicle $VehicleId has no modules — nothing to repair."; repaired = 0 }
    }

    $repaired = 0; $skipped = 0
    foreach ($row in $mods) {
        $modId = [int64](ConvertTo-DuneInt $row['module_id'])
        $tmpl = [string]$row['template']
        $rule = Get-DuneGameplayItemRule -TemplateId $tmpl
        $max = [double]$rule.max_durability
        if ($max -le 0) {
            $statMax = 0.0
            [double]::TryParse([string]$row['stat_max'], [ref]$statMax) | Out-Null
            if ($statMax -gt 0) { $max = $statMax } else { $skipped++; continue }
        }
        $upd = @"
UPDATE dune.vehicle_modules
SET stats = jsonb_set(
    jsonb_set(stats,
        '{FVehicleModuleDurabilityStats,1,CurrentDurability}',
        to_jsonb($max::float8)),
    '{FVehicleModuleDurabilityStats,1,DecayedMaxDurability}',
    to_jsonb($max::float8))
WHERE id = $modId::bigint;
"@
        $ur = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 20
        if (-not $ur.ok) { $skipped++; continue }
        $repaired++
    }
    return @{
        ok = $true
        message = "Repaired $repaired vehicle module(s) on vehicle $VehicleId (skipped $skipped without catalog durability)."
        repaired = $repaired; skipped = $skipped
    }
}

function Invoke-DuneVehicleRefuel {
    param([string]$Ip, [long]$VehicleId)
    if ($VehicleId -le 0) { return @{ ok = $false; error = 'vehicle_id is required.' } }

    $clsSql = "SELECT class::text AS cls FROM dune.actors WHERE id = $VehicleId::bigint;"
    $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $clsSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $cr.ok) { return @{ ok = $false; error = "lookup vehicle class: $($cr.error)" } }
    $cmaps = ConvertTo-DuneRowMaps -Result $cr
    if ($cmaps.Count -eq 0) {
        return @{ ok = $false; error = "vehicle $VehicleId not found." }
    }
    $cls = [string]$cmaps[0]['cls']
    if (-not $cls) { return @{ ok = $false; error = "vehicle $VehicleId has no class." } }
    # bpClass = basename after last "." — strip any leading "/Game/.../"
    $bp = $cls
    $idx = $bp.LastIndexOf('.')
    if ($idx -ge 0) { $bp = $bp.Substring($idx + 1) }
    $safeBp = ConvertTo-DuneSqlString $bp

    $upd = @"
UPDATE dune.actors
SET properties = jsonb_set(
    properties,
    ARRAY['$safeBp', 'm_InitialFuel'],
    to_jsonb(1.0::float8),
    true)
WHERE id = $VehicleId::bigint;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = "refuel: $($r.error)" } }
    return @{ ok = $true; message = "Refuelled vehicle $VehicleId ($bp -> m_InitialFuel = 1.0)." }
}

# ---------------------------------------------------------------------------
# §5 — Teleport (offline path)
# ---------------------------------------------------------------------------

function Invoke-DunePlayerTeleportToPlayer {
    param(
        [string]$Ip,
        [long]$SourcePawnId,
        [long]$TargetPawnId,
        [Nullable[long]]$PartitionId = $null
    )
    if ($SourcePawnId -le 0) { return @{ ok = $false; error = 'source_pawn_id is required.' } }
    if ($TargetPawnId -le 0) { return @{ ok = $false; error = 'target_pawn_id is required.' } }

    # target pawn coords (needed for both online and offline paths)
    $tgtSql = @"
SELECT (location->>'X')::float8 AS x,
       (location->>'Y')::float8 AS y,
       (location->>'Z')::float8 AS z
FROM dune.actors WHERE id = $TargetPawnId::bigint;
"@
    $tr = Invoke-DuneSqlQuery -Ip $Ip -Sql $tgtSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $tr.ok) { return @{ ok = $false; error = "lookup target coords: $($tr.error)" } }
    $tmaps = ConvertTo-DuneRowMaps -Result $tr
    if ($tmaps.Count -eq 0) { return @{ ok = $false; error = "target pawn $TargetPawnId not found." } }
    $tx = [double]$tmaps[0]['x']; $ty = [double]$tmaps[0]['y']; $tz = [double]$tmaps[0]['z']

    # Online path -> RMQ TeleportToExact. Offline path -> admin_move_offline_player_to_partition.
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $SourcePawnId
    if (-not $off.ok) {
        # Online: send TeleportToExact via RMQ to the source player's FLS id.
        $flsResolve = Resolve-DuneFlsIdFromActorId -Ip $Ip -ActorId $SourcePawnId
        if (-not $flsResolve.ok) { return @{ ok = $false; error = "resolve source fls id: $($flsResolve.error)" } }
        $res = Invoke-DuneRmqTeleportToExact -FlsId $flsResolve.fls_id -X $tx -Y $ty -Z $tz
        if (-not $res.ok) { return $res }
        $res.message = "Sent TeleportToExact to online pawn $SourcePawnId -> ($tx, $ty, $tz) via RMQ."
        $res.path = 'rmq'; $res.x = $tx; $res.y = $ty; $res.z = $tz
        return $res
    }

    # Offline: source must resolve to an account/FLS id.
    $srcAcct = 0L
    $srcSql = "SELECT owner_account_id::text AS aid FROM dune.actors WHERE id = $SourcePawnId::bigint LIMIT 1;"
    $sr = Invoke-DuneSqlQuery -Ip $Ip -Sql $srcSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if ($sr.ok) {
        $maps = ConvertTo-DuneRowMaps -Result $sr
        if ($maps.Count -ge 1) { $srcAcct = [int64](ConvertTo-DuneInt $maps[0]['aid']) }
    }
    if ($srcAcct -le 0) { return @{ ok = $false; error = "source pawn $SourcePawnId has no account row." } }
    $fls = Get-DuneRawFuncomId -Ip $Ip -AccountId $srcAcct
    if (-not $fls.ok) { return @{ ok = $false; error = $fls.error } }
    $safeFls = ConvertTo-DuneSqlString $fls.funcom_id

    # resolve partition
    $pid = 0L
    if ($PartitionId -and $PartitionId.HasValue) { $pid = [int64]$PartitionId.Value }
    if ($pid -le 0) {
        $pSql = "SELECT id::text AS pid FROM dune.world_partition WHERE COALESCE(is_blocked, false) = false ORDER BY id LIMIT 1;"
        $pr = Invoke-DuneSqlQuery -Ip $Ip -Sql $pSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if ($pr.ok) {
            $pmaps = ConvertTo-DuneRowMaps -Result $pr
            if ($pmaps.Count -ge 1) { $pid = [int64](ConvertTo-DuneInt $pmaps[0]['pid']) }
        }
        if ($pid -le 0) { return @{ ok = $false; error = 'no unblocked world_partition rows found.' } }
    }

    $sql = "SELECT dune.admin_move_offline_player_to_partition('$safeFls'::text, $pid::bigint, ROW($tx::float8, $ty::float8, $tz::float8)::dune.Vector);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "admin_move_offline_player_to_partition: $($r.error)" } }
    return @{
        ok = $true
        message = "Teleported offline pawn $SourcePawnId -> ($tx, $ty, $tz) on partition $pid."
        path = 'offline'
        partition = $pid; x = $tx; y = $ty; z = $tz
    }
}

# ---------------------------------------------------------------------------
# §6 — Progression / journey / contracts / jobs / codex / tutorials
# ---------------------------------------------------------------------------

function Invoke-DunePlayerProgressionUnlock {
    param([string]$Ip, [long]$ActorId, [string]$Faction, [string]$Preset)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $factionLower = $Faction.ToLowerInvariant()
    $factionID = 0; $dialogue=''; $aligned=''; $metRec=''; $factionUnlocked=''; $recruitmentDone=''
    switch ($factionLower) {
        'atreides' {
            $factionID = 1
            $dialogue = 'DialogueFlags.Factions.SentToMeetHawat'
            $aligned = 'DialogueFlags.Factions.AlignedAtreides'
            $metRec = 'DialogueFlags.Factions.MetHawat'
            $factionUnlocked = 'Contract.Tracking.AtreidesFactionUnlocked'
            $recruitmentDone = 'Contract.Tracking.AtreidesRecruitmentCompleted'
        }
        'harkonnen' {
            $factionID = 2
            $dialogue = 'DialogueFlags.Factions.SentToPiterDeVries'
            $aligned = 'DialogueFlags.Factions.AlignedHarkonnen'
            $metRec = 'DialogueFlags.Factions.MetPiterDeVries'
            $factionUnlocked = 'Contract.Tracking.HarkonnenFactionUnlocked'
            $recruitmentDone = 'Contract.Tracking.HarkonnenRecruitmentCompleted'
        }
        default { return @{ ok = $false; error = 'faction must be atreides or harkonnen' } }
    }
    $presetLower = $Preset.ToLowerInvariant()
    $targetTier = 0
    switch ($presetLower) {
        'ch3_start'        { $targetTier = 5 }
        'rank19_eligible'  { $targetTier = 19 }
        default { return @{ ok = $false; error = 'preset must be ch3_start or rank19_eligible' } }
    }

    # actor -> account + controller
    $accCtlSql = @"
SELECT COALESCE(a.owner_account_id, 0)::text AS aid,
       COALESCE(ps.player_controller_id, 0)::text AS cid
FROM dune.actors a
LEFT JOIN dune.player_state ps ON ps.account_id = a.owner_account_id
WHERE a.id = $ActorId::bigint
LIMIT 1;
"@
    $acr = Invoke-DuneSqlQuery -Ip $Ip -Sql $accCtlSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $acr.ok) { return @{ ok = $false; error = "lookup account: $($acr.error)" } }
    $acmaps = ConvertTo-DuneRowMaps -Result $acr
    if ($acmaps.Count -eq 0) { return @{ ok = $false; error = "actor $ActorId not found." } }
    $accountID = [int64](ConvertTo-DuneInt $acmaps[0]['aid'])
    $controllerID = [int64](ConvertTo-DuneInt $acmaps[0]['cid'])
    if ($accountID -le 0) { return @{ ok = $false; error = "actor $ActorId has no owner_account_id." } }
    if ($controllerID -le 0) { return @{ ok = $false; error = "actor $ActorId has no controller (player_state row missing)." } }

    $fls = Get-DuneRawFuncomId -Ip $Ip -AccountId $accountID
    if (-not $fls.ok) { return @{ ok = $false; error = $fls.error } }
    $safeFls = ConvertTo-DuneSqlString $fls.funcom_id

    $nodes = Get-DuneNodesForPreset -Faction $factionLower -Preset $presetLower
    if ($nodes.Count -eq 0) { return @{ ok = $false; error = 'progression-nodes catalog empty (data file missing?).' } }
    $nodesArr = ConvertTo-DunePgTextArray $nodes

    $factionName = Get-DuneFactionDisplayName $factionID
    $safeFactionName = ConvertTo-DuneSqlString $factionName

    $allTags = @(
        $dialogue, $aligned, $metRec,
        $factionUnlocked, $recruitmentDone,
        'DialogueFlags.Factions.FactionIntro',
        'DialogueFlags.Factions.FactionRank1',
        'DialogueFlags.Factions.FactionRank3',
        'DialogueFlags.Factions.MetARecruiter',
        'DialogueFlags.Factions.PlayedAllegianceCinematic',
        'DialogueFlags.Factions.SeenAnvilCinematic'
    )
    if ($targetTier -ge 19) { $allTags += 'Journey.LandsraadContractsUnlocked' }
    for ($t = 0; $t -le 5; $t++) {
        $allTags += "Faction.$factionName.Tier$t"
    }
    $tagsArr = ConvertTo-DunePgTextArray $allTags

    $targetRep = $script:DuneFactionTierThresholds[$targetTier]
    if ($targetTier -gt 0) { $targetRep++ }

    # Single transactional script — each statement uses literal values (we
    # already sanitised). Pg "BEGIN ... COMMIT" works in one Invoke-DuneSqlQuery
    # so long as the helper passes the whole string through pgx.
    $tx = @"
BEGIN;
SELECT dune.complete_journey_story_nodes_for_player('$safeFls'::text, $nodesArr);
SELECT dune.change_player_faction($controllerID::bigint, $factionID::smallint, 3::smallint, NOW()::timestamp);
SELECT dune.update_player_tags($accountID::bigint, $tagsArr, ARRAY[]::text[]);
SELECT dune.set_player_faction_reputation($controllerID::bigint, $factionID::smallint, $targetRep::integer);
$([string]::Format($script:DuneFactionComponentRepSqlTpl, $controllerID, $safeFactionName, $targetRep))
COMMIT;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $tx -ReadOnly $false -MaxRows 1 -TimeoutSec 90
    if (-not $r.ok) {
        # Best-effort rollback (no-op if tx already aborted)
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "progression-unlock tx: $($r.error)" }
    }

    return @{
        ok = $true
        message = ("Progression unlock ($presetLower/$factionLower): $($nodes.Count) journey nodes completed + " +
                   "$factionName tier tags 0-5 + rep tier $targetTier on controller $controllerID - takes effect on next login.")
        nodes = $nodes.Count; faction = $factionName; tier = $targetTier; controller_id = $controllerID
    }
}

function Invoke-DunePlayerProgressionReverse {
    param([string]$Ip, [long]$ActorId, [string]$Faction, [string]$Preset)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $factionLower = $Faction.ToLowerInvariant()
    $presetLower = $Preset.ToLowerInvariant()
    if ($factionLower -ne 'atreides' -and $factionLower -ne 'harkonnen') {
        return @{ ok = $false; error = 'faction must be atreides or harkonnen' }
    }
    if ($presetLower -ne 'ch3_start' -and $presetLower -ne 'rank19_eligible') {
        return @{ ok = $false; error = 'preset must be ch3_start or rank19_eligible' }
    }

    $accountID = Get-DuneAccountIdFromActor -Ip $Ip -ActorId $ActorId
    if ($accountID -le 0) { return @{ ok = $false; error = "actor $ActorId has no owner_account_id." } }

    $factionID = if ($factionLower -eq 'atreides') { 1 } else { 2 }
    $factionName = Get-DuneFactionDisplayName $factionID
    $nodes = Get-DuneNodesForPreset -Faction $factionLower -Preset $presetLower

    # Tags to remove = baseline + faction + Tier0..5 (matches the forward set,
    # minus things we never want to roll back like Aligned/Recruited which would
    # break re-attempts).
    $removeTags = @(
        'DialogueFlags.Factions.FactionIntro',
        'DialogueFlags.Factions.FactionRank1',
        'DialogueFlags.Factions.FactionRank3',
        'DialogueFlags.Factions.MetARecruiter',
        'DialogueFlags.Factions.PlayedAllegianceCinematic',
        'DialogueFlags.Factions.SeenAnvilCinematic'
    )
    for ($t = 0; $t -le 5; $t++) { $removeTags += "Faction.$factionName.Tier$t" }
    if ($presetLower -eq 'rank19_eligible') {
        $removeTags += 'Journey.LandsraadContractsUnlocked'
    }
    $tagsArr = ConvertTo-DunePgTextArray $removeTags

    if ($nodes.Count -eq 0) { return @{ ok = $false; error = 'progression-nodes catalog empty.' } }

    $nodeUpdates = ''
    foreach ($n in $nodes) {
        $safe = ConvertTo-DuneSqlString $n
        $nodeUpdates += "UPDATE dune.journey_story_node SET complete_condition_state='false'::jsonb, has_pending_reward=false WHERE account_id=$accountID::bigint AND (story_node_id='$safe' OR story_node_id LIKE '$safe.%');`n"
    }

    $tx = @"
BEGIN;
SELECT dune.update_player_tags($accountID::bigint, ARRAY[]::text[], $tagsArr);
$nodeUpdates
COMMIT;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $tx -ReadOnly $false -MaxRows 1 -TimeoutSec 120
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "progression-reverse tx: $($r.error)" }
    }
    return @{
        ok = $true
        message = ("Progression reverse ($presetLower/$factionLower): reset $($nodes.Count) journey node(s) " +
                   "+ removed $($removeTags.Count) tag(s). Rep + faction alignment untouched.")
        nodes = $nodes.Count; tags = $removeTags.Count; faction = $factionName
    }
}

function Invoke-DunePlayerApplyProgressionPreset {
    param([string]$Ip, [long]$AccountId, [string]$PresetId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $PresetId) { return @{ ok = $false; error = 'preset_id is required.' } }
    $cat = Get-DuneProgressionPresetCatalog
    $preset = $null
    foreach ($p in $cat) { if ($p.id -eq $PresetId) { $preset = $p; break } }
    if (-not $preset) { return @{ ok = $false; error = "unknown preset_id '$PresetId'." } }

    $completed = 0
    $errs = @()
    foreach ($node in $preset.journey_nodes) {
        $r = Invoke-DunePlayerCompleteJourneyNode -Ip $Ip -AccountId $AccountId -NodeId $node -SkipMsg
        if ($r.ok) { $completed++ }
        else { $errs += "$node : $($r.error)" }
    }
    $ok = $errs.Count -eq 0
    $msg = "Applied preset '$PresetId' ($($preset.label)): completed $completed/$($preset.journey_nodes.Count) journey node(s)."
    if ($errs.Count -gt 0) { $msg += " Failures: $($errs -join '; ')" }
    return @{ ok = $ok; message = $msg; completed = $completed; total = $preset.journey_nodes.Count }
}

function Invoke-DunePlayerCompleteJourneyNode {
    param([string]$Ip, [long]$AccountId, [string]$NodeId, [switch]$SkipMsg)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $NodeId) { return @{ ok = $false; error = 'node_id is required.' } }
    $safeNode = ConvertTo-DuneSqlString $NodeId

    $upd = @"
UPDATE dune.journey_story_node
SET complete_condition_state = 'true'::jsonb,
    reveal_condition_state   = 'true'::jsonb
WHERE account_id = $AccountId::bigint
  AND (story_node_id = '$safeNode' OR story_node_id LIKE '$safeNode.%');
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "complete node: $($r.error)" } }
    $updated = (Get-DuneSqlAffected $r)
    if ($updated -eq 0) {
        $ins = @"
INSERT INTO dune.journey_story_node
    (account_id, story_node_id, has_pending_reward,
     complete_condition_state, reveal_condition_state,
     fail_condition_state, metadata_state, reset_group)
VALUES ($AccountId::bigint, '$safeNode', false,
    'true'::jsonb, 'true'::jsonb,
    '{}'::jsonb, '{}'::jsonb,
    'Default'::dune.JourneyStoryResetGroup);
"@
        $ir = Invoke-DuneSqlQuery -Ip $Ip -Sql $ins -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $ir.ok) { return @{ ok = $false; error = "insert node: $($ir.error)" } }
        $updated = 1
    }

    $tags = Get-DuneTagsForJourneyNodeSubtree -NodeId $NodeId
    $bumpRes = Invoke-DuneApplyTagsWithTierBump -Ip $Ip -AccountId $AccountId -Tags $tags
    if (-not $bumpRes.ok) { return @{ ok = $false; error = $bumpRes.error } }

    if ($SkipMsg) { return @{ ok = $true } }
    return @{
        ok = $true
        message = "Completed $NodeId + $updated node(s)$($bumpRes.extra) - takes effect on next login"
        nodes = $updated; tags = $tags.Count
    }
}

function Invoke-DunePlayerResetJourneyNode {
    param([string]$Ip, [long]$AccountId, [string]$NodeId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $NodeId) { return @{ ok = $false; error = 'node_id is required.' } }
    $safeNode = ConvertTo-DuneSqlString $NodeId

    $upd = @"
UPDATE dune.journey_story_node
SET complete_condition_state = 'false'::jsonb,
    has_pending_reward       = false
WHERE account_id = $AccountId::bigint
  AND (story_node_id = '$safeNode' OR story_node_id LIKE '$safeNode.%');
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "reset node: $($r.error)" } }

    $removeTags = Get-DuneTagsForJourneyNodeSubtree -NodeId $NodeId
    $extra = ''
    if ($removeTags.Count -gt 0) {
        $arr = ConvertTo-DunePgTextArray $removeTags
        $rt = "SELECT dune.update_player_tags($AccountId::bigint, ARRAY[]::text[], $arr);"
        $rr = Invoke-DuneSqlQuery -Ip $Ip -Sql $rt -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $rr.ok) { return @{ ok = $false; error = "remove node tags: $($rr.error)" } }
        $extra = ", removed $($removeTags.Count) tag(s)"
    }
    return @{ ok = $true; message = "Reset $NodeId$extra"; tags_removed = $removeTags.Count }
}

function Invoke-DunePlayerWipeJourneyNodes {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }

    $sql = "SELECT dune.delete_all_journey_story_nodes($AccountId::bigint);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = "delete_all_journey_story_nodes: $($r.error)" } }

    $allTags = Get-DuneAllJourneyTags
    $extra = ''
    if ($allTags.Count -gt 0) {
        $arr = ConvertTo-DunePgTextArray $allTags
        $rt = "SELECT dune.update_player_tags($AccountId::bigint, ARRAY[]::text[], $arr);"
        $rr = Invoke-DuneSqlQuery -Ip $Ip -Sql $rt -ReadOnly $false -MaxRows 1 -TimeoutSec 60
        if (-not $rr.ok) { return @{ ok = $false; error = "remove all journey tags: $($rr.error)" } }
        $extra = ", removed $($allTags.Count) journey tag(s)"
    }
    return @{ ok = $true; message = "Wiped all journey nodes for account $AccountId$extra"; tags_removed = $allTags.Count }
}

function Invoke-DunePlayerCompleteContracts {
    param([string]$Ip, [long]$AccountId, [string[]]$ContractIds)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $ContractIds -or $ContractIds.Count -eq 0) {
        return @{ ok = $false; error = 'contract_ids[] is required.' }
    }

    _Load-DuneTagsData
    $seenTag = @{}; $allTags = New-Object System.Collections.Generic.List[string]
    $seenSkill = @{}; $allSkills = New-Object System.Collections.Generic.List[string]
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($id in $ContractIds) {
        $r = Resolve-DuneContractTagsForId -ContractId $id
        if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
        [void]$resolved.Add($r.name)
        foreach ($t in $r.tags) {
            if (-not $seenTag.ContainsKey($t)) { $seenTag[$t] = $true; [void]$allTags.Add($t) }
        }
        if ($script:DuneTagsData.contractSkillGrants.ContainsKey($r.name)) {
            foreach ($sk in $script:DuneTagsData.contractSkillGrants[$r.name]) {
                if (-not $seenSkill.ContainsKey($sk)) { $seenSkill[$sk] = $true; [void]$allSkills.Add($sk) }
            }
        }
    }

    $bumpRes = Invoke-DuneApplyTagsWithTierBump -Ip $Ip -AccountId $AccountId -Tags @($allTags)
    if (-not $bumpRes.ok) { return @{ ok = $false; error = $bumpRes.error } }
    $extra = $bumpRes.extra

    if ($allSkills.Count -gt 0) {
        $gr = Invoke-DuneGrantSkillBlocks -Ip $Ip -AccountId $AccountId -SkillKeys @($allSkills)
        if (-not $gr.ok) { return @{ ok = $false; error = $gr.error } }
        $extra += $gr.extra
    }

    $shortNames = @($resolved | ForEach-Object { if ($_ -like 'DA_CT_*') { $_.Substring(6) } else { $_ } })
    $dr = Invoke-DuneDismissActiveContracts -Ip $Ip -AccountId $AccountId -ShortNames $shortNames
    if (-not $dr.ok) { return @{ ok = $false; error = $dr.error } }
    $extra += $dr.extra

    $summary = if ($resolved.Count -eq 1) { $resolved[0] } else { "$($resolved.Count) contracts" }
    return @{
        ok = $true
        message = "Applied $summary$extra - takes effect on next login"
        contracts = $resolved.Count; tags = $allTags.Count; skills = $allSkills.Count
    }
}

function Invoke-DunePlayerReverseContracts {
    param([string]$Ip, [long]$AccountId, [string[]]$ContractIds)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $ContractIds -or $ContractIds.Count -eq 0) {
        return @{ ok = $false; error = 'contract_ids[] is required.' }
    }

    _Load-DuneTagsData
    $seenTag = @{}; $removeTags = New-Object System.Collections.Generic.List[string]
    $seenSkill = @{}; $removeSkills = New-Object System.Collections.Generic.List[string]
    $resolved = New-Object System.Collections.Generic.List[string]

    foreach ($id in $ContractIds) {
        $r = Resolve-DuneContractTagsForId -ContractId $id
        if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
        [void]$resolved.Add($r.name)
        foreach ($t in $r.tags) {
            if (-not $seenTag.ContainsKey($t)) { $seenTag[$t] = $true; [void]$removeTags.Add($t) }
        }
        if ($script:DuneTagsData.contractSkillGrants.ContainsKey($r.name)) {
            foreach ($sk in $script:DuneTagsData.contractSkillGrants[$r.name]) {
                if (-not $seenSkill.ContainsKey($sk)) { $seenSkill[$sk] = $true; [void]$removeSkills.Add($sk) }
            }
        }
    }

    if ($removeTags.Count -gt 0) {
        $arr = ConvertTo-DunePgTextArray @($removeTags)
        $rt = "SELECT dune.update_player_tags($AccountId::bigint, ARRAY[]::text[], $arr);"
        $rr = Invoke-DuneSqlQuery -Ip $Ip -Sql $rt -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $rr.ok) { return @{ ok = $false; error = "remove tags: $($rr.error)" } }
    }

    $stripped = 0
    if ($removeSkills.Count -gt 0) {
        $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
        if ($pawnID -gt 0) {
            foreach ($sk in $removeSkills) {
                $key = "(TagName=`"$sk`")"
                $safeKey = ConvertTo-DuneSqlString $key
                $sql = @"
UPDATE dune.fgl_entities fe
SET components = jsonb_set(
    fe.components,
    ARRAY['FLevelComponent','1','ModuleData'],
    (fe.components->'FLevelComponent'->1->'ModuleData') - '$safeKey'::text)
WHERE fe.entity_id = (
    SELECT entity_id FROM dune.actor_fgl_entities
    WHERE actor_id = $pawnID::bigint AND slot_name = 'DuneCharacter'
)
AND COALESCE(
    (fe.components->'FLevelComponent'->1->'ModuleData'->'$safeKey'->>'SkillPointsSpent')::int,
    0
) <= 1;
"@
                $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
                if (-not $r.ok) { return @{ ok = $false; error = "strip $sk : $($r.error)" } }
                if ((Get-DuneSqlAffected $r) -gt 0) { $stripped++ }
            }
        }
    }
    $summary = if ($resolved.Count -eq 1) { $resolved[0] } else { "$($resolved.Count) contracts" }
    return @{
        ok = $true
        message = "Reversed $summary : removed $($removeTags.Count) tag(s), stripped $stripped skill block(s) - takes effect on next login"
        contracts = $resolved.Count; tags = $removeTags.Count; stripped = $stripped
    }
}

function Invoke-DunePlayerGrantJobSkills {
    param([string]$Ip, [long]$AccountId, [string]$Job)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $Job) { return @{ ok = $false; error = 'job is required.' } }
    _Load-DuneTagsData
    if (-not $script:DuneTagsData.jobSkillBlocks.ContainsKey($Job)) {
        return @{ ok = $false; error = "unknown job '$Job' (check dune-tags.json job_skill_blocks)." }
    }
    $blocks = @($script:DuneTagsData.jobSkillBlocks[$Job] | ForEach-Object { [string]$_ })
    $r = Invoke-DuneGrantSkillBlocks -Ip $Ip -AccountId $AccountId -SkillKeys $blocks
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; message = "Unlocked $Job skill tree$($r.extra) - takes effect on next login" }
}

function Invoke-DunePlayerResetJobSkills {
    param([string]$Ip, [long]$AccountId, [string]$Job)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $Job) { return @{ ok = $false; error = 'job is required.' } }
    _Load-DuneTagsData
    if (-not $script:DuneTagsData.jobAllModules.ContainsKey($Job)) {
        return @{ ok = $false; error = "unknown job '$Job' (check dune-tags.json job_all_modules)." }
    }
    $modules = @($script:DuneTagsData.jobAllModules[$Job] | ForEach-Object { [string]$_ })
    if ($modules.Count -eq 0) { return @{ ok = $false; error = "job '$Job' has no modules listed." } }

    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $false; error = "no pawn for account $AccountId." } }

    $keys = @($modules | ForEach-Object { "(TagName=`"$_`")" })
    $keysArr = ConvertTo-DunePgTextArray $keys

    $sql = @"
UPDATE dune.fgl_entities fe
SET components = jsonb_set(
    fe.components,
    ARRAY['FLevelComponent','1','ModuleData'],
    (fe.components->'FLevelComponent'->1->'ModuleData') - $keysArr)
WHERE fe.entity_id = (
    SELECT entity_id FROM dune.actor_fgl_entities
    WHERE actor_id = $pawnID::bigint AND slot_name = 'DuneCharacter'
);
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "reset $Job tree: $($r.error)" } }
    if ((Get-DuneSqlAffected $r) -eq 0) {
        return @{ ok = $true; message = "Reset $Job skill tree - no ModuleData on pawn" }
    }
    return @{ ok = $true; message = "Reset $Job skill tree - scanned $($modules.Count) module slot(s)" }
}

function Invoke-DunePlayerSetStarterClass {
    param([string]$Ip, [long]$AccountId, [string]$Job)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $Job) { return @{ ok = $false; error = 'job is required.' } }
    _Load-DuneTagsData
    _Load-DuneProgressionNodesCatalog
    if (-not $script:DuneTagsData.jobSkillBlocks.ContainsKey($Job)) {
        return @{ ok = $false; error = "unknown job '$Job'." }
    }
    if (-not $script:DuneProgressionNodesCatalog.starterAbilityByJob.ContainsKey($Job)) {
        return @{ ok = $false; error = "no starter ability mapping for '$Job'." }
    }
    $newAbility = [string]$script:DuneProgressionNodesCatalog.starterAbilityByJob[$Job]

    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $false; error = "no pawn for account $AccountId." } }

    $oldSql = @"
SELECT fe.components->'FLevelComponent'->1->'StarterSkillTreeTag'->>'TagName' AS old_tag
FROM dune.fgl_entities fe
JOIN dune.actor_fgl_entities afe ON afe.entity_id = fe.entity_id
WHERE afe.actor_id = $pawnID::bigint AND afe.slot_name = 'DuneCharacter'
LIMIT 1;
"@
    $or = Invoke-DuneSqlQuery -Ip $Ip -Sql $oldSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $oldTag = ''
    if ($or.ok) {
        $omaps = ConvertTo-DuneRowMaps -Result $or
        if ($omaps.Count -ge 1) { $oldTag = [string]$omaps[0]['old_tag'] }
    }

    $keysToRemove = @()
    if ($oldTag -and $oldTag.StartsWith('Skills.Key.') -and $oldTag.EndsWith('1')) {
        $oldJob = $oldTag.Substring(11)
        $oldJob = $oldJob.Substring(0, $oldJob.Length - 1)
        if ($oldJob -and $oldJob -ne $Job) {
            $keysToRemove += "(TagName=`"$oldTag`")"
            if ($script:DuneProgressionNodesCatalog.starterAbilityByJob.ContainsKey($oldJob)) {
                $oldAb = [string]$script:DuneProgressionNodesCatalog.starterAbilityByJob[$oldJob]
                $keysToRemove += "(TagName=`"$oldAb`")"
            }
        }
    }
    $removeArr = ConvertTo-DunePgTextArray $keysToRemove

    $newStarterTag = "Skills.Key.${Job}1"
    $newStarterKey = "(TagName=`"$newStarterTag`")"
    $newAbilityKey = "(TagName=`"$newAbility`")"
    $safeNewTag = ConvertTo-DuneSqlString $newStarterTag
    $safeNewKey = ConvertTo-DuneSqlString $newStarterKey
    $safeAbKey = ConvertTo-DuneSqlString $newAbilityKey

    $sql = @"
UPDATE dune.fgl_entities fe
SET components = jsonb_set(
    jsonb_set(
        jsonb_set(
            jsonb_set(
                fe.components,
                ARRAY['FLevelComponent','1','ModuleData'],
                (fe.components->'FLevelComponent'->1->'ModuleData') - $removeArr),
            ARRAY['FLevelComponent','1','StarterSkillTreeTag','TagName'],
            to_jsonb('$safeNewTag'::text)),
        ARRAY['FLevelComponent','1','ModuleData','$safeNewKey'],
        '{"SkillPointsSpent": 1}'::jsonb,
        true),
    ARRAY['FLevelComponent','1','ModuleData','$safeAbKey'],
    '{"SkillPointsSpent": 1}'::jsonb,
    true)
WHERE fe.entity_id = (
    SELECT entity_id FROM dune.actor_fgl_entities
    WHERE actor_id = $pawnID::bigint AND slot_name = 'DuneCharacter'
);
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "set starter tag: $($r.error)" } }
    $msg = "Starter class set to $Job ($newStarterTag + $newAbility active)"
    if ($keysToRemove.Count -gt 0) { $msg += ", cleared previous starter ($($keysToRemove.Count) module(s))" }
    return @{ ok = $true; message = $msg }
}

function Invoke-DunePlayerDeleteTutorials {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $sql = "SELECT dune.delete_all_tutorial_entries($AccountId::bigint);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "delete_all_tutorial_entries: $($r.error)" } }
    return @{ ok = $true; message = "Cleared tutorial flags for account $AccountId." }
}

function Invoke-DunePlayerWipeCodex {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $sql = "SELECT dune.delete_mnemonic_recall_lesson_all($AccountId::bigint);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "delete_mnemonic_recall_lesson_all: $($r.error)" } }
    return @{ ok = $true; message = "Wiped codex / mnemonic recall for account $AccountId." }
}

# ---------------------------------------------------------------------------
# §10 — Storage owner debug (read-only)
# ---------------------------------------------------------------------------

function Get-DuneStorageOwnerDebug {
    param([string]$Ip, [long]$PlaceableId)
    if ($PlaceableId -le 0) { return @{ ok = $false; error = 'placeable_id is required.' } }

    $out = [ordered]@{ placeable_id = $PlaceableId }

    $sql1 = "SELECT owner_entity_id::text AS eid FROM dune.placeables WHERE id = $PlaceableId::bigint LIMIT 1;"
    $r1 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql1 -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r1.ok) { return @{ ok = $false; error = "placeables: $($r1.error)" } }
    $m1 = ConvertTo-DuneRowMaps -Result $r1
    if ($m1.Count -eq 0) { $out['placeable_found'] = $false; return @{ ok = $true; result = $out } }
    $out['placeable_found'] = $true
    $entityId = [int64](ConvertTo-DuneInt $m1[0]['eid'])
    $out['owner_entity_id'] = $entityId

    if ($entityId -gt 0) {
        $sql2 = "SELECT actor_id::text AS aid, slot_name AS slot FROM dune.actor_fgl_entities WHERE entity_id = $entityId::bigint LIMIT 1;"
        $r2 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql2 -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if ($r2.ok) {
            $m2 = ConvertTo-DuneRowMaps -Result $r2
            if ($m2.Count -ge 1) {
                $aid = [int64](ConvertTo-DuneInt $m2[0]['aid'])
                $out['actor_id'] = $aid
                $out['slot_name'] = [string]$m2[0]['slot']

                if ($aid -gt 0) {
                    $sql3 = "SELECT COALESCE(owner_account_id,0)::text AS oacc, class::text AS cls FROM dune.actors WHERE id = $aid::bigint LIMIT 1;"
                    $r3 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql3 -ReadOnly $true -MaxRows 1 -TimeoutSec 10
                    if ($r3.ok) {
                        $m3 = ConvertTo-DuneRowMaps -Result $r3
                        if ($m3.Count -ge 1) {
                            $out['actor_class'] = [string]$m3[0]['cls']
                            $out['owner_account_id'] = [int64](ConvertTo-DuneInt $m3[0]['oacc'])
                        }
                    }
                }
            }
        }
    }

    # fallback chain via permission_actor_rank if no owner_account_id resolved
    if (-not $out.Contains('owner_account_id') -or [int64]$out['owner_account_id'] -le 0) {
        $sql4 = @"
SELECT par.player_id::text AS pid FROM dune.permission_actor_rank par
WHERE par.actor_id = $PlaceableId::bigint
ORDER BY par.rank DESC NULLS LAST
LIMIT 1;
"@
        $r4 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql4 -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if ($r4.ok) {
            $m4 = ConvertTo-DuneRowMaps -Result $r4
            if ($m4.Count -ge 1) {
                $pid = [int64](ConvertTo-DuneInt $m4[0]['pid'])
                $out['permission_player_id'] = $pid
                if ($pid -gt 0) {
                    $sql5 = "SELECT account_id::text AS aid FROM dune.player_state WHERE player_pawn_id = $pid::bigint OR player_controller_id = $pid::bigint LIMIT 1;"
                    $r5 = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql5 -ReadOnly $true -MaxRows 1 -TimeoutSec 10
                    if ($r5.ok) {
                        $m5 = ConvertTo-DuneRowMaps -Result $r5
                        if ($m5.Count -ge 1) {
                            $out['fallback_owner_account_id'] = [int64](ConvertTo-DuneInt $m5[0]['aid'])
                        }
                    }
                }
            }
        }
    }

    return @{ ok = $true; result = $out }
}

