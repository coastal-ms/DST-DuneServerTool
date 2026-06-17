# Coriolis Admin — v11.5.7
#
# Wraps dune.debug_get_coriolis_seeds() + dune.debug_set_farm_seed() /
# debug_set_map_seed() / debug_set_partition_seed() so admins can inspect and
# override the world-reset (Coriolis storm) seeds without resetting state.
#
# Background: every map + partition has a "world_reset_seed" that determines
# the next Coriolis storm layout. The game updates it automatically on storm
# events. Setting it manually lets admins (a) pin a specific layout / spawn
# pattern across resets, or (b) force-trigger a reset by changing the value
# (which cleans up old corpses / loose loot via coriolis_cleanup_*).
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
# Writes — set seed at farm / map / partition scope.
# These call dune.debug_set_* functions, which also cascade cleanup (corpses,
# coriolis-affected partition state) when the seed actually changes.
# ----------------------------------------------------------------------------
function Invoke-DuneCoriolisSetFarmSeed {
    param([string]$Ip, [int]$Seed)
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $sql = "SELECT dune.debug_set_farm_seed($Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'farm'; seed = $Seed; message = "Set farm + all maps + all partitions to seed $Seed (cleanup will cascade if changed)." }
}

function Invoke-DuneCoriolisSetMapSeed {
    param([string]$Ip, [string]$Map, [int]$Seed)
    if (-not $Map) { return @{ ok = $false; error = 'map name is required.' } }
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $safeMap = ConvertTo-DuneSqlString $Map
    $sql = "SELECT dune.debug_set_map_seed('$safeMap'::text, $Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'map'; map = $Map; seed = $Seed; message = "Set map '$Map' (+ its partitions) to seed $Seed." }
}

function Invoke-DuneCoriolisSetPartitionSeed {
    param([string]$Ip, [long]$PartitionId, [int]$Seed)
    if ($PartitionId -le 0) { return @{ ok = $false; error = 'partition_id is required.' } }
    if ($Seed -lt -1 -or $Seed -gt 11) { return @{ ok = $false; error = 'Seed must be -1 (auto) or 0-11 (one of the 12 Coriolis world layouts).' } }
    $sql = "SELECT dune.debug_set_partition_seed($PartitionId::bigint, $Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'partition'; partition_id = $PartitionId; seed = $Seed; message = "Set partition $PartitionId to seed $Seed." }
}
