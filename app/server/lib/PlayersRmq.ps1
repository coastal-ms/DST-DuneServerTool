# PlayersRmq.ps1
# High-level handlers that publish RMQ ServerCommand messages for live
# (online-player) operations. Ports the reference implementation handlers_rmq.go logic:
# parameter validation, optional FLS id resolution from actor_id, lightweight
# capacity check for give-item-live, and the static "Claim Rewards" path
# for grant-live (which is pg_notify-based, not RMQ).
#
# All handlers take -Ip for DB lookups (FLS resolve, capacity check). The
# RMQ publish step uses Get-V6BroadcastContext internally for SSH/VM.
#
# Depends on Rmq.ps1 (Send-DuneRmqServerCommand + typed wrappers),
# Database.ps1 (Invoke-DuneSqlQuery), PlayersAdmin.ps1, PlayersWrites.ps1.

# Per-item inventory volume, resolved the way the game does: a catalogued item's
# `volume` is authoritative (0 is valid — the item takes no space), otherwise fall
# back to the live DB volume_override for that template, otherwise 0 (unknown =
# treats as weightless). Mirrors the reference implementation resolveItemVolume.
function Resolve-DuneItemVolume {
    param([Parameter(Mandatory)] [string] $Ip, [Parameter(Mandatory)] [string] $Template)
    $rule = Get-DuneGameplayItemRule -TemplateId $Template
    if ($rule -and $rule.ContainsKey('volume') -and $null -ne $rule.volume) { return [double]$rule.volume }
    $safe = ($Template -replace "'", "''")
    $sql = "SELECT MAX(volume_override)::text AS v FROM dune.items WHERE template_id = '$safe' AND volume_override IS NOT NULL;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if ($r.ok) {
        $m = ConvertTo-DuneRowMaps -Result $r
        if ($m.Count -ge 1 -and $m[0]['v']) { $v = [double]([string]$m[0]['v']); if ($v -gt 0) { return $v } }
    }
    return 0.0
}

# Picker-only ammo templates are absent from gameplay-item-data.json, so they
# have no catalogued stack_max even though the game stacks them.
$script:DuneKnownStackableItemLimits = @{
    Ammo              = 500
    AntiRadiationPill = 20
    HeavyAmmo         = 500
    InfantryRocketAmmo = 500
    Napalm            = 500
    RocketAmmo        = 500
    SolarisCoin       = [int]::MaxValue
}

# Max stack size for a template: catalogued stack_max wins, else known
# picker-only stackables, else the largest stack_size seen live for that
# template+quality, else 1. Mirrors the reference implementation resolveStackMax
# with DST catalog backfill for items missing from gameplay-item-data.json.
function Resolve-DuneStackMax {
    param([Parameter(Mandatory)] [string] $Ip, [Parameter(Mandatory)] [string] $Template, [long] $Quality = 0)
    $rule = Get-DuneGameplayItemRule -TemplateId $Template
    if ($rule -and $rule.ContainsKey('stack_max') -and [int]$rule.stack_max -gt 0) { return [int]$rule.stack_max }
    if ($script:DuneKnownStackableItemLimits.ContainsKey($Template)) {
        return [int]$script:DuneKnownStackableItemLimits[$Template]
    }
    $safe = ($Template -replace "'", "''")
    $sql = "SELECT COALESCE(MAX(stack_size), 0)::text AS s FROM dune.items WHERE template_id = '$safe' AND quality_level = $Quality::bigint;"
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if ($r.ok) {
        $m = ConvertTo-DuneRowMaps -Result $r
        if ($m.Count -ge 1 -and $m[0]['s']) { $s = [int](ConvertTo-DuneInt $m[0]['s']); if ($s -gt 0) { return $s } }
    }
    return 1
}

# Best-effort backpack capacity guard. Ports the reference implementation
# checkInventoryCapacity: this game's inventory cap is VOLUME-based
# (inventories.max_item_volume), with an optional slot cap (max_item_count).
# A stack occupies ONE slot, but the whole stack's VOLUME (per-item volume x
# stack_size) counts against the volume cap. Either cap is enforced only when
# set (> 0); when neither is set the game server validates. Returns @{ ok=$true }
# when the add fits.
function Test-DuneInventoryCapacity {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [long]   $PawnId,
        [Parameter(Mandatory)] [string] $Template,
        [int]  $Quantity = 1,
        [long] $Quality  = 0
    )
    if ($Quantity -lt 1) { $Quantity = 1 }

    $sql = @"
SELECT id::text AS inv_id,
       COALESCE(max_item_count, -1)  AS max_slots,
       COALESCE(max_item_volume, -1) AS max_vol
FROM dune.inventories
WHERE actor_id = $PawnId::bigint AND inventory_type = 0
LIMIT 1;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok) { return @{ ok = $true; note = 'inventory lookup failed; game server will validate.' } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $true; note = 'no backpack inventory row; game server will validate.' } }
    $invId    = [int64](ConvertTo-DuneInt $maps[0]['inv_id'])
    $maxSlots = [int](ConvertTo-DuneInt $maps[0]['max_slots'])
    $maxVol   = [double]([string]$maps[0]['max_vol'])
    $hasSlotCap   = $maxSlots -gt 0
    $hasVolumeCap = $maxVol   -gt 0
    if (-not $hasSlotCap -and -not $hasVolumeCap) { return @{ ok = $true } }

    # Tally current usage: one row = one slot; volume = per-item volume x stack_size.
    $itemsSql = "SELECT template_id AS t, stack_size::text AS ss, COALESCE(volume_override, -1)::text AS vov FROM dune.items WHERE inventory_id = $invId::bigint;"
    $ir = Invoke-DuneSqlQuery -Ip $Ip -Sql $itemsSql -ReadOnly $true -MaxRows 100000 -TimeoutSec 15
    if (-not $ir.ok) { return @{ ok = $true; note = 'item scan failed; game server will validate.' } }
    $imaps = ConvertTo-DuneRowMaps -Result $ir
    $usedSlots  = $imaps.Count
    $usedVolume = 0.0
    if ($hasVolumeCap) {
        foreach ($it in $imaps) {
            $ss  = [double](ConvertTo-DuneInt $it['ss'])
            $vov = [double]([string]$it['vov'])
            $iv  = 0.0
            if ($vov -gt 0) {
                $iv = $vov
            } else {
                $itRule = Get-DuneGameplayItemRule -TemplateId ([string]$it['t'])
                if ($itRule -and $itRule.ContainsKey('volume') -and $null -ne $itRule.volume) { $iv = [double]$itRule.volume }
            }
            $usedVolume += $iv * $ss
        }
    }

    # Volume gate (primary — capacity is volume-based in this game).
    if ($hasVolumeCap) {
        $perItemVol = Resolve-DuneItemVolume -Ip $Ip -Template $Template
        if ($perItemVol -gt 0) {
            $availVol = $maxVol - $usedVolume
            if ($availVol -lt 0) { $availVol = 0 }
            $maxByVolume = [long][Math]::Floor($availVol / $perItemVol)
            if ($maxByVolume -lt $Quantity) {
                return @{
                    ok = $false
                    error = ("Over volume limit: room for {0} more {1} ({2:N1}/{3:N1} volume used)." -f $maxByVolume, $Template, $usedVolume, $maxVol)
                }
            }
        }
        # perItemVol == 0: item takes no volume, always fits.
    }

    # Slot gate (only when a slot cap is set; a stack occupies one slot).
    if ($hasSlotCap) {
        $stackMax = Resolve-DuneStackMax -Ip $Ip -Template $Template -Quality $Quality
        if ($stackMax -lt 1) { $stackMax = 1 }
        $newStacks = [int][Math]::Ceiling($Quantity / [double]$stackMax)
        $freeSlots = $maxSlots - $usedSlots
        if ($freeSlots -lt $newStacks) {
            return @{ ok = $false; error = "Inventory full: need $newStacks free slot(s), have $freeSlots." }
        }
        return @{ ok = $true; free_slots = $freeSlots; new_stacks = $newStacks }
    }
    return @{ ok = $true }
}

# ── handlers ──────────────────────────────────────────────────────────────────

function Invoke-DunePlayerKickLive {
    param([string] $Ip, [string] $FlsId, [long] $ActorId = 0)
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqKickPlayer -FlsId $r.fls_id
    if ($res.ok) { $res.message = "Kick command sent for $($r.fls_id)." }
    return $res
}

function Invoke-DunePlayerFillWaterLive {
    param([string] $Ip, [string] $FlsId, [long] $ActorId = 0, [int] $WaterAmount = 1000000)
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    if ($WaterAmount -le 0) { $WaterAmount = 1000000 }
    $res = Invoke-DuneRmqUpdateAllWaterFillables -FlsId $r.fls_id -WaterAmount $WaterAmount
    if ($res.ok) { $res.message = "Fill water command sent for $($r.fls_id) (amount $WaterAmount)." }
    return $res
}

function Invoke-DunePlayerSetSkillPointsLive {
    param([string] $Ip, [string] $FlsId, [long] $ActorId = 0, [int] $SkillPoints = 0)
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqSkillsSetUnspentSkillPoints -FlsId $r.fls_id -SkillPoints $SkillPoints
    if ($res.ok) { $res.message = "Set skill points $SkillPoints sent for $($r.fls_id)." }
    return $res
}

function Invoke-DunePlayerCleanInventoryLive {
    param([string] $Ip, [string] $FlsId, [long] $ActorId = 0)
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqCleanPlayerInventory -FlsId $r.fls_id
    if ($res.ok) { $res.message = "Clean inventory command sent for $($r.fls_id)." }
    return $res
}

function Invoke-DunePlayerResetProgressionLive {
    param([string] $Ip, [string] $FlsId, [long] $ActorId = 0)
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqResetProgression -FlsId $r.fls_id
    if ($res.ok) { $res.message = "Reset progression command sent for $($r.fls_id)." }
    return $res
}

function Invoke-DunePlayerSetSkillModuleLive {
    param(
        [string] $Ip, [string] $FlsId, [long] $ActorId = 0,
        [Parameter(Mandatory)] [string] $Module,
        [int] $Level = 1
    )
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqSkillsSetModuleLevel -FlsId $r.fls_id -Module $Module -Level $Level
    if ($res.ok) { $res.message = "Set module $Module level $Level sent for $($r.fls_id)." }
    return $res
}

function Invoke-DunePlayerGiveItemLive {
    param(
        [string] $Ip,
        [long]   $ActorId = 0,
        [string] $FlsId,
        [Parameter(Mandatory)] [string] $Template,
        [int]    $Quantity = 1,
        [double] $Durability = 1.0,
        [bool]   $AllowOverflow = $true
    )
    if ($Quantity -le 0)   { $Quantity = 1 }
    if ($Durability -le 0) { $Durability = 1.0 }

    $tv = Test-DuneValidGiveTemplate -TemplateId $Template
    if (-not $tv.ok) { return @{ ok = $false; error = $tv.error } }

    # When AllowOverflow is set we skip the capacity guard and let the game's
    # native AddItemToInventory ServerCommand handle the overflow — it drops the
    # items that don't fit onto the ground next to the online player.
    if ($ActorId -gt 0 -and -not $AllowOverflow) {
        $cap = Test-DuneInventoryCapacity -Ip $Ip -PawnId $ActorId -Template $Template -Quantity $Quantity
        if (-not $cap.ok) { return $cap }
    }

    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqAddItemToInventory -FlsId $r.fls_id -ItemName $Template -Quantity $Quantity -Durability $Durability
    if ($res.ok) {
        $res.message = "Sent $Quantity x $Template to online player $($r.fls_id) via server command."
        $res.path    = 'rmq'
    }
    return $res
}

# Live character-XP award. The offline DB path (Invoke-DunePlayerAwardCharXp)
# writes TotalXPEarned directly; that gets clobbered while the player is online,
# so for online players we send the game-native RMQ AwardXP ServerCommand and let
# the game server roll it into character level / SP / intel itself.
#
# AwardXP is category-based (Combat / Exploration / Science) and additive only.
# Character level/SP derive from TOTAL character XP = the sum across the three
# categories, so awarding the full delta to a single default category yields the
# same total/level. Category is therefore cosmetic for this admin goal; we default
# to Combat and keep it a parameter for flexibility.
function Invoke-DunePlayerAwardCharXpLive {
    param(
        [string] $Ip,
        [string] $FlsId,
        [long]   $ActorId = 0,
        [Parameter(Mandatory)] [long] $XpDelta,
        [string] $Category = 'Combat'
    )
    if ($XpDelta -le 0) {
        return @{ ok = $false; error = 'Live XP awards are additive only (delta must be > 0). To reduce XP, log the player out and apply the edit offline.' }
    }
    $valid = @('Combat', 'Exploration', 'Science')
    $cat = $valid | Where-Object { $_ -ieq [string]$Category } | Select-Object -First 1
    if (-not $cat) { $cat = 'Combat' }

    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }

    $res = Invoke-DuneRmqAwardXp -FlsId $r.fls_id -Category $cat -Experience ([int]$XpDelta)
    if ($res.ok) {
        $res.message = "Awarded $XpDelta $cat XP live to online player $($r.fls_id) via server command - the game applies the resulting level / skill points."
        $res.path    = 'rmq'
        $res.category = $cat
    }
    return $res
}

function Invoke-DunePlayerCheatScriptLive {
    param(
        [string] $Ip, [string] $FlsId, [long] $ActorId = 0,
        [Parameter(Mandatory)] [string] $ScriptName
    )
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    $res = Invoke-DuneRmqCheatScript -FlsId $r.fls_id -ScriptName $ScriptName
    if ($res.ok) { $res.message = "Cheat script '$ScriptName' sent for $($r.fls_id)." }
    return $res
}

# cmdGrantLive: NOT an RMQ command. Inserts into dune.landsraad_house_rewards
# with house_name='AdminGrant'; the pg_notify trigger surfaces a Claim Rewards
# popup to the player whether online or offline. Mirrors the reference implementation db.go.
function Invoke-DunePlayerGrantLive {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [long]   $ControllerId,
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [long]   $Amount
    )
    if ($ControllerId -le 0) { return @{ ok = $false; error = 'controller_id is required.' } }
    if ([string]::IsNullOrWhiteSpace($Template)) { return @{ ok = $false; error = 'template is required.' } }
    if ($Amount -le 0) { return @{ ok = $false; error = 'amount must be > 0.' } }
    $safeTpl = ConvertTo-DuneSqlString $Template
    $sql = @"
DELETE FROM dune.landsraad_house_rewards
WHERE player_id = $ControllerId::bigint AND house_name = 'AdminGrant';
INSERT INTO dune.landsraad_house_rewards (player_id, house_name, amount, template_id, last_updated)
VALUES ($ControllerId::bigint, 'AdminGrant', $Amount::bigint, '$safeTpl'::text, NOW());
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
    if (-not $r.ok) { return @{ ok = $false; error = "grant live: $($r.error)" } }
    return @{
        ok = $true
        message = "Queued live grant: $Amount x $Template - player $ControllerId will see Claim Rewards."
        path = 'pg_notify'
    }
}

function Invoke-DuneVehicleSpawnLive {
    param(
        [string] $Ip,
        [string] $FlsId,
        [long]   $ActorId = 0,
        [Parameter(Mandatory)] [string] $VehicleId,
        [Parameter(Mandatory)] [string] $ActorClass,
        [double] $X = 0.0, [double] $Y = 0.0, [double] $Z = 0.0,
        [double] $Rotation = 0.0,
        [string] $TemplateName,
        [bool]   $Persistent = $false,
        [string] $Faction,
        [int]    $VerificationDelaySeconds = 2
    )
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    if (-not $Persistent) {
        return @{ ok = $false; error = 'Persistent must be enabled so DST can assign and verify vehicle ownership.' }
    }
    $controllerId = 0L

    # Funcom's command expects an open spawn point rather than the pawn's exact
    # coordinates. Resolve the live transform and place the vehicle 10 meters in
    # front of the player using the pawn's horizontal forward vector.
    if ($X -eq 0.0 -and $Y -eq 0.0 -and $Z -eq 0.0 -and $ActorId -gt 0) {
        $locSql = @"
SELECT ps.player_controller_id::bigint AS controller_id,
       ((a.transform).location).x::float8 AS x,
       ((a.transform).location).y::float8 AS y,
       ((a.transform).location).z::float8 AS z,
       ((a.transform).rotation).x::float8 AS qx,
       ((a.transform).rotation).y::float8 AS qy,
       ((a.transform).rotation).z::float8 AS qz,
       ((a.transform).rotation).w::float8 AS qw
FROM dune.player_state ps
JOIN dune.actors a ON a.id = ps.player_pawn_id
WHERE ps.player_pawn_id = $ActorId::bigint
  AND ps.online_status::text = 'Online'
LIMIT 1;
"@
        $lr = Invoke-DuneSqlQuery -Ip $Ip -Sql $locSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if (-not $lr.ok) { return @{ ok = $false; error = $lr.error } }
        $lmaps = ConvertTo-DuneRowMaps -Result $lr
        if ($lmaps.Count -eq 0) {
            return @{ ok = $false; error = 'The player must be online with a live pawn location before spawning a vehicle.' }
        }
        $loc = $lmaps[0]
        $controllerId = [long]$loc['controller_id']
        $baseX = [double]$loc['x']; $baseY = [double]$loc['y']; $Z = [double]$loc['z']
        $qx = [double]$loc['qx']; $qy = [double]$loc['qy']; $qz = [double]$loc['qz']; $qw = [double]$loc['qw']
        $forwardX = 1.0 - (2.0 * (($qy * $qy) + ($qz * $qz)))
        $forwardY = 2.0 * (($qx * $qy) + ($qw * $qz))
        $forwardLength = [Math]::Sqrt(($forwardX * $forwardX) + ($forwardY * $forwardY))
        if ($forwardLength -lt 0.000001) {
            $yaw = [Math]::Atan2(
                2.0 * (($qw * $qz) + ($qx * $qy)),
                1.0 - (2.0 * (($qy * $qy) + ($qz * $qz)))
            )
            $forwardX = [Math]::Cos($yaw)
            $forwardY = [Math]::Sin($yaw)
        } else {
            $forwardX /= $forwardLength
            $forwardY /= $forwardLength
            $yaw = [Math]::Atan2($forwardY, $forwardX)
        }
        $X = $baseX + ($forwardX * 1000.0)
        $Y = $baseY + ($forwardY * 1000.0)
        $Rotation = $yaw * 180.0 / [Math]::PI
    }

    $maxSql = 'SELECT COALESCE(MAX(id), 0)::bigint AS max_id FROM dune.vehicles;'
    $maxResult = Invoke-DuneSqlQuery -Ip $Ip -Sql $maxSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $maxResult.ok) { return @{ ok = $false; error = $maxResult.error } }
    $maxRows = ConvertTo-DuneRowMaps -Result $maxResult
    $beforeVehicleId = if ($maxRows.Count -gt 0) { [long]$maxRows[0]['max_id'] } else { 0L }

    # Funcom expects the short vehicle id (for example "Tank"), not the Unreal
    # actor-class path used to identify the resulting database row.
    $res = Invoke-DuneRmqSpawnVehicleAt -FlsId $r.fls_id -ClassName $VehicleId -X $X -Y $Y -Z $Z -Rotation $Rotation -TemplateName $TemplateName -Persistent $Persistent -Faction $Faction
    if (-not $res.ok) { return $res }

    $safeActorClass = $ActorClass -replace "'", "''"
    $permissionRepaired = $false
    if ($controllerId -gt 0) {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            Start-Sleep -Seconds 1
            $repairSql = @"
WITH candidate AS (
    SELECT a.id
    FROM dune.vehicles v
    JOIN dune.actors a ON a.id = v.id
    WHERE v.id > $beforeVehicleId::bigint
      AND a.class = '$safeActorClass'
      AND a.transform IS NOT NULL
      AND ABS(((a.transform).location).x::float8 - ($X)::float8) <= 5000
      AND ABS(((a.transform).location).y::float8 - ($Y)::float8) <= 5000
      AND ABS(((a.transform).location).z::float8 - ($Z)::float8) <= 5000
    ORDER BY
      POWER(((a.transform).location).x::float8 - ($X)::float8, 2) +
      POWER(((a.transform).location).y::float8 - ($Y)::float8, 2) +
      POWER(((a.transform).location).z::float8 - ($Z)::float8, 2),
      a.id DESC
    LIMIT 1
),
permission_row AS (
    INSERT INTO dune.permission_actor(actor_id, actor_name, actor_type, access_level, is_child)
    SELECT c.id, '##' || REGEXP_REPLACE(SPLIT_PART(SPLIT_PART(a.class, '.', 2), '_C', 1), '^BP_', ''), 2, 3, false
    FROM candidate c
    JOIN dune.actors a ON a.id = c.id
    ON CONFLICT (actor_id) DO NOTHING
    RETURNING actor_id
)
INSERT INTO dune.permission_actor_rank(permission_actor_id, player_id, rank)
SELECT c.id, $controllerId::bigint, 1
FROM candidate c
WHERE NOT EXISTS (
    SELECT 1
    FROM dune.permission_actor_rank existing
    WHERE existing.permission_actor_id = c.id
      AND existing.player_id = $controllerId::bigint
)
RETURNING permission_actor_id;
"@
            $repair = Invoke-DuneSqlQuery -Ip $Ip -Sql $repairSql -ReadOnly $false -MaxRows 1 -TimeoutSec 15
            if ($repair.ok) {
                $repairRows = ConvertTo-DuneRowMaps -Result $repair
                if ($repairRows.Count -gt 0) {
                    $permissionRepaired = $true
                    break
                }
            }
        }
    }

    if ($VerificationDelaySeconds -gt 0) {
        Start-Sleep -Seconds $VerificationDelaySeconds
    }
    $survivalSql = @"
SELECT a.id::bigint AS vehicle_id
FROM dune.vehicles v
JOIN dune.actors a ON a.id = v.id
WHERE v.id > $beforeVehicleId::bigint
  AND a.class = '$safeActorClass'
  AND a.transform IS NOT NULL
  AND EXISTS (
      SELECT 1
      FROM dune.permission_actor_rank par
      WHERE par.permission_actor_id = a.id
        AND par.player_id = $controllerId::bigint
        AND par.rank = 1
  )
ORDER BY a.id DESC
LIMIT 1;
"@
    $survival = Invoke-DuneSqlQuery -Ip $Ip -Sql $survivalSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    $survivalRows = if ($survival.ok) { ConvertTo-DuneRowMaps -Result $survival } else { @() }
    $vehicleSurvived = $survivalRows.Count -gt 0

    $res['permission_repaired'] = $permissionRepaired
    $res['vehicle_survived'] = $vehicleSurvived
    if (-not $vehicleSurvived) {
        $res['ok'] = $false
        $res['error'] = "Funcom accepted the $VehicleId command, but the vehicle did not survive with a valid actor and owner permission."
        return $res
    }
    $res['message'] = "Spawned $VehicleId for $($r.fls_id) and verified rank-1 owner permission."
    return $res
}

function Invoke-DuneChatWhisperLive {
    param(
        [string] $Ip,
        [Parameter(Mandatory)] [string] $TargetFlsId,
        [string] $TargetName,
        [string] $SenderName = 'GM',
        [Parameter(Mandatory)] [string] $Message,
        [string] $ImpersonatedFlsId
    )
    if ([string]::IsNullOrWhiteSpace($TargetFlsId)) { return @{ ok = $false; error = 'target_fls_id is required.' } }
    if ([string]::IsNullOrWhiteSpace($Message))     { return @{ ok = $false; error = 'message is required.' } }
    if ([string]::IsNullOrWhiteSpace($SenderName))  { $SenderName = 'GM' }
    $res = Invoke-DuneRmqSendWhisper -TargetFlsId $TargetFlsId -TargetName $TargetName -SenderName $SenderName -Message $Message -ImpersonatedFlsId $ImpersonatedFlsId
    if ($res.ok) {
        $res.message = "Whisper sent to $TargetFlsId (broker accepted; in-game delivery is experimental)."
        $res.note    = "The external chat publish recipe is not live-tested - check the target's whispers tab to confirm delivery."
    }
    return $res
}
