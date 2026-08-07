# Coriolis Admin — v11.5.7
#
# Wraps dune.debug_get_coriolis_seeds() + dune.debug_set_farm_seed() so admins
# can inspect and override the world-reset (Coriolis storm) seeds without
# resetting state.
#
# Map- and partition-scoped writes go DIRECTLY to dune.world_map_reset_seed /
# dune.world_partition_reset_seed instead of through the game's
# dune.debug_set_map_seed() / dune.debug_set_partition_seed(). Those two stored
# functions are broken in the shipped DB: both reference an undeclared
# `in_server_info` variable, so every call aborts with
# `missing FROM-clause entry for table "in_server_info"`. debug_set_map_seed()
# additionally filters world_partition_reset_seed by a `map` column that table
# does not have — the map->partition cascade has to join through
# dune.world_partition. dune.debug_set_farm_seed() is clean, so the farm path
# still calls it.
#
# Background: every farm / map / partition has a "world_reset_seed" recording the
# Coriolis storm layout. These rows are the game's OUTPUT: on map load the game
# calls dune.coriolis_update_seed(...) and stamps its own derived seed over all
# three tables, so an admin-written row survives only until that map next loads.
# The actual control is the INI key m_ForcedCoriolisWorldSeed in
# [/Script/DuneSandbox.CoriolisSubsystem] (Game Config -> Storm Cycle -> Forced
# Coriolis World Seed): -1 = automatic, 0-11 pin one of the twelve fixed layouts
# server-wide. The writes below are kept because they are still useful for a map
# that is not currently loaded, but they are reported as records, never as
# applied settings.
#
# DST never calls dune.coriolis_update_seed itself — it triggers
# dune.corilis_cleanup_map / dune.coriolis_cleanup_partition, which destroy
# player markers, surveyed areas, resource-field state and, outside the
# shieldwall, actors and survivors.
#
# All paths use Invoke-DuneSqlSoft so missing tables / functions on legacy or
# self-hosted DBs degrade to a clear "unsupported" response instead of 500s.

# ----------------------------------------------------------------------------
# Read — current farm / map / partition seeds.
# ----------------------------------------------------------------------------
# Postgres does the array-splitting via unnest() and emits ONE clean scalar row
# per farm / map / partition. This avoids round-tripping JSON arrays through the
# psql CSV layer (commas + quotes inside array_to_json text collided with CSV
# field parsing, collapsing every map name into a single space-joined string).
# unnest(arr_a, arr_b, ...) zips the parallel arrays element-wise.
$script:DuneCoriolisSeedsSql = @'
WITH s AS (
    SELECT farm_seed, map_names, map_seeds,
           partitions_ids, partitions_map, partitions_seeds
    FROM dune.debug_get_coriolis_seeds()
)
SELECT 'farm'::text AS kind, NULL::bigint AS partition_id,
       ''::text AS map_name, COALESCE(s.farm_seed, -1) AS seed
FROM s
UNION ALL
SELECT 'map'::text, NULL::bigint, mm.map_name, COALESCE(mm.seed, -1)
FROM s, unnest(s.map_names, s.map_seeds) AS mm(map_name, seed)
UNION ALL
SELECT 'partition'::text, pp.pid, pp.map_name, COALESCE(pp.seed, -1)
FROM s, unnest(s.partitions_ids, s.partitions_map, s.partitions_seeds)
        AS pp(pid, map_name, seed);
'@

function Get-DuneCoriolisSeedsLive {
    param([string]$Ip)
    $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $script:DuneCoriolisSeedsSql -MaxRows 2000 -TimeoutSec 15
    if (-not $soft.ok) { return @{ ok = $false; error = $soft.error } }
    if ($soft.unsupported) {
        return @{ ok = $true; unsupported = $true; farm_seed = 0; maps = @(); partitions = @() }
    }
    $rows = ConvertTo-DuneRowMaps -Result $soft.raw
    $farm = 0
    $maps = @()
    $partitions = @()
    foreach ($r in $rows) {
        switch ([string]$r['kind']) {
            'farm' { $farm = [int](ConvertTo-DuneInt $r['seed']) }
            'map'  {
                $maps += [ordered]@{
                    map  = [string]$r['map_name']
                    seed = [int](ConvertTo-DuneInt $r['seed'])
                }
            }
            'partition' {
                $partitions += [ordered]@{
                    partition_id = ConvertTo-DuneInt $r['partition_id']
                    map          = [string]$r['map_name']
                    seed         = [int](ConvertTo-DuneInt $r['seed'])
                }
            }
        }
    }
    return @{ ok = $true; farm_seed = $farm; maps = $maps; partitions = $partitions }
}

function Get-DuneCoriolisSeedsDemo {
    return @{
        ok         = $true
        farm_seed  = 12345
        maps       = @(
            [ordered]@{ map = 'HaggaBasin';   seed = 12345 },
            [ordered]@{ map = 'DeepDesert';   seed = 67890 }
        )
        partitions = @(
            [ordered]@{ partition_id = 101; map = 'HaggaBasin'; seed = 12345 },
            [ordered]@{ partition_id = 201; map = 'DeepDesert'; seed = 67890 }
        )
    }
}

# ----------------------------------------------------------------------------
# Writes — record a seed at farm / map / partition scope.
#
# IMPORTANT — what a successful write does and does not mean.
# The world-reset seed tables are the game's OUTPUT, not its input. When a map
# loads, the game calls dune.coriolis_update_seed(...) and overwrites
# world_farm_reset_seed / world_map_reset_seed / world_partition_reset_seed with
# the seed it derived for itself. With the INI key m_ForcedCoriolisWorldSeed at
# its default (-1 = automatic) that derived value is the current Coriolis
# cycle's seed, so an admin-written row is replaced the next time the map loads.
#
# DST therefore never claims a write was "applied". It records the value,
# re-reads the rows to confirm the WRITE LANDED (which is all a read-back can
# prove — the replacement happens later, on the next map load, not immediately),
# and says plainly that the value is transient unless the layout is pinned via
# the Forced Coriolis World Seed setting in Game Config -> Storm Cycle.
#
# DST deliberately does NOT call dune.coriolis_update_seed. That function fires
# dune.corilis_cleanup_map / dune.coriolis_cleanup_partition, which delete
# player markers, surveyed areas, resource-field state and (outside the
# shieldwall) actors and survivors. Applying a seed on demand is not worth
# destroying player data over.
#
# Farm scope calls dune.debug_set_farm_seed, which also cascades cleanup
# (corpses, coriolis-affected partition state) when the seed actually changes.
# Map / partition scope write the reset-seed tables directly (see header).
# ----------------------------------------------------------------------------

# Appended to every write response. Keep the wording free of "applied" / "set on
# the map" — the write is a record, not an application.
$script:DuneCoriolisTransientNote = 'This is a record only: the game re-asserts its own layout when a map next loads, so the value is transient. To pin a layout for good, use Game Config -> Storm Cycle -> Forced Coriolis World Seed.'

# Re-read the rows a write just touched. Soft by design: a database that cannot
# answer the read-back is reported as unverified rather than turned into an
# error, because the write itself already succeeded.
#
# The query must project three columns: kind, name, seed.
function Get-DuneCoriolisSeedReadback {
    param([string]$Ip, [string]$Sql)
    $soft = $null
    try {
        $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $Sql -MaxRows 500 -TimeoutSec 15
    } catch {
        return @{ checked = $false; reason = $_.Exception.Message; rows = @() }
    }
    if (-not $soft -or -not $soft.ok) {
        $why = if ($soft) { [string]$soft.error } else { 'read-back unavailable' }
        return @{ checked = $false; reason = $why; rows = @() }
    }
    if ($soft.unsupported) {
        return @{ checked = $false; reason = 'read-back not supported on this database'; rows = @() }
    }
    $rows = @()
    try { $rows = @(ConvertTo-DuneRowMaps -Result $soft.raw) }
    catch { return @{ checked = $false; reason = $_.Exception.Message; rows = @() } }
    $out = @()
    foreach ($r in $rows) {
        $out += [ordered]@{
            kind = [string]$r['kind']
            key  = [string]$r['name']
            seed = [int](ConvertTo-DuneInt $r['seed'])
        }
    }
    return @{ checked = $true; rows = $out }
}

# Turn a read-back into an honest sentence. Never says "applied" or "set" in a
# way that implies the map adopted the seed.
#
# -Context carries rows that were read but NOT written (the other naming scheme's
# rows in world_map_reset_seed). They are reported verbatim, under the key they
# were read as, and take no part in the comparison — DST does not claim they
# describe the same map.
function Format-DuneCoriolisWriteMessage {
    param([string]$Subject, [int]$Seed, $Readback, $Context = @())
    $note = $script:DuneCoriolisTransientNote
    $ctx  = @($Context)
    $ctxTxt = ''
    if ($ctx.Count -gt 0) {
        $list = (($ctx | ForEach-Object { "'$($_.key)' = $($_.seed)" }) -join ', ')
        $ctxTxt = " For reference, the other rows in world_map_reset_seed currently read $list; DST did not write these and does not assume which map each one describes."
    }
    if (-not $Readback -or -not $Readback.checked) {
        $why = if ($Readback -and $Readback.reason) { " ($($Readback.reason))" } else { '' }
        return "Recorded seed $Seed for $Subject. Could not re-read the rows to confirm the write landed$why. $note$ctxTxt"
    }
    $rows = @($Readback.rows)
    if ($rows.Count -eq 0) {
        return "Wrote seed $Seed for $Subject, but a re-read found no matching rows, so the write did not land. $note$ctxTxt"
    }
    $read = (($rows | ForEach-Object { if ($_.key -and $_.key -ne $_.kind) { "$($_.kind) '$($_.key)'" } else { [string]$_.kind } }) -join ', ')
    $bad  = @($rows | Where-Object { $_.seed -ne $Seed })
    if ($bad.Count -eq 0) {
        return "Recorded seed $Seed for $Subject. Re-read of $read confirms the write landed. $note$ctxTxt"
    }
    $badTxt = (($bad | ForEach-Object { if ($_.key -and $_.key -ne $_.kind) { "$($_.kind) '$($_.key)' now reads $($_.seed)" } else { "$($_.kind) now reads $($_.seed)" } }) -join ', ')
    return "Wrote seed $Seed for $Subject, but a re-read shows $badTxt, so the game has already replaced the value. $note$ctxTxt"
}

function Invoke-DuneCoriolisSetFarmSeed {
    param([string]$Ip, [int]$Seed)
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $sql = "SELECT dune.debug_set_farm_seed($Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $readback = Get-DuneCoriolisSeedReadback -Ip $Ip -Sql @"
SELECT 'farm'::text AS kind, 'farm'::text AS name, f.world_reset_seed AS seed
FROM dune.world_farm_reset_seed f;
"@
    $msg = Format-DuneCoriolisWriteMessage -Subject 'the farm (every map and partition)' -Seed $Seed -Readback $readback
    return @{
        ok        = $true
        scope     = 'farm'
        seed      = $Seed
        recorded  = $true
        transient = $true
        verified  = [bool]($readback.checked -and -not @($readback.rows | Where-Object { $_.seed -ne $Seed }).Count)
        readback  = @($readback.rows)
        message   = $msg
    }
}

function Invoke-DuneCoriolisSetMapSeed {
    param([string]$Ip, [string]$Map, [int]$Seed)
    if (-not $Map) { return @{ ok = $false; error = 'map name is required.' } }
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $safeMap = ConvertTo-DuneSqlString $Map
    # Upsert the map's own seed, then cascade to every partition on that map.
    # world_partition_reset_seed has no `map` column, so the partition list has
    # to come from dune.world_partition.
    $sql = @"
BEGIN;
INSERT INTO dune.world_map_reset_seed (map, world_reset_seed)
VALUES ('$safeMap'::text, $Seed::int)
ON CONFLICT (map) DO UPDATE SET world_reset_seed = EXCLUDED.world_reset_seed;
INSERT INTO dune.world_partition_reset_seed (partition_id, world_reset_seed)
SELECT DISTINCT wp.partition_id, $Seed::int FROM dune.world_partition wp WHERE wp.map = '$safeMap'::text
ON CONFLICT (partition_id) DO UPDATE SET world_reset_seed = EXCLUDED.world_reset_seed;
COMMIT;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    # Read back exactly what was written: the map row under the name that was
    # asked for, plus the partition rows reached through dune.world_partition.
    #
    # dune.world_map_reset_seed holds BOTH naming schemes for the same map — the
    # partition name (Survival_1, Overmap, DeepDesert_1) and the friendly name
    # (HaggaBasin, Overland, DeepDesert) — and the friendly-name row is the one
    # the game rewrites, so it is the more informative of the two. There is no
    # reliable join in dune.world_partition that pairs the two names, so DST does
    # not guess: the remaining map rows are read and reported verbatim under the
    # keys they were read as ('other_map'), they take no part in deciding whether
    # the write landed, and no claim is made about which map each describes.
    $readback = Get-DuneCoriolisSeedReadback -Ip $Ip -Sql @"
SELECT 'map'::text AS kind, wm.map::text AS name, wm.world_reset_seed AS seed
FROM dune.world_map_reset_seed wm
WHERE wm.map = '$safeMap'::text
UNION ALL
SELECT 'partition'::text, wp.partition_id::text, wr.world_reset_seed
FROM dune.world_partition wp
JOIN dune.world_partition_reset_seed wr ON wr.partition_id = wp.partition_id
WHERE wp.map = '$safeMap'::text
UNION ALL
SELECT 'other_map'::text, wm2.map::text, wm2.world_reset_seed
FROM dune.world_map_reset_seed wm2
WHERE wm2.map <> '$safeMap'::text;
"@
    $written = @($readback.rows | Where-Object { $_.kind -ne 'other_map' })
    $context = @($readback.rows | Where-Object { $_.kind -eq 'other_map' })
    $msg = Format-DuneCoriolisWriteMessage -Subject "map '$Map' (and its partitions)" -Seed $Seed -Readback @{ checked = $readback.checked; reason = $readback.reason; rows = $written } -Context $context
    return @{
        ok        = $true
        scope     = 'map'
        map       = $Map
        seed      = $Seed
        recorded  = $true
        transient = $true
        verified  = [bool]($readback.checked -and $written.Count -and -not @($written | Where-Object { $_.seed -ne $Seed }).Count)
        readback  = @($written)
        other_map_rows = @($context)
        message   = $msg
    }
}

function Invoke-DuneCoriolisSetPartitionSeed {
    param([string]$Ip, [long]$PartitionId, [int]$Seed)
    if ($PartitionId -le 0) { return @{ ok = $false; error = 'partition_id is required.' } }
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $sql = @"
INSERT INTO dune.world_partition_reset_seed (partition_id, world_reset_seed)
VALUES ($PartitionId::int, $Seed::int)
ON CONFLICT (partition_id) DO UPDATE SET world_reset_seed = EXCLUDED.world_reset_seed;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    $readback = Get-DuneCoriolisSeedReadback -Ip $Ip -Sql @"
SELECT 'partition'::text AS kind, wr.partition_id::text AS name, wr.world_reset_seed AS seed
FROM dune.world_partition_reset_seed wr
WHERE wr.partition_id = $PartitionId::int;
"@
    $msg = Format-DuneCoriolisWriteMessage -Subject "partition $PartitionId" -Seed $Seed -Readback $readback
    return @{
        ok           = $true
        scope        = 'partition'
        partition_id = $PartitionId
        seed         = $Seed
        recorded     = $true
        transient    = $true
        verified     = [bool]($readback.checked -and -not @($readback.rows | Where-Object { $_.seed -ne $Seed }).Count)
        readback     = @($readback.rows)
        message      = $msg
    }
}
