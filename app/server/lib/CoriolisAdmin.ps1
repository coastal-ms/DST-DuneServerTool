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
$script:DuneCoriolisSeedsSql = @'
SELECT
    COALESCE(farm_seed, 0)                              AS farm_seed,
    COALESCE(array_to_json(map_names)::text, '[]')      AS map_names_json,
    COALESCE(array_to_json(map_seeds)::text, '[]')      AS map_seeds_json,
    COALESCE(array_to_json(partitions_ids)::text, '[]') AS partition_ids_json,
    COALESCE(array_to_json(partitions_map)::text, '[]') AS partition_maps_json,
    COALESCE(array_to_json(partitions_seeds)::text, '[]') AS partition_seeds_json
FROM dune.debug_get_coriolis_seeds();
'@

function Get-DuneCoriolisSeedsLive {
    param([string]$Ip)
    $soft = Invoke-DuneSqlSoft -Ip $Ip -Sql $script:DuneCoriolisSeedsSql -MaxRows 1 -TimeoutSec 15
    if (-not $soft.ok) { return @{ ok = $false; error = $soft.error } }
    if ($soft.unsupported) {
        return @{ ok = $true; unsupported = $true; farm_seed = 0; maps = @(); partitions = @() }
    }
    $maps = ConvertTo-DuneRowMaps -Result $soft.raw
    if ($maps.Count -lt 1) {
        return @{ ok = $true; farm_seed = 0; maps = @(); partitions = @() }
    }
    $r = $maps[0]
    $farm = [int](ConvertTo-DuneInt $r['farm_seed'])
    $mapNames  = @(); $mapSeeds = @()
    $partIds   = @(); $partMaps = @(); $partSeeds = @()
    try { $mapNames  = @(ConvertFrom-Json ([string]$r['map_names_json'])) } catch {}
    try { $mapSeeds  = @(ConvertFrom-Json ([string]$r['map_seeds_json'])) } catch {}
    try { $partIds   = @(ConvertFrom-Json ([string]$r['partition_ids_json'])) } catch {}
    try { $partMaps  = @(ConvertFrom-Json ([string]$r['partition_maps_json'])) } catch {}
    try { $partSeeds = @(ConvertFrom-Json ([string]$r['partition_seeds_json'])) } catch {}

    $maps = @()
    for ($i = 0; $i -lt $mapNames.Count; $i++) {
        $maps += [ordered]@{
            map  = [string]$mapNames[$i]
            seed = if ($i -lt $mapSeeds.Count) { [int](ConvertTo-DuneInt $mapSeeds[$i]) } else { 0 }
        }
    }
    $partitions = @()
    for ($i = 0; $i -lt $partIds.Count; $i++) {
        $partitions += [ordered]@{
            partition_id = ConvertTo-DuneInt $partIds[$i]
            map          = if ($i -lt $partMaps.Count)  { [string]$partMaps[$i] } else { '' }
            seed         = if ($i -lt $partSeeds.Count) { [int](ConvertTo-DuneInt $partSeeds[$i]) } else { 0 }
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
    if ($Seed -lt 0) { return @{ ok = $false; error = 'Seed must be a non-negative 32-bit integer.' } }
    $sql = "SELECT dune.debug_set_farm_seed($Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'farm'; seed = $Seed; message = "Set farm + all maps + all partitions to seed $Seed (cleanup will cascade if changed)." }
}

function Invoke-DuneCoriolisSetMapSeed {
    param([string]$Ip, [string]$Map, [int]$Seed)
    if (-not $Map) { return @{ ok = $false; error = 'map name is required.' } }
    if ($Seed -lt 0) { return @{ ok = $false; error = 'Seed must be a non-negative 32-bit integer.' } }
    $safeMap = ConvertTo-DuneSqlString $Map
    $sql = "SELECT dune.debug_set_map_seed('$safeMap'::text, $Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'map'; map = $Map; seed = $Seed; message = "Set map '$Map' (+ its partitions) to seed $Seed." }
}

function Invoke-DuneCoriolisSetPartitionSeed {
    param([string]$Ip, [long]$PartitionId, [int]$Seed)
    if ($PartitionId -le 0) { return @{ ok = $false; error = 'partition_id is required.' } }
    if ($Seed -lt 0) { return @{ ok = $false; error = 'Seed must be a non-negative 32-bit integer.' } }
    $sql = "SELECT dune.debug_set_partition_seed($PartitionId::bigint, $Seed::int);"
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $res.ok) { return @{ ok = $false; error = $res.error } }
    return @{ ok = $true; scope = 'partition'; partition_id = $PartitionId; seed = $Seed; message = "Set partition $PartitionId to seed $Seed." }
}
