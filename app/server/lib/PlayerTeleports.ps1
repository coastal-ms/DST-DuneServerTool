# Personal destinations are separate from the host's shared bookmarks. All
# reads/writes are on demand; capture uses the existing authenticated game chat.
function Get-DunePlayerTeleportTarget {
    param([string]$Ip, [long]$AccountId)
    if ($AccountId -le 0) { throw 'A linked character is required.' }
    $server = Get-DuneVehicleHostScope -Ip $Ip
    $sql = @"
SELECT ps.account_id, ps.player_pawn_id AS pawn, ps.player_controller_id AS controller,
       a.funcom_id, a."user" AS fls,
       ps.online_status::text AS status, actor.map,
       actor.partition_id AS partition, actor.dimension_index AS dimension
FROM dune.player_state ps JOIN dune.accounts a ON a.id = ps.account_id
JOIN dune.actors actor ON actor.id = ps.player_pawn_id
WHERE ps.account_id = $AccountId::bigint;
"@
    $read = Invoke-DuneSqlQuery -Ip $Ip -Sql $sql -ReadOnly $true -MaxRows 2 -TimeoutSec 10
    $rows = @(ConvertTo-DuneRowMaps -Result $read)
    if (-not $read.ok -or $rows.Count -ne 1) { throw 'Your linked character could not be uniquely resolved.' }
    $row = $rows[0]
    if (-not $row.funcom_id -or -not $row.fls -or [long]$row.pawn -le 0 -or [long]$row.controller -le 0) { throw 'Your linked character identity is unavailable.' }
    # A namespace identifies the selected battlegroup, not a client-supplied host.
    if (-not $server.key) { throw 'The server identity is unavailable.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($server.key)|$AccountId|$($row.funcom_id)"))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
    return @{ key=$key; account=$AccountId; pawn=[long]$row.pawn; controller=[long]$row.controller;
        funcom=[string]$row.funcom_id; fls=[string]$row.fls; status=[string]$row.status;
        map=[string]$row.map; partition=[long]$row.partition; dimension=[int]$row.dimension }
}

function Get-DunePlayerTeleportsPath {
    param([ValidatePattern('^[a-f0-9]{64}$')][string]$Key)
    $root = Join-Path (Split-Path -Parent (Get-DuneChatTeleportsPath)) 'player-teleports'
    [void][IO.Directory]::CreateDirectory($root)
    return (Join-Path $root "$Key.json")
}

function Read-DunePlayerTeleports {
    param([string]$Key)
    $path = Get-DunePlayerTeleportsPath $Key
    if (-not (Test-Path -LiteralPath $path)) { return @{ schema=1; bookmarks=@(); pending=$null; lastTeleport='' } }
    $state = ConvertTo-DunePortalHashtable (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop)
    if ($state.schema -ne 1 -or @($state.bookmarks).Count -gt 5) { throw 'Personal destinations could not be read safely.' }
    return $state
}

function Save-DunePlayerTeleports {
    param([string]$Key, [hashtable]$State)
    if (@($State.bookmarks).Count -gt 5) { throw 'You can save five private locations total.' }
    $path = Get-DunePlayerTeleportsPath $Key
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $State -Depth 8), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
}

function Assert-DunePlayerTeleportEnabled {
    $settings = Read-DuneChatCommandsState
    if (-not $settings.enabled -or -not $settings.commands.tp.enabled) { throw 'The host has disabled !tp. Ask the host to enable it in Community tools.' }
    return $settings
}

function Assert-DunePlayerTeleportOnline {
    param([hashtable]$Target)
    if ($Target.status -ine 'Online' -or -not $Target.map -or $Target.partition -le 0) { throw 'Your linked character must be online on a known map.' }
}

function Get-DunePlayerTeleportWorld {
    param([string]$Ip, [hashtable]$Target)
    # Read existing recorded seeds only. Never change or regenerate a world.
    $seeds = Get-DuneCoriolisSeedsLive -Ip $Ip
    # Actor maps and partition maps use different names (HaggaBasin versus
    # Survival_1). The actor's partition ID is the authoritative relationship;
    # the map seed still uses the actor's map name independently.
    $part = @($seeds.partitions | Where-Object { [long]$_.partition_id -eq $Target.partition })
    $map = @($seeds.maps | Where-Object { $_.map -ieq $Target.map })
    if (-not $seeds.ok -or $seeds.unsupported -or $part.Count -ne 1 -or $map.Count -ne 1 -or $part[0].seed -lt 0 -or $map[0].seed -lt 0) {
        throw 'The current map layout could not be verified. Try again after the map has loaded.'
    }
    return "$($seeds.farm_seed)|$($map[0].seed)|$($part[0].seed)"
}

function Get-DunePlayerTeleportView {
    param([hashtable]$Target)
    $state = Read-DunePlayerTeleports $Target.key
    $pending = $state.pending
    if ($pending -and [datetimeoffset]$pending.expiresAt -le [datetimeoffset]::UtcNow) { $pending=$null }
    $enabled = $false
    try { [void](Assert-DunePlayerTeleportEnabled); $enabled=$true } catch {}
    return @{ ok=$true; enabled=$enabled; limit=5;
        shared=@(Read-DuneChatTeleports | ForEach-Object { @{ id=$_.key; name=$_.name; map=$_.map } });
        private=@($state.bookmarks | ForEach-Object { @{ id=$_.id; name=$_.name; map=$_.map } });
        pending=$(if ($pending) { @{ command="!tp save $($pending.token)"; name=$pending.name; expiresAt=$pending.expiresAt } } else { $null }) }
}

function Start-DunePlayerTeleportCapture {
    param([string]$Ip, [hashtable]$Target, [string]$Name)
    [void](Assert-DunePlayerTeleportEnabled)
    Assert-DunePlayerTeleportOnline $Target
    $nameValue = ConvertTo-DuneChatTeleportName $Name
    if (-not $nameValue) { throw 'Use a location name of 1-40 letters, numbers, spaces, apostrophes, underscores or hyphens.' }
    $world = Get-DunePlayerTeleportWorld -Ip $Ip -Target $Target
    return Invoke-DuneChatTeleportFileLock -Script {
        $state = Read-DunePlayerTeleports $Target.key
        if (@($state.bookmarks).Count -ge 5 -and -not @($state.bookmarks | Where-Object { $_.name -ieq $nameValue }).Count) { throw 'You can save five private locations total. Delete a location or use its name to replace it.' }
        $state.pending = @{ name=$nameValue; token=('P-' + [guid]::NewGuid().ToString('N')); pawn=$Target.pawn; controller=$Target.controller;
            map=$Target.map; partition=$Target.partition; dimension=$Target.dimension; world=$world;
            expiresAt=[datetimeoffset]::UtcNow.AddSeconds(120).ToString('o') }
        Save-DunePlayerTeleports -Key $Target.key -State $state
        return @{ ok=$true; command="!tp save $($state.pending.token)"; expiresAt=$state.pending.expiresAt }
    }
}

function Get-DunePlayerTeleportChatTarget {
    param([string]$Ip, [string]$FuncomId)
    # Resolve the sender's active character; never scan every player's files.
    $safe = $FuncomId -replace "'", "''"
    $read = Invoke-DuneSqlQuery -Ip $Ip -Sql "SELECT ps.account_id FROM dune.player_state ps JOIN dune.accounts a ON a.id=ps.account_id WHERE a.funcom_id='$safe';" -ReadOnly $true -MaxRows 2 -TimeoutSec 10
    $rows = @(ConvertTo-DuneRowMaps -Result $read)
    if (-not $read.ok -or $rows.Count -ne 1) { throw 'The command sender could not be uniquely resolved.' }
    return Get-DunePlayerTeleportTarget -Ip $Ip -AccountId ([long]$rows[0].account_id)
}

function Find-DunePlayerTeleportChatDestination {
    param([string]$Ip, [string]$FuncomId, [string]$Name)
    $root = Join-Path (Split-Path -Parent (Get-DuneChatTeleportsPath)) 'player-teleports'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $target = Get-DunePlayerTeleportChatTarget -Ip $Ip -FuncomId $FuncomId
    $state = Read-DunePlayerTeleports $target.key
    $matches = @($state.bookmarks | Where-Object { $_.name -ieq $Name })
    if ($matches.Count -gt 1) { throw 'Private location names are ambiguous.' }
    if ($matches.Count -eq 1) { return @{ target=$target; bookmark=$matches[0] } }
    return $null
}

function Complete-DunePlayerTeleportCapture {
    param([string]$Ip, [string]$FuncomId, [string]$Token, [hashtable]$Location)
    [void](Assert-DunePlayerTeleportEnabled)
    $target = Get-DunePlayerTeleportChatTarget -Ip $Ip -FuncomId $FuncomId
    Assert-DunePlayerTeleportOnline $target
    $world = Get-DunePlayerTeleportWorld -Ip $Ip -Target $target
    return Invoke-DuneChatTeleportFileLock -Script {
        $state = Read-DunePlayerTeleports $target.key
        $p = $state.pending
        if (-not $p -or $p.token -cne $Token -or [datetimeoffset]$p.expiresAt -le [datetimeoffset]::UtcNow) { throw 'Private capture code is invalid or expired. Create a new one in the Player Portal.' }
        if ($target.pawn -ne $p.pawn -or $target.controller -ne $p.controller -or $target.map -ine $p.map -or $target.partition -ne $p.partition -or $target.dimension -ne $p.dimension -or $world -cne $p.world) { throw 'Your character or map changed. Create a new capture in the Player Portal.' }
        $coords=@{}
        foreach ($axis in @('x','y','z')) {
            if (-not $Location.ContainsKey($axis) -or $null -eq $Location[$axis]) { throw 'The game message did not include complete live coordinates.' }
            $value=[Convert]::ToDouble($Location[$axis], [cultureinfo]::InvariantCulture)
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { throw 'Invalid live coordinates.' }
            $coords[$axis]=$value
        }
        $existing = @($state.bookmarks | Where-Object { $_.name -ieq $p.name })
        $next=@($state.bookmarks | Where-Object { $_.name -ine $p.name })
        if ($next.Count -ge 5) { throw 'You can save five private locations total.' }
        $next += @{ id=$(if($existing.Count){$existing[0].id}else{[guid]::NewGuid().ToString('N')}); name=$p.name;
            map=$p.map; partition=$p.partition; dimension=$p.dimension; world=$world;
            x=$coords.x; y=$coords.y; z=$coords.z }
        $state.bookmarks=@($next); $state.pending=$null
        Save-DunePlayerTeleports -Key $target.key -State $state
        return @{ ok=$true; applyCooldown=$false; reply='Private location saved. Refresh My teleport locations in the Player Portal.' }
    }
}

function Remove-DunePlayerTeleport {
    param([hashtable]$Target, [string]$Id)
    return Invoke-DuneChatTeleportFileLock -Script {
        $state=Read-DunePlayerTeleports $Target.key
        if ($Id -eq 'pending') { $state.pending=$null }
        else {
            $next=@($state.bookmarks | Where-Object { $_.id -cne $Id })
            if($next.Count -eq @($state.bookmarks).Count){throw 'Private location not found.'}
            $state.bookmarks=$next
        }
        Save-DunePlayerTeleports -Key $Target.key -State $state
        return @{ok=$true}
    }
}

function Invoke-DunePlayerTeleport {
    param([string]$Ip, [hashtable]$Target, [string]$Id, [ValidateSet('shared','private')][string]$Scope)
    $settings=Assert-DunePlayerTeleportEnabled
    Assert-DunePlayerTeleportOnline $Target
    $state=Read-DunePlayerTeleports $Target.key
    $bookmarks=if($Scope -eq 'shared'){@(Read-DuneChatTeleports)}else{@($state.bookmarks)}
    $b=@($bookmarks | Where-Object { $(if($Scope -eq 'shared'){$_.key}else{$_.id}) -ceq $Id })
    if($b.Count -ne 1){throw 'Location not found.'}; $b=$b[0]
    if($Target.map -ine $b.map -or $Target.partition -ne $b.partition -or $Target.dimension -ne $b.dimension){throw 'Travel to the destination map first.'}
    if($Scope -eq 'private' -and $b.world -cne (Get-DunePlayerTeleportWorld -Ip $Ip -Target $Target)){throw 'The map layout changed. Delete and save this private location again.'}
    $key=Get-DuneChatCooldownKey -FromId $Target.funcom -Verb 'tp'
    $seconds=[math]::Max(1,[int]$settings.commands.tp.cooldownSeconds)
    $cool=Test-DuneChatCooldown -Cooldowns $settings.cooldowns -Key $key -CooldownSeconds $seconds -Now ([datetime]::UtcNow)
    if(-not $cool.allowed){throw 'Teleport is on cooldown. Please wait before trying again.'}
    foreach($axis in @('x','y','z')){if($null -eq $b[$axis] -or [double]::IsNaN([double]$b[$axis]) -or [double]::IsInfinity([double]$b[$axis])){throw 'Invalid destination coordinates.'}}
    Enter-DunePlayerTeleportCooldown -Ip $Ip -FuncomId $Target.funcom -Seconds $seconds -Create
    $result=Invoke-DuneRmqTeleportTo -FlsId $Target.fls -X $b.x -Y $b.y -Z $b.z -RepeatForReliability
    if(-not $result.ok){throw 'Teleport could not be confirmed. Wait for the cooldown before trying again.'}
    return @{ok=$true;message='Teleport command sent.'}
}
function Enter-DunePlayerTeleportCooldown {
    param([string]$Ip, [string]$FuncomId, [int]$Seconds, [switch]$Create)
    # Both portal and chat use this small timestamp store. No background job.
    $path=Join-Path (Split-Path -Parent (Get-DuneChatTeleportsPath)) 'player-teleport-cooldowns.json'
    if(-not $Create -and -not (Test-Path -LiteralPath $path)){return}
    $server=Get-DuneVehicleHostScope -Ip $Ip
    if(-not $server.key -or -not $FuncomId){throw 'Teleport identity is unavailable.'}
    $key="$($server.key)|$($FuncomId.ToLowerInvariant())"
    Invoke-DuneChatTeleportFileLock -Script {
        $times=@{}
        if(Test-Path -LiteralPath $path){$times=ConvertTo-DunePortalHashtable (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop)}
        $now=[datetimeoffset]::UtcNow
        if($times.ContainsKey($key) -and ($now-[datetimeoffset]$times[$key]).TotalSeconds -lt [math]::Max(1,$Seconds)){throw 'Teleport is on cooldown. Please wait before trying again.'}
        foreach($old in @($times.Keys)){if(($now-[datetimeoffset]$times[$old]).TotalDays -ge 1){$times.Remove($old)}}
        if($times.Count -ge 5000 -and -not $times.ContainsKey($key)){throw 'Teleport cooldown storage is busy. Try again later.'}
        $times[$key]=$now.ToString('o')
        $temp="$path.$([guid]::NewGuid().ToString('N')).tmp"
        try{[IO.File]::WriteAllText($temp,($times|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop}
        finally{Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue}
    }
}

