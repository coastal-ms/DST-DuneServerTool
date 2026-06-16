# PlayersRead.ps1 — v11.5.9 read endpoints ported from the reference implementation §1.
# Each Get-Dune* returns @{ ok=$true|$false; <payload-key>=...; error?=... }.
# Routes wrap with Invoke-DunePlayerReadRoute (live + demo fallback).
#
# Catalogs (keystones, tags, presets) come from app/data/dune-*.json,
# loaded lazily and cached for the life of the process.

# ----- Catalog loaders -----------------------------------------------------

$script:DuneKeystoneCatalog   = $null  # hashtable id(int) -> @{track;name;level;cost}
$script:DuneTagsData          = $null  # @{ContractTags=@{}; ContractAliases=@{}; ...}
$script:DuneProgressionPresetCatalog = $null  # array of preset hashtables

function _Resolve-DuneCatalog {
    param([string]$Filename)
    foreach ($cand in @(
        (Join-Path $PSScriptRoot "..\..\data\$Filename"),
        (Join-Path (Split-Path -Parent $PSScriptRoot) "..\data\$Filename")
    )) {
        $resolved = $null
        try { $resolved = (Resolve-Path -LiteralPath $cand -ErrorAction Stop).Path } catch {}
        if ($resolved) { return $resolved }
    }
    return $null
}

function _Load-DuneKeystoneCatalog {
    if ($null -ne $script:DuneKeystoneCatalog) { return }
    $script:DuneKeystoneCatalog = @{}
    $p = _Resolve-DuneCatalog 'dune-keystones.json'
    if (-not $p) { return }
    try {
        $json = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) {
            $id = 0; if (-not [int]::TryParse($prop.Name, [ref]$id)) { continue }
            $v = $prop.Value
            $script:DuneKeystoneCatalog[$id] = @{
                track = [string]$v.track
                name  = [string]$v.name
                level = [int]$v.level
                cost  = [int]$v.cost
            }
        }
    } catch {}
}

function _Load-DuneTagsData {
    if ($null -ne $script:DuneTagsData) { return }
    $script:DuneTagsData = @{
        contractTags         = @{}
        contractAliases      = @{}
        contractSkillGrants  = @{}
        jobSkillBlocks       = @{}
        jobAllModules        = @{}
        journeyNodeTags      = @{}
    }
    $p = _Resolve-DuneCatalog 'dune-tags.json'
    if (-not $p) { return }
    try {
        $json = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $map = @{
            'contract_tags'         = 'contractTags'
            'contract_aliases'      = 'contractAliases'
            'contract_skill_grants' = 'contractSkillGrants'
            'job_skill_blocks'      = 'jobSkillBlocks'
            'job_all_modules'       = 'jobAllModules'
            'journey_node_tags'     = 'journeyNodeTags'
        }
        foreach ($srcKey in $map.Keys) {
            $dstKey = $map[$srcKey]
            if ($json.PSObject.Properties[$srcKey]) {
                foreach ($prop in $json.$srcKey.PSObject.Properties) {
                    $val = $prop.Value
                    if ($val -is [string]) {
                        $script:DuneTagsData[$dstKey][$prop.Name] = [string]$val
                    } else {
                        $script:DuneTagsData[$dstKey][$prop.Name] = @($val)
                    }
                }
            }
        }
    } catch {}
}

function _Load-DuneProgressionPresetCatalog {
    if ($null -ne $script:DuneProgressionPresetCatalog) { return }
    $script:DuneProgressionPresetCatalog = @()
    $p = _Resolve-DuneCatalog 'dune-progression-presets.json'
    if (-not $p) { return }
    try {
        $json = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $list = @()
        foreach ($entry in $json) {
            $list += @{
                id          = [string]$entry.id
                name        = [string]$entry.name
                description = [string]$entry.description
                node_count  = [int]$entry.node_count
                nodes       = @($entry.nodes)
            }
        }
        $script:DuneProgressionPresetCatalog = $list
    } catch {}
}

function Get-DuneKeystoneCatalog {
    _Load-DuneKeystoneCatalog
    return $script:DuneKeystoneCatalog
}

function Get-DuneProgressionPresetCatalog {
    _Load-DuneProgressionPresetCatalog
    return $script:DuneProgressionPresetCatalog
}

function Get-DuneTagsData {
    _Load-DuneTagsData
    return $script:DuneTagsData
}

# ----- §1.1 GET /players/online -------------------------------------------
function Get-DunePlayersOnlineLive {
    param([string]$Ip)
    $sql = @'
SELECT ps.player_controller_id::text AS pid,
       COALESCE(ps.character_name, '') AS name,
       COALESCE(a.map, '') AS map,
       ps.online_status::text AS status,
       COALESCE(to_char(ps.last_avatar_activity AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), '') AS last_seen
FROM dune.player_state ps
LEFT JOIN dune.actors a ON a.id = ps.player_controller_id
ORDER BY ps.online_status DESC, ps.last_avatar_activity DESC;
'@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $list += @{
            player_id = [int64](ConvertTo-DuneInt $row['pid'])
            name      = [string]$row['name']
            map       = [string]$row['map']
            status    = [string]$row['status']
            last_seen = [string]$row['last_seen']
        }
    }
    return @{ ok = $true; players = $list; total = $list.Count }
}

# ----- §1.2 GET /players/factions -----------------------------------------
function Get-DunePlayerFactionsLive {
    param([string]$Ip)
    $scripId = Resolve-DuneScripCurrencyId -Ip $Ip
    if ($null -eq $scripId) { $scripId = -1 }
    $sql = @"
SELECT pfr.actor_id::text AS aid,
       pfr.faction_id::int AS fid,
       f.name AS fname,
       pfr.reputation_amount AS rep,
       COALESCE(vcb.balance, 0) AS scrips
FROM dune.player_faction_reputation pfr
JOIN dune.factions f ON f.id = pfr.faction_id
LEFT JOIN dune.player_virtual_currency_balances vcb
    ON vcb.player_controller_id = pfr.actor_id
   AND vcb.currency_id = $scripId::smallint
ORDER BY pfr.actor_id, pfr.faction_id;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $list += @{
            actor_id     = [int64](ConvertTo-DuneInt $row['aid'])
            faction_id   = [int](ConvertTo-DuneInt $row['fid'])
            faction_name = [string]$row['fname']
            reputation   = [int](ConvertTo-DuneInt $row['rep'])
            scrips       = [int64](ConvertTo-DuneInt $row['scrips'])
        }
    }
    return @{ ok = $true; factions = $list; scrip_currency_id = $scripId }
}

# ----- §1.3 GET /players/specs --------------------------------------------
function Get-DunePlayerSpecsLive {
    param([string]$Ip)
    $sql = @'
SELECT player_id::text AS pid, track_type::text AS track, xp_amount AS xp, level AS lvl
FROM dune.specialization_tracks
ORDER BY player_id, track_type;
'@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 20000 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $lvl = 0.0
        [void][double]::TryParse([string]$row['lvl'], [ref]$lvl)
        $list += @{
            player_id  = [int64](ConvertTo-DuneInt $row['pid'])
            track_type = [string]$row['track']
            xp         = [int](ConvertTo-DuneInt $row['xp'])
            level      = $lvl
        }
    }
    return @{ ok = $true; specs = $list }
}

# ----- §1.4 GET /players/{id}/journey -------------------------------------
function Get-DunePlayerJourneyLive {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $sql = @"
SELECT story_node_id AS node_id,
       (complete_condition_state = 'true'::jsonb) AS is_complete,
       (reveal_condition_state   = 'true'::jsonb) AS is_revealed,
       has_pending_reward
FROM dune.journey_story_node
WHERE account_id = $AccountId::bigint
ORDER BY story_node_id;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $list += @{
            node_id            = [string]$row['node_id']
            is_complete        = ([string]$row['is_complete']).ToLower() -eq 't' -or ([string]$row['is_complete']).ToLower() -eq 'true'
            is_revealed        = ([string]$row['is_revealed']).ToLower() -eq 't' -or ([string]$row['is_revealed']).ToLower() -eq 'true'
            has_pending_reward = ([string]$row['has_pending_reward']).ToLower() -eq 't' -or ([string]$row['has_pending_reward']).ToLower() -eq 'true'
        }
    }
    return @{ ok = $true; nodes = $list; total = $list.Count }
}

# ----- §1.5 GET /players/{id}/export --------------------------------------
function Get-DunePlayerExportLive {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $resolve = Get-DuneRawFuncomId -Ip $Ip -AccountId $AccountId
    if (-not $resolve.ok) { return @{ ok = $false; error = $resolve.error } }
    $funcom = ConvertTo-DuneSqlString $resolve.funcom_id
    $sql = "SELECT dune.character_transfer_export('$funcom')::text AS export_json;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 60
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    if ($rows.Count -eq 0) { return @{ ok = $false; error = "No export returned for account $AccountId." } }
    return @{ ok = $true; export_json = [string]$rows[0]['export_json']; account_id = $AccountId; funcom_id = $resolve.funcom_id }
}

# ----- §1.6 GET /players/{id}/keystones -----------------------------------
function Get-DunePlayerKeystonesLive {
    param([string]$Ip, [long]$PlayerId)
    if ($PlayerId -le 0) { return @{ ok = $false; error = 'player_id is required.' } }
    $sql = "SELECT keystone_id::int AS kid FROM dune.purchased_specialization_keystones WHERE player_id = $PlayerId::bigint ORDER BY keystone_id;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1000 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $cat = Get-DuneKeystoneCatalog
    $list = @()
    foreach ($row in $rows) {
        $id = [int](ConvertTo-DuneInt $row['kid'])
        $info = $cat[$id]
        if ($null -ne $info) {
            $list += @{ id = $id; track = $info.track; name = $info.name; level = $info.level; cost = $info.cost }
        } else {
            $list += @{ id = $id; track = 'Unknown'; name = "keystone_$id"; level = 0; cost = 0 }
        }
    }
    return @{ ok = $true; keystones = $list; total = $list.Count }
}

# ----- §1.7 GET /players/{id}/vehicles ------------------------------------
function Get-DunePlayerVehiclesLive {
    param([string]$Ip, [long]$ControllerId)
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    $accSql = "SELECT account_id::text AS aid FROM dune.player_state WHERE player_controller_id = $ControllerId::bigint LIMIT 1;"
    $acc = Invoke-DuneSqlQuery -Ip $Ip -Sql $accSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $accountId = 0L
    if ($acc.ok) {
        $maps = ConvertTo-DuneRowMaps -Result $acc
        if ($maps.Count -ge 1) { $accountId = [int64](ConvertTo-DuneInt $maps[0]['aid']) }
    }
    $sql = @"
SELECT pa.actor_id::text AS vid, a.class AS class, COALESCE(a.map, '') AS map,
       COALESCE(rv.chassis_durability::float8, 1.0) AS dur,
       COALESCE(pa.actor_name, rv.vehicle_name, '') AS vname,
       (rv.vehicle_id IS NOT NULL) AS recovered,
       false AS backup
FROM dune.permission_actor pa
JOIN dune.permission_actor_rank par ON par.permission_actor_id = pa.actor_id
JOIN dune.actors a ON a.id = pa.actor_id
LEFT JOIN dune.recovered_vehicles rv ON rv.vehicle_id = pa.actor_id AND rv.account_id = $accountId::bigint
WHERE par.player_id = $ControllerId::bigint AND pa.actor_type = 2
UNION ALL
SELECT a.id::text AS vid, a.class AS class, '' AS map,
       1.0 AS dur, '' AS vname, false AS recovered, true AS backup
FROM dune.backup_vehicles bv
JOIN dune.actors a ON a.id = bv.vehicle_id
WHERE bv.account_id = $accountId::bigint
ORDER BY class;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1000 -TimeoutSec 20
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $cls = [string]$row['class']
        $short = $cls
        $dot = $cls.LastIndexOf('.')
        if ($dot -ge 0 -and $dot -lt $cls.Length - 1) { $short = $cls.Substring($dot + 1) }
        $idx = $short.IndexOf("'")
        if ($idx -ge 0) { $short = $short.Substring(0, $idx) }
        $dur = 1.0
        [void][double]::TryParse([string]$row['dur'], [ref]$dur)
        $list += @{
            id                 = [int64](ConvertTo-DuneInt $row['vid'])
            class              = $short
            map                = [string]$row['map']
            chassis_durability = $dur
            vehicle_name       = [string]$row['vname']
            is_recovered       = ([string]$row['recovered']).ToLower() -eq 't' -or ([string]$row['recovered']).ToLower() -eq 'true'
            is_backup          = ([string]$row['backup']).ToLower() -eq 't' -or ([string]$row['backup']).ToLower() -eq 'true'
        }
    }
    return @{ ok = $true; vehicles = $list; total = $list.Count }
}

# ----- §1.8 GET /players/{id}/dungeons ------------------------------------
function Get-DunePlayerDungeonsLive {
    param([string]$Ip, [long]$PlayerId)
    if ($PlayerId -le 0) { return @{ ok = $false; error = 'player_id is required.' } }
    $sql = @"
SELECT dc.dungeon_id, dc.difficulty::text AS difficulty,
       dc.duration_ms::text AS duration_ms,
       dc.players_num::int AS players_num,
       dc.completion_id::text AS completion_id
FROM dune.dungeon_completion_players dcp
JOIN dune.dungeon_completion dc ON dc.completion_id = dcp.completion_id
WHERE dcp.player_id = $PlayerId::bigint
ORDER BY dc.completion_id DESC
LIMIT 100;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 100 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    $list = @()
    foreach ($row in $rows) {
        $list += @{
            dungeon_id    = [string]$row['dungeon_id']
            difficulty    = [string]$row['difficulty']
            duration_ms   = [int64](ConvertTo-DuneInt $row['duration_ms'])
            players_num   = [int](ConvertTo-DuneInt $row['players_num'])
            completion_id = [int64](ConvertTo-DuneInt $row['completion_id'])
        }
    }
    return @{ ok = $true; dungeons = $list; total = $list.Count }
}

# ----- §1.9 GET /players/{id}/player-ids ----------------------------------
function Get-DunePlayerIdsLive {
    param([string]$Ip, [long]$ActorId)
    if ($ActorId -le 0) { return @{ ok = $false; error = 'actor_id is required.' } }
    $sql = @"
SELECT convert_from(e.encrypted_funcom_id, 'UTF8') AS display_name,
       COALESCE(ac."user", '') AS hex_id,
       e.id::text AS account_id,
       ps.character_name AS char_name,
       ps.online_status::text AS status,
       ps.player_pawn_id::text AS pawn_id,
       ps.player_controller_id::text AS controller_id
FROM dune.encrypted_accounts e
JOIN dune.actors a ON a.owner_account_id = e.id
LEFT JOIN dune.accounts ac ON ac.id = e.id
LEFT JOIN dune.player_state ps ON ps.account_id = e.id
WHERE a.id = $ActorId::bigint
LIMIT 1;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r
    if ($rows.Count -eq 0) { return @{ ok = $false; error = "No player found for actor $ActorId." } }
    $row = $rows[0]
    return @{
        ok = $true
        actor_id        = $ActorId
        display_name    = [string]$row['display_name']
        hex_id          = [string]$row['hex_id']
        player_id_field = [string]$row['hex_id']
        account_id      = [int64](ConvertTo-DuneInt $row['account_id'])
        character_name  = [string]$row['char_name']
        status          = [string]$row['status']
        pawn_id         = [int64](ConvertTo-DuneInt $row['pawn_id'])
        controller_id   = [int64](ConvertTo-DuneInt $row['controller_id'])
        publish_method  = 'rabbitmqctl eval (user_id=fls)'
    }
}

# ----- §1.10 GET /players/partitions (hardcoded teleport locations) ------

$script:DuneTeleportPartitions = @(
    @{ name = 'Windsack';      x = 974276.75; y = 20084.312;  z = 5112.283  },
    @{ name = 'EcoLabs';       x = 826879.3;  y = -925967.2;  z = 4974.4277 },
    @{ name = 'CrashSite';     x = 330284.22; y = 205236.98;  z = 2251.008  },
    @{ name = 'MediumStarter'; x = 268515.8;  y = 207559.39;  z = 5000.0    },
    @{ name = 'ConvoyAmbush';  x = -920080.0; y = 909620.0;   z = 300.0     },
    @{ name = 'SpiceRaid';     x = 271590.0;  y = -493122.0;  z = 8471.0    },
    @{ name = 'PS5_ESW_0';     x = -113881.4; y = -305252.1;  z = 20864.5   },
    @{ name = 'PS5_ESW_1';     x = -109861.8; y = -307020.0;  z = 21192.9   },
    @{ name = 'PS5_ESW_2';     x = -129029.6; y = -312757.8;  z = 21099.6   },
    @{ name = 'PS5_ESW_3';     x = -117312.0; y = -305453.9;  z = 21649.8   }
)

function Get-DunePartitionsCatalog {
    return @{ ok = $true; partitions = $script:DuneTeleportPartitions; total = $script:DuneTeleportPartitions.Count }
}

# ----- §1.11 GET /contracts (catalog from app/data/dune-tags.json) -------
function Get-DuneContractCatalog {
    $tags = Get-DuneTagsData
    $aliasReverse = @{}
    foreach ($k in $tags.contractAliases.Keys) {
        $full = $tags.contractAliases[$k]
        if (-not $aliasReverse.ContainsKey($full)) { $aliasReverse[$full] = $k }
    }
    $list = @()
    $ids = @($tags.contractTags.Keys | Sort-Object)
    foreach ($id in $ids) {
        $alias = if ($aliasReverse.ContainsKey($id)) { $aliasReverse[$id] } else { $id }
        $list += @{
            id        = [string]$id
            alias     = [string]$alias
            tag_count = @($tags.contractTags[$id]).Count
        }
    }
    return @{ ok = $true; contracts = $list; total = $list.Count }
}

# ----- §1.12 GET /progression/presets -------------------------------------
function Get-DuneProgressionPresetsCatalog {
    $cat = Get-DuneProgressionPresetCatalog
    return @{ ok = $true; presets = @($cat); total = @($cat).Count }
}

# ----- §1.13 GET /players/trainers ----------------------------------------
# Skill-trainer quest lines. Each job's starting quest line is a set of
# DA_CT_Trainer_<Job><tier>_<nn> contracts (transcribed into dune-tags.json).
# Completing them + granting the job skill tree = "unlock trainer".
$script:DuneTrainerJobOrder = @('Swordmaster', 'Trooper', 'Mentat', 'BeneGesserit', 'Planetologist')
$script:DuneTrainerJobLabels = @{
    Swordmaster   = 'Swordmaster'
    Trooper       = 'Trooper'
    Mentat        = 'Mentat'
    BeneGesserit  = 'Bene Gesserit'
    Planetologist = 'Planetologist'
}

function Get-DuneTrainerContractIds {
    param([string]$Job)
    $tags = Get-DuneTagsData
    $esc = [regex]::Escape($Job)
    $ids = @($tags.contractTags.Keys | Where-Object { $_ -match "^DA_CT_Trainer_$esc\d" } | Sort-Object)
    return $ids
}

function Get-DuneTrainerCatalog {
    $tags = Get-DuneTagsData
    $list = @()
    foreach ($job in $script:DuneTrainerJobOrder) {
        if (-not $tags.jobSkillBlocks.ContainsKey($job)) { continue }
        $ids = Get-DuneTrainerContractIds -Job $job
        $list += @{
            job            = [string]$job
            name           = [string]$script:DuneTrainerJobLabels[$job]
            contract_count = @($ids).Count
            skill_count    = @($tags.jobSkillBlocks[$job]).Count
        }
    }
    return @{ ok = $true; trainers = $list; total = $list.Count }
}

# ----- §1.13a GET /players/trainer-status?account_id=<id> -----------------
# Per-character skill-tree ownership. Reads the pawn's ModuleData
# (FLevelComponent.1.ModuleData, keyed by (TagName="...")) plus its
# StarterSkillTreeTag, then reports per trainer job how many of the trainer's
# skill blocks and how many of the full job module set the character already
# has - so the UI can show present values instead of a blind Unlock button.
# Offline-safe (pure DB read); reports everything locked when no pawn exists.
function Get-DunePlayerTrainerStatusLive {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { return @{ ok = $false; error = 'account_id is required.' } }
    $tags = Get-DuneTagsData

    $build = {
        param([hashtable]$Owned, [string]$StarterJob, [bool]$HasPawn)
        $jobs = @()
        foreach ($job in $script:DuneTrainerJobOrder) {
            if (-not $tags.jobSkillBlocks.ContainsKey($job)) { continue }
            $blocks = @($tags.jobSkillBlocks[$job] | ForEach-Object { [string]$_ })
            $modules = if ($tags.jobAllModules.ContainsKey($job)) { @($tags.jobAllModules[$job] | ForEach-Object { [string]$_ }) } else { @() }
            $blocksOwned = 0
            foreach ($b in $blocks) { if ($Owned.ContainsKey($b)) { $blocksOwned++ } }
            $modulesOwned = 0
            foreach ($mm in $modules) { if ($Owned.ContainsKey($mm)) { $modulesOwned++ } }
            $jobs += @{
                job           = [string]$job
                name          = [string]$script:DuneTrainerJobLabels[$job]
                blocks_owned  = $blocksOwned
                blocks_total  = $blocks.Count
                modules_owned = $modulesOwned
                modules_total = $modules.Count
                unlocked      = ($blocks.Count -gt 0 -and $blocksOwned -ge $blocks.Count)
                is_starter    = ($StarterJob -eq $job)
            }
        }
        return @{ ok = $true; account_id = $AccountId; has_pawn = $HasPawn; jobs = $jobs; total = $jobs.Count }
    }

    $pawnID = Get-DunePlayerPawnFromAccount -Ip $Ip -AccountId $AccountId
    if ($pawnID -le 0) { return (& $build @{} '' $false) }

    # Pull every ModuleData key + the starter skill-tree tag in one read.
    $sql = @"
SELECT 'module'::text AS kind, jsonb_object_keys(md) AS val
FROM (
    SELECT fe.components->'FLevelComponent'->1->'ModuleData' AS md
    FROM dune.fgl_entities fe
    JOIN dune.actor_fgl_entities afe ON afe.entity_id = fe.entity_id
    WHERE afe.actor_id = $pawnID::bigint AND afe.slot_name = 'DuneCharacter'
    LIMIT 1
) s
WHERE md IS NOT NULL
UNION ALL
SELECT 'starter'::text AS kind,
       fe.components->'FLevelComponent'->1->'StarterSkillTreeTag'->>'TagName' AS val
FROM dune.fgl_entities fe
JOIN dune.actor_fgl_entities afe ON afe.entity_id = fe.entity_id
WHERE afe.actor_id = $pawnID::bigint AND afe.slot_name = 'DuneCharacter';
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 5000 -TimeoutSec 30
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $rows = ConvertTo-DuneRowMaps -Result $r

    # ModuleData keys look like (TagName="Skills.Key.Swordmaster1"); strip to the
    # inner tag name so they can be matched against the job block / module lists.
    $owned = @{}
    $starterTag = ''
    foreach ($row in $rows) {
        $kind = [string]$row['kind']
        $val = [string]$row['val']
        if ($kind -eq 'starter') { if ($val) { $starterTag = $val }; continue }
        if (-not $val) { continue }
        $m = [regex]::Match($val, '"([^"]+)"')
        $tag = if ($m.Success) { $m.Groups[1].Value } else { $val }
        $owned[$tag] = $true
    }

    $starterJob = ''
    if ($starterTag -and $starterTag.StartsWith('Skills.Key.') -and $starterTag.EndsWith('1')) {
        $sj = $starterTag.Substring(11)
        $starterJob = $sj.Substring(0, $sj.Length - 1)
    }

    return (& $build $owned $starterJob $true)
}

# ----- §1.14 GET /players/main-quests -------------------------------------
# Main-quest story lines. Each is a DA_MQ_<Root> subtree in journey_node_tags;
# completing the root node flips every DA_MQ_<Root>.* journey row complete and
# applies the union of subtree reward tags.
$script:DuneMainQuestOrder = @(
    'DA_MQ_ANewBeginning',
    'DA_MQ_FindTheFremen',
    'DA_MQ_AssassinsHandbook',
    'DA_MQ_TheGreatConvention',
    'DA_MQ_TheGreatConventionPt2'
)
$script:DuneMainQuestLabels = @{
    DA_MQ_ANewBeginning         = 'A New Beginning'
    DA_MQ_FindTheFremen         = 'Find the Fremen'
    DA_MQ_AssassinsHandbook     = "Assassin's Handbook"
    DA_MQ_TheGreatConvention    = 'The Great Convention'
    DA_MQ_TheGreatConventionPt2 = 'The Great Convention (Pt. 2)'
}

function Get-DuneMainQuestRoots {
    $tags = Get-DuneTagsData
    $counts = @{}
    foreach ($k in $tags.journeyNodeTags.Keys) {
        if ($k -notlike 'DA_MQ_*') { continue }
        $dot = $k.IndexOf('.')
        $root = if ($dot -gt 0) { $k.Substring(0, $dot) } else { $k }
        if ($counts.ContainsKey($root)) { $counts[$root]++ } else { $counts[$root] = 1 }
    }
    return $counts
}

function Get-DuneMainQuestCatalog {
    $counts = Get-DuneMainQuestRoots
    $list = @()
    $seen = @{}
    foreach ($root in $script:DuneMainQuestOrder) {
        $seen[$root] = $true
        $name = if ($script:DuneMainQuestLabels.ContainsKey($root)) { $script:DuneMainQuestLabels[$root] } else { $root }
        $n = if ($counts.ContainsKey($root)) { [int]$counts[$root] } else { 0 }
        $list += @{ id = [string]$root; name = [string]$name; node_count = $n }
    }
    foreach ($root in ($counts.Keys | Sort-Object)) {
        if ($seen.ContainsKey($root)) { continue }
        $name = ($root -replace '^DA_MQ_', '') -creplace '(?<!^)([A-Z])', ' $1'
        $list += @{ id = [string]$root; name = [string]$name.Trim(); node_count = [int]$counts[$root] }
    }
    return @{ ok = $true; main_quests = $list; total = $list.Count }
}

function Test-DuneMainQuestRoot {
    param([string]$Root)
    $counts = Get-DuneMainQuestRoots
    return $counts.ContainsKey($Root)
}
