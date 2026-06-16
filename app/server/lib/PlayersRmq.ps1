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

# Max stack size for a template: catalogued stack_max wins, else the largest
# stack_size seen live for that template+quality, else 1. Mirrors the reference
# implementation resolveStackMax.
function Resolve-DuneStackMax {
    param([Parameter(Mandatory)] [string] $Ip, [Parameter(Mandatory)] [string] $Template, [long] $Quality = 0)
    $rule = Get-DuneGameplayItemRule -TemplateId $Template
    if ($rule -and $rule.ContainsKey('stack_max') -and [int]$rule.stack_max -gt 0) { return [int]$rule.stack_max }
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
        [bool]   $AllowOverflow = $false
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
        [Parameter(Mandatory)] [string] $ClassName,
        [double] $X = 0.0, [double] $Y = 0.0, [double] $Z = 0.0,
        [double] $Rotation = 0.0,
        [string] $TemplateName,
        [bool]   $Persistent = $false,
        [string] $Faction
    )
    $r = Resolve-DuneFlsIdOrError -Ip $Ip -FlsId $FlsId -ActorId $ActorId
    if (-not $r.ok) { return @{ ok = $false; error = $r.error } }
    # Spawn at the target's pawn when no explicit coords were supplied. The UI
    # passes the player's pawn/actor id; read its live location from dune.actors
    # so the vehicle drops on the player rather than at map origin (0,0,0).
    if ($X -eq 0.0 -and $Y -eq 0.0 -and $Z -eq 0.0 -and $ActorId -gt 0) {
        $locSql = @"
SELECT (location->>'X')::float8 AS x,
       (location->>'Y')::float8 AS y,
       (location->>'Z')::float8 AS z
FROM dune.actors WHERE id = $ActorId::bigint;
"@
        $lr = Invoke-DuneSqlQuery -Ip $Ip -Sql $locSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if ($lr.ok) {
            $lmaps = ConvertTo-DuneRowMaps -Result $lr
            if ($lmaps.Count -gt 0 -and $null -ne $lmaps[0]['x']) {
                $X = [double]$lmaps[0]['x']; $Y = [double]$lmaps[0]['y']; $Z = [double]$lmaps[0]['z']
            }
        }
    }
    $res = Invoke-DuneRmqSpawnVehicleAt -FlsId $r.fls_id -ClassName $ClassName -X $X -Y $Y -Z $Z -Rotation $Rotation -TemplateName $TemplateName -Persistent $Persistent -Faction $Faction
    if ($res.ok) { $res.message = "Spawn $ClassName command sent for $($r.fls_id)." }
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
