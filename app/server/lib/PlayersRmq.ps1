# PlayersRmq.ps1
# High-level handlers that publish RMQ ServerCommand messages for live
# (online-player) operations. Ports dune-admin handlers_rmq.go logic:
# parameter validation, optional FLS id resolution from actor_id, lightweight
# capacity check for give-item-live, and the static "Claim Rewards" path
# for grant-live (which is pg_notify-based, not RMQ).
#
# All handlers take -Ip for DB lookups (FLS resolve, capacity check). The
# RMQ publish step uses Get-V6BroadcastContext internally for SSH/VM.
#
# Depends on Rmq.ps1 (Send-DuneRmqServerCommand + typed wrappers),
# Database.ps1 (Invoke-DuneSqlQuery), PlayersAdmin.ps1, PlayersWrites.ps1.

# Best-effort backpack capacity guard. Mirrors dune-admin checkInventoryCapacity
# but only enforces the slot cap (max_item_count). Volume is left to the
# game server. Returns @{ ok=$true } when room exists or when no cap is set.
function Test-DuneInventoryCapacity {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [long]   $PawnId,
        [Parameter(Mandatory)] [string] $Template,
        [int] $Quantity = 1
    )
    if ($Quantity -lt 1) { $Quantity = 1 }

    $sql = @"
SELECT id::text AS inv_id, COALESCE(max_item_count, -1) AS max_slots
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
    if ($maxSlots -le 0) { return @{ ok = $true } }

    $cSql = "SELECT COUNT(*)::text AS c FROM dune.items WHERE inventory_id = $invId::bigint;"
    $cr = Invoke-DuneSqlQuery -Ip $Ip -Sql $cSql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $cr.ok) { return @{ ok = $true; note = 'item count failed; game server will validate.' } }
    $cmaps = ConvertTo-DuneRowMaps -Result $cr
    $used = if ($cmaps.Count -ge 1) { [int](ConvertTo-DuneInt $cmaps[0]['c']) } else { 0 }

    $rule = Get-DuneGameplayItemRule -Template $Template
    $stackMax = 1
    if ($rule -and $rule.max_stack -is [int] -and $rule.max_stack -gt 0) { $stackMax = [int]$rule.max_stack }
    $newStacks = [int][Math]::Ceiling($Quantity / [double]$stackMax)
    $freeSlots = $maxSlots - $used
    if ($freeSlots -lt $newStacks) {
        return @{
            ok = $false
            error = "Inventory full: need $newStacks free slot(s), have $freeSlots."
        }
    }
    return @{ ok = $true; free_slots = $freeSlots; new_stacks = $newStacks }
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
        [double] $Durability = 1.0
    )
    if ($Quantity -le 0)   { $Quantity = 1 }
    if ($Durability -le 0) { $Durability = 1.0 }

    if ($ActorId -gt 0) {
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
# popup to the player whether online or offline. Mirrors dune-admin db.go.
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
        $res.note    = "dune-admin/Adain external chat publish recipe is not live-tested - check the target's whispers tab to confirm delivery."
    }
    return $res
}
