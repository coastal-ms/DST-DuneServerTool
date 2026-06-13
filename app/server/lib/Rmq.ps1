# Rmq.ps1
# Generic ServerCommand publisher + courier (chat) publisher for the
# battlegroup's mq-game RabbitMQ broker.
#
# Mirrors dune-admin's rmq_commands.go: builds the {Version, AuthToken,
# MessageContent} envelope, base64-encodes it host-side, ships a tiny Erlang
# script over SSH -> sudo kubectl exec -> rabbitmqctl eval. Uses the same
# AuthToken and exchange/routing-key conventions as send-dune-broadcast and
# Broadcast.ps1.
#
# Depends on Get-V6BroadcastContext + Find-V6MqGamePod (Broadcast.ps1) and
# Invoke-V6Ssh (Db-Postgres.ps1, transitively).

$script:DuneRmqAuthToken = 'Nu6VmPWUMvdPMeB7qErr'

# ── core publish ──────────────────────────────────────────────────────────────

# Send-DuneRmqServerCommand
# Publishes a ServerCommand to exchange=heartbeats, routingKey=notifications.
# Fields is the inner ServerCommand payload (must include a 'ServerCommand'
# key; PlayerId is the accounts."user" FLS hex id for player-targeted commands).
function Send-DuneRmqServerCommand {
    param(
        [Parameter(Mandatory)] [hashtable] $Fields,
        [string] $Action = 'server-command',
        [hashtable] $Extra
    )

    $ctx = Get-V6BroadcastContext
    if (-not $ctx.ok) { return $ctx }
    $ip  = $ctx.vm.ip
    try { $pod = Find-V6MqGamePod -Ip $ip } catch {
        return @{ ok = $false; status = 503; message = $_.Exception.Message }
    }

    # Marshal inner -> envelope -> base64, mirroring dune-admin/publishServerCommand.
    $innerJson = (ConvertTo-Json $Fields -Depth 8 -Compress)
    $envelope = [ordered]@{
        Version        = 2
        AuthToken      = $script:DuneRmqAuthToken
        MessageContent = $innerJson
    }
    $outerJson = (ConvertTo-Json $envelope -Depth 8 -Compress)
    $outerB64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($outerJson))
    $msgId     = 'dune-tool-cmd-{0}' -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

    # Tiny Erlang: decode envelope from base64 and publish via rabbit_basic.
    $erl = @"
Outer = base64:decode(<<"$outerB64">>),
XName = rabbit_misc:r(<<"/">>, exchange, <<"heartbeats">>),
X = rabbit_exchange:lookup_or_die(XName),
MsgId = <<"$msgId">>,
P = {list_to_atom("P_basic"), <<"Content">>, undefined, [], undefined,
     undefined, undefined, undefined, undefined, MsgId, undefined,
     undefined, <<"fls">>, <<"fls_backend">>, undefined},
Content = rabbit_basic:build_content(P, Outer),
{ok, Msg} = rabbit_basic:message(XName, <<"notifications">>, Content),
rabbit_queue_type:publish_at_most_once(X, Msg).
"@

    return _Invoke-V6BroadcastErl -Ip $ip -Pod $pod -Erl $erl -Action $Action -Extra $Extra
}

# Send-DuneRmqCourierMessage
# Publishes a courier-system message (chat/whisper). Routing differs from
# ServerCommand: exchange + routing key are channel-specific and the basic
# 'type' field carries the message-type byte (e.g. "12" for text chat).
function Send-DuneRmqCourierMessage {
    param(
        [Parameter(Mandatory)] [string] $Exchange,
        [Parameter(Mandatory)] [string] $RoutingKey,
        [Parameter(Mandatory)] [string] $BodyJson,
        [string] $TypeStr = '12',
        [string] $Action = 'courier-message',
        [hashtable] $Extra
    )

    $ctx = Get-V6BroadcastContext
    if (-not $ctx.ok) { return $ctx }
    $ip  = $ctx.vm.ip
    try { $pod = Find-V6MqGamePod -Ip $ip } catch {
        return @{ ok = $false; status = 503; message = $_.Exception.Message }
    }

    $bodyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BodyJson))
    $msgId   = 'dune-tool-chat-{0}' -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    # Erlang string literal escape — exchange/routingKey/typeStr are simple
    # identifiers, but be defensive.
    $exEsc = ($Exchange   -replace '\\', '\\\\' -replace '"', '\\"')
    $rkEsc = ($RoutingKey -replace '\\', '\\\\' -replace '"', '\\"')
    $tyEsc = ($TypeStr    -replace '\\', '\\\\' -replace '"', '\\"')

    $erl = @"
Body = base64:decode(<<"$bodyB64">>),
XName = rabbit_misc:r(<<"/">>, exchange, <<"$exEsc">>),
X = rabbit_exchange:lookup_or_die(XName),
MsgId = <<"$msgId">>,
P = {list_to_atom("P_basic"), <<"Content">>, undefined, [], undefined,
     undefined, undefined, undefined, undefined, MsgId, undefined,
     <<"$tyEsc">>, <<"fls">>, <<"fls_backend">>, undefined},
Content = rabbit_basic:build_content(P, Body),
{ok, Msg} = rabbit_basic:message(XName, <<"$rkEsc">>, Content),
rabbit_queue_type:publish_at_most_once(X, Msg).
"@

    return _Invoke-V6BroadcastErl -Ip $ip -Pod $pod -Erl $erl -Action $Action -Extra $Extra
}

# ── FLS id resolution ─────────────────────────────────────────────────────────

# Resolves the accounts."user" hex Funcom UUID (the PlayerId form RMQ
# ServerCommands expect) for a player-pawn actor_id. Mirrors dune-admin's
# flsIDFromActorID — joins dune.actors -> dune.accounts and returns "user".
function Resolve-DuneFlsIdFromActorId {
    param([Parameter(Mandatory)] [string] $Ip,
          [Parameter(Mandatory)] [long]   $ActorId)
    $sql = @"
SELECT a."user" AS funcom
FROM dune.actors act
JOIN dune.accounts a ON a.id = act.owner_account_id
WHERE act.id = $ActorId::bigint
LIMIT 1;
"@
    $r = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $r.ok)        { return @{ ok = $false; status = 500; error = $r.error } }
    $maps = ConvertTo-DuneRowMaps -Result $r
    if ($maps.Count -eq 0) { return @{ ok = $false; status = 404; error = "No account found for actor $ActorId." } }
    $fls = [string]$maps[0]['funcom']
    if ([string]::IsNullOrWhiteSpace($fls)) {
        return @{ ok = $false; status = 404; error = "Actor $ActorId has no FLS funcom user id." }
    }
    return @{ ok = $true; fls_id = $fls }
}

# Helper: resolve FLS id by either accepting one directly (when the route
# already received fls_id) or looking it up by actor_id. Returns the same
# error shape as Resolve-DuneFlsIdFromActorId.
function Resolve-DuneFlsIdOrError {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [string] $FlsId,
        [long]   $ActorId
    )
    if (-not [string]::IsNullOrWhiteSpace($FlsId)) {
        return @{ ok = $true; fls_id = $FlsId }
    }
    if ($ActorId -le 0) {
        return @{ ok = $false; status = 400; error = 'Either fls_id or actor_id is required.' }
    }
    return Resolve-DuneFlsIdFromActorId -Ip $Ip -ActorId $ActorId
}

# ── typed wrappers (one per ServerCommand) ────────────────────────────────────

function Invoke-DuneRmqKickPlayer {
    param([Parameter(Mandatory)] [string] $FlsId)
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'KickPlayer'
        PlayerId      = $FlsId
    } -Action 'kick'
}

function Invoke-DuneRmqUpdateAllWaterFillables {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [int] $WaterAmount = 10000
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'UpdateAllWaterFillables'
        PlayerId      = $FlsId
        WaterAmount   = $WaterAmount
    } -Action 'fill-water-live'
}

function Invoke-DuneRmqAwardXp {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [int]    $Experience
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'AwardXP'
        PlayerId      = $FlsId
        Category      = $Category
        Experience    = $Experience
    } -Action 'award-xp-live'
}

function Invoke-DuneRmqSkillsSetUnspentSkillPoints {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [int]    $SkillPoints
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'SkillsSetUnspentSkillPoints'
        PlayerId      = $FlsId
        SkillPoints   = $SkillPoints
    } -Action 'set-skill-points-live'
}

function Invoke-DuneRmqCleanPlayerInventory {
    param([Parameter(Mandatory)] [string] $FlsId)
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'CleanPlayerInventory'
        PlayerId      = $FlsId
    } -Action 'clean-inventory-live'
}

function Invoke-DuneRmqResetProgression {
    param([Parameter(Mandatory)] [string] $FlsId)
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'ResetProgression'
        PlayerId      = $FlsId
    } -Action 'reset-progression-live'
}

function Invoke-DuneRmqTeleportTo {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [double] $X,
        [Parameter(Mandatory)] [double] $Y,
        [Parameter(Mandatory)] [double] $Z
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'TeleportTo'
        PlayerId      = $FlsId
        X             = $X
        Y             = $Y
        Z             = $Z
    } -Action 'teleport-live'
}

function Invoke-DuneRmqTeleportToExact {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [double] $X,
        [Parameter(Mandatory)] [double] $Y,
        [Parameter(Mandatory)] [double] $Z
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'TeleportToExact'
        PlayerId      = $FlsId
        X             = $X
        Y             = $Y
        Z             = $Z
    } -Action 'teleport-to-player-live'
}

function Invoke-DuneRmqSkillsSetModuleLevel {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [string] $Module,
        [Parameter(Mandatory)] [int]    $Level
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'SkillsSetModuleLevel'
        PlayerId      = $FlsId
        Module        = $Module
        Level         = $Level
    } -Action 'set-skill-module-live'
}

function Invoke-DuneRmqAddItemToInventory {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [string] $ItemName,
        [int]    $Quantity   = 1,
        [double] $Durability = 1.0
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'AddItemToInventory'
        PlayerId      = $FlsId
        ItemName      = $ItemName
        Quantity      = $Quantity
        Durability    = $Durability
    } -Action 'give-item-live'
}

function Invoke-DuneRmqCheatScript {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [string] $ScriptName
    )
    Send-DuneRmqServerCommand -Fields @{
        ServerCommand = 'CheatScript'
        PlayerId      = $FlsId
        ScriptName    = $ScriptName
    } -Action 'cheat-script-live'
}

function Invoke-DuneRmqSpawnVehicleAt {
    param(
        [Parameter(Mandatory)] [string] $FlsId,
        [Parameter(Mandatory)] [string] $ClassName,
        [Parameter(Mandatory)] [double] $X,
        [Parameter(Mandatory)] [double] $Y,
        [Parameter(Mandatory)] [double] $Z,
        [double] $Rotation = 0.0,
        [string] $TemplateName,
        [bool]   $Persistent = $false,
        [string] $Faction
    )
    $fields = [ordered]@{
        ServerCommand = 'SpawnVehicleAt'
        PlayerId      = $FlsId
        ClassName     = $ClassName
        X             = $X
        Y             = $Y
        Z             = $Z
    }
    if ($Rotation -ne 0) { $fields['Rotation'] = $Rotation }
    if (-not [string]::IsNullOrWhiteSpace($TemplateName)) { $fields['TemplateName'] = $TemplateName }
    $fields['Persistent'] = if ($Persistent) { 1.0 } else { 0.0 }
    if (-not [string]::IsNullOrWhiteSpace($Faction)) { $fields['Faction'] = $Faction }
    Send-DuneRmqServerCommand -Fields ([hashtable]$fields) -Action 'spawn-vehicle-live'
}

# Whisper a single player. SenderName drives bUseSpoofedUserName so the
# message shows up signed; pass empty for an unsigned admin whisper.
function Invoke-DuneRmqSendWhisper {
    param(
        [Parameter(Mandatory)] [string] $TargetFlsId,
        [Parameter(Mandatory)] [string] $TargetName,
        [string] $SenderName,
        [Parameter(Mandatory)] [string] $Message,
        [string] $ImpersonatedFlsId = ''
    )
    $chatMsg = [ordered]@{
        Id                  = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + [DateTimeOffset]::UtcNow.Ticks.ToString())
        ChannelType         = 'ETextChatChannelType::Whispers'
        FuncomIdFrom        = $ImpersonatedFlsId
        UserNameTo          = $TargetName
        Message             = @{ Body = $Message }
        TimeStamp           = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        bUseSpoofedUserName = (-not [string]::IsNullOrWhiteSpace($SenderName))
        SpoofedUserNameFrom = @{ AuthorName = $SenderName }
    }
    $chatJson = (ConvertTo-Json $chatMsg -Depth 8 -Compress)
    $envelope = [ordered]@{
        Content = $chatJson
        Type    = 'ECourierMessageType::TextChat'
    }
    $envelopeJson = (ConvertTo-Json $envelope -Depth 8 -Compress)
    Send-DuneRmqCourierMessage -Exchange 'chat.whispers' -RoutingKey $TargetFlsId -BodyJson $envelopeJson -TypeStr '12' -Action 'whisper'
}
