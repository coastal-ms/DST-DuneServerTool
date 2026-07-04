# PlayersWrites.ps1 — v11.5.9 player write actions ported from the reference implementation.
# Covers Phases C, D, E, F of the v11.5.9 port (37 endpoints across):
#   §3 items, §4 vehicles, §5 teleport (offline), §6 progression/journey/
#   contracts/jobs/codex, §10 storage owner debug.
#
# Style mirrors lib/PlayersAdmin.ps1: every Invoke-Dune* takes -Ip and returns
# @{ ok=$true|$false; message; ... }. Routes wrap via Invoke-DunePlayerWriteRoute
# from routes/GameplayPlayers.ps1.
#
# Schema notes (verified against the reference implementation db.go):
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
# Helpers — pawn / account / faction lookups (matching the reference implementation behaviour)
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
    param([string]$Ip, [long]$AccountId, [string[]]$Tags, [string[]]$RemoveTags)
    $addCount = if ($Tags) { @($Tags).Count } else { 0 }
    $remCount = if ($RemoveTags) { @($RemoveTags).Count } else { 0 }
    if ($addCount -eq 0 -and $remCount -eq 0) { return @{ ok = $true; extra = '' } }

    $tagsArr = if ($addCount -gt 0) { ConvertTo-DunePgTextArray $Tags } else { 'ARRAY[]::text[]' }
    $remArr  = if ($remCount -gt 0) { ConvertTo-DunePgTextArray $RemoveTags } else { 'ARRAY[]::text[]' }
    $sql = "SELECT dune.update_player_tags($AccountId::bigint, $tagsArr, $remArr);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "apply tags: $($r.error)" } }

    $extra = ''
    if ($addCount -gt 0) { $extra += ", +$addCount tag(s)" }
    if ($remCount -gt 0) { $extra += ", -$remCount tag(s)" }

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
    param([string]$Ip, [long]$PawnId, $Items, [string]$FlsId, [bool]$AllowOverflow = $true)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    if (-not $Items -or @($Items).Count -eq 0) {
        return @{ ok = $false; error = 'items[] is required.' }
    }
    # Route each item the same way the single give-item endpoint does: an online
    # player keeps their inventory in memory, so a direct SQL write is ignored and
    # overwritten on the next save (the item never appears, or vanishes on relog).
    # Default-quality gives to an online player must therefore go through the RMQ
    # live path. Custom-quality gives can't be delivered live, so they fall back to
    # SQL with a "must relog" note. Resolve online status + fls_id once up front.
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    $isOnline = -not $off.ok
    $fls = $FlsId
    if ($isOnline -and [string]::IsNullOrWhiteSpace($fls)) {
        $fr = Resolve-DuneFlsIdOrError -Ip $Ip -ActorId $PawnId
        if ($fr.ok) { $fls = [string]$fr.fls_id }
    }
    $results = New-Object System.Collections.Generic.List[object]
    $failures = 0
    # Each RMQ ServerCommand is applied asynchronously by the game; firing several
    # AddItemToInventory commands back-to-back can outrun the deposit so later items
    # (often the bulky vehicle modules at the end of a kit) silently never land.
    # Space consecutive live gives so the game finishes depositing each before the next.
    $rmqGives = 0
    $rmqSpacingMs = 500
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
        if ($isOnline -and $qlevel -le 0 -and -not [string]::IsNullOrWhiteSpace($fls)) {
            # Online + default quality → RMQ live (instant, no relog)
            if ($rmqGives -gt 0) { Start-Sleep -Milliseconds $rmqSpacingMs }
            $r = Invoke-DunePlayerGiveItemLive -Ip $Ip -ActorId $PawnId -FlsId $fls -Template $tmpl -Quantity ([int]$qty) -Durability 1.0 -AllowOverflow $AllowOverflow
            if ($r.ok -and -not $r.path) { $r['path'] = 'rmq' }
            $rmqGives++
        } else {
            # Offline, OR online with custom quality / unresolved fls → SQL
            $r = Invoke-DunePlayerGiveItem -Ip $Ip -PawnId $PawnId -Template $tmpl -Qty $qty -Quality ([int64]$qlevel)
            if ($r.ok) {
                $r['path'] = 'sql'
                if ($isOnline) {
                    $r['message'] = "$($r.message) Player is online — they must relog to see this item."
                }
            }
        }
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
    return @{ ok = $ok; message = $msg; results = $results.ToArray(); failures = $failures; total = $total }
}

# Repair equipped gear — OFFLINE only. Sets every durability item in the gear
# inventory types to GREATEST(catalog.max_durability, item.MaxDurability,
# item.CurrentDurability, item.DecayedMaxDurability), so a buggy/decayed
# MaxDurability can never leave repair below the factory-spec cap, but
# stat/perk-buffed ceilings (the item's own MaxDurability after equip-time
# bonuses) are preserved. Catalog miss => GREATEST of the item's three fields.
function Invoke-DunePlayerRepairGear {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }

    _Load-DuneProgressionNodesCatalog
    $invTypes = $script:DuneProgressionNodesCatalog.repairGearInventoryTypes
    $invTypesArr = '(' + (($invTypes | ForEach-Object { "$_::int" }) -join ',') + ')'

    $listSql = @"
SELECT i.id, i.template_id,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8, 0)        AS m,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, 0)    AS c,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'DecayedMaxDurability')::float8, 0) AS d,
       (i.stats->'FItemStackAndDurabilityStats'->1 ? 'CurrentDurability') AS has_c
FROM dune.items i
JOIN dune.inventories inv ON inv.id = i.inventory_id
WHERE inv.actor_id = $PawnId::bigint
  AND inv.inventory_type IN $invTypesArr
  AND i.stats ? 'FItemStackAndDurabilityStats';
"@
    $listRes = Invoke-DuneSqlQuery -Ip $Ip -Sql $listSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 60
    if (-not $listRes.ok) { return @{ ok = $false; error = "repair gear (lookup): $($listRes.error)" } }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($r in (ConvertTo-DuneRowMaps -Result $listRes)) {
        $tmpl = [string]$r['template_id']
        $iMax = [double]([string]$r['m'])
        $iCur = [double]([string]$r['c'])
        $iDec = [double]([string]$r['d'])
        $cMax = Get-DuneItemCatalogMaxDurability -TemplateId $tmpl
        $hasCur = ConvertTo-DuneBool $r['has_c']
        $target = Resolve-DuneRepairDurabilityTarget -CatalogMax $cMax -ItemMax $iMax -ItemCurrent $iCur -ItemDecayedMax $iDec -HasCurrent $hasCur
        if ($target -gt 0) {
            $iid  = [long]$r['id']
            $tval = Format-DuneFloatForSql -Value $target
            $values.Add("($iid::bigint, $tval::float8)")
        }
    }
    if ($values.Count -eq 0) {
        return @{ ok = $true; message = 'No gear with durability stats — nothing to repair.'; repaired = 0 }
    }

    $valuesClause = ($values -join ', ')
    $sql = @"
UPDATE dune.items i
SET stats = jsonb_set(jsonb_set(jsonb_set(i.stats,
        '{FItemStackAndDurabilityStats,1,MaxDurability}',        to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,CurrentDurability}',    to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,DecayedMaxDurability}', to_jsonb(tgt.val), true)
FROM (VALUES $valuesClause) AS tgt(item_id, val)
WHERE i.id = tgt.item_id
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

# Restore destroyed gear — OFFLINE only. Targets ONLY items that already have an
# FItemStackAndDurabilityStats block and whose CurrentDurability is 0 or NULL
# (Chopper's "completely dead" case the standard Repair didn't obviously cover).
# Same inventory_type scope as RepairGear. Each match is re-seeded to
# GREATEST(catalog.max_durability, item.MaxDurability, item.CurrentDurability,
# item.DecayedMaxDurability). It deliberately does NOT graft a durability block
# onto items that lack one — resources, consumables, and contract items
# legitimately have no durability and must be left alone.
function Invoke-DunePlayerRestoreDestroyedGear {
    param([string]$Ip, [long]$PawnId)
    if ($PawnId -le 0) { return @{ ok = $false; error = 'pawn_id is required.' } }
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $PawnId
    if (-not $off.ok) { return @{ ok = $false; error = $off.reason } }

    _Load-DuneProgressionNodesCatalog
    $invTypes = $script:DuneProgressionNodesCatalog.repairGearInventoryTypes
    $invTypesArr = '(' + (($invTypes | ForEach-Object { "$_::int" }) -join ',') + ')'

    $listSql = @"
SELECT i.id, i.template_id,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'MaxDurability')::float8, 0)        AS m,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, 0)    AS c,
       COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'DecayedMaxDurability')::float8, 0) AS d,
       (i.stats->'FItemStackAndDurabilityStats'->1 ? 'CurrentDurability') AS has_c
FROM dune.items i
JOIN dune.inventories inv ON inv.id = i.inventory_id
WHERE inv.actor_id = $PawnId::bigint
  AND inv.inventory_type IN $invTypesArr
  AND i.stats ? 'FItemStackAndDurabilityStats'
  AND COALESCE((i.stats->'FItemStackAndDurabilityStats'->1->>'CurrentDurability')::float8, 0) <= 0;
"@
    $listRes = Invoke-DuneSqlQuery -Ip $Ip -Sql $listSql -ReadOnly $true -MaxRows 5000 -TimeoutSec 60
    if (-not $listRes.ok) { return @{ ok = $false; error = "restore destroyed (lookup): $($listRes.error)" } }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($r in (ConvertTo-DuneRowMaps -Result $listRes)) {
        $tmpl = [string]$r['template_id']
        $iMax = [double]([string]$r['m'])
        $iCur = [double]([string]$r['c'])
        $iDec = [double]([string]$r['d'])
        $cMax = Get-DuneItemCatalogMaxDurability -TemplateId $tmpl
        $hasCur = ConvertTo-DuneBool $r['has_c']
        $target = Resolve-DuneRepairDurabilityTarget -CatalogMax $cMax -ItemMax $iMax -ItemCurrent $iCur -ItemDecayedMax $iDec -HasCurrent $hasCur
        if ($target -gt 0) {
            $iid  = [long]$r['id']
            $tval = Format-DuneFloatForSql -Value $target
            $values.Add("($iid::bigint, $tval::float8)")
        }
    }
    if ($values.Count -eq 0) {
        return @{ ok = $true; message = 'No destroyed items with a durability block — nothing to restore.'; restored = 0 }
    }

    $valuesClause = ($values -join ', ')
    $sql = @"
UPDATE dune.items i
SET stats = jsonb_set(jsonb_set(jsonb_set(i.stats,
        '{FItemStackAndDurabilityStats,1,MaxDurability}',        to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,CurrentDurability}',    to_jsonb(tgt.val), true),
        '{FItemStackAndDurabilityStats,1,DecayedMaxDurability}', to_jsonb(tgt.val), true)
FROM (VALUES $valuesClause) AS tgt(item_id, val)
WHERE i.id = tgt.item_id
RETURNING i.id::text AS item_id;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 5000 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = "restore destroyed: $($r.error)" } }
    $restored = @(ConvertTo-DuneRowMaps -Result $r).Count
    if ($restored -eq 0) {
        return @{ ok = $true; message = 'No destroyed items with a durability block — nothing to restore.'; restored = 0 }
    }
    return @{
        ok = $true
        message = "Restored $restored destroyed item(s) to full durability on pawn $PawnId."
        restored = $restored
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

    # target pawn coords (needed for both online and offline paths). Coords live in
    # the `transform` composite (transform.location.x/y/z), NOT a `location` column.
    $tgtSql = @"
SELECT (transform).location.x AS x,
       (transform).location.y AS y,
       (transform).location.z AS z
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

    # resolve partition ($partId, not $pid — $PID is a read-only automatic var)
    $partId = 0L
    if ($PartitionId -and $PartitionId.HasValue) { $partId = [int64]$PartitionId.Value }
    if ($partId -le 0) {
        $pSql = "SELECT id::text AS pid FROM dune.world_partition WHERE COALESCE(is_blocked, false) = false ORDER BY id LIMIT 1;"
        $pr = Invoke-DuneSqlQuery -Ip $Ip -Sql $pSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if ($pr.ok) {
            $pmaps = ConvertTo-DuneRowMaps -Result $pr
            if ($pmaps.Count -ge 1) { $partId = [int64](ConvertTo-DuneInt $pmaps[0]['pid']) }
        }
        if ($partId -le 0) { return @{ ok = $false; error = 'no unblocked world_partition rows found.' } }
    }

    $sql = "SELECT dune.admin_move_offline_player_to_partition('$safeFls'::text, $partId::bigint, ROW($tx::float8, $ty::float8, $tz::float8)::dune.Vector);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "admin_move_offline_player_to_partition: $($r.error)" } }
    return @{
        ok = $true
        message = "Teleported offline pawn $SourcePawnId -> ($tx, $ty, $tz) on partition $partId."
        path = 'offline'
        partition = $partId; x = $tx; y = $ty; z = $tz
    }
}

# ---------------------------------------------------------------------------
# Named teleport / respawn destinations. Each entry is a navigable map or hub
# with a verified world-partition id + an anchor coordinate (pulled from real
# actors on that map). `partition` drives admin_move_offline_player_to_partition
# for teleport; `respawnMap` is the dune.actors.map-style name written into a
# respawn row. Coords/partitions verified live 2026-06-23 against build 23654991.
# ---------------------------------------------------------------------------
$script:DuneTeleportDestinations = @(
    [ordered]@{ id = 'hagga_basin';   label = 'Hagga Basin';     respawnMap = 'HaggaBasin';       partition = 1;  x = 163939;  y = 316397;  z = 2939  }
    [ordered]@{ id = 'deep_desert';   label = 'Deep Desert';     respawnMap = 'DeepDesert';       partition = 8;  x = -265065; y = -35981;  z = 2720  }
    [ordered]@{ id = 'arrakeen';      label = 'Arrakeen';        respawnMap = 'Arrakeen';         partition = 3;  x = 6038;    y = 417;     z = 52228 }
    [ordered]@{ id = 'harko_village'; label = 'Harko Village';   respawnMap = 'HarkoVillage';     partition = 4;  x = 3630;    y = 1876;    z = 13794 }
    [ordered]@{ id = 'ruins_tsimpo';  label = 'Ruins of Tsimpo'; respawnMap = 'TheRuinsOfTsimpo'; partition = 28; x = 13393;   y = 16955;   z = 1710  }
)

function Get-DuneTeleportDestinations {
    $list = @()
    foreach ($d in $script:DuneTeleportDestinations) {
        $list += [ordered]@{ id = [string]$d.id; label = [string]$d.label; map = [string]$d.respawnMap; partition = [int64]$d.partition }
    }
    return $list
}

function Get-DuneTeleportDestinationById {
    param([string]$Id)
    $key = ([string]$Id).Trim()
    foreach ($d in $script:DuneTeleportDestinations) { if ($d.id -eq $key) { return $d } }
    return $null
}

# Teleport a player to a named map/hub destination. Offline-only at the route
# layer: this writes the player's partition + location, which the game caches in
# RAM while connected. Resolves the source by account -> FLS id, then calls the
# same admin_move_offline_player_to_partition primitive the teleport-to-player
# offline path uses.
function Invoke-DunePlayerTeleportToLocation {
    param([string]$Ip, [long]$AccountId, [string]$Destination)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $dest = Get-DuneTeleportDestinationById -Id $Destination
    if (-not $dest) { return @{ ok = $false; error = "unknown destination '$Destination'." } }

    $fls = Get-DuneRawFuncomId -Ip $Ip -AccountId $AccountId
    if (-not $fls.ok) { return @{ ok = $false; error = $fls.error } }
    $safeFls = ConvertTo-DuneSqlString $fls.funcom_id
    $x = [double]$dest.x; $y = [double]$dest.y; $z = [double]$dest.z; $part = [int64]$dest.partition

    $sql = "SELECT dune.admin_move_offline_player_to_partition('$safeFls'::text, $part::bigint, ROW($x::float8, $y::float8, $z::float8)::dune.vector);"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "teleport to location: $($r.error)" } }
    return @{
        ok = $true
        message = "Teleported to $($dest.label) (partition $part) - takes effect on next login."
        destination = [string]$dest.id; partition = $part; x = $x; y = $y; z = $z
    }
}

# Add a respawn point at a named destination for a player. NON-DESTRUCTIVE: this
# INSERTs a new Transform respawn row and leaves the player's existing respawn
# points intact. We deliberately do NOT call dune.update_respawn_locations(),
# which DELETES any existing rows not present in its input array. last_used set
# to now so the new point sorts as the most recent. Offline-only at the route.
function Invoke-DunePlayerSetRespawn {
    param([string]$Ip, [long]$AccountId, [string]$Destination)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $dest = Get-DuneTeleportDestinationById -Id $Destination
    if (-not $dest) { return @{ ok = $false; error = "unknown destination '$Destination'." } }

    $x = [double]$dest.x; $y = [double]$dest.y; $z = [double]$dest.z
    $safeMap = ConvertTo-DuneSqlString ([string]$dest.respawnMap)
    $safeGroup = ConvertTo-DuneSqlString ("Admin: " + [string]$dest.label)

    $sql = @"
INSERT INTO dune.player_respawn_locations
    (id, character_id, "group", locator_transform, locator_actor_id, locator_name, locator_name_index, map, dimension, last_used_timestamp)
VALUES (
    gen_random_uuid(), (SELECT id FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1), '$safeGroup',
    ROW(ROW($x::float8, $y::float8, $z::float8)::dune.vector, ROW(0,0,0,1)::dune.quaternion)::dune.transform,
    NULL, NULL, 0, '$safeMap', 0,
    (extract(epoch from now()) * 1000)::bigint
);
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "set respawn: $($r.error)" } }
    return @{
        ok = $true
        message = "Added a respawn point at $($dest.label) - takes effect on next login."
        destination = [string]$dest.id
    }
}

# ---------------------------------------------------------------------------
# §6 — Progression / journey / contracts / jobs / codex / tutorials
# ---------------------------------------------------------------------------

# Recruitment dialogue / contract-tracking tags per faction (Atreides=1, Harkonnen=2).
# Returns $null for unsupported factions (only houses have a recruitment questline).
function Get-DuneFactionRecruitTags {
    param([int]$FactionId)
    switch ($FactionId) {
        1 { @{ dialogue='DialogueFlags.Factions.SentToMeetHawat';      aligned='DialogueFlags.Factions.AlignedAtreides';  metRec='DialogueFlags.Factions.MetHawat';        factionUnlocked='Contract.Tracking.AtreidesFactionUnlocked';  recruitmentDone='Contract.Tracking.AtreidesRecruitmentCompleted' } }
        2 { @{ dialogue='DialogueFlags.Factions.SentToPiterDeVries';   aligned='DialogueFlags.Factions.AlignedHarkonnen'; metRec='DialogueFlags.Factions.MetPiterDeVries';  factionUnlocked='Contract.Tracking.HarkonnenFactionUnlocked'; recruitmentDone='Contract.Tracking.HarkonnenRecruitmentCompleted' } }
        default { $null }
    }
}

# UPSERT for the controller actor's FactionPlayerComponent.m_FactionDataArray entry.
# Unlike $script:DuneFactionComponentRepSqlTpl (which only UPDATEs an existing entry
# and silently no-ops when the array entry is missing), this creates the
# FactionPlayerComponent / appends the faction entry / updates it in place, matching
# the exact shape the game writes for a recruited member:
#   { "Faction": { "Name": <name> }, "timestamp": <epoch>, "ReputationAmount": <int> }
# Validated live (BEGIN/ROLLBACK) for create-from-nothing, append, and update.
function Get-DuneFactionComponentUpsertSql {
    param([long]$ActorId, [string]$FactionName, [int]$Rep)
    $safe = ($FactionName -replace "'", "''")
    return @"
UPDATE dune.actors a SET properties = jsonb_set(
    COALESCE(a.properties, '{}'::jsonb), '{FactionPlayerComponent}',
    COALESCE(a.properties->'FactionPlayerComponent', '{}'::jsonb) || jsonb_build_object('m_FactionDataArray',
      COALESCE((SELECT jsonb_agg(e) FROM jsonb_array_elements(
                  COALESCE(a.properties->'FactionPlayerComponent'->'m_FactionDataArray', '[]'::jsonb)) e
                WHERE e->'Faction'->>'Name' <> '$safe'), '[]'::jsonb)
      || jsonb_build_array(jsonb_build_object('Faction', jsonb_build_object('Name', '$safe'),
           'timestamp', to_jsonb(extract(epoch from now())), 'ReputationAmount', to_jsonb($($Rep)::int)))), true)
  WHERE a.id = $($ActorId)::bigint;
"@
}

# Returns the faction_id the controller is currently aligned to, or 0 if unaligned.
# (change_player_faction(->neutral) deletes the player_faction row, so a present row
# means the character is currently a faction member.)
function Get-DunePlayerAlignedFaction {
    param([string]$Ip, [long]$ControllerId)
    $sql = "SELECT faction_id::text AS fid FROM dune.player_faction WHERE actor_id = $ControllerId::bigint LIMIT 1;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return 0 }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return 0 }
    return [int](ConvertTo-DuneInt $maps[0]['fid'])
}

# Establishes FULL faction membership for an OFFLINE, currently-UNALIGNED player so
# the game honours it after a battlegroup restart: alignment + the recruitment /
# ClimbTheRanks journey nodes + faction tags + the FactionPlayerComponent entry +
# reputation. This mirrors a real recruited member (the trader unlocks and the
# recruiter quest stops re-offering), closing the gap where rep-only writes landed
# on rows the game ignores. Atreides/Harkonnen only.
function Invoke-DuneEstablishFactionMembership {
    param([string]$Ip, [long]$ControllerId, [long]$AccountId, [int]$FactionId, [int]$Rep)
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller id is required.' } }
    if ($AccountId   -le 0) { return @{ ok = $false; error = 'account id is required.' } }
    $recruit = Get-DuneFactionRecruitTags $FactionId
    if (-not $recruit) { return @{ ok = $false; error = 'establish-membership supports Atreides or Harkonnen only.' } }
    if ($Rep -lt 0) { $Rep = 0 }
    if ($Rep -gt $script:DuneFactionRepCap) { $Rep = $script:DuneFactionRepCap }

    $factionName  = Get-DuneFactionDisplayName $FactionId
    $factionLower = $factionName.ToLowerInvariant()
    $tier   = Convert-DuneRepToTier $Rep
    $preset = if ($tier -ge 19) { 'rank19_eligible' } else { 'ch3_start' }

    $fls = Get-DuneRawFuncomId -Ip $Ip -AccountId $AccountId
    if (-not $fls.ok) { return @{ ok = $false; error = $fls.error } }
    $safeFls = ConvertTo-DuneSqlString $fls.funcom_id

    $nodes = Get-DuneNodesForPreset -Faction $factionLower -Preset $preset
    if ($nodes.Count -eq 0) { return @{ ok = $false; error = 'progression-nodes catalog empty (data file missing?).' } }
    $nodesArr = ConvertTo-DunePgTextArray $nodes

    $allTags = @(
        $recruit.dialogue, $recruit.aligned, $recruit.metRec,
        $recruit.factionUnlocked, $recruit.recruitmentDone,
        'DialogueFlags.Factions.FactionIntro',
        'DialogueFlags.Factions.FactionRank1',
        'DialogueFlags.Factions.FactionRank3',
        'DialogueFlags.Factions.MetARecruiter',
        'DialogueFlags.Factions.PlayedAllegianceCinematic',
        'DialogueFlags.Factions.SeenAnvilCinematic'
    )
    if ($tier -ge 19) { $allTags += 'Journey.LandsraadContractsUnlocked' }
    for ($t = 0; $t -le 5; $t++) { $allTags += "Faction.$factionName.Tier$t" }
    $tagsArr = ConvertTo-DunePgTextArray $allTags

    $compSql = Get-DuneFactionComponentUpsertSql -ActorId $ControllerId -FactionName $factionName -Rep $Rep

    # Single transaction: complete recruitment nodes, align, write tags, set rep on
    # the table, and upsert the FactionPlayerComponent entry the game reads at login.
    $tx = @"
BEGIN;
SELECT dune.complete_journey_story_nodes_for_player('$safeFls'::text, $nodesArr);
SELECT dune.change_player_faction($ControllerId::bigint, $FactionId::smallint, 3::smallint, NOW()::timestamp);
SELECT dune.update_player_tags($AccountId::bigint, $tagsArr, ARRAY[]::text[]);
SELECT dune.set_player_faction_reputation($ControllerId::bigint, $FactionId::smallint, $Rep::integer);
$compSql
COMMIT;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $tx -ReadOnly $false -MaxRows 1 -TimeoutSec 90
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "establish-membership tx: $($r.error)" }
    }

    $tierName = Get-DuneFactionTierName $FactionId $tier
    return @{
        ok = $true
        faction = $factionName; faction_id = $FactionId; rep = $Rep; tier = $tier; tier_name = $tierName
        nodes = $nodes.Count; controller_id = $ControllerId
        message = "Established $factionName membership at tier $tier ($tierName), rep $Rep - $($nodes.Count) recruitment nodes completed + faction tags + standing. Takes effect on next login."
    }
}

function Invoke-DunePlayerProgressionUnlock {
    param([string]$Ip, [long]$ActorId, [string]$Faction, [string]$Preset)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $factionLower = $Faction.ToLowerInvariant()
    $factionID = switch ($factionLower) {
        'atreides'  { 1 }
        'harkonnen' { 2 }
        default     { 0 }
    }
    if ($factionID -eq 0) { return @{ ok = $false; error = 'faction must be atreides or harkonnen' } }
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

    $factionName = Get-DuneFactionDisplayName $factionID
    $targetRep = $script:DuneFactionTierThresholds[$targetTier]
    if ($targetTier -gt 0) { $targetRep++ }

    $res = Invoke-DuneEstablishFactionMembership -Ip $Ip -ControllerId $controllerID -AccountId $accountID -FactionId $factionID -Rep $targetRep
    if ($res.ok) {
        $res.message = ("Progression unlock ($presetLower/$factionLower): $($res.nodes) journey nodes completed + " +
                        "$factionName tier tags 0-5 + rep tier $($res.tier) on controller $controllerID - takes effect on next login.")
    }
    return $res
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
        $nodeUpdates += "UPDATE dune.journey_story_node SET complete_condition_state='false'::jsonb, has_pending_reward=false WHERE character_id IN (SELECT id FROM dune.player_state WHERE account_id=$accountID::bigint) AND (story_node_id='$safe' OR story_node_id LIKE '$safe.%');`n"
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

# Completely wipe a player's faction progression so they can start fresh.
# Removes ALL Atreides/Harkonnen journey nodes (DA_FQ_ClimbTheRanks*), zeroes
# faction reputation + alignment, and deletes every faction/rank/recruitment tag
# for the chosen faction (or both). Offline-only — the game holds this state in
# RAM while connected. $Faction = 'atreides' | 'harkonnen' | 'both'.
function Invoke-DunePlayerResetFaction {
    param([string]$Ip, [long]$AccountId, [string]$Faction, [bool]$Deep = $false)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $fl = ([string]$Faction).ToLowerInvariant()
    if ($fl -ne 'atreides' -and $fl -ne 'harkonnen' -and $fl -ne 'both') {
        return @{ ok = $false; error = 'faction must be atreides, harkonnen, or both' }
    }
    $controllerID = Get-DunePlayerControllerFromAccount -Ip $Ip -AccountId $AccountId
    if ($controllerID -le 0) { return @{ ok = $false; error = "no player_controller for account $AccountId." } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId

    $factions = if ($fl -eq 'both') { @('Atreides','Harkonnen') } else { @((Get-Culture).TextInfo.ToTitleCase($fl)) }
    $charScope = "character_id IN (SELECT id FROM dune.player_state WHERE account_id=$AccountId::bigint)"
    $isBoth = ($fl -eq 'both')

    # Build the tag LIKE patterns for the wipe. The wildcard %Atreides%/%Harkonnen%/
    # %Atre%/%Hark% patterns handle per-faction suffixed tags (e.g.
    # R*C*Completed_Atreides, Fac_Atre_*, DialogueFlags.*Atre*).
    # Single-faction scope: only wipe tags that clearly belong to that faction.
    # 'both' scope: also wipe the shared / neutral faction-storyline markers below.
    $likes = [System.Collections.Generic.List[string]]::new()
    [void]$likes.Add("tag LIKE 'Faction.%'")
    [void]$likes.Add("tag LIKE 'FactionStoryline%'")
    [void]$likes.Add("tag LIKE 'DialogueFlags.Factions.%'")
    [void]$likes.Add("tag LIKE 'Contract.Faction.%'")
    [void]$likes.Add("tag = 'Journey.LandsraadContractsUnlocked'")
    [void]$likes.Add("tag LIKE 'Contract.Tracking.%FactionUnlocked'")
    [void]$likes.Add("tag LIKE 'Contract.Tracking.%RecruitmentCompleted'")
    if ($isBoth) {
        [void]$likes.Add("tag LIKE '%Atreides%'")
        [void]$likes.Add("tag LIKE '%Harkonnen%'")
        [void]$likes.Add("tag LIKE '%Atre%'")
        [void]$likes.Add("tag LIKE '%Hark%'")
    } else {
        # single-faction: match the specific faction's tag variants
        if ($fl -eq 'atreides') {
            [void]$likes.Add("tag LIKE '%Atreides%'")
            [void]$likes.Add("tag LIKE '%Atre%'")
        } else {
            [void]$likes.Add("tag LIKE '%Harkonnen%'")
            [void]$likes.Add("tag LIKE '%Hark%'")
        }
    }
    # --- FactionStory rank grid + milestones (R*C*Completed, SentToMeetAndreaGanan,
    #     TalkedToDeserter, TestOfLoyaltyCompleted, etc.). Per-faction rows are
    #     suffixed (R*C*Completed_Atreides / _Harkonnen) and already covered above;
    #     the un-suffixed neutral shared markers here are only safe on 'both'.
    [void]$likes.Add("tag LIKE 'Contract.Tracking.FactionStory.%'")
    # --- Named faction storyline beats (FindSkorda, RecoverSpyReport). A player is on
    #     only one faction path at a time, so these are safe to wipe on any scope.
    [void]$likes.Add("tag LIKE 'Contract.Tracking.Completed.FactionStoryline.%'")
    # --- MaasKharet faction-agent contracts + dialogue + locations + lore.
    [void]$likes.Add("tag LIKE 'Contract.Tracking.Completed.MaasKharet%'")
    [void]$likes.Add("tag LIKE 'Contract.Target.Dialogue.FactionRank%'")
    [void]$likes.Add("tag LIKE 'Contract.Target.Location.MaasKharet%'")
    [void]$likes.Add("tag LIKE 'Contract.Target.Lore.MaasKharet%'")
    # --- Rank 4 Arrakeen Social Hub banquet sub-state (BlackMarketVendorInterrogated,
    #     WarehouseInvestigated). Shared faction-milestone dialogue.
    [void]$likes.Add("tag LIKE 'Contract.Target.Dialogue.Arrakeen_Social_Hub.Banquet.%'")
    # --- Faction-recruiter introduction flags. Atreides = ThufirHawat; Harkonnen =
    #     PiterDeVries. MaasKharet is the shared cross-faction agent. Match by name
    #     so single-faction scope only clears the matching recruiter.
    if ($isBoth -or $fl -eq 'atreides') {
        [void]$likes.Add("tag = 'DialogueFlags.IntroductionDone.ThufirHawat'")
    }
    if ($isBoth -or $fl -eq 'harkonnen') {
        [void]$likes.Add("tag = 'DialogueFlags.IntroductionDone.PiterDeVries'")
    }
    [void]$likes.Add("tag = 'DialogueFlags.IntroductionDone.MaasKharet'")
    [void]$likes.Add("tag = 'Contract.Tracking.FactionsKytheriaInvestigationCompleted'")
    $likesJoined = ($likes -join ' OR ')
    # Reset ClimbTheRanks journey nodes to incomplete (NOT delete — deleting stops
    # the game re-offering them, so the recruiter quest can't be replayed). Also
    # clear reveal_condition_state — otherwise the STORY tab still renders every
    # previously-revealed chapter as an active quest card (root cause of the stuck
    # "Hunting Skorda" and similar cards observed on live characters).
    # Deep reset — optional. Wipe faction-related Dunipedia lore fragments so the
    # character reads as if the faction storyline was never encountered. Neutral
    # world lore (ManualOfTheFriendlyDesert, WarForArrakis.Bandits) is preserved.
    $deepPatterns = [System.Collections.Generic.List[string]]::new()
    if ($Deep) {
        if ($isBoth -or $fl -eq 'atreides') {
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_KnownUniverse.TheRiseOfHouseAtreides%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Ariste Atreides%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.House Atreides%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Leto Atreides%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Paul Atreides%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Jessica%'")
        }
        if ($isBoth -or $fl -eq 'harkonnen') {
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Baron Vladimir Harkonnen%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Feyd Rautha Harkonnen%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.Glossu Rabban Harkonnen%'")
            [void]$deepPatterns.Add("story_node_id LIKE 'DA_Dunipedia_WarForArrakis.House Harkonnen%'")
        }
    }
    $hasDeep = ($Deep -and $deepPatterns.Count -gt 0)
    $deepJoined = if ($hasDeep) { ($deepPatterns -join ' OR ') } else { '' }

    # --- Pre-count what will change, for a useful success message. Character
    #     name too, so the toast reads naturally.
    $loreCountSql = if ($hasDeep) {
        "(SELECT COUNT(*) FROM dune.journey_story_node WHERE $charScope AND ($deepJoined))"
    } else { '0::bigint' }
    $countSql = @"
SELECT
  (SELECT COALESCE(properties->'CharacterProfileComponent'->>'m_CharacterName','account '||$AccountId::text) FROM dune.actors WHERE id=$controllerID::bigint) AS name,
  (SELECT COUNT(*) FROM dune.player_tags WHERE $charScope AND ($likesJoined)) AS tag_n,
  (SELECT COUNT(*) FROM dune.journey_story_node WHERE $charScope AND story_node_id LIKE 'DA_FQ_ClimbTheRanks%') AS node_n,
  $loreCountSql AS lore_n
"@
    $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $countSql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    $tagN = 0; $nodeN = 0; $loreN = 0; $playerName = "account $AccountId"
    if ($cr.ok -and $cr.rows -and $cr.rows.Count -gt 0) {
        $row0 = $cr.rows[0]
        if ($row0.name) { $playerName = [string]$row0.name }
        $tagN  = [int]$row0.tag_n
        $nodeN = [int]$row0.node_n
        $loreN = [int]$row0.lore_n
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('BEGIN;')
    # zero rep + reset alignment to None (3) so the recruiter funnel re-triggers.
    # Faction reputation is dual-written: the player_faction_reputation TABLE *and*
    # the pawn's FactionPlayerComponent (actors.properties). The game reads the
    # component at runtime, so zeroing only the table leaves a stale maxed value
    # that reappears on login — we must zero BOTH (mirrors give-rep / progression).
    [void]$sb.AppendLine("SELECT dune.set_player_faction_reputation($controllerID::bigint, 1::smallint, 0::integer);")
    [void]$sb.AppendLine("SELECT dune.set_player_faction_reputation($controllerID::bigint, 2::smallint, 0::integer);")
    [void]$sb.AppendLine([string]::Format($script:DuneFactionComponentRepSqlTpl, $controllerID, 'Atreides', 0))
    [void]$sb.AppendLine([string]::Format($script:DuneFactionComponentRepSqlTpl, $controllerID, 'Harkonnen', 0))
    [void]$sb.AppendLine("SELECT dune.change_player_faction($controllerID::bigint, 3::smallint, 3::smallint, NOW()::timestamp);")
    [void]$sb.AppendLine("DELETE FROM dune.player_tags WHERE $charScope AND ($likesJoined);")
    [void]$sb.AppendLine("UPDATE dune.journey_story_node SET complete_condition_state='false'::jsonb, reveal_condition_state='false'::jsonb, has_pending_reward=false WHERE $charScope AND story_node_id LIKE 'DA_FQ_ClimbTheRanks%';")
    if ($hasDeep) {
        [void]$sb.AppendLine("UPDATE dune.journey_story_node SET complete_condition_state='false'::jsonb, reveal_condition_state='false'::jsonb, has_pending_reward=false WHERE $charScope AND ($deepJoined);")
    }
    # Remove lingering faction-storyline contract ITEMS (Fac_Atre_* / Fac_Hark_*) from
    # the pawn's contract inventory (inventory_type 29). The rep/tag/journey reset above
    # does NOT touch these item rows, so without this the completed-but-uncleared faction
    # contract cards keep showing in the Arrakeen Contract tab after a wipe (e.g. a stuck
    # "Skorda's Last Stand: Report to Hawat" or "The Last Beacon"). Then clear the pawn's
    # tracked-contract pointer if it now dangles (points at a row we just deleted).
    # Non-faction contracts (Survival/Trainer/Landsraad) are intentionally left alone.
    if ($pawnID -gt 0) {
        [void]$sb.AppendLine("DELETE FROM dune.items WHERE template_id='ContractItem' AND inventory_id IN (SELECT id FROM dune.inventories WHERE actor_id=$pawnID::bigint AND inventory_type=29) AND (stats->'FContractItemStats'->1->'ContractName'->>'Name' LIKE 'Fac_Atre_%' OR stats->'FContractItemStats'->1->'ContractName'->>'Name' LIKE 'Fac_Hark_%');")
        [void]$sb.AppendLine("UPDATE dune.actors a SET properties = jsonb_set(a.properties, '{ContractsCoordinatorComponent,m_TrackedContractItemUid}', to_jsonb('!!itm#0'::text)) WHERE a.id=$pawnID::bigint AND a.properties ? 'ContractsCoordinatorComponent' AND COALESCE(a.properties->'ContractsCoordinatorComponent'->>'m_TrackedContractItemUid','!!itm#0') <> '!!itm#0' AND NOT EXISTS (SELECT 1 FROM dune.items it WHERE ('!!itm#'||it.id::text) = a.properties->'ContractsCoordinatorComponent'->>'m_TrackedContractItemUid');")
    }
    [void]$sb.AppendLine('COMMIT;')

    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sb.ToString() -ReadOnly $false -MaxRows 1 -TimeoutSec 120
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "reset-faction tx: $($r.error)" }
    }
    $lorePart = if ($hasDeep) { ", cleared $loreN Dunipedia lore node(s)" } else { '' }
    $msg = "Reset faction for '$playerName' ($fl): removed $tagN tag(s), reset $nodeN ClimbTheRanks node(s)$lorePart. Takes effect on next login."
    return @{ ok = $true; message = $msg; faction = $fl; deep = [bool]$Deep; tags = $tagN; nodes = $nodeN; lore = $loreN }
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
    $totalRecipes = 0
    $errs = @()
    foreach ($node in $preset.nodes) {
        $r = Invoke-DunePlayerCompleteJourneyNode -Ip $Ip -AccountId $AccountId -NodeId $node -SkipMsg
        if ($r.ok) { $completed++; $totalRecipes += [int]$r.recipes }
        else { $errs += "$node : $($r.error)" }
    }
    $total = @($preset.nodes).Count
    $ok = $errs.Count -eq 0
    $msg = "Applied preset '$PresetId' ($($preset.name)): completed $completed/$total journey node(s), granted $totalRecipes recipe(s)."
    if ($errs.Count -gt 0) { $msg += " Failures: $($errs -join '; ')" }
    return @{ ok = $ok; message = $msg; completed = $completed; total = $total; recipes = $totalRecipes }
}

function Invoke-DunePlayerCompleteJourneyNode {
    param([string]$Ip, [long]$AccountId, [string]$NodeId, [switch]$SkipMsg)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $NodeId) { return @{ ok = $false; error = 'node_id is required.' } }
    $safeNode = ConvertTo-DuneSqlString $NodeId

    # NOTE: the Funcom 1.4.10.0 patch rekeyed dune.journey_story_node from
    # account_id to character_id (= dune.player_state.id), so writes here resolve
    # the account to its character via a subquery, exactly as Funcom's own
    # save_journey_story_node()/delete_journey_story_node() stored functions do
    # internally. This keeps the existing subtree (story_node_id LIKE 'x.%') and
    # partial-field semantics that a single-node stored-function upsert can't.
    $upd = @"
UPDATE dune.journey_story_node
SET complete_condition_state = 'true'::jsonb,
    reveal_condition_state   = 'true'::jsonb
WHERE character_id IN (SELECT id FROM dune.player_state WHERE account_id = $AccountId::bigint)
  AND (story_node_id = '$safeNode' OR story_node_id LIKE '$safeNode.%');
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "complete node: $($r.error)" } }
    $updated = (Get-DuneSqlAffected $r)
    if ($updated -eq 0) {
        $ins = @"
INSERT INTO dune.journey_story_node
    (character_id, story_node_id, has_pending_reward,
     complete_condition_state, reveal_condition_state,
     fail_condition_state, metadata_state, reset_group)
VALUES ((SELECT id FROM dune.player_state WHERE account_id = $AccountId::bigint LIMIT 1), '$safeNode', false,
    'true'::jsonb, 'true'::jsonb,
    '{}'::jsonb, '{}'::jsonb,
    'Default'::dune.JourneyStoryResetGroup);
"@
        $ir = Invoke-DuneSqlQuery -Ip $Ip -Sql $ins -ReadOnly $false -MaxRows 1 -TimeoutSec 30
        if (-not $ir.ok) { return @{ ok = $false; error = "insert node: $($ir.error)" } }
        $updated = 1
    }

    $tags = @(Get-DuneTagsForJourneyNodeSubtree -NodeId $NodeId)
    # Reward-unblock tags (e.g. the Find the Fremen 3rd active-ability slot +
    # prescience) are gated by Journey.RewardsUnblocked, which the game sets via a
    # cutscene - NOT by journey-node completion - so it is not in the node->tag map.
    # Apply it here so EVERY completion path (Apply Quick Preset, Unlock Main Quest,
    # single Complete) grants it. See $script:DuneJourneyRewardUnblockRoots.
    $tags = @($tags + @(Get-DuneRewardUnblockTagsForJourneyNode -NodeId $NodeId) | Select-Object -Unique)
    $bumpRes = Invoke-DuneApplyTagsWithTierBump -Ip $Ip -AccountId $AccountId -Tags $tags
    if (-not $bumpRes.ok) { return @{ ok = $false; error = $bumpRes.error } }

    # Grant any recipes this subtree awards. The recipe award (stored on the pawn
    # TechKnowledge) is what unlocks the related ability slot / gear - not a tag -
    # so every journey-completion path must grant it here. Best-effort: a missing
    # pawn TechKnowledge component must not fail the journey completion.
    $recipes = Get-DuneRecipesForJourneyNodeSubtree -NodeId $NodeId
    $recipeCount = 0
    foreach ($rcp in $recipes) {
        $rr = Invoke-DuneGrantRecipe -Ip $Ip -AccountId $AccountId -RecipeKey $rcp
        if ($rr.ok) { $recipeCount++ }
    }
    $recipeMsg = if ($recipeCount -gt 0) { ", +$recipeCount recipe(s)" } else { '' }

    # Enable SpiceVision (Prescience / 3rd active-ability slot) for the Find the
    # Fremen questline. Gated by an FGL component flag the game's 4th-Trial quest
    # script sets in-game - not the journey nodes, the tag, or the recipe - so it
    # must be applied explicitly here or the slot stays locked. Best-effort: a
    # failure (or a pawn with no spice component) never fails the completion.
    $spiceApplied = $false
    if (Test-DuneNodeTriggersSpiceVision -NodeId $NodeId) {
        $sv = Invoke-DuneGrantSpiceVision -Ip $Ip -AccountId $AccountId
        if ($sv.ok -and $sv.applied) { $spiceApplied = $true }
    }
    $spiceMsg = if ($spiceApplied) { ', enabled Prescience (3rd ability slot)' } else { '' }

    if ($SkipMsg) { return @{ ok = $true; recipes = $recipeCount; spiceVision = $spiceApplied } }
    return @{
        ok = $true
        message = "Completed $NodeId + $updated node(s)$($bumpRes.extra)$recipeMsg$spiceMsg - takes effect on next login"
        nodes = $updated; tags = $tags.Count; recipes = $recipeCount; spiceVision = $spiceApplied
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
WHERE character_id IN (SELECT id FROM dune.player_state WHERE account_id = $AccountId::bigint)
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

function Invoke-DunePlayerResetJourneyNodes {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }

    $upd = @"
UPDATE dune.journey_story_node
SET complete_condition_state = 'false'::jsonb,
    has_pending_reward       = false
WHERE character_id IN (SELECT id FROM dune.player_state WHERE account_id = $AccountId::bigint);
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $upd -ReadOnly $false -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = "reset journey nodes: $($r.error)" } }
    $updated = Get-DuneSqlAffected $r

    $allTags = Get-DuneAllJourneyTags
    $extra = ''
    if ($allTags.Count -gt 0) {
        $arr = ConvertTo-DunePgTextArray $allTags
        $rt = "SELECT dune.update_player_tags($AccountId::bigint, ARRAY[]::text[], $arr);"
        $rr = Invoke-DuneSqlQuery -Ip $Ip -Sql $rt -ReadOnly $false -MaxRows 1 -TimeoutSec 60
        if (-not $rr.ok) { return @{ ok = $false; error = "remove all journey tags: $($rr.error)" } }
        $extra = ", removed $($allTags.Count) journey tag(s)"
    }
    return @{ ok = $true; message = "Reset journey for account $AccountId - reset $updated node(s)$extra"; nodes = $updated; tags_removed = $allTags.Count }
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

# Clear a dangling "tracked contract" pointer on the player's pawn. An Arrakeen
# Contract-tab card is a `ContractItem` row in the pawn's contract inventory
# (inventory_type 29); the *active/tracked* one is whichever item the pawn's
# ContractsCoordinatorComponent.m_TrackedContractItemUid points at (format
# '!!itm#<items.id>', '!!itm#0' = nothing tracked). When a contract item is
# dismissed/deleted out-of-band (Complete Contract's dismiss-by-name, or the
# faction-item purge in Reset Faction) the pointer can be left referencing the
# now-deleted row, which the game still renders as a ghost card (and keeps Hawat
# gated on the "occupational hazard" line). Reset the pointer to '!!itm#0' ONLY
# when it points at an items.id that no longer exists - a valid, still-owned tracked
# contract is never touched, so this is a safe no-op on a healthy character.
#
# This (plus the item removal itself) - NOT any journey_story_node edit - is what
# actually clears the card: verified live on a reference server where a completed
# faction contract item + its tracked pointer kept a card visible even though the
# matching journey node was already fully consumed to '{}'.
function Invoke-DuneClearDanglingTrackedContract {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $true; cleared = 0 } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $true; cleared = 0 } }
    $sql = @"
UPDATE dune.actors a
SET properties = jsonb_set(a.properties, '{ContractsCoordinatorComponent,m_TrackedContractItemUid}', to_jsonb('!!itm#0'::text))
WHERE a.id = $pawnID::bigint
  AND a.properties ? 'ContractsCoordinatorComponent'
  AND COALESCE(a.properties->'ContractsCoordinatorComponent'->>'m_TrackedContractItemUid', '!!itm#0') <> '!!itm#0'
  AND NOT EXISTS (
      SELECT 1 FROM dune.items it
      WHERE ('!!itm#' || it.id::text) = a.properties->'ContractsCoordinatorComponent'->>'m_TrackedContractItemUid'
  );
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "clear tracked contract: $($r.error)" } }
    return @{ ok = $true; cleared = (Get-DuneSqlAffected $r) }
}

# ---------------------------------------------------------------------------
# Fresh Start (keep builds & cosmetics) -- snapshot + restore-by-name.
#
# A genuinely-fresh character can ONLY be produced by the game engine: the player
# deletes the character in-game, recreates it, and spawns. An in-place DB wipe
# does NOT work -- the engine rebuilds the journey journal, skill-tree scaffold
# and ability slots from the character's footprint on every login (verified live
# 2026-07-03: deleting all 1979 non-achievement journey rows just made the engine
# recreate them and reveal 1195). So Fresh Start does not wipe anything.
#
# Instead it preserves the two things a player is entitled to keep across a fresh
# restart -- their unlocked BUILDING SETS/pieces (dune.building_progression) and
# COSMETICS (actors.properties->CustomizationLibraryActorComponent). Character
# NAME is the stable key across delete+recreate (account_id / character_id change;
# the name does not). Flow:
#   1) Snapshot builds + cosmetics BEFORE the delete -> saved to
#      %APPDATA%\DuneServer\fresh-start-snapshots.json keyed by name.
#   2) Player deletes + recreates the character in-game with the SAME name, spawns.
#   3) Restore-by-name grants the snapshot's building sets + cosmetics onto the
#      new character (offline-only; unioned with the fresh character's starter set
#      so nothing is lost).
# ---------------------------------------------------------------------------

function Get-DuneFreshStartSnapshotPath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir 'fresh-start-snapshots.json')
}

function Get-DuneFreshStartSnapshots {
    $path = Get-DuneFreshStartSnapshotPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return @() }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $list = if ($obj -is [System.Array]) { $obj } elseif ($obj.snapshots) { $obj.snapshots } else { @() }
        return @($list)
    } catch { return @() }
}

function Save-DuneFreshStartSnapshots {
    param($Snapshots)
    $path = Get-DuneFreshStartSnapshotPath
    $json = @{ snapshots = @($Snapshots) } | ConvertTo-Json -Depth 60
    $tmp = "$path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Metadata-only list of saved snapshots for the UI (no bulky cosmetics blob).
function Get-DuneFreshStartSnapshotList {
    $out = @()
    foreach ($s in (Get-DuneFreshStartSnapshots)) {
        $out += [ordered]@{
            name      = [string]$s.name
            saved_at  = [string]$s.saved_at
            sets      = @($s.building_sets).Count
            pieces    = @($s.buildable_pieces).Count
            cosmetics = [bool]([string]$s.cosmetics)
        }
    }
    return @($out)
}

# Capture a character's unlocked building sets/pieces + cosmetics to the snapshot
# store, keyed by character name. Run this BEFORE the player deletes the character
# (the data is character-bound and is destroyed with the character).
function Invoke-DunePlayerSnapshotBuilds {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $false; error = "no pawn for account $AccountId." } }

    $sql = @"
SELECT
  (SELECT character_name FROM dune.player_state WHERE account_id=$AccountId::bigint LIMIT 1) AS name,
  (SELECT id::text FROM dune.player_state WHERE account_id=$AccountId::bigint LIMIT 1) AS character_id,
  (SELECT to_json(learned_building_sets)::text FROM dune.building_progression WHERE character_id=(SELECT id FROM dune.player_state WHERE account_id=$AccountId::bigint LIMIT 1)) AS sets,
  (SELECT to_json(new_buildable_pieces)::text FROM dune.building_progression WHERE character_id=(SELECT id FROM dune.player_state WHERE account_id=$AccountId::bigint LIMIT 1)) AS pieces,
  (SELECT (properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList}')::text FROM dune.actors WHERE id=$pawnID::bigint) AS cosmetics;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = "snapshot read: $($r.error)" } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $false; error = "no character for account $AccountId." } }
    $row = $maps[0]
    $name = [string]$row['name']
    if (-not $name) { return @{ ok = $false; error = 'character has no name.' } }

    $sets = @(); $pieces = @()
    try { if ([string]$row['sets'])   { $sets   = @([string]$row['sets']   | ConvertFrom-Json) } } catch {}
    try { if ([string]$row['pieces']) { $pieces = @([string]$row['pieces'] | ConvertFrom-Json) } } catch {}
    $cosmeticsJson = [string]$row['cosmetics']

    $snap = [ordered]@{
        name             = $name
        saved_at         = (Get-Date).ToUniversalTime().ToString('o')
        account_id       = $AccountId
        character_id     = [int64](ConvertTo-DuneInt $row['character_id'])
        building_sets    = @($sets)
        buildable_pieces = @($pieces)
        cosmetics        = $cosmeticsJson   # raw JSON string, reapplied verbatim
    }
    # Replace any existing snapshot for the same name (case-insensitive -ne).
    $others = @(Get-DuneFreshStartSnapshots | Where-Object { [string]$_.name -ne $name })
    Save-DuneFreshStartSnapshots -Snapshots (@($snap) + $others)

    $cosMsg = if ($cosmeticsJson) { 'cosmetics captured' } else { 'no cosmetics found' }
    return @{
        ok = $true
        message = "Snapshot saved for '$name' - $($sets.Count) building set(s), $($pieces.Count) piece(s), $cosMsg. Now delete + recreate the character with the SAME name in-game, spawn, then use Restore."
        name = $name; sets = $sets.Count; pieces = $pieces.Count; cosmetics = [bool]$cosmeticsJson
    }
}

# Fresh Start Step 1 (combined): snapshot the account's purchases + cosmetics to
# disk, then run the full Delete Account cleanup (character rows, actors, world
# ownership 3-rule cleanup, per-player state, guild/party membership, etc.).
# On snapshot failure, the delete is skipped and the caller retries. On delete
# failure, the snapshot is still on disk so Restore can pick it up after the
# operator resolves whatever blocked the delete (usually the offline gate).
function Invoke-DunePlayerFreshStartWipe {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }

    $snap = Invoke-DunePlayerSnapshotBuilds -Ip $Ip -AccountId $AccountId
    if (-not $snap.ok) { return @{ ok = $false; error = "snapshot failed - delete not attempted: $($snap.error)" } }

    $del = Invoke-DunePlayerDeleteAccount -Ip $Ip -AccountId $AccountId
    if (-not $del.ok) {
        return @{ ok = $false; error = "snapshot saved for '$($snap.name)', but delete failed: $($del.error)" ; snapshot_saved = $true; name = $snap.name }
    }

    $cosMsg = if ($snap.cosmetics) { ' + cosmetics' } else { '' }
    return @{
        ok = $true
        message = "Fresh Start: snapshotted '$($snap.name)' ($($snap.sets) set(s), $($snap.pieces) piece(s)$cosMsg) and wiped account $AccountId. Recreate the character in-game with the SAME name, spawn in, then click Restore."
        name = $snap.name; sets = $snap.sets; pieces = $snap.pieces; cosmetics = $snap.cosmetics
    }
}

# Restore a saved snapshot's building sets/pieces + cosmetics onto the CURRENT
# live character with the given name (the freshly recreated one). Offline-only:
# building_progression and the pawn cosmetics component are RAM-authoritative
# while connected. Unions with whatever the fresh character already has so its
# starter unlocks are never lost.
function Invoke-DunePlayerRestoreBuilds {
    param([string]$Ip, [string]$Name, [bool]$SkipNpe = $false)
    if (-not $Name) { return @{ ok = $false; error = 'name is required.' } }
    $snap = @(Get-DuneFreshStartSnapshots | Where-Object { [string]$_.name -eq $Name })
    if ($snap.Count -eq 0) { return @{ ok = $false; error = "no saved snapshot for '$Name' - snapshot the character before deleting it." } }
    $s = $snap[0]

    $safeName = ConvertTo-DuneSqlString $Name
    $idSql = "SELECT id::text AS cid, player_pawn_id::text AS pawn FROM dune.player_state WHERE character_name = '$safeName' ORDER BY last_login_time DESC NULLS LAST LIMIT 1;"
    $ir = Invoke-DuneSqlQuery -Ip $Ip -Sql $idSql -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $ir.ok) { return @{ ok = $false; error = "resolve character: $($ir.error)" } }
    $imaps = ConvertTo-DuneRowMaps -Result $ir
    if ($imaps.Count -eq 0) { return @{ ok = $false; error = "no live character named '$Name' - recreate it (same name) and spawn in first, then restore." } }
    $charID = [int64](ConvertTo-DuneInt $imaps[0]['cid'])
    $pawnID = [int64](ConvertTo-DuneInt $imaps[0]['pawn'])
    if ($charID -le 0 -or $pawnID -le 0) { return @{ ok = $false; error = "character '$Name' has no pawn yet - spawn in first." } }

    # Offline-only guard (pawn cosmetics + building_progression are overwritten on
    # logout otherwise).
    $off = Test-DunePlayerOffline -Ip $Ip -PawnId $pawnID
    if (-not $off.ok) { return @{ ok = $false; error = "Player must be offline to restore builds. $($off.reason)" } }

    # Only restore what the player *paid for*: real-money MTX items (MTX_*) and
    # CHOAM-shop purchases (Choam_*). Faction-earned sets (Atre_*/Hark_*/Fremen_*/
    # AtreidesSet/HarkonnenSet) get re-earned by re-progressing faction rank, and
    # tutorial/base patents (Basic*/Advanced*/Large*/Deathstill/etc.) get re-granted
    # by the fresh character's starter tech tree. Verified live on 2026-07-04 - the
    # building_progression columns are a mixed bag of purchased + earned + tutorial
    # unlocks, so restoring the whole array over-grants faction perks to a Rank-0
    # character.
    $purchasedRx = '^(MTX_|Choam)'
    $filteredSets   = @($s.building_sets    | Where-Object { [string]$_ -match $purchasedRx })
    $filteredPieces = @($s.buildable_pieces | Where-Object { [string]$_ -match $purchasedRx })
    $setsArr   = ConvertTo-DunePgTextArray ($filteredSets   | ForEach-Object { [string]$_ })
    $piecesArr = ConvertTo-DunePgTextArray ($filteredPieces | ForEach-Object { [string]$_ })
    $cosmetics = [string]$s.cosmetics

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('BEGIN;')
    # Building sets/pieces: union the snapshot into the current row (a fresh char
    # always has a building_progression row with its starter sets).
    [void]$sb.AppendLine("UPDATE dune.building_progression SET learned_building_sets = ARRAY(SELECT DISTINCT unnest(COALESCE(learned_building_sets,'{}'::text[]) || $setsArr)), new_buildable_pieces = ARRAY(SELECT DISTINCT unnest(COALESCE(new_buildable_pieces,'{}'::text[]) || $piecesArr)) WHERE character_id=$charID::bigint;")
    # If the fresh char somehow has no row yet, insert one.
    [void]$sb.AppendLine("INSERT INTO dune.building_progression (character_id, learned_building_sets, new_buildable_pieces) SELECT $charID::bigint, $setsArr, $piecesArr WHERE NOT EXISTS (SELECT 1 FROM dune.building_progression WHERE character_id=$charID::bigint);")
    # Cosmetics: shallow-merge the snapshot's unlock object into the pawn's
    # (snapshot is a superset, so its keys win).
    if ($cosmetics) {
        $safeCos = ConvertTo-DuneSqlString $cosmetics
        [void]$sb.AppendLine("UPDATE dune.actors SET properties = jsonb_set(COALESCE(properties,'{}'::jsonb), '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList}', COALESCE(properties #> '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList}','{}'::jsonb) || '$safeCos'::jsonb, true) WHERE id=$pawnID::bigint;")
    }
    [void]$sb.AppendLine('COMMIT;')

    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sb.ToString() -ReadOnly $false -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "restore builds tx: $($r.error)" }
    }
    # Optional: also mark the tutorial as complete on restore. Used by the
    # "Fresh Start + No NPE" variant. Best-effort: a failure here doesn't roll
    # back the successful build restore.
    $npeMsg = ''
    $npeMarked = $false
    if ($SkipNpe) {
        $npeRes = Invoke-DunePlayerMarkNpeCompleted -Ip $Ip -CharacterId $charID
        $npeMarked = [bool]$npeRes.ok
        $npeMsg = if ($npeRes.ok) { ' Also marked NPE as completed so Advanced buildables (Fabricator, etc.) unlock immediately.' } else { " (NPE mark skipped: $($npeRes.error))" }
    }
    $cosMsg = if ($cosmetics) { ' + cosmetics' } else { '' }
    return @{
        ok = $true
        message = "Restored $($filteredSets.Count) purchased set(s) + $($filteredPieces.Count) purchased piece(s)$cosMsg onto '$Name'. Faction sets, tutorial patents, and tech-tree unlocks will re-populate as the character progresses. Takes effect on next login.$npeMsg"
        sets = $filteredSets.Count; pieces = $filteredPieces.Count; npe_marked = $npeMarked
    }
}

# Marks the New Player Experience (tutorial) as completed on the given character:
# sets the NPE.HasCompletedNPE tag and marks every node in the DA_MQ_ANewBeginning
# + DA_MQ_NPEAutocompleted subtrees complete + revealed. Matches the state a
# character has when the player picks "Skip Tutorial" at character creation, which
# unlocks Advanced_*_Fabricator patents and the rest of the tutorial-gated
# buildables. Node list is captured live from a completed character (data file
# app/data/dune-npe-completion-nodes.json) so we insert the exact IDs the game
# expects — a fresh character's journey_story_node rows for these subtrees
# don't exist yet (game creates them lazily), so UPDATE alone is insufficient.
# Offline-only. The pawn TechKnowledge / tag state is RAM-authoritative while
# connected, same reason as other tag/journey writes.
function Invoke-DunePlayerMarkNpeCompleted {
    param([string]$Ip, [long]$CharacterId)
    if ($CharacterId -le 0) { return @{ ok = $false; error = 'character_id is required.' } }

    $nodes = @(Get-DuneNpeCompletionNodes)
    if ($nodes.Count -eq 0) { return @{ ok = $false; error = 'NPE completion node catalog is empty (app/data/dune-npe-completion-nodes.json missing?).' } }
    $nodeArr = ConvertTo-DunePgTextArray $nodes

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('BEGIN;')
    # Tag: NPE.HasCompletedNPE. player_tags is keyed by (character_id, tag);
    # guard with NOT EXISTS so re-running is a no-op.
    [void]$sb.AppendLine("INSERT INTO dune.player_tags (character_id, tag) SELECT $CharacterId::bigint, 'NPE.HasCompletedNPE' WHERE NOT EXISTS (SELECT 1 FROM dune.player_tags WHERE character_id=$CharacterId::bigint AND tag='NPE.HasCompletedNPE');")
    # Journey nodes: UPDATE any that already exist.
    [void]$sb.AppendLine("UPDATE dune.journey_story_node SET complete_condition_state='true'::jsonb, reveal_condition_state='true'::jsonb, has_pending_reward=false WHERE character_id=$CharacterId::bigint AND story_node_id = ANY($nodeArr);")
    # Journey nodes: INSERT any missing. PK is (character_id, story_node_id) so
    # ON CONFLICT DO NOTHING skips ones the UPDATE already touched.
    [void]$sb.AppendLine("INSERT INTO dune.journey_story_node (character_id, story_node_id, has_pending_reward, complete_condition_state, reveal_condition_state, fail_condition_state, metadata_state, reset_group) SELECT $CharacterId::bigint, unnest($nodeArr), false, 'true'::jsonb, 'true'::jsonb, '{}'::jsonb, '{}'::jsonb, 'Default'::dune.JourneyStoryResetGroup ON CONFLICT (character_id, story_node_id) DO NOTHING;")
    [void]$sb.AppendLine('COMMIT;')

    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sb.ToString() -ReadOnly $false -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "mark NPE completed tx: $($r.error)" }
    }
    return @{
        ok = $true
        message = "Marked NPE completed on character $CharacterId - applied NPE.HasCompletedNPE tag and $($nodes.Count) tutorial journey node(s). Advanced buildable patents unlock on next login."
        tag_added = $true
        nodes_touched = $nodes.Count
    }
}

# Grant every skill in the bundled catalog on the target character. Writes
# jsonb_set for each catalog key with {"SkillPointsSpent":1} onto the pawn's
# FLevelComponent[1].ModuleData (keyed via actor_fgl_entities.slot_name='DuneCharacter').
# Existing entries with SkillPointsSpent>=1 are skipped (idempotent). Does NOT
# touch the character's skill-point pool. Offline-only. Same catalog for every
# character (static game content, bundled).
function Invoke-DunePlayerGrantAllSkills {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $false; error = "no pawn for account $AccountId." } }

    $keys = @(Get-DuneSkillsCatalog)
    if ($keys.Count -eq 0) {
        return @{ ok = $false; error = 'skills catalog is empty (app/data/dune-skills-catalog.json missing?).' }
    }

    # Build one transaction that jsonb_set each catalog key onto the character's
    # ModuleData. The guard `COALESCE(...->'SkillPointsSpent')::int < 1` makes
    # each UPDATE idempotent - already-unlocked keys are skipped.
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('BEGIN;')
    foreach ($sk in $keys) {
        # Skill key on-disk shape is a full tag like `(TagName="Skills.Ability.X")`.
        # Catalog stores these verbatim, so no wrapping needed - just SQL-escape.
        $safeKey = ConvertTo-DuneSqlString $sk
        [void]$sb.AppendLine(@"
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
"@)
    }
    [void]$sb.AppendLine('COMMIT;')

    # -Bulk streams SQL through ssh stdin so the ~60 KB payload (145 UPDATEs)
    # doesn't hit the Windows ~32 KB command-line limit that Start-Process
    # enforces ("The filename or extension is too long").
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sb.ToString() -ReadOnly $false -MaxRows 1 -TimeoutSec 120 -Bulk
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "grant all skills tx: $($r.error)" }
    }
    return @{
        ok = $true
        message = "Granted every skill ($($keys.Count) total) on the character (existing entries preserved). Takes effect on next login."
        catalog_size = $keys.Count
    }
}

# Grant every tech ItemKey in the bundled catalog as Purchased on the target
# character's Intel terminal (TechKnowledgePlayerComponent.m_TechKnowledge.m_TechKnowledgeData).
# Existing entries are preserved verbatim (their UnlockedState is NOT downgraded).
# Missing keys are appended as {ItemKey, bIsNewEntry:true, UnlockedState:"Purchased"}.
# Does NOT touch m_TechKnowledgePoints. Offline-only. Same catalog for every character.
function Invoke-DunePlayerGrantAllTech {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return @{ ok = $false; error = "no pawn for account $AccountId." } }

    $itemKeys = @(Get-DuneTechCatalog)
    if ($itemKeys.Count -eq 0) {
        return @{ ok = $false; error = 'tech catalog is empty (app/data/dune-tech-catalog.json missing?).' }
    }
    $catalogArr = ConvertTo-DunePgTextArray $itemKeys
    $path = "'{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}'"

    # Single UPDATE in a transaction: append every catalog ItemKey that is NOT
    # already present in the existing array as a Purchased entry. Nested
    # jsonb_set + COALESCE seeds any missing intermediate paths so this works
    # on a brand-new character too.
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('BEGIN;')
    [void]$sb.AppendLine(@"
UPDATE dune.actors a
SET properties = jsonb_set(
    jsonb_set(
        jsonb_set(
            COALESCE(a.properties, '{}'::jsonb),
            '{TechKnowledgePlayerComponent}',
            COALESCE(a.properties -> 'TechKnowledgePlayerComponent', '{}'::jsonb),
            true),
        '{TechKnowledgePlayerComponent,m_TechKnowledge}',
        COALESCE(a.properties #> '{TechKnowledgePlayerComponent,m_TechKnowledge}', '{}'::jsonb),
        true),
    $path,
    COALESCE(a.properties #> $path, '[]'::jsonb) || COALESCE((
        SELECT jsonb_agg(jsonb_build_object('ItemKey', k, 'bIsNewEntry', true, 'UnlockedState', 'Purchased'))
        FROM unnest($catalogArr) AS k
        WHERE k NOT IN (
            SELECT e->>'ItemKey'
            FROM jsonb_array_elements(COALESCE(a.properties #> $path, '[]'::jsonb)) e
        )
    ), '[]'::jsonb),
    true)
WHERE a.id = $pawnID::bigint;
"@)
    [void]$sb.AppendLine('COMMIT;')

    # -Bulk for the ~40 KB payload (449 ItemKeys inline) - see grant-all-skills.
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sb.ToString() -ReadOnly $false -MaxRows 1 -TimeoutSec 120 -Bulk
    if (-not $r.ok) {
        Invoke-DuneSqlQuery -Ip $Ip -Sql 'ROLLBACK;' -ReadOnly $false -MaxRows 1 -TimeoutSec 5 | Out-Null
        return @{ ok = $false; error = "grant all tech tx: $($r.error)" }
    }
    return @{
        ok = $true
        message = "Granted every tech recipe ($($itemKeys.Count) total) on the character (existing entries preserved, Intel points untouched). Takes effect on next login."
        catalog_size = $itemKeys.Count
    }
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
    $seenRem = @{}; $allRemove = New-Object System.Collections.Generic.List[string]
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
        if ($script:DuneTagsData.contractRemoveTags.ContainsKey($r.name)) {
            foreach ($rt in $script:DuneTagsData.contractRemoveTags[$r.name]) {
                $rs = [string]$rt
                if ($rs -and -not $seenRem.ContainsKey($rs)) { $seenRem[$rs] = $true; [void]$allRemove.Add($rs) }
            }
        }
    }

    $bumpRes = Invoke-DuneApplyTagsWithTierBump -Ip $Ip -AccountId $AccountId -Tags @($allTags) -RemoveTags @($allRemove)
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

    # A dismissed contract item may still be referenced by the pawn's tracked-contract
    # pointer (ContractsCoordinatorComponent.m_TrackedContractItemUid), which the game
    # renders as a ghost card in the Arrakeen Contract tab even after the item row is
    # gone. Clear the pointer when it now dangles (no-op if it still points at a live
    # contract). This is the actual card-clearing step - see
    # Invoke-DuneClearDanglingTrackedContract.
    $tc = Invoke-DuneClearDanglingTrackedContract -Ip $Ip -AccountId $AccountId
    if (-not $tc.ok) { return @{ ok = $false; error = $tc.error } }
    if ($tc.cleared -gt 0) { $extra += ', cleared tracked contract card' }

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

# Unlock a skill-trainer quest line: completes every DA_CT_Trainer_<Job>* contract
# (applies their reward tags + skill grants, dismisses active contract items) and
# grants the full job skill tree. Offline-safe (DB writes; takes effect next login).
function Invoke-DunePlayerUnlockTrainer {
    param([string]$Ip, [long]$AccountId, [string]$Job)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $Job) { return @{ ok = $false; error = 'job is required.' } }
    _Load-DuneTagsData
    if (-not $script:DuneTagsData.jobSkillBlocks.ContainsKey($Job)) {
        return @{ ok = $false; error = "unknown trainer job '$Job'." }
    }

    $ids = @(Get-DuneTrainerContractIds -Job $Job)
    $parts = New-Object System.Collections.Generic.List[string]
    $contractsDone = 0

    if ($ids.Count -gt 0) {
        $cr = Invoke-DunePlayerCompleteContracts -Ip $Ip -AccountId $AccountId -ContractIds $ids
        if (-not $cr.ok) { return @{ ok = $false; error = "trainer contracts: $($cr.error)" } }
        $contractsDone = [int]$cr.contracts
        [void]$parts.Add("completed $contractsDone contract(s)")
    }

    $gr = Invoke-DunePlayerGrantJobSkills -Ip $Ip -AccountId $AccountId -Job $Job
    if (-not $gr.ok) { return @{ ok = $false; error = "grant skill tree: $($gr.error)" } }
    [void]$parts.Add('granted full skill tree')

    $label = $Job
    $summary = if ($parts.Count -gt 0) { " - $($parts -join ', ')" } else { '' }
    return @{
        ok = $true
        message = "Unlocked $label trainer$summary - takes effect on next login"
        contracts = $contractsDone
    }
}

# Unlock a main-quest story line: flips every DA_MQ_<Root>.* journey row complete
# and applies the union of subtree reward tags (reuses the journey-node engine).
function Invoke-DunePlayerUnlockMainQuest {
    param([string]$Ip, [long]$AccountId, [string]$Quest)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $Quest) { return @{ ok = $false; error = 'quest is required.' } }
    if (-not (Test-DuneMainQuestRoot -Root $Quest)) {
        return @{ ok = $false; error = "unknown main quest '$Quest'." }
    }
    $r = Invoke-DunePlayerCompleteJourneyNode -Ip $Ip -AccountId $AccountId -NodeId $Quest
    if (-not $r.ok) { return $r }
    # Journey.RewardsUnblocked (Find the Fremen 3rd ability slot + prescience) is now
    # applied centrally inside Invoke-DunePlayerCompleteJourneyNode, so no per-quest
    # special-case is needed here.
    return @{ ok = $true; message = "Unlocked main quest $Quest - $($r.nodes) node(s) completed - takes effect on next login"; nodes = $r.nodes }
}

# ---------------------------------------------------------------------------
# Recipe knowledge grant. Some progression rewards (e.g. completing an Aql
# trial) are an awarded crafting recipe stored on the player's pawn, in
#   TechKnowledgePlayerComponent.m_TechKnowledge.m_TechKnowledgeData[]
# as { ItemKey, bIsNewEntry, UnlockedState }. The game reads that recipe
# ownership directly, NOT a journey/player tag, so the Tags editor cannot
# reproduce the award. Completing the content in-game flips the recipe to
# "Purchased"; this helper does the same for a character a tag-only edit left
# stuck. ItemKeys are verified against live pawn TechKnowledge data.
# ---------------------------------------------------------------------------

# Flip a recipe to "Purchased" (or append it when absent) in a character's pawn
# TechKnowledge. Creates the TechKnowledge path if missing (e.g. fresh character
# that hasn't crafted yet). Offline-only at the route layer (pawn JSON is
# RAM-authoritative while connected); takes effect on next login.
function Invoke-DuneGrantRecipe {
    param([string]$Ip, [long]$AccountId, [string]$RecipeKey)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    if (-not $RecipeKey) { return @{ ok = $false; error = 'recipe key is required.' } }

    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) {
        $err = "no pawn for account $AccountId."
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe FAIL: $err (recipe=$RecipeKey)" 'WARN' }
        return @{ ok = $false; error = $err }
    }

    $rk = ConvertTo-DuneSqlString $RecipeKey
    $path = "'{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}'"
    # Attempt 1: path exists — flip existing recipe or append to array.
    $sql = @"
UPDATE dune.actors a
SET properties = jsonb_set(a.properties, $path,
  CASE WHEN EXISTS (
         SELECT 1 FROM jsonb_array_elements(a.properties #> $path) e
         WHERE e->>'ItemKey' = '$rk')
       THEN (SELECT jsonb_agg(
                 CASE WHEN e->>'ItemKey' = '$rk'
                      THEN jsonb_set(e, '{UnlockedState}', '"Purchased"', true)
                      ELSE e END)
             FROM jsonb_array_elements(a.properties #> $path) e)
       ELSE COALESCE(a.properties #> $path, '[]'::jsonb)
            || jsonb_build_object('ItemKey', '$rk', 'bIsNewEntry', false, 'UnlockedState', 'Purchased')
  END, true)
WHERE a.id = $pawnID::bigint
  AND a.properties #> $path IS NOT NULL;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe FAIL: SQL error (recipe=$RecipeKey, pawn=$pawnID): $($r.error)" 'ERROR' }
        return @{ ok = $false; error = "grant recipe: $($r.error)" }
    }
    $updated = (Get-DuneSqlAffected $r)
    if ($updated -gt 0) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe OK: $RecipeKey (pawn=$pawnID, account=$AccountId)" }
        return @{ ok = $true; message = "Granted recipe $RecipeKey - takes effect on next login"; recipe = $RecipeKey }
    }

    # Attempt 2: TechKnowledge path missing — create it with this recipe as the
    # sole entry. Uses nested jsonb_set + COALESCE to preserve any existing
    # intermediate keys while filling in missing levels.
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe: TechKnowledge path missing on pawn $pawnID — creating (recipe=$RecipeKey)" 'WARN' }
    $initSql = @"
UPDATE dune.actors a
SET properties = jsonb_set(
    jsonb_set(
        jsonb_set(
            COALESCE(a.properties, '{}'::jsonb),
            '{TechKnowledgePlayerComponent}',
            COALESCE(a.properties -> 'TechKnowledgePlayerComponent', '{}'::jsonb),
            true),
        '{TechKnowledgePlayerComponent,m_TechKnowledge}',
        COALESCE(a.properties #> '{TechKnowledgePlayerComponent,m_TechKnowledge}', '{}'::jsonb),
        true),
    $path,
    jsonb_build_array(jsonb_build_object('ItemKey', '$rk', 'bIsNewEntry', false, 'UnlockedState', 'Purchased')),
    true)
WHERE a.id = $pawnID::bigint;
"@
    $r2 = Invoke-DuneSqlQuery -Ip $Ip -Sql $initSql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r2.ok) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe FAIL: init TechKnowledge SQL error (pawn=$pawnID): $($r2.error)" 'ERROR' }
        return @{ ok = $false; error = "init TechKnowledge: $($r2.error)" }
    }
    $updated2 = (Get-DuneSqlAffected $r2)
    if ($updated2 -eq 0) {
        $err = "pawn $pawnID not found in dune.actors."
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe FAIL: $err (recipe=$RecipeKey)" 'ERROR' }
        return @{ ok = $false; error = $err }
    }
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantRecipe OK: $RecipeKey (pawn=$pawnID, account=$AccountId, created TechKnowledge path)" }
    return @{ ok = $true; message = "Granted recipe $RecipeKey (created TechKnowledge) - takes effect on next login"; recipe = $RecipeKey; created = $true }
}

# ---------------------------------------------------------------------------
# Enable SpiceVision (Prescience) on a character's pawn. The 3rd active-ability
# slot + spice-vision buff are gated by the FSpiceAddictionComponent on the
# pawn's DuneCharacter FGL entity. In-game these flags are written by the 4th
# Trial of Aql quest script - NOT by journey-node completion, a journey tag, or
# the awarded recipe - so admin-completing Find the Fremen through the tool must
# set them explicitly or the slot stays locked.
#
# The component is a JSON array [ <int>, { ...statuses... } ]; the statuses live
# at index 1. BOTH flags must be FullyEnabled - verified by comparing a working
# vs a locked character on live DBs:
#   working (slot unlocked): {"SystemStatus":"FullyEnabled","SpiceVisionEnabledStatus":"FullyEnabled"}
#   locked  (slot locked):   {"SystemStatus":"AddictionDisabled","SpiceVisionEnabledStatus":"FullyEnabled"}
# i.e. SpiceVisionEnabledStatus alone is NOT enough - SystemStatus must also be
# FullyEnabled (the spice-addiction system being active, which is exactly what
# completing the 4th Trial turns on). We set both. The WHERE clause is idempotent
# (writes only if EITHER flag is not yet FullyEnabled) and safe (only when the
# FSpiceAddictionComponent[1] object exists). Offline-safe: FGL components are
# RAM-authoritative while connected, so it takes effect on next login - same
# caveat as the recipe grant.
# ---------------------------------------------------------------------------
function Invoke-DuneGrantSpiceVision {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }

    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) {
        $err = "no pawn for account $AccountId."
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantSpiceVision FAIL: $err" 'WARN' }
        return @{ ok = $false; error = $err }
    }

    $sql = @"
UPDATE dune.fgl_entities fe
SET components = jsonb_set(
    jsonb_set(
        fe.components,
        '{FSpiceAddictionComponent,1,SystemStatus}',
        '"FullyEnabled"'::jsonb,
        true),
    '{FSpiceAddictionComponent,1,SpiceVisionEnabledStatus}',
    '"FullyEnabled"'::jsonb,
    true)
WHERE fe.entity_id = (
    SELECT entity_id FROM dune.actor_fgl_entities
    WHERE actor_id = $pawnID::bigint AND slot_name = 'DuneCharacter'
  )
  AND fe.components #> '{FSpiceAddictionComponent,1}' IS NOT NULL
  AND (
        COALESCE(fe.components #>> '{FSpiceAddictionComponent,1,SystemStatus}', '') <> 'FullyEnabled'
     OR COALESCE(fe.components #>> '{FSpiceAddictionComponent,1,SpiceVisionEnabledStatus}', '') <> 'FullyEnabled'
  );
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 30
    if (-not $r.ok) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantSpiceVision FAIL: SQL error (pawn=$pawnID): $($r.error)" 'ERROR' }
        return @{ ok = $false; error = "grant spice vision: $($r.error)" }
    }
    $updated = (Get-DuneSqlAffected $r)
    if ($updated -gt 0) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantSpiceVision OK: enabled (pawn=$pawnID, account=$AccountId)" }
        return @{ ok = $true; applied = $true; message = "Enabled Prescience / 3rd ability slot - takes effect on next login" }
    }
    # affected = 0: either already FullyEnabled, or the pawn has no
    # FSpiceAddictionComponent[1] object (a character that has never engaged the
    # spice/addiction system). Nothing to do; treat as success so a missing
    # component never fails the surrounding journey completion.
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) { Write-DuneLog "GrantSpiceVision: no change (pawn=$pawnID) - already enabled or no spice component" }
    return @{ ok = $true; applied = $false; message = "SpiceVision already enabled or not applicable" }
}

# ---------------------------------------------------------------------------
# Journey node -> awarded recipe map. Completing a journey node in-game grants a
# crafting recipe into the pawn's TechKnowledge, and that award (not a tag) is
# what unlocks the related ability slot / gear. This is the single source of
# truth so EVERY path that completes journey nodes (Apply Quick Preset, Unlock Main
# Quest, single Complete) grants the recipe via the shared
# Invoke-DunePlayerCompleteJourneyNode chokepoint. Mirrors the JourneySets.Fremkit.*
# tag map in dune-tags.json; recipe ItemKeys verified against live pawn data.
# ---------------------------------------------------------------------------
$script:DuneJourneyNodeRecipes = [ordered]@{
    'DA_MQ_FindTheFremen.FirstTest.FirstQuestion.CompleteFirstTest'      = 'RCP_LeakyStillsuit_Top_Recipe'
    'DA_MQ_FindTheFremen.SecondTest.SecondQuestion.CompleteSecondTest'   = 'RCP_ChoamStaticCompactorRecipe'
    'DA_MQ_FindTheFremen.FourthTest.FourthQuestion.CompleteFourthTest'   = 'RCP_Crysknife_Recipe'
    'DA_MQ_FindTheFremen.FifthTest.FifthQuestion.CompleteFifthTest'      = 'RCP_T4_Structure_Thumper1_Recipe'
    'DA_MQ_FindTheFremen.SeventhTest.SeventhQuestion.CompleteSeventhTest' = 'RCP_StilltentRecipe'
}

# Recipes awarded by a journey node and everything beneath it (subtree match),
# mirroring Get-DuneTagsForJourneyNodeSubtree. De-duplicated.
function Get-DuneRecipesForJourneyNodeSubtree {
    param([string]$NodeId)
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $prefix = $NodeId + '.'
    foreach ($node in $script:DuneJourneyNodeRecipes.Keys) {
        if ($node -eq $NodeId -or $node.StartsWith($prefix)) {
            $rcp = [string]$script:DuneJourneyNodeRecipes[$node]
            if ($rcp -and -not $seen.ContainsKey($rcp)) { $seen[$rcp] = $true; [void]$out.Add($rcp) }
        }
    }
    return @($out)
}

# ---------------------------------------------------------------------------
# Journey node -> reward-unblock tag. Some journey rewards (notably the Find the
# Fremen 3rd active-ability slot + prescience) are gated by a tag the game sets
# during a cutscene - Journey.RewardsUnblocked - NOT by journey-node completion.
# So completing the questline through the tool leaves those rewards stuck unless
# we also flip this tag. Single source of truth: any path that completes a node
# at or under one of these roots (Apply Quick Preset, Unlock Main Quest, single
# Complete) flips the tag via the shared Invoke-DunePlayerCompleteJourneyNode
# chokepoint. Add roots here as more cutscene-gated rewards are identified.
# ---------------------------------------------------------------------------
$script:DuneJourneyRewardUnblockRoots = @('DA_MQ_FindTheFremen')

# Returns the reward-unblock tags to apply when completing $NodeId, matched if the
# node is one of the roots, a descendant of a root, or an ancestor that contains a
# root (completing the whole questline). De-duplicated.
function Get-DuneRewardUnblockTagsForJourneyNode {
    param([string]$NodeId)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($root in $script:DuneJourneyRewardUnblockRoots) {
        if ($NodeId -eq $root -or
            $NodeId.StartsWith($root + '.') -or
            $root.StartsWith($NodeId + '.')) {
            [void]$out.Add('Journey.RewardsUnblocked')
            break
        }
    }
    return @($out)
}

# True when completing $NodeId should also enable SpiceVision (Prescience / 3rd
# active-ability slot). Tied to the same Find the Fremen root(s) as the
# reward-unblock tag - it is the questline that contains the 4th Trial of Aql.
# Matches the root, a descendant, or an ancestor that contains a root (completing
# the whole questline).
function Test-DuneNodeTriggersSpiceVision {
    param([string]$NodeId)
    foreach ($root in $script:DuneJourneyRewardUnblockRoots) {
        if ($NodeId -eq $root -or
            $NodeId.StartsWith($root + '.') -or
            $root.StartsWith($NodeId + '.')) {
            return $true
        }
    }
    return $false
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
                # $permPid, not $pid — $PID is a read-only automatic variable.
                $permPid = [int64](ConvertTo-DuneInt $m4[0]['pid'])
                $out['permission_player_id'] = $permPid
                if ($permPid -gt 0) {
                    $sql5 = "SELECT account_id::text AS aid FROM dune.player_state WHERE player_pawn_id = $permPid::bigint OR player_controller_id = $permPid::bigint LIMIT 1;"
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
