# PlayersRmq.ps1 - v11.5.9 live (RMQ) player command routes ported from
# the reference implementation handlers_rmq.go. All routes publish to the mq-game broker via
# rabbitmqctl eval over SSH. The HTTP response indicates whether the command
# was queued; the game server applies it asynchronously.

function _DuneRmqFlsId { param($body) [string](Get-DuneBodyValue -Body $body -Name 'fls_id') }
function _DuneRmqActor { param($body) $v = Get-DuneBodyInt -Body $body -Name 'actor_id'; if ($null -eq $v) { 0L } else { [int64]$v } }

function _DuneRmqRequireTarget {
    param($Response, [string]$FlsId, [long]$ActorId)
    if ([string]::IsNullOrWhiteSpace($FlsId) -and $ActorId -le 0) {
        Write-DuneError -Response $Response -Status 400 -Message 'fls_id or actor_id is required.'
        return $false
    }
    return $true
}

# POST /api/gameplay/players/kick  { fls_id? , actor_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/kick' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerKickLive -Ip $ip -FlsId $fls -ActorId $aid }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Kick failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/fill-water  { fls_id?, actor_id?, water_amount? }
# Note: lives in routes/GameplayPlayers.ps1 which is loaded first and handles
# both online (RMQ) and offline (SQL) paths. Routes here are RMQ-only.

# POST /api/gameplay/players/set-skill-points  { fls_id?, actor_id?, skill_points }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-skill-points' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        $sp = Get-DuneBodyInt -Body $body -Name 'skill_points'
        if ($null -eq $sp) { Write-DuneError -Response $res -Status 400 -Message 'skill_points must be an integer.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSetSkillPointsLive -Ip $ip -FlsId $fls -ActorId $aid -SkillPoints ([int]$sp) }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Set skill points failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/clean-inventory  { fls_id?, actor_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/clean-inventory' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerCleanInventoryLive -Ip $ip -FlsId $fls -ActorId $aid }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Clean inventory failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/reset-progression  { fls_id?, actor_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/reset-progression' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerResetProgressionLive -Ip $ip -FlsId $fls -ActorId $aid }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Reset progression failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/set-skill-module  { fls_id?, actor_id?, module, level }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/set-skill-module' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        $mod = [string](Get-DuneBodyValue -Body $body -Name 'module')
        if ([string]::IsNullOrWhiteSpace($mod)) { Write-DuneError -Response $res -Status 400 -Message 'module is required.'; return }
        $lvl = Get-DuneBodyInt -Body $body -Name 'level'; if ($null -eq $lvl) { $lvl = 1 }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerSetSkillModuleLive -Ip $ip -FlsId $fls -ActorId $aid -Module $mod -Level ([int]$lvl) }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Set skill module failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/give-item-live  { actor_id?, fls_id?, template, qty?, durability? }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/give-item-live' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        $tpl = [string](Get-DuneBodyValue -Body $body -Name 'template')
        if ([string]::IsNullOrWhiteSpace($tpl)) { Write-DuneError -Response $res -Status 400 -Message 'template is required.'; return }
        $qty = Get-DuneBodyInt -Body $body -Name 'qty'; if ($null -eq $qty -or $qty -le 0) { $qty = 1 }
        $durRaw = Get-DuneBodyValue -Body $body -Name 'durability'
        $dur = 1.0
        if ($null -ne $durRaw) { try { $dur = [double]$durRaw } catch {} }
        if ($dur -le 0) { $dur = 1.0 }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGiveItemLive -Ip $ip -ActorId $aid -FlsId $fls -Template $tpl -Quantity ([int]$qty) -Durability $dur }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Give item live failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/cheat-script  { fls_id?, actor_id?, script_name }
Register-DuneRoute -Method POST -Path '/api/gameplay/players/cheat-script' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        $name = [string](Get-DuneBodyValue -Body $body -Name 'script_name')
        if ([string]::IsNullOrWhiteSpace($name)) { Write-DuneError -Response $res -Status 400 -Message 'script_name is required.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerCheatScriptLive -Ip $ip -FlsId $fls -ActorId $aid -ScriptName $name }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Cheat script failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/players/grant-live  { controller_id, template, amount }
# Not RMQ - pg_notify-based Claim Rewards path. Works for both online + offline players.
Register-DuneRoute -Method POST -Path '/api/gameplay/players/grant-live' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $cid = Get-DuneBodyInt -Body $body -Name 'controller_id'
        if ($null -eq $cid -or $cid -le 0) { Write-DuneError -Response $res -Status 400 -Message 'controller_id is required.'; return }
        $tpl = [string](Get-DuneBodyValue -Body $body -Name 'template')
        if ([string]::IsNullOrWhiteSpace($tpl)) { Write-DuneError -Response $res -Status 400 -Message 'template is required.'; return }
        $amt = Get-DuneBodyInt -Body $body -Name 'amount'
        if ($null -eq $amt -or $amt -le 0) { Write-DuneError -Response $res -Status 400 -Message 'amount must be > 0.'; return }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DunePlayerGrantLive -Ip $ip -ControllerId ([int64]$cid) -Template $tpl -Amount ([int64]$amt) }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Grant live failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/vehicles/spawn  { fls_id?, actor_id?, class_name, x?, y?, z?, rotation?, template_name?, persistent?, faction? }
Register-DuneRoute -Method POST -Path '/api/gameplay/vehicles/spawn' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $fls = _DuneRmqFlsId $body; $aid = _DuneRmqActor $body
        if (-not (_DuneRmqRequireTarget -Response $res -FlsId $fls -ActorId $aid)) { return }
        $cls = [string](Get-DuneBodyValue -Body $body -Name 'class_name')
        if ([string]::IsNullOrWhiteSpace($cls)) { Write-DuneError -Response $res -Status 400 -Message 'class_name is required.'; return }
        $xv = Get-DuneBodyValue -Body $body -Name 'x'; $x = if ($null -ne $xv) { try { [double]$xv } catch { 0.0 } } else { 0.0 }
        $yv = Get-DuneBodyValue -Body $body -Name 'y'; $y = if ($null -ne $yv) { try { [double]$yv } catch { 0.0 } } else { 0.0 }
        $zv = Get-DuneBodyValue -Body $body -Name 'z'; $z = if ($null -ne $zv) { try { [double]$zv } catch { 0.0 } } else { 0.0 }
        $rv = Get-DuneBodyValue -Body $body -Name 'rotation'; $rot = if ($null -ne $rv) { try { [double]$rv } catch { 0.0 } } else { 0.0 }
        $tname = [string](Get-DuneBodyValue -Body $body -Name 'template_name')
        $persRaw = Get-DuneBodyValue -Body $body -Name 'persistent'
        $pers = $false; if ($null -ne $persRaw) { $pers = [bool]$persRaw }
        $fac = [string](Get-DuneBodyValue -Body $body -Name 'faction')
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneVehicleSpawnLive -Ip $ip -FlsId $fls -ActorId $aid -ClassName $cls -X $x -Y $y -Z $z -Rotation $rot -TemplateName $tname -Persistent $pers -Faction $fac }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Spawn vehicle failed: $($_.Exception.Message)" }
}

# POST /api/gameplay/chat/whisper  { target_fls_id, target_name?, sender_name?, message, impersonated_fls_id? }
Register-DuneRoute -Method POST -Path '/api/gameplay/chat/whisper' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $target = [string](Get-DuneBodyValue -Body $body -Name 'target_fls_id')
        if ([string]::IsNullOrWhiteSpace($target)) { Write-DuneError -Response $res -Status 400 -Message 'target_fls_id is required.'; return }
        $msg = [string](Get-DuneBodyValue -Body $body -Name 'message')
        if ([string]::IsNullOrWhiteSpace($msg)) { Write-DuneError -Response $res -Status 400 -Message 'message is required.'; return }
        $tname  = [string](Get-DuneBodyValue -Body $body -Name 'target_name')
        $sender = [string](Get-DuneBodyValue -Body $body -Name 'sender_name')
        $imp    = [string](Get-DuneBodyValue -Body $body -Name 'impersonated_fls_id')
        if ([string]::IsNullOrWhiteSpace($sender)) { $sender = 'GM' }
        Invoke-DunePlayerWriteRoute -Response $res -Action { param($ip) Invoke-DuneChatWhisperLive -Ip $ip -TargetFlsId $target -TargetName $tname -SenderName $sender -Message $msg -ImpersonatedFlsId $imp }
    } catch { Write-DuneError -Response $res -Status 500 -Message "Whisper failed: $($_.Exception.Message)" }
}
