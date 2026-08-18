# -----------------------------------------------------------------------------
# ChatCommands.ps1 — player-triggered `!commands` from in-game chat.
#
# HOW THIS IS POSSIBLE AT ALL (proven live 2026-08-04):
#
#   The battlegroup's mq-game broker carries a TOPIC exchange `chat.intercept`,
#   catch-all bound (`#`) to Funcom's own `queue.intercept`, which their
#   textRouter consumes. Because it is a topic exchange, binding a SECOND queue
#   alongside gives us a COPY of every chat message and leaves Funcom's consumer
#   completely untouched - no interception, no diversion, nothing removed from
#   their queue.
#
#   A captured message body looks like (outer envelope, inner JSON string):
#     { "Type": "TextChat",
#       "content": "{ \"m_ChannelType\": \"Proximity\",
#                     \"m_FuncomIdFrom\": \"Coastal#45066\",
#                     \"m_Message\": { \"m_UnlocalizedMessage\": \"!large\" },
#                     \"m_OriginLocation\": { \"X\":..,\"Y\":..,\"Z\":.. },
#                     \"m_Timestamp\": \"2026.08.05-00.13.11\" }" }
#
#   So we get the literal text, who sent it, which channel, when, and where they
#   were standing. That is everything a command needs.
#
# WHY POLLING AND NOT A CONSUMER:
#   DST has no AMQP client - every RMQ operation it already performs (broadcasts,
#   whispers, ServerCommands) goes through `rabbitmqctl eval` over SSH. This
#   follows that exact path rather than introducing a persistent connection and
#   a new dependency. We basic_get in batches on a scheduler tick; a few seconds
#   of latency is irrelevant for a chat command.
#
# SAFETY POSTURE (deliberate - do not loosen without asking):
#   - OFF by default, master switch plus per-command opt-in.
#   - The queue is declared BOUNDED (x-max-length + TTL, drop-head) so it can
#     never grow without limit if DST stops draining it. That matters: this
#     queue receives a copy of ALL chat.
#   - Per-player, per-command cooldowns.
#   - These are world-affecting actions triggered by ordinary players, which is a
#     real shift in who controls the server. Default to the conservative option
#     every time.
# -----------------------------------------------------------------------------

$script:DuneChatQueueName    = 'dst.chat.commands'
$script:DuneChatExchange     = 'chat.intercept'
# Bounded on purpose - see SAFETY POSTURE above.
$script:DuneChatQueueMaxLen  = 500
$script:DuneChatQueueTtlMs   = 300000
# Drained per tick. Enough to absorb a busy server between ticks without letting
# one tick block on an unbounded loop.
$script:DuneChatDrainMax     = 25

$script:DuneChatStateFile = $null
$script:DuneChatTeleportsFile = $null
$script:DuneChatTeleportCaptureFile = $null
$script:DuneChatTeleportMax = 20
$script:DuneChatTeleportNameMax = 40
$script:DuneChatTeleportCaptureTtlSeconds = 120

function Get-DuneChatCommandsStatePath {
    if ($script:DuneChatStateFile) { return $script:DuneChatStateFile }
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {}
    }
    return (Join-Path $dir 'chat-commands.json')
}

function Get-DuneChatTeleportsPath {
    if ($script:DuneChatTeleportsFile) { return $script:DuneChatTeleportsFile }
    $dir = if ($env:APPDATA) { Join-Path $env:APPDATA 'DuneServer' } else { $env:TEMP }
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'teleport-bookmarks.json')
}

function Get-DuneChatTeleportCapturePath {
    if ($script:DuneChatTeleportCaptureFile) { return $script:DuneChatTeleportCaptureFile }
    return (Join-Path (Split-Path -Parent (Get-DuneChatTeleportsPath)) 'teleport-capture.json')
}

function Invoke-DuneChatTeleportFileLock {
    param([Parameter(Mandatory)][scriptblock]$Script, [int]$TimeoutSeconds = 10)
    $mutex = [Threading.Mutex]::new($false, 'Local\DuneServerTool.ChatTeleportBookmarks')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne($TimeoutSeconds * 1000) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Teleport bookmarks are busy. Try again.' }
        return (& $Script)
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function ConvertTo-DuneChatTeleportName {
    param([string]$Name)
    $value = ([string]$Name).Trim() -replace '\s+', ' '
    if (-not $value -or $value.Length -gt $script:DuneChatTeleportNameMax) { return '' }
    if ($value -notmatch "^[A-Za-z0-9][A-Za-z0-9 _'-]*$") { return '' }
    if ($value -ieq 'chat-teleport-bookmarks' -or
        $value -match '^(?i:(?:list|save))(?:\s|$)') { return '' }
    return $value
}

function Get-DuneChatTeleportKey {
    param([string]$Name)
    $value = ConvertTo-DuneChatTeleportName -Name $Name
    if (-not $value) { return '' }
    return $value.ToLowerInvariant()
}

function Read-DuneChatTeleports {
    $path = Get-DuneChatTeleportsPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not read teleport bookmarks: $($_.Exception.Message)"
    }

    $items = @()
    $keys = @{}
    $reservedKeys = @{}
    foreach ($entry in @($parsed)) {
        $rawName = ([string]$entry.name).Trim()
        if ($rawName -ieq 'chat-teleport-bookmarks' -or
            $rawName -match '^(?i:(?:list|save))(?:\s|$)') { continue }
        $reservedName = ConvertTo-DuneChatTeleportName -Name $rawName
        if (-not $reservedName) { throw 'Teleport bookmarks contain an invalid or reserved name.' }
        $reservedKey = $reservedName.ToLowerInvariant()
        if ($reservedKeys.ContainsKey($reservedKey)) {
            throw "Teleport bookmarks contain duplicate name '$reservedName'."
        }
        $reservedKeys[$reservedKey] = $true
    }
    foreach ($entry in @($parsed)) {
        # Preview 4's first field build accidentally saved the named-lock value
        # instead of the requested bookmark name. Ignore that exact internal
        # sentinel so the next real save replaces the broken one cleanly.
        if ([string]$entry.name -ieq 'chat-teleport-bookmarks') { continue }
        $rawName = ([string]$entry.name).Trim()
        $legacyCommandName = $rawName -match '^(?i:(?:list|save))(?:\s|$)'
        if ($legacyCommandName) {
            $base = "legacy-$rawName"
            if ($base.Length -gt $script:DuneChatTeleportNameMax) {
                $base = $base.Substring(0, $script:DuneChatTeleportNameMax).Trim()
            }
            $name = ConvertTo-DuneChatTeleportName -Name $base
            $suffix = 2
            while ($name -and (
                    $reservedKeys.ContainsKey($name.ToLowerInvariant()) -or
                    $keys.ContainsKey($name.ToLowerInvariant()))) {
                $tail = "-$suffix"
                $stemLength = $script:DuneChatTeleportNameMax - $tail.Length
                $name = ConvertTo-DuneChatTeleportName -Name ($base.Substring(0, [math]::Min($base.Length, $stemLength)).Trim() + $tail)
                $suffix++
            }
        } else {
            $name = ConvertTo-DuneChatTeleportName -Name $rawName
        }
        if (-not $name) { throw 'Teleport bookmarks contain an invalid or reserved name.' }
        $key = $name.ToLowerInvariant()
        if ($keys.ContainsKey($key)) { throw "Teleport bookmarks contain duplicate name '$name'." }

        $partition = 0L
        $dimension = 0
        if (-not [int64]::TryParse([string]$entry.partition, [ref]$partition) -or $partition -le 0) {
            throw "Teleport bookmark '$name' has an invalid partition."
        }
        if (-not [int]::TryParse([string]$entry.dimension, [ref]$dimension)) {
            throw "Teleport bookmark '$name' has an invalid dimension."
        }

        try {
            $x = [Convert]::ToDouble($entry.x, [cultureinfo]::InvariantCulture)
            $y = [Convert]::ToDouble($entry.y, [cultureinfo]::InvariantCulture)
            $z = [Convert]::ToDouble($entry.z, [cultureinfo]::InvariantCulture)
        } catch {
            throw "Teleport bookmark '$name' has invalid coordinates."
        }
        if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or
            [double]::IsNaN($y) -or [double]::IsInfinity($y) -or
            [double]::IsNaN($z) -or [double]::IsInfinity($z)) {
            throw "Teleport bookmark '$name' has non-finite coordinates."
        }

        $map = ([string]$entry.map).Trim()
        if (-not $map) { throw "Teleport bookmark '$name' has no map." }
        $keys[$key] = $true
        $items += [ordered]@{
            name = $name
            key = $key
            map = $map
            partition = $partition
            dimension = $dimension
            x = $x
            y = $y
            z = $z
            capturedFrom = [string]$entry.capturedFrom
            capturedAt = [string]$entry.capturedAt
        }
    }
    if ($items.Count -gt $script:DuneChatTeleportMax) {
        throw "Teleport bookmarks exceed the limit of $($script:DuneChatTeleportMax)."
    }
    return @($items)
}

function Save-DuneChatTeleports {
    param([object[]]$Bookmarks)
    $path = Get-DuneChatTeleportsPath
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject @($Bookmarks) -Depth 6
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $path -Force
        return $true
    } catch {
        throw "Could not save teleport bookmarks: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Read-DuneChatTeleportCapture {
    param([switch]$IncludeConsumed)
    $path = Get-DuneChatTeleportCapturePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $entry = Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not read pending teleport capture: $($_.Exception.Message)"
    }
    $expires = [datetime]::MinValue
    if (-not [datetime]::TryParse(
            [string]$entry.expiresAt, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$expires)) {
        throw 'Pending teleport capture has an invalid expiry.'
    }
    if ($expires.ToUniversalTime() -le [datetime]::UtcNow) { return $null }
    $consumedAt = [string]$entry.consumedAt
    if ($consumedAt -and -not $IncludeConsumed) { return $null }
    return [ordered]@{
        name = [string]$entry.name
        key = [string]$entry.key
        pawnId = [int64]$entry.pawnId
        funcomId = [string]$entry.funcomId
        playerName = [string]$entry.playerName
        token = [string]$entry.token
        map = [string]$entry.map
        partition = [int64]$entry.partition
        dimension = [int]$entry.dimension
        armedAt = [string]$entry.armedAt
        expiresAt = [string]$entry.expiresAt
        consumedAt = $consumedAt
    }
}

function Save-DuneChatTeleportCapture {
    param([System.Collections.IDictionary]$Capture)
    $path = Get-DuneChatTeleportCapturePath
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = ConvertTo-Json -InputObject $Capture -Depth 4
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $path -Force
    } catch {
        throw "Could not save pending teleport capture: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Remove-DuneChatTeleportCapture {
    $path = Get-DuneChatTeleportCapturePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $path) {
        throw 'Pending teleport capture could not be removed.'
    }
}

function Cancel-DuneChatTeleportCapture {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return @{ ok = $false; status = 400; error = 'Capture token is required.' }
    }
    $pending = Read-DuneChatTeleportCapture -IncludeConsumed
    if (-not $pending) {
        return @{ ok = $false; status = 404; error = 'No pending teleport capture exists.' }
    }
    if ([string]$pending.token -ine $Token.Trim()) {
        return @{ ok = $false; status = 409; error = 'A newer teleport capture replaced the one shown. Refresh DST before cancelling.' }
    }
    Remove-DuneChatTeleportCapture
    return @{ ok = $true }
}

function Set-DuneChatTeleportBookmark {
    param([hashtable]$Bookmark)
    $current = @(Read-DuneChatTeleports)
    $next = @()
    $replaced = $false
    foreach ($item in $current) {
        if ([string]$item.key -eq [string]$Bookmark.key) {
            $next += $Bookmark
            $replaced = $true
        } else {
            $next += $item
        }
    }
    if (-not $replaced) {
        if ($next.Count -ge $script:DuneChatTeleportMax) {
            return @{ ok = $false; status = 409; error = "Teleport bookmark limit reached ($($script:DuneChatTeleportMax))." }
        }
        $next += $Bookmark
    }
    [void](Save-DuneChatTeleports -Bookmarks $next)
    return @{ ok = $true; bookmark = $Bookmark; replaced = $replaced; teleports = @($next) }
}

function Save-DuneChatTeleportFromPawn {
    param([string]$Ip, [string]$Name, [long]$PawnId)
    $nameValue = ConvertTo-DuneChatTeleportName -Name $Name
    if (-not $nameValue) {
        return @{ ok = $false; status = 400; error = "Name must be 1-$($script:DuneChatTeleportNameMax) characters, use letters/numbers/spaces/_/-/', and cannot start with 'list' or 'save'." }
    }
    if ($PawnId -le 0) { return @{ ok = $false; status = 400; error = 'pawn_id is required.' } }

    $sql = @"
SELECT COALESCE(ps.character_name, '') AS player_name,
       COALESCE(ps.online_status::text, 'Offline') AS status,
       COALESCE(a.map, '') AS map,
       COALESCE(a.partition_id, 0)::text AS partition,
       COALESCE(a.dimension_index, 0)::text AS dimension,
       (a.transform).location.x AS x,
       (a.transform).location.y AS y,
       (a.transform).location.z AS z
FROM dune.player_state ps
JOIN dune.actors a ON a.id = ps.player_pawn_id
WHERE ps.player_pawn_id = $PawnId::bigint
LIMIT 1;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $res.ok) { return @{ ok = $false; status = 500; error = "capture player location: $($res.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $res
    if ($rows.Count -eq 0) { return @{ ok = $false; status = 404; error = "Player pawn $PawnId was not found." } }
    $row = $rows[0]
    if ([string]$row['status'] -match '^(?i:offline)$') {
        return @{ ok = $false; status = 409; error = 'The selected player must be online and standing at the destination.' }
    }

    $map = ([string]$row['map']).Trim()
    $partition = [int64](ConvertTo-DuneInt $row['partition'])
    $dimension = [int](ConvertTo-DuneInt $row['dimension'])
    if (-not $map -or $partition -le 0) {
        return @{ ok = $false; status = 409; error = 'The selected player has no current map/partition to capture.' }
    }
    if ($null -eq $row['x'] -or $null -eq $row['y'] -or $null -eq $row['z']) {
        return @{ ok = $false; status = 409; error = 'The selected player has no current coordinates to capture.' }
    }
    try {
        $x = [Convert]::ToDouble($row['x'], [cultureinfo]::InvariantCulture)
        $y = [Convert]::ToDouble($row['y'], [cultureinfo]::InvariantCulture)
        $z = [Convert]::ToDouble($row['z'], [cultureinfo]::InvariantCulture)
    } catch {
        return @{ ok = $false; status = 409; error = 'The selected player has no current coordinates to capture.' }
    }
    if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or
        [double]::IsNaN($y) -or [double]::IsInfinity($y) -or
        [double]::IsNaN($z) -or [double]::IsInfinity($z)) {
        return @{ ok = $false; status = 409; error = 'The selected player has invalid coordinates to capture.' }
    }
    $bookmark = [ordered]@{
        name = $nameValue
        key = $nameValue.ToLowerInvariant()
        map = $map
        partition = $partition
        dimension = $dimension
        x = $x
        y = $y
        z = $z
        capturedFrom = [string]$row['player_name']
        capturedAt = ([datetime]::UtcNow).ToString('o')
    }
    return Set-DuneChatTeleportBookmark -Bookmark $bookmark
}

function Set-DuneChatTeleportCaptureForPawn {
    param([string]$Ip, [string]$Name, [long]$PawnId)
    $nameValue = ConvertTo-DuneChatTeleportName -Name $Name
    if (-not $nameValue) {
        return @{ ok = $false; status = 400; error = "Name must be 1-$($script:DuneChatTeleportNameMax) characters, use letters/numbers/spaces/_/-/', and cannot start with 'list' or 'save'." }
    }
    if ($PawnId -le 0) { return @{ ok = $false; status = 400; error = 'pawn_id is required.' } }

    $sql = @"
SELECT COALESCE(ps.character_name, '') AS player_name,
       COALESCE(ps.online_status::text, 'Offline') AS status,
       COALESCE(account.funcom_id, '') AS funcom_id,
       COALESCE(a.map, '') AS map,
       COALESCE(a.partition_id, 0)::text AS partition,
       COALESCE(a.dimension_index, 0)::text AS dimension
FROM dune.player_state ps
JOIN dune.actors a ON a.id = ps.player_pawn_id
JOIN dune.accounts account ON account.id = ps.account_id
WHERE ps.player_pawn_id = $PawnId::bigint
LIMIT 1;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $res.ok) { return @{ ok = $false; status = 500; error = "capture player location: $($res.error)" } }
    $rows = ConvertTo-DuneRowMaps -Result $res
    if ($rows.Count -eq 0) { return @{ ok = $false; status = 404; error = "Player pawn $PawnId was not found." } }
    $row = $rows[0]
    $status = [string]$row['status']
    if ($status -match '^(?i:offline)$') {
        return @{ ok = $false; status = 409; error = 'The selected player must be online and standing at the destination.' }
    }

    $funcomId = ([string]$row['funcom_id']).Trim()
    if (-not $funcomId) {
        return @{ ok = $false; status = 409; error = 'The selected player has no chat identity to arm.' }
    }
    $map = ([string]$row['map']).Trim()
    $partition = [int64](ConvertTo-DuneInt $row['partition'])
    $dimension = [int](ConvertTo-DuneInt $row['dimension'])
    if (-not $map -or $partition -le 0) {
        return @{ ok = $false; status = 409; error = 'The selected player current map/partition is unavailable.' }
    }
    $now = [datetime]::UtcNow
    $token = [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant()
    $capture = [ordered]@{
        name = $nameValue
        key = $nameValue.ToLowerInvariant()
        pawnId = $PawnId
        funcomId = $funcomId
        playerName = [string]$row['player_name']
        token = $token
        map = $map
        partition = $partition
        dimension = $dimension
        armedAt = $now.ToString('o')
        expiresAt = $now.AddSeconds($script:DuneChatTeleportCaptureTtlSeconds).ToString('o')
    }
    Save-DuneChatTeleportCapture -Capture $capture
    return @{ ok = $true; pending = $capture }
}

function Complete-DuneChatTeleportCapture {
    param([string]$Ip, [string]$FuncomId, [string]$Token, [hashtable]$Location)
    $pending = Read-DuneChatTeleportCapture -IncludeConsumed
    if (-not $pending) {
        return @{ ok = $false; status = 404; error = 'No admin-armed teleport capture is waiting. Arm one in DST first.' }
    }
    if ($pending.consumedAt) {
        return @{ ok = $false; status = 409; error = 'That capture code was already consumed. Arm a new capture in DST.' }
    }
    if ([string]$pending.funcomId -ine [string]$FuncomId) {
        return @{ ok = $false; status = 403; error = "The pending capture is waiting for $($pending.playerName), not this player." }
    }
    if (-not $Token -or [string]$pending.token -ine $Token.Trim()) {
        return @{ ok = $false; status = 403; error = "Use the exact capture command shown in DST: !tp save $($pending.token)" }
    }
    if (-not $Location) {
        return @{ ok = $false; status = 409; error = 'The game chat message did not include a live location.' }
    }
    if (-not $Location.ContainsKey('x') -or -not $Location.ContainsKey('y') -or
        -not $Location.ContainsKey('z') -or
        $null -eq $Location.x -or $null -eq $Location.y -or $null -eq $Location.z) {
        return @{ ok = $false; status = 409; error = 'The game chat message did not include complete live coordinates.' }
    }
    try {
        $x = [Convert]::ToDouble($Location.x, [cultureinfo]::InvariantCulture)
        $y = [Convert]::ToDouble($Location.y, [cultureinfo]::InvariantCulture)
        $z = [Convert]::ToDouble($Location.z, [cultureinfo]::InvariantCulture)
    } catch {
        return @{ ok = $false; status = 409; error = 'The game chat message contained invalid live coordinates.' }
    }
    if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or
        [double]::IsNaN($y) -or [double]::IsInfinity($y) -or
        [double]::IsNaN($z) -or [double]::IsInfinity($z)) {
        return @{ ok = $false; status = 409; error = 'The game chat message contained non-finite live coordinates.' }
    }
    $current = Get-DuneChatPlayerLocation -Ip $Ip -FuncomId $FuncomId
    if (-not $current.ok -or [string]$current.status -match '^(?i:offline)$') {
        return @{ ok = $false; status = 409; error = 'Could not resolve the player current map for capture.' }
    }
    if (-not $current.map -or [int64]$current.partition -le 0) {
        return @{ ok = $false; status = 409; error = 'The player current map/partition is unavailable.' }
    }
    if ([string]$current.map -ine [string]$pending.map -or
        [int64]$current.partition -ne [int64]$pending.partition -or
        [int]$current.dimension -ne [int]$pending.dimension) {
        return @{ ok = $false; status = 409; error = 'The player changed map, partition, or dimension after capture was armed. Arm it again at the destination.' }
    }

    $bookmark = [ordered]@{
        name = [string]$pending.name
        key = [string]$pending.key
        map = [string]$pending.map
        partition = [int64]$pending.partition
        dimension = [int]$pending.dimension
        x = $x
        y = $y
        z = $z
        capturedFrom = [string]$pending.playerName
        capturedAt = ([datetime]::UtcNow).ToString('o')
    }
    $pending.consumedAt = ([datetime]::UtcNow).ToString('o')
    Save-DuneChatTeleportCapture -Capture $pending
    $result = Set-DuneChatTeleportBookmark -Bookmark $bookmark
    if ($result.ok) {
        try { Remove-DuneChatTeleportCapture }
        catch { $result['cleanupWarning'] = $_.Exception.Message }
    }
    return $result
}

function Remove-DuneChatTeleport {
    param([string]$Name)
    $key = Get-DuneChatTeleportKey -Name $Name
    if (-not $key) { return @{ ok = $false; status = 400; error = 'A valid bookmark name is required.' } }
    $current = @(Read-DuneChatTeleports)
    $next = @($current | Where-Object { [string]$_.key -ne $key })
    if ($next.Count -eq $current.Count) {
        return @{ ok = $false; status = 404; error = "Teleport bookmark '$Name' was not found." }
    }
    [void](Save-DuneChatTeleports -Bookmarks $next)
    return @{ ok = $true; removed = $Name; teleports = @($next) }
}

# Default config. Every command is OFF until the admin turns it on.
function New-DuneChatCommandsDefault {
    return @{
        enabled  = $false
        # Replies go out through DST's existing broadcast feature, which carries
        # no sender identity - so there is nothing to impersonate and no account
        # to pick. What the admin DOES control is the heading players see, which
        # is the meaningful equivalent. ("SERVER" is what the game renders it as.)
        replyTitle = 'Server'
        commands = @{
            kit     = @{ enabled = $false; cooldownSeconds = 604800 }
            item    = @{ enabled = $false; cooldownSeconds = 3600; maxQty = 1000 }
            water   = @{ enabled = $false; cooldownSeconds = 300 }
            tp      = @{ enabled = $false; cooldownSeconds = 60 }
            vehicle = @{ enabled = $false; cooldownSeconds = 604800 }
            small   = @{ enabled = $false; cooldownSeconds = 900 }
            medium  = @{ enabled = $false; cooldownSeconds = 900 }
            large   = @{ enabled = $false; cooldownSeconds = 900 }
        }
        # channels the handler will listen on; anything else is ignored outright
        channels = @('Proximity', 'Map')
        # How often DST drains the queue, in seconds. This is a genuine trade the
        # admin should own rather than one baked in: the cost is paid per CALL,
        # not per message, because `rabbitmqctl eval` starts a hidden Erlang node
        # each time (~1.5 core-seconds, measured 2026-08-04 on an 8-core VM). So
        # roughly 3s ~ 0.50 of a core sustained, 10s ~ 0.15, 30s ~ 0.05 - against
        # a reply that lands in about that many seconds. Defaults to responsive.
        pollSeconds = 3
        cooldowns = @{}
        lastError = ''
        lastSeenAt = ''
    }
}

# Kept as the single place that decides whether the feature may run, so adding a
# future prerequisite does not mean hunting call sites. Broadcast replies need
# no account, so today the only gate is the master switch plus at least one
# enabled command - a feature that can never respond to anything is a
# misconfiguration worth surfacing rather than silently doing nothing.
function Test-DuneChatCommandsReady {
    param([hashtable]$State)
    if (-not $State) { return @{ ready = $false; reason = 'no-state' } }
    $anyOn = $false
    foreach ($k in @($State.commands.Keys)) {
        if ($State.commands[$k].enabled) { $anyOn = $true; break }
    }
    if (-not $anyOn) {
        return @{ ready = $false; reason = 'no-commands-enabled'
                  message = 'Turn on at least one command, or the listener has nothing to respond to.' }
    }
    return @{ ready = $true }
}

function Read-DuneChatCommandsState {
    $path = Get-DuneChatCommandsStatePath
    $def = New-DuneChatCommandsDefault
    if (-not (Test-Path -LiteralPath $path)) { return $def }
    try {
        $obj = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
        $out = $def
        if ($null -ne $obj.enabled) { $out.enabled = [bool]$obj.enabled }
        if ($obj.channels)   { $out.channels = @($obj.channels) }
        if ($obj.lastError)  { $out.lastError = [string]$obj.lastError }
        if ($obj.lastSeenAt) { $out.lastSeenAt = [string]$obj.lastSeenAt }
        if ($null -ne $obj.pollSeconds) {
            $p = 0
            if ([int]::TryParse("$($obj.pollSeconds)", [ref]$p)) { $out.pollSeconds = $p }
        }
        if ($obj.commands) {
            foreach ($p in $obj.commands.PSObject.Properties) {
                $name = "$($p.Name)".ToLowerInvariant()
                if (-not $out.commands.ContainsKey($name)) { $out.commands[$name] = @{} }
                foreach ($cp in $p.Value.PSObject.Properties) {
                    $out.commands[$name][$cp.Name] = $cp.Value
                }
            }
        }
        if ($obj.cooldowns) {
            $cd = @{}
            foreach ($p in $obj.cooldowns.PSObject.Properties) { $cd[$p.Name] = [string]$p.Value }
            $out.cooldowns = $cd
        }
        return $out
    } catch {
        return $def
    }
}

# Allowed poll intervals, and the measured cost of each. Kept as a list rather
# than a free number so the UI and the scheduler agree on what is offerable, and
# so nobody sets 1s without seeing what it costs.
#
# Cost is per CALL, not per message: `rabbitmqctl eval` starts a hidden Erlang
# node every time (~1.5 core-seconds, measured 2026-08-04 on an 8-core VM). So
# the sustained cost is roughly 1.5 / interval cores, for as long as the feature
# is enabled, whether or not anyone is chatting.
$script:DuneChatPollChoices = @(1, 3, 5, 10, 15, 30)
$script:DuneChatPollDefault = 3

# What the scheduler actually sleeps between drains. Clamped here rather than
# trusted from the state file, because this value directly sets a permanent load
# on someone's game server.
function Get-DuneChatCommandPollSeconds {
    param([hashtable]$State)
    $n = $script:DuneChatPollDefault
    try {
        if (-not $State) { $State = Read-DuneChatCommandsState }
        if ($State -and $State.pollSeconds) { $n = [int]$State.pollSeconds }
    } catch { $n = $script:DuneChatPollDefault }
    if ($n -lt 1)  { $n = 1 }
    if ($n -gt 60) { $n = 60 }
    return $n
}

function Save-DuneChatCommandsState {    param([hashtable]$State)
    $path = Get-DuneChatCommandsStatePath
    try {
        ($State | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Pure parsing. Kept free of SSH/RMQ so it is directly unit-testable, and
# because this is the part that has to survive Funcom changing their payload.
# -----------------------------------------------------------------------------

# Pull the courier envelope out of whatever wrapper it arrived in and normalise
# it. Returns $null when the text is not a chat message we understand - callers
# must treat that as "ignore", never as an error.
function ConvertFrom-DuneChatMessage {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # The envelope is {"content":"<escaped json>","Type":"TextChat"}. It may be
    # embedded in a larger Erlang term dump, so locate it rather than assuming
    # the whole string is JSON.
    $m = [regex]::Match($Text, '\{"content":"(?:[^"\\]|\\.)*","Type":"[^"]*"\}')
    if (-not $m.Success) {
        $m = [regex]::Match($Text, '\{"content":.*?,"Type":"[^"]*"\}')
        if (-not $m.Success) { return $null }
    }
    try { $outer = $m.Value | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if (-not $outer.content) { return $null }
    try { $inner = $outer.content | ConvertFrom-Json -ErrorAction Stop } catch { return $null }

    $body = ''
    if ($inner.m_Message -and $inner.m_Message.m_UnlocalizedMessage) {
        $body = [string]$inner.m_Message.m_UnlocalizedMessage
    }
    # Funcom sends the channel bare ("Proximity") from the intercept exchange but
    # enum-qualified ("ETextChatChannelType::Whispers") elsewhere. Normalise.
    $channel = [string]$inner.m_ChannelType
    if ($channel -match '::') { $channel = ($channel -split '::')[-1] }

    return @{
        type      = [string]$outer.Type
        channel   = $channel
        fromId    = [string]$inner.m_FuncomIdFrom
        toId      = [string]$inner.m_UserNameTo
        text      = $body
        timestamp = [string]$inner.m_Timestamp
        location  = if ($inner.m_OriginLocation) {
            # Preserve raw values here. Capture completion owns validation so a
            # missing/malformed field cannot become 0 or throw out of the parser.
            @{ x = $inner.m_OriginLocation.X; y = $inner.m_OriginLocation.Y; z = $inner.m_OriginLocation.Z }
        } else { $null }
    }
}

# "!large" / "  !KIT extra bits " -> @{ verb='large'; args=@() }
# Returns $null for anything that is not a bang command, which is the common
# case - the queue carries ALL chat, so most messages are ordinary conversation
# and must be ignored silently.
function Get-DuneChatCommand {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if (-not $t.StartsWith('!')) { return $null }
    $t = $t.Substring(1)
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    $parts = @($t -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { return $null }
    $verb = $parts[0].ToLowerInvariant()
    # Guard against a pathological "!" spam string becoming a giant verb.
    if ($verb.Length -gt 32) { return $null }
    return @{
        verb = $verb
        args = @(if ($parts.Count -gt 1) { $parts[1..($parts.Count - 1)] } else { @() })
    }
}

# Cooldown bookkeeping is keyed per player AND per command so a shared cooldown
# never leaks between commands.
function Get-DuneChatCooldownKey {
    param([string]$FromId, [string]$Verb)
    return ('{0}|{1}' -f "$FromId".ToLowerInvariant(), "$Verb".ToLowerInvariant())
}

# Returns @{ allowed=bool; remainingSeconds=int }. An unparseable stored stamp
# is treated as "no cooldown recorded" rather than blocking the player forever.
function Test-DuneChatCooldown {
    param(
        [hashtable]$Cooldowns,
        [string]$Key,
        [int]$CooldownSeconds,
        [datetime]$Now = [datetime]::UtcNow
    )
    if ($CooldownSeconds -le 0) { return @{ allowed = $true; remainingSeconds = 0 } }
    if (-not $Cooldowns -or -not $Cooldowns.ContainsKey($Key)) {
        return @{ allowed = $true; remainingSeconds = 0 }
    }
    $last = [datetime]::MinValue
    if (-not [datetime]::TryParse(
            [string]$Cooldowns[$Key], [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$last)) {
        return @{ allowed = $true; remainingSeconds = 0 }
    }
    $elapsed = ($Now - $last.ToUniversalTime()).TotalSeconds
    if ($elapsed -ge $CooldownSeconds) { return @{ allowed = $true; remainingSeconds = 0 } }
    return @{ allowed = $false; remainingSeconds = [int][math]::Ceiling($CooldownSeconds - $elapsed) }
}

function Format-DuneChatCooldownRemaining {
    param([int]$Seconds)
    if ($Seconds -le 0) { return 'now' }
    if ($Seconds -lt 60) { return "{0}s" -f $Seconds }
    if ($Seconds -lt 3600) { return "{0}m" -f [int][math]::Ceiling($Seconds / 60) }
    if ($Seconds -lt 86400) { return "{0}h" -f [int][math]::Ceiling($Seconds / 3600) }
    return "{0}d" -f [int][math]::Ceiling($Seconds / 86400)
}

# Decide what to do with one parsed chat message, WITHOUT performing it. Pure, so
# the whole gate chain (enabled -> channel -> is-a-command -> known -> per-command
# enabled -> cooldown) is testable without a server.
function Resolve-DuneChatCommandAction {
    param(
        [hashtable]$Message,
        [hashtable]$State,
        [datetime]$Now = [datetime]::UtcNow
    )
    if (-not $Message) { return @{ action = 'ignore'; reason = 'unparsed' } }
    if (-not $State.enabled) { return @{ action = 'ignore'; reason = 'disabled' } }
    # Belt and braces: even if something flips `enabled` without going through
    # the route's validation, a missing reply account stops the feature dead
    # rather than running commands nobody can be told about.
    $ready = Test-DuneChatCommandsReady -State $State
    if (-not $ready.ready) { return @{ action = 'ignore'; reason = $ready.reason } }
    if ("$($Message.type)" -ne 'TextChat') { return @{ action = 'ignore'; reason = 'not-text-chat' } }

    $channels = @($State.channels)
    if ($channels.Count -gt 0 -and ($channels -notcontains "$($Message.channel)")) {
        return @{ action = 'ignore'; reason = 'channel-not-listened' }
    }

    $cmd = Get-DuneChatCommand -Text $Message.text
    if (-not $cmd) { return @{ action = 'ignore'; reason = 'not-a-command' } }

    if (-not $State.commands.ContainsKey($cmd.verb)) {
        return @{ action = 'ignore'; reason = 'unknown-command'; verb = $cmd.verb }
    }
    $cfg = $State.commands[$cmd.verb]
    if (-not $cfg.enabled) {
        return @{ action = 'ignore'; reason = 'command-disabled'; verb = $cmd.verb }
    }

    $key = Get-DuneChatCooldownKey -FromId $Message.fromId -Verb $cmd.verb
    $tpAction = if (@($cmd.args).Count -gt 0) { [string]$cmd.args[0] } else { '' }
    $isListAction = ($tpAction -eq 'list' -and @($cmd.args).Count -eq 1)
    if ($cmd.verb -eq 'tp' -and ($isListAction -or $tpAction -eq 'save')) {
        return @{ action = 'run'; verb = $cmd.verb; args = @($cmd.args); key = $key; from = $Message.fromId }
    }
    $cool = Test-DuneChatCooldown -Cooldowns $State.cooldowns -Key $key `
        -CooldownSeconds ([int]$cfg.cooldownSeconds) -Now $Now
    if (-not $cool.allowed) {
        return @{
            action = 'cooldown'; verb = $cmd.verb; key = $key
            remainingSeconds = $cool.remainingSeconds
            reply = "{0} is on cooldown - try again in {1}." -f ('!' + $cmd.verb), (Format-DuneChatCooldownRemaining -Seconds $cool.remainingSeconds)
        }
    }

    return @{ action = 'run'; verb = $cmd.verb; args = @($cmd.args); key = $key; from = $Message.fromId }
}

# -----------------------------------------------------------------------------
# Live layer. Everything below talks to the broker through DST's existing
# `rabbitmqctl eval` path (Broadcast.ps1 / _Invoke-V6BroadcastErl) - no AMQP
# client, no new dependency, no persistent connection.
# -----------------------------------------------------------------------------

# Declare our queue and bind it to chat.intercept. Idempotent: rabbit's declare
# is a no-op when the queue already exists with identical arguments, and
# rabbit_binding:add on an existing binding likewise. Safe to call every tick.
#
# The queue is BOUNDED by construction. It receives a copy of ALL chat, so if
# DST stops draining (app closed, tick erroring) an unbounded queue would grow
# until it pressured the broker - which would be DST degrading someone's server.
# x-max-length with drop-head plus a TTL makes that impossible.
function Initialize-DuneChatCommandQueue {
    param([string]$Ip)
    if (-not (Get-Command Find-V6MqGamePod -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; message = 'Broadcast helpers unavailable (Broadcast.ps1 not loaded).' }
    }
    try { $pod = Find-V6MqGamePod -Ip $Ip } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
    $erl = @"
QName = rabbit_misc:r(<<"/">>, queue, <<"$($script:DuneChatQueueName)">>),
Args = [{<<"x-max-length">>, long, $($script:DuneChatQueueMaxLen)},
        {<<"x-message-ttl">>, long, $($script:DuneChatQueueTtlMs)},
        {<<"x-overflow">>, longstr, <<"drop-head">>}],
rabbit_amqqueue:declare(QName, false, false, Args, none, <<"dst">>),
XName = rabbit_misc:r(<<"/">>, exchange, <<"$($script:DuneChatExchange)">>),
rabbit_binding:add({binding, XName, <<"#">>, QName, []}, <<"dst">>).
"@
    $r = _Invoke-V6BroadcastErl -Ip $Ip -Pod $pod -Erl $erl -Action 'chat-queue-declare'
    return @{ ok = [bool]$r.ok; raw = $r.raw }
}

# Remove the queue and its binding. Used when the feature is switched off, so a
# disabled DST is not quietly accumulating a copy of every message players type.
function Remove-DuneChatCommandQueue {
    param([string]$Ip)
    try { $pod = Find-V6MqGamePod -Ip $Ip } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
    $erl = @"
QName = rabbit_misc:r(<<"/">>, queue, <<"$($script:DuneChatQueueName)">>),
case rabbit_amqqueue:lookup(QName) of
  {ok, Q} -> rabbit_amqqueue:delete(Q, false, false, <<"dst">>), io:format("deleted~n");
  _ -> io:format("absent~n")
end.
"@
    $r = _Invoke-V6BroadcastErl -Ip $Ip -Pod $pod -Erl $erl -Action 'chat-queue-delete'
    return @{ ok = [bool]$r.ok; raw = $r.raw }
}

# Drain up to $Max messages, newest-last. Each is returned as the raw envelope
# text; parsing is the caller's job (and is pure/tested).
#
# NoAck=true: this queue is ours alone, and a command we have already read but
# failed to act on should NOT be redelivered forever - at-most-once is the right
# semantic for a chat command.
function Get-DuneChatCommandMessages {
    param([string]$Ip, [int]$Max = 0)
    if ($Max -le 0) { $Max = $script:DuneChatDrainMax }
    try { $pod = Find-V6MqGamePod -Ip $Ip } catch {
        return @{ ok = $false; message = $_.Exception.Message; messages = @() }
    }
    # Body is emitted base64, one per line, so UTF-8 and newlines in player chat
    # survive the trip back through ssh intact.
    $erl = @"
QName = rabbit_misc:r(<<"/">>, queue, <<"$($script:DuneChatQueueName)">>),
case rabbit_amqqueue:lookup(QName) of
  {ok, Q} ->
    F = fun(Loop, N) ->
      case N of
        0 -> ok;
        _ ->
          case rabbit_amqqueue:basic_get(Q, true, 0, <<"dst">>, rabbit_queue_type:init()) of
            {ok, _C, {_QN, _QP, _MI, _RD, Msg}, _S} ->
              Content = mc:protocol_state(Msg),
              Body = iolist_to_binary(lists:reverse(element(6, Content))),
              io:format("MSG:~s~n", [base64:encode(Body)]),
              Loop(Loop, N - 1);
            _ -> ok
          end
      end
    end,
    F(F, $Max);
  _ -> io:format("NOQUEUE~n")
end.
"@
    $r = _Invoke-V6BroadcastErl -Ip $Ip -Pod $pod -Erl $erl -Action 'chat-drain'
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (("$($r.raw)") -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t.StartsWith('MSG:')) { continue }
        $b64 = $t.Substring(4).Trim()
        if (-not $b64) { continue }
        try { $out.Add([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))) } catch {}
    }
    return @{ ok = $true; messages = $out.ToArray(); raw = $r.raw }
}

# The intercept payload identifies the sender by their Funcom display id
# ("Coastal#45066"), but chat.whispers routes on the FLS hex id
# ("F9230538A63A2B3D"). dune.accounts carries both, so this is the bridge that
# makes replying possible at all.
function Resolve-DuneChatFlsId {
    param([string]$Ip, [string]$FuncomId)
    if ([string]::IsNullOrWhiteSpace($FuncomId)) { return @{ ok = $false; message = 'no funcom id' } }
    $safe = $FuncomId -replace "'", "''"
    $sql = "SELECT ""user"" AS fls FROM dune.accounts WHERE funcom_id = '$safe' LIMIT 1;"
    try {
        $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 2 -TimeoutSec 20
        if (-not $res.ok) { return @{ ok = $false; message = [string]$res.error } }
        $rows = @($res.rows)
        if ($rows.Count -lt 1 -or -not $rows[0]) { return @{ ok = $false; message = "no account for $FuncomId" } }
        $fls = [string]$rows[0][0]
        if (-not $fls) { return @{ ok = $false; message = "empty fls id for $FuncomId" } }
        return @{ ok = $true; flsId = $fls }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Resolve-DuneChatCharacterName {
    param([string]$Ip, [string]$FuncomId)
    if ([string]::IsNullOrWhiteSpace($FuncomId)) { return @{ ok = $false; message = 'no funcom id' } }
    $safe = $FuncomId -replace "'", "''"
    $sql = @"
SELECT COALESCE(ps.character_name, '') AS character_name
FROM dune.accounts account
JOIN dune.player_state ps ON ps.account_id = account.id
WHERE account.funcom_id = '$safe'
ORDER BY ps.last_avatar_activity DESC NULLS LAST
LIMIT 1;
"@
    try {
        $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
        if (-not $res.ok) { return @{ ok = $false; message = [string]$res.error } }
        $rows = ConvertTo-DuneRowMaps -Result $res
        if ($rows.Count -eq 0) { return @{ ok = $false; message = "no active character for $FuncomId" } }
        $name = ([string]$rows[0]['character_name']).Trim()
        if (-not $name) { return @{ ok = $false; message = "empty character name for $FuncomId" } }
        return @{ ok = $true; characterName = $name }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

function Get-DuneChatPlayerLocation {
    param([string]$Ip, [string]$FuncomId)
    if ([string]::IsNullOrWhiteSpace($FuncomId)) {
        return @{ ok = $false; message = 'no funcom id' }
    }
    $safe = $FuncomId -replace "'", "''"
    $sql = @"
SELECT COALESCE(ps.online_status::text, 'Offline') AS status,
       COALESCE(actor.map, '') AS map,
       COALESCE(actor.partition_id, 0)::text AS partition,
       COALESCE(actor.dimension_index, 0)::text AS dimension
FROM dune.accounts account
JOIN dune.player_state ps ON ps.account_id = account.id
JOIN dune.actors actor ON actor.id = ps.player_pawn_id
WHERE account.funcom_id = '$safe'
ORDER BY ps.last_avatar_activity DESC NULLS LAST
LIMIT 1;
"@
    $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 1 -TimeoutSec 10
    if (-not $res.ok) { return @{ ok = $false; message = [string]$res.error } }
    $rows = ConvertTo-DuneRowMaps -Result $res
    if ($rows.Count -eq 0) { return @{ ok = $false; message = "no active character for $FuncomId" } }
    return @{
        ok = $true
        status = [string]$rows[0]['status']
        map = [string]$rows[0]['map']
        partition = [int64](ConvertTo-DuneInt $rows[0]['partition'])
        dimension = [int](ConvertTo-DuneInt $rows[0]['dimension'])
    }
}

# Reply to a command using DST's EXISTING broadcast feature rather than a
# bespoke whisper path.
#
# Why broadcast and not whisper:
#   - It already works and is already shipped, so there is one message path in
#     the app instead of two that can drift.
#   - Whispers turned out to route on the FUNCOM DISPLAY ID, not the fls hex id
#     (the per-player queue is NAMED after the fls id but BOUND on funcom_id:
#     `chat.whispers  F9230538A63A2B3D_queue  Coastal#45066`). Publishing to the
#     wrong key is silently dropped by the direct exchange - no error, no
#     message. That is a sharp edge worth not depending on.
#   - For world-affecting commands like !large, everyone seeing the result is
#     arguably correct rather than a compromise.
#
# The trade-off is real and deliberate: this is NOT private. A cooldown notice
# for one player is visible to the whole server.
function Send-DuneChatReply {
    param(
        [string]$Ip,
        [hashtable]$State,
        [string]$ToFuncomId,
        [string]$Message,
        [int]$DurationSec = 12
    )
    if (-not (Get-Command Send-V6GenericBroadcast -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; message = 'Broadcast helper unavailable (Broadcast.ps1 not loaded).' }
    }
    # Name the character so broadcasts match the identity players see in-game.
    # Fall back to the Funcom display id only when the active character cannot
    # be resolved; a reply is still better than silently dropping the result.
    $identity = Resolve-DuneChatCharacterName -Ip $Ip -FuncomId $ToFuncomId
    $who = if ($identity.ok) { [string]$identity.characterName } else { ($ToFuncomId -split '#')[0] }
    $body = if ($who) { "$who - $Message" } else { $Message }
    $title = if ($State -and $State.replyTitle) { [string]$State.replyTitle } else { 'Server' }
    try {
        $r = Send-V6GenericBroadcast -Title $title -Body $body -DurationSec $DurationSec
        return @{ ok = [bool]$r.ok; raw = $r.raw; message = [string]$r.message }
    } catch {
        return @{ ok = $false; message = $_.Exception.Message }
    }
}

# -----------------------------------------------------------------------------
# Command executors
# -----------------------------------------------------------------------------

# !kit [name] — hand over an admin-defined item package.
#
# With no name we ASK rather than guess. A server can have several kits and
# silently picking one (or the first) would hand players the wrong thing.
function Invoke-DuneChatCommandKit {
    param([string]$Ip, [hashtable]$State, [string]$FuncomId, [string[]]$CommandArgs)
    $packages = @(Read-DuneItemPackages)
    if ($packages.Count -eq 0) {
        return @{ ok = $false; reply = 'No kits are configured on this server yet.' }
    }

    $wanted = (@($CommandArgs) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        return @{ ok = $false; reply = 'Which Kit "!kit <kit name>"' }
    }

    $pkg = $packages | Where-Object { "$($_.name)".Trim() -ieq $wanted } | Select-Object -First 1
    if (-not $pkg) {
        $names = (@($packages | ForEach-Object { "$($_.name)" }) -join ', ')
        return @{ ok = $false; reply = "No kit called '$wanted'. Available: $names" }
    }

    $fls = Resolve-DuneChatFlsId -Ip $Ip -FuncomId $FuncomId
    if (-not $fls.ok) { return @{ ok = $false; reply = 'Could not identify your account.' } }

    $given = 0; $failed = 0
    foreach ($item in @($pkg.items)) {
        if (-not $item -or -not $item.template) { continue }
        try {
            $r = Invoke-DuneRmqAddItemToInventory -FlsId $fls.flsId -ItemName ([string]$item.template) `
                    -Quantity ([int]$item.qty)
            if ($r.ok) { $given++ } else { $failed++ }
        } catch { $failed++ }
    }
    if ($given -eq 0) {
        return @{ ok = $false; reply = "Could not deliver '$($pkg.name)' - nothing was added." }
    }
    $reply = "$($pkg.name) delivered."
    if ($failed -gt 0) { $reply += " ($failed item$(if($failed -ne 1){'s'}) could not be added.)" }
    return @{ ok = $true; reply = $reply; given = $given; failed = $failed }
}

# !small / !medium / !large - ask the server to spawn spice fields of that size.
#
# WHICH FUNCTION, AND WHY (learned the hard way 2026-08-04):
#   dune.try_prime_spicefield() looks like the obvious choice and is NOT. On a
#   map with no active fields it moves current_globally_primed 0 -> 2 and back
#   to 0 with current_globally_active never leaving 0 - nothing spawns.
#   dune.request_spawn_spice_field() is the real entry point: it appends to
#   requested_spawned_of_type, which the game server drains into an actual
#   field. Spawning is not instant, so do not report it as such.
#
# ONLY EVER TARGET A RUNNING SERVER. spicefield_server_availability keeps a row
# for every server that ever registered and nothing removes it when a map is
# retired, so a Deep Desert used for testing months ago still looks real. A
# request queued against a dead server is accepted, increments the counter, and
# NEVER drains. Get-DuneActiveMapPartitions already answers "which maps are
# live or pinned", so reuse it rather than inventing a second liveness rule.
function Invoke-DuneChatCommandSpiceField {
    param([string]$Ip, [string]$Size)

    $label = (Get-Culture).TextInfo.ToTitleCase("$Size".ToLowerInvariant())

    # Live server guids, straight from the battlegroup's own status.
    $liveIds = @{}
    $liveMaps = @{}
    try {
        $bg = (Get-V6Battlegroup -Ip $Ip).Bg
        foreach ($s in @($bg.status.servers)) {
            if (-not $s) { continue }
            if ($s.PSObject.Properties['serverGuid'] -and $s.serverGuid) { $liveIds["$($s.serverGuid)"] = $true }
            if ($s.PSObject.Properties['partitionMap'] -and $s.partitionMap) { $liveMaps["$($s.partitionMap)"] = $true }
        }
    } catch {
        return @{ ok = $false; reply = 'Could not reach the server list.' }
    }
    if ($liveIds.Count -eq 0) {
        return @{ ok = $false; reply = 'No game servers are running right now.' }
    }

    $safe = $Size -replace "'", "''"
    # free_slots is the GLOBAL headroom for the type (cap minus active minus
    # everything already queued), repeated on each row so it can be budgeted
    # once. Budgeting per row would queue servers x headroom and overshoot -
    # request_spawn_spice_field checks the cap at REQUEST time, not spawn time.
    $sql = @"
SELECT a.server_id, t.spicefield_type_id, t.map_name, a.inactive_fields_of_type,
       GREATEST(t.max_globally_active - t.current_globally_active
                - COALESCE((SELECT SUM(q.requested_spawned_of_type)
                            FROM dune.spicefield_server_availability q
                            WHERE q.spicefield_type_id = t.spicefield_type_id), 0), 0)
FROM dune.spicefield_types t
JOIN dune.spicefield_server_availability a USING (spicefield_type_id)
WHERE lower(t.field_type) = lower('$safe') AND t.is_spawning_active IS TRUE
ORDER BY t.spicefield_type_id, a.server_id;
"@
    try {
        $res = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 100 -TimeoutSec 25
        if (-not $res.ok) { return @{ ok = $false; reply = 'Could not read spice field settings.' } }
    } catch {
        return @{ ok = $false; reply = 'Could not read spice field settings.' }
    }

    $rows = @($res.rows)
    if ($rows.Count -eq 0) {
        return @{ ok = $false; reply = "No $label spice fields are configured on this server." }
    }

    # Drop rows belonging to servers that are not running, then say plainly when
    # that leaves nothing - "the map is down" is a different answer from "the
    # cap is full", and players should be told which.
    $usable = @($rows | Where-Object { $liveIds.ContainsKey("$($_[0])") })
    if ($usable.Count -eq 0) {
        $mapName = "$(@($rows)[0][2])"
        $mapLabel = if ($mapName -eq 'DeepDesert') { 'Deep Desert' } elseif ($mapName -eq 'HaggaBasin') { 'Hagga Basin' } else { $mapName }
        return @{ ok = $false; reply = "The $mapLabel is not running, so no $label fields can be activated." }
    }

    $budget = @{}
    foreach ($r in $usable) {
        $t = [int]$r[1]
        if (-not $budget.ContainsKey($t)) { try { $budget[$t] = [int]$r[4] } catch { $budget[$t] = 0 } }
    }

    $requested = 0
    foreach ($r in $usable) {
        $server = [string]$r[0]
        $t = [int]$r[1]
        $pool = 0; try { $pool = [int]$r[3] } catch { $pool = 0 }
        if ($pool -le 0 -or $budget[$t] -le 0) { continue }
        $take = [math]::Min($pool, $budget[$t])
        if ($take -gt 20) { $take = 20 }   # hard ceiling against a malformed row
        $safeServer = $server -replace "'", "''"
        for ($i = 0; $i -lt $take; $i++) {
            try {
                $r2 = Invoke-DuneSqlQuery -Ip $Ip -ReadOnly $false -MaxRows 2 -TimeoutSec 20 `
                        -Sql "SELECT dune.request_spawn_spice_field('$safeServer', $t);"
                if (-not $r2.ok) { break }
                $requested++
                $budget[$t] = $budget[$t] - 1
                if ($budget[$t] -le 0) { break }
            } catch { break }
        }
    }

    if ($requested -eq 0) {
        return @{ ok = $false; reply = "$label Spice Fields are already at their limit." }
    }
    return @{ ok = $true; reply = "$label Spice Fields Activated"; requested = $requested }
}

# Dispatch table.
# !water - refill the sender's water containers (stillsuits, jons, canteens).
#
# Reuses the exact RMQ command behind the Player Admin "Fill Water" button
# (UpdateAllWaterFillables) rather than the SQL refill, because the sender is by
# definition online: an online player holds their inventory in memory, so a
# direct SQL write is ignored and overwritten on their next save. Same reasoning
# as the give-item path in PlayersWrites.ps1.
function Invoke-DuneChatCommandWater {
    param([string]$Ip, [string]$FuncomId)
    $fls = Resolve-DuneChatFlsId -Ip $Ip -FuncomId $FuncomId
    if (-not $fls.ok) { return @{ ok = $false; reply = 'Could not identify your account.' } }
    try {
        $r = Invoke-DuneRmqUpdateAllWaterFillables -FlsId $fls.flsId -WaterAmount 1000000
        if (-not $r.ok) {
            return @{ ok = $false; reply = 'Could not refill your water.' }
        }
        return @{ ok = $true; reply = 'Water refilled.' }
    } catch {
        return @{ ok = $false; reply = 'Could not refill your water.' }
    }
}

# !vehicle - deliver a vehicle part kit to the sender.
#
# Mirrors the Players page "Give Vehicle Kit" action exactly: it hands over the
# vehicle's parts plus fuel and a repair tool, into the player's inventory, to be
# assembled at a Vehicle Assembly. It does NOT spawn a drivable vehicle, and the
# reply says so - a player told "vehicle delivered" would go looking for one.
#
# Vehicles with no part kit (Tank, Container Vehicle) are filtered out for the
# same reason the UI filters them: there is nothing to give.
function Invoke-DuneChatCommandVehicle {
    param([string]$Ip, [string]$FuncomId, [string[]]$CommandArgs)
    $catalog = Get-DuneVehicleKitCatalog
    $vehicles = @(@($catalog.vehicles) | Where-Object { @($_.kit).Count -gt 0 })
    if ($vehicles.Count -eq 0) {
        return @{ ok = $false; reply = 'No vehicle kits are available on this server.' }
    }

    $wanted = (@($CommandArgs) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        $names = (@($vehicles | ForEach-Object { "$($_.label)" }) -join ', ')
        return @{ ok = $false; reply = "Which vehicle? Available: $names" }
    }

    # Match on the friendly label first, then the id, so both "!vehicle Ornithopter (Light)"
    # and "!vehicle OrnithopterLight" work.
    $veh = $vehicles | Where-Object { "$($_.label)".Trim() -ieq $wanted } | Select-Object -First 1
    if (-not $veh) {
        $veh = $vehicles | Where-Object { "$($_.id)".Trim() -ieq $wanted } | Select-Object -First 1
    }
    if (-not $veh) {
        $names = (@($vehicles | ForEach-Object { "$($_.label)" }) -join ', ')
        return @{ ok = $false; reply = "No vehicle called '$wanted'. Available: $names" }
    }

    $fls = Resolve-DuneChatFlsId -Ip $Ip -FuncomId $FuncomId
    if (-not $fls.ok) { return @{ ok = $false; reply = 'Could not identify your account.' } }

    $parts = @()
    $parts += @($veh.kit)
    $parts += @($veh.unique)
    if ($catalog.fuelTemplate)  { $parts += $catalog.fuelTemplate }
    if ($catalog.torchTemplate) { $parts += $catalog.torchTemplate }

    $given = 0; $failed = 0
    foreach ($tpl in $parts) {
        if ([string]::IsNullOrWhiteSpace($tpl)) { continue }
        $qty = 1
        if ($veh.qty -and $veh.qty.Contains("$tpl")) { $qty = [int]$veh.qty["$tpl"] }
        if ($qty -lt 1) { $qty = 1 }
        try {
            $r = Invoke-DuneRmqAddItemToInventory -FlsId $fls.flsId -ItemName ([string]$tpl) -Quantity $qty
            if ($r.ok) { $given++ } else { $failed++ }
        } catch { $failed++ }
    }
    if ($given -eq 0) {
        return @{ ok = $false; reply = "Could not deliver the $($veh.label) kit - nothing was added." }
    }
    $reply = "$($veh.label) kit delivered - assemble it at a Vehicle Assembly."
    if ($failed -gt 0) { $reply += " ($failed part$(if($failed -ne 1){'s'}) could not be added.)" }
    return @{ ok = $true; reply = $reply; given = $given; failed = $failed }
}

# !item <name> [qty] - give the sender an item from the catalog.
#
# The broadest of the commands by a distance: every other one is bounded by
# something the admin defined up front (a package, a vehicle kit, their own
# water), whereas this one can produce anything in the game. It is off by
# default like the rest, and additionally capped by maxQty so enabling it cannot
# be turned into "!item <anything> 999999999". Treat raising that cap as the
# same decision as handing out admin.
#
# Name resolution deliberately refuses to guess: an ambiguous term lists the
# candidates back rather than picking one, because silently delivering the wrong
# item is worse than asking again.
function Invoke-DuneChatCommandItem {
    param([string]$Ip, [hashtable]$State, [string]$FuncomId, [string[]]$CommandArgs)
    $argv = @(@($CommandArgs) | Where-Object { "$_".Trim() })
    if ($argv.Count -eq 0) {
        return @{ ok = $false; reply = 'Which item? "!item <name> [amount]"' }
    }

    # A trailing all-digits token is the amount; everything before it is the name,
    # so multi-word items ("Plastanium Ingot 10") work.
    $qty = 1
    if ($argv.Count -gt 1 -and "$($argv[-1])" -match '^\d+$') {
        $qty = [int]$argv[-1]
        $argv = @($argv[0..($argv.Count - 2)])
    }
    $wanted = (@($argv) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($wanted)) {
        return @{ ok = $false; reply = 'Which item? "!item <name> [amount]"' }
    }

    $cfg = $State.commands['item']
    $max = 1000
    if ($cfg -and $cfg.maxQty) { $max = [int]$cfg.maxQty }
    if ($max -lt 1) { $max = 1 }
    if ($qty -lt 1) { $qty = 1 }
    $capped = $false
    if ($qty -gt $max) { $qty = $max; $capped = $true }

    $items = @((Get-DuneItemCatalog).items)
    if ($items.Count -eq 0) {
        return @{ ok = $false; reply = 'The item catalog is not available on this server.' }
    }

    # Exact template id, then exact name, then a unique substring.
    $hit = $items | Where-Object { "$($_.templateId)" -ieq $wanted } | Select-Object -First 1
    if (-not $hit) {
        $hit = $items | Where-Object { "$($_.name)" -ieq $wanted } | Select-Object -First 1
    }
    if (-not $hit) {
        $partial = @($items | Where-Object { "$($_.name)" -imatch [regex]::Escape($wanted) })
        if ($partial.Count -eq 1) {
            $hit = $partial[0]
        } elseif ($partial.Count -gt 1) {
            $names = (@($partial | Select-Object -First 6 | ForEach-Object { "$($_.name)" }) -join ', ')
            $more = if ($partial.Count -gt 6) { " (+$($partial.Count - 6) more)" } else { '' }
            return @{ ok = $false; reply = "'$wanted' matches several items: $names$more" }
        }
    }
    if (-not $hit) {
        return @{ ok = $false; reply = "No item called '$wanted'." }
    }

    $fls = Resolve-DuneChatFlsId -Ip $Ip -FuncomId $FuncomId
    if (-not $fls.ok) { return @{ ok = $false; reply = 'Could not identify your account.' } }

    try {
        $r = Invoke-DuneRmqAddItemToInventory -FlsId $fls.flsId -ItemName ([string]$hit.templateId) -Quantity $qty
        if (-not $r.ok) {
            return @{ ok = $false; reply = "Could not deliver $($hit.name)." }
        }
    } catch {
        return @{ ok = $false; reply = "Could not deliver $($hit.name)." }
    }

    $reply = "$($hit.name) x$qty delivered."
    if ($capped) { $reply += " (capped at $max)" }
    return @{ ok = $true; reply = $reply; template = [string]$hit.templateId; qty = $qty }
}

function Invoke-DuneChatCommandTeleport {
    param([string]$Ip, [string]$FuncomId, [string[]]$CommandArgs, [hashtable]$Message)
    $wanted = (@($CommandArgs) -join ' ').Trim()
    $argv = @($CommandArgs)
    if ($argv.Count -gt 0 -and [string]$argv[0] -ieq 'save') {
        $token = if ($argv.Count -gt 1) { (@($argv[1..($argv.Count - 1)]) -join ' ').Trim() } else { '' }
        try {
            $result = Invoke-DuneChatTeleportFileLock -Script {
                Complete-DuneChatTeleportCapture -Ip $Ip -FuncomId $FuncomId -Token $token -Location $Message.location
            }
        } catch {
            return @{ ok = $false; applyCooldown = $false; reply = 'Could not save the armed teleport destination - check DST.' }
        }
        if (-not $result.ok) {
            return @{ ok = $false; applyCooldown = $false; reply = [string]$result.error }
        }
        return @{ ok = $true; applyCooldown = $false; reply = "Saved $($result.bookmark.name) at your live location." }
    }
    $bookmarks = @()
    try { $bookmarks = @(Read-DuneChatTeleports) } catch {
        return @{ ok = $false; reply = 'Teleport destinations are unavailable - check DST.' }
    }
    if (-not $wanted) {
        return @{ ok = $false; reply = 'Use "!tp list" or "!tp <destination name>".' }
    }
    if ($wanted -ieq 'list') {
        if ($bookmarks.Count -eq 0) {
            return @{ ok = $true; applyCooldown = $false; reply = 'No teleport destinations are saved on the DST instance handling chat.' }
        }
        $names = @($bookmarks | Sort-Object name | ForEach-Object { [string]$_.name })
        return @{
            ok = $true
            applyCooldown = $false
            reply = ('Teleport destinations: ' + ($names -join ', ') + '. Use !tp <name>.')
        }
    }

    $key = Get-DuneChatTeleportKey -Name $wanted
    $bookmark = $null
    if ($key) {
        $bookmark = $bookmarks | Where-Object { [string]$_.key -eq $key } | Select-Object -First 1
    }
    if (-not $bookmark) {
        if ($bookmarks.Count -eq 0) {
            return @{ ok = $false; reply = 'No teleport destinations are saved on the DST instance handling chat.' }
        }
        $available = @($bookmarks | Sort-Object name | ForEach-Object { [string]$_.name })
        return @{ ok = $false; reply = "Unknown teleport destination '$wanted'. Available: $($available -join ', ')." }
    }

    $current = Get-DuneChatPlayerLocation -Ip $Ip -FuncomId $FuncomId
    if (-not $current.ok) {
        return @{ ok = $false; reply = 'Could not resolve your current map for teleport.' }
    }
    if ([string]$current.status -match '^(?i:offline)$') {
        return @{ ok = $false; reply = 'You must be online to use !tp.' }
    }
    if ([string]$current.map -ine [string]$bookmark.map -or
        [int64]$current.partition -ne [int64]$bookmark.partition -or
        [int]$current.dimension -ne [int]$bookmark.dimension) {
        return @{ ok = $false; reply = "'$($bookmark.name)' is on $($bookmark.map). Travel to that map first." }
    }

    $fls = Resolve-DuneChatFlsId -Ip $Ip -FuncomId $FuncomId
    if (-not $fls.ok) { return @{ ok = $false; reply = 'Could not resolve your player id for teleport.' } }
    # Let the game resolve a safe landing surface. TeleportToExact can force a
    # distant stored Z before destination terrain finishes streaming.
    $res = Invoke-DuneRmqTeleportTo -FlsId $fls.flsId `
        -X ([double]$bookmark.x) -Y ([double]$bookmark.y) -Z ([double]$bookmark.z)
    if (-not $res.ok) { return @{ ok = $false; reply = "Teleport to '$($bookmark.name)' failed." } }
    return @{ ok = $true; reply = "Teleported to $($bookmark.name)." }
}

function Invoke-DuneChatCommandExecutor {
    param([string]$Ip, [hashtable]$State, [string]$Verb, [string]$FuncomId, [string[]]$CommandArgs, [hashtable]$Message)
    switch ("$Verb".ToLowerInvariant()) {
        'kit'     { return Invoke-DuneChatCommandKit -Ip $Ip -State $State -FuncomId $FuncomId -CommandArgs @($CommandArgs) }
        'item'    { return Invoke-DuneChatCommandItem -Ip $Ip -State $State -FuncomId $FuncomId -CommandArgs @($CommandArgs) }
        'water'   { return Invoke-DuneChatCommandWater -Ip $Ip -FuncomId $FuncomId }
        'tp'      { return Invoke-DuneChatCommandTeleport -Ip $Ip -FuncomId $FuncomId -CommandArgs @($CommandArgs) -Message $Message }
        'vehicle' { return Invoke-DuneChatCommandVehicle -Ip $Ip -FuncomId $FuncomId -CommandArgs @($CommandArgs) }
        'small'   { return Invoke-DuneChatCommandSpiceField -Ip $Ip -Size 'Small' }
        'medium'  { return Invoke-DuneChatCommandSpiceField -Ip $Ip -Size 'Medium' }
        'large'   { return Invoke-DuneChatCommandSpiceField -Ip $Ip -Size 'Large' }
        default   { return @{ ok = $false; reply = 'Unknown command.' } }
    }
}

# -----------------------------------------------------------------------------
# Scheduler tick
# -----------------------------------------------------------------------------

# Silent no-op unless the feature is on AND a reply account is configured.
#
# LATENCY: this runs from the 30 s restart-scheduler loop, so a player can wait
# up to half a minute for a response. That is acceptable for a first cut but is
# poor for chat; a dedicated faster loop is the obvious follow-up. Do not
# describe the current behaviour as instant.
function Invoke-DuneChatCommandTick {
    try {
        $state = Read-DuneChatCommandsState
        if (-not $state.enabled) { return @{ ok = $true; acted = $false; enabled = $false } }
        $ready = Test-DuneChatCommandsReady -State $state
        if (-not $ready.ready) { return @{ ok = $false; acted = $false; message = $ready.message } }

        if (-not (Get-Command Get-DuneDbContext -ErrorAction SilentlyContinue)) {
            return @{ ok = $false; acted = $false; message = 'db context helper unavailable' }
        }
        $ctx = Get-DuneDbContext
        if (-not $ctx.ok) { return @{ ok = $false; acted = $false; message = $ctx.message } }
        $ip = $ctx.ip

        # Cheap when it already exists, and self-heals if the broker was
        # restarted and lost a transient queue.
        [void](Initialize-DuneChatCommandQueue -Ip $ip)

        $drain = Get-DuneChatCommandMessages -Ip $ip
        if (-not $drain.ok) { return @{ ok = $false; acted = $false; message = $drain.message } }

        $handled = 0
        $dirty = $false
        foreach ($raw in @($drain.messages)) {
            $msg = ConvertFrom-DuneChatMessage -Text $raw
            if (-not $msg) { continue }
            $act = Resolve-DuneChatCommandAction -Message $msg -State $state
            switch ($act.action) {
                'cooldown' {
                    [void](Send-DuneChatReply -Ip $ip -State $state -ToFuncomId $msg.fromId -Message $act.reply)
                    $handled++
                }
                'run' {
                    $res = Invoke-DuneChatCommandExecutor -Ip $ip -State $state -Verb $act.verb `
                              -FuncomId $msg.fromId -CommandArgs @($act.args) -Message $msg
                    if ($res.reply) {
                        [void](Send-DuneChatReply -Ip $ip -State $state -ToFuncomId $msg.fromId -Message $res.reply)
                    }
                    # Only start the cooldown when the command actually ran. A
                    # failed grant must not burn a player's weekly kit.
                    if ($res.ok -and $res.applyCooldown -ne $false) {
                        $state.cooldowns[$act.key] = ([datetime]::UtcNow).ToString('o')
                        $dirty = $true
                    }
                    $handled++
                    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                        try { Write-DuneLog "chat command !$($act.verb) from $($msg.fromId): ok=$($res.ok)" 'INFO' } catch {}
                    }
                }
                default { }
            }
        }

        if ($handled -gt 0) { $state.lastSeenAt = ([datetime]::UtcNow).ToString('o'); $dirty = $true }
        if ($dirty) { [void](Save-DuneChatCommandsState -State $state) }
        return @{ ok = $true; acted = ($handled -gt 0); handled = $handled; scanned = @($drain.messages).Count }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            try { Write-DuneLog "chat command tick error: $($_.Exception.Message)" 'WARN' } catch {}
        }
        return @{ ok = $false; acted = $false; message = $_.Exception.Message }
    }
}
