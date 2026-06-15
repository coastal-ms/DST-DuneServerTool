# Db-Postgres.ps1
# Thin PowerShell wrapper around the VM's K8s-hosted Postgres pod.
# All queries are run as: ssh dune@<vm-ip> "echo <b64> | base64 -d | sudo kubectl exec -i -n <ns> <pod> -- psql -U dune -d dune -p 15432 -t -A"
# SQL strings cribbed verbatim from the dune-awakening-server-manager MIT reference
# (server.js lines 1020-1460). Translated to PowerShell.

$script:V6DbPodCache     = $null
$script:V6DbPodCacheTime = [datetime]::MinValue

function Get-V6SshKeyPath {
    if ($script:V6SshKeyCache -and (Test-Path $script:V6SshKeyCache)) { return $script:V6SshKeyCache }
    try {
        $cfg = $null
        if (Get-Command Read-Config -ErrorAction SilentlyContinue) {
            $cfg = Read-Config
        } else {
            $cfgPath = $null
            if ($script:ConfigFile -and (Test-Path $script:ConfigFile)) { $cfgPath = $script:ConfigFile }
            elseif (Test-Path "$env:APPDATA\DuneServer\dune-server.config") { $cfgPath = "$env:APPDATA\DuneServer\dune-server.config" }
            if ($cfgPath) {
                $cfg = @{}
                Get-Content $cfgPath | ForEach-Object {
                    if ($_ -match '^([^#=]+)=(.*)$') { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
                }
            }
        }
        if ($cfg -and $cfg.SshKey -and (Test-Path $cfg.SshKey)) { $script:V6SshKeyCache = $cfg.SshKey; return $cfg.SshKey }
    } catch {}
    return $null
}

function Invoke-V6Ssh {
    param([string]$Ip, [string]$Cmd, [int]$TimeoutSec = 30, [string]$StdinData)
    # Strip CRs from the command — here-strings in CRLF-saved .ps1 files
    # preserve \r, which breaks bash (commands appear as "head -1\r" etc).
    if ($Cmd) { $Cmd = $Cmd -replace "`r","" }
    $key = Get-V6SshKeyPath
    if ($TimeoutSec -lt 1) { $TimeoutSec = 30 }

    # NOTE 2026-06-03 (v10.1.14): previously this function called
    # `& ssh ...` directly and SILENTLY IGNORED its $TimeoutSec parameter
    # — only OpenSSH-level ConnectTimeout=8 was set, which caps the TCP
    # handshake but lets a *connected* remote command hang forever. That
    # bug caused a Map SpinUp toggle to wedge the entire backend UI when
    # the underlying ssh child process never returned (the HTTP listener
    # runs handlers inline on a single thread; one hung handler froze
    # every panel — see app/server/HttpServer.ps1:298). We now spawn ssh
    # as a managed Process and hard-kill it past the deadline.
    # ServerAliveInterval+ServerAliveCountMax are belt-and-suspenders so
    # OpenSSH itself tears down a silent session in ~30 s even if the
    # host-side kill ever misfires. The single-thread-listener problem
    # itself is the v10.1.15 work tracked separately.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    if ($StdinData) { $psi.RedirectStandardInput = $true }

    # PS 5.1 lacks ProcessStartInfo.ArgumentList — build the command line
    # by hand. All values here are fixed literals, an IP, a file path we
    # control ($key), or the caller's remote command ($Cmd). Quote any
    # arg containing whitespace or quotes; escape embedded " as \".
    $sshArgs = @(
        '-o','BatchMode=yes'
        '-o','StrictHostKeyChecking=no'
        '-o','LogLevel=QUIET'
        '-o','ConnectTimeout=8'
        '-o','ServerAliveInterval=10'
        '-o','ServerAliveCountMax=3'
    )
    # When there's no payload to stream, pass -n so ssh doesn't inherit the
    # backend's stdin handle and hang waiting on it after the remote command
    # exits. When StdinData IS supplied we keep stdin open and feed the payload
    # through it — this is how large writes avoid the OS command-line length
    # limit (a multi-KB command string is rejected by the remote with
    # "Connection closed by remote host"); the command itself stays tiny and
    # reads the bytes from stdin instead.
    if (-not $StdinData) { $sshArgs = @('-n') + $sshArgs }
    if ($key) { $sshArgs += @('-i', $key) }
    $sshArgs += @("dune@$Ip")
    if ($null -ne $Cmd) { $sshArgs += @($Cmd) }
    $psi.Arguments = (@($sshArgs) | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        if ($StdinData) {
            # Stream the payload over stdin, then close so the remote sees EOF.
            $proc.StandardInput.Write($StdinData)
            $proc.StandardInput.Close()
        }
        # Drain both streams asynchronously — a chatty remote command can
        # fill the ~4 KB pipe buffer before we reach WaitForExit, causing
        # ssh to block on stdout.write and us to deadlock waiting for it
        # to exit.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $timeoutMs = [int]$TimeoutSec * 1000
        $exited = $proc.WaitForExit($timeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch {}
            try { [void]$proc.WaitForExit(2000) } catch {}
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Invoke-V6Ssh: ssh to $Ip exceeded ${TimeoutSec}s, killed" 'WARN'
            }
            # Surface the timeout to callers via the stdout slot they
            # already inspect — most do `($out -join "`n").Trim()` then
            # string-match the result; an `ERROR:` line is clearly
            # visible (vs. the silent `$null`/empty failure mode that
            # produced the misleading "kubectl patch may have failed:"
            # toast in the v10.1.13 incident).
            return "ERROR: ssh timed out after ${TimeoutSec}s"
        }
        # Per Microsoft docs, an unbounded WaitForExit() after a bounded
        # one ensures the async stream readers fully drain before we
        # consume the tasks.
        [void]$proc.WaitForExit()
        [void]$errTask.GetAwaiter().GetResult()  # discarded — mirrors prior `2>$null`
        $text = $outTask.GetAwaiter().GetResult()
        if ([string]::IsNullOrEmpty($text)) { return }
        # Emit one pipeline item per stdout line — matches the original
        # `& ssh ...` capture semantics so existing callers keep working.
        return ($text -split "`r?`n")
    } finally {
        try { $proc.Dispose() } catch {}
    }
}

# Run an arbitrary ssh command with a HIDDEN window (no conhost flash) and
# return BOTH stdout and stderr separately, plus the process exit code.
#
# Why this exists alongside Invoke-V6Ssh:
#   Invoke-V6Ssh is tuned for the kubectl/psql call path -- it discards
#   stderr (mirrors the old `2>$null` semantics) and only returns stdout.
#   The preflight / status code paths need stderr (to surface "Permission
#   denied" / "Host key verification failed" etc. as actionable hints) AND
#   the exit code. They used to call `& ssh ... 2>$errFile`, which
#   silently allocates a fresh conhost window for every spawn when run
#   from a background runspace whose parent's hidden console isn't
#   inherited -- producing the "console keeps popping up and disappearing"
#   flash users see while the dashboard polls (every 10-15 s per panel).
function Invoke-DuneSshHidden {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Ip,
        [Parameter(Mandatory)] [string]   $KeyPath,
        [string[]]                       $SshOptions = @(),
        [string]                         $RemoteCommand,
        [string]                         $User       = 'dune',
        [int]                            $TimeoutSec = 30
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    # Build argv. Same quoting strategy as Invoke-V6Ssh: only quote args
    # that contain whitespace or quotes, and escape any embedded ".
    $sshArgs = @('-n') + $SshOptions
    if ($KeyPath) { $sshArgs += @('-i', $KeyPath) }
    $sshArgs += @("$User@$Ip")
    if ($RemoteCommand) { $sshArgs += @($RemoteCommand) }
    $psi.Arguments = (@($sshArgs) | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $outTask  = $proc.StandardOutput.ReadToEndAsync()
        $errTask  = $proc.StandardError.ReadToEndAsync()
        $timeoutMs = [int]$TimeoutSec * 1000
        if (-not $proc.WaitForExit($timeoutMs)) {
            try { $proc.Kill() } catch {}
            try { [void]$proc.WaitForExit(2000) } catch {}
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Invoke-DuneSshHidden: ssh to $Ip exceeded ${TimeoutSec}s, killed" 'WARN'
            }
            return @{
                Stdout = @()
                Stderr = "ssh timed out after ${TimeoutSec}s"
                Exit   = -1
            }
        }
        [void]$proc.WaitForExit()
        $stdoutText = $outTask.GetAwaiter().GetResult()
        $stderrText = $errTask.GetAwaiter().GetResult()
        return @{
            Stdout = if ([string]::IsNullOrEmpty($stdoutText)) { @() } else { @($stdoutText -split "`r?`n") }
            Stderr = $stderrText
            Exit   = $proc.ExitCode
        }
    } finally {
        try { $proc.Dispose() } catch {}
    }
}

function Find-V6DbPod {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:V6DbPodCache -and ((Get-Date) - $script:V6DbPodCacheTime).TotalSeconds -lt 120) {
        return $script:V6DbPodCache
    }
    $raw = Invoke-V6Ssh -Ip $Ip -Cmd "sudo kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep 'db-dbdepl-sts.*Running'"
    $line = (($raw -join "`n") -split "`n" | Where-Object { $_ } | Select-Object -First 1)
    if (-not $line) { throw "Postgres pod not found. Make sure the battlegroup is running and fully initialized before editing characters." }
    $parts = ($line.Trim() -split '\s+')
    $pod = @{ ns = $parts[0]; name = $parts[1] }
    $script:V6DbPodCache = $pod
    $script:V6DbPodCacheTime = Get-Date
    return $pod
}

function Invoke-V6Psql {
    param([string]$Ip, [string]$Sql, [int]$TimeoutSec = 30)
    $pod = Find-V6DbPod -Ip $Ip
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
    $cmd = "echo $b64 | base64 -d | sudo kubectl exec -i -n $($pod.ns) $($pod.name) -- psql -U dune -d dune -p 15432 -t -A 2>&1"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec $TimeoutSec
    return (($out -join "`n")).Trim()
}

function ConvertFrom-V6PsqlJson {
    param([string]$Raw, $Default = $null)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $Default }
    try { return ($Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $Default }
}

# -----------------------------------------------------------------------------
# Online players — used by the route-layer guard to refuse mutating operations
# while anyone is connected. Returns [] when the DB is unreachable so the guard
# fails open (we don't want a transient SSH/psql blip to block all edits).
# -----------------------------------------------------------------------------
function Get-V6OnlinePlayers {
    param([string]$Ip)
    $sql = @"
SELECT json_agg(row_to_json(t)) FROM (
  SELECT eps.player_pawn_id::text  AS id,
         decrypt_user_data(eps.encrypted_character_name) AS name,
         eps.online_status::text   AS status
  FROM encrypted_player_state eps
  WHERE eps.online_status::text <> 'Offline'
  ORDER BY eps.player_pawn_id
) t
"@
    try {
        $raw = Invoke-V6Psql -Ip $Ip -Sql $sql
    } catch {
        return @()
    }
    $list = ConvertFrom-V6PsqlJson -Raw $raw -Default @()
    if (-not $list) { return @() }
    return @($list)
}

# -----------------------------------------------------------------------------
# Character list
# -----------------------------------------------------------------------------
function Get-V6CharacterList {
    param([string]$Ip)
    $sql = @"
SELECT json_agg(row_to_json(t)) FROM (
  SELECT eps.player_pawn_id AS id, decrypt_user_data(eps.encrypted_character_name) AS name
  FROM encrypted_player_state eps
  WHERE eps.player_pawn_id IS NOT NULL
  ORDER BY eps.player_pawn_id
) t
"@
    $raw = Invoke-V6Psql -Ip $Ip -Sql $sql
    $list = ConvertFrom-V6PsqlJson -Raw $raw -Default @()
    if (-not $list) { return @() }
    return $list
}

# -----------------------------------------------------------------------------
# Character detail (properties + gas_attributes)
# -----------------------------------------------------------------------------
function Get-V6CharacterDetail {
    param([string]$Ip, [int]$Id)
    $props = Invoke-V6Psql -Ip $Ip -Sql "SELECT properties::text FROM actors WHERE id = $Id"
    $gas   = Invoke-V6Psql -Ip $Ip -Sql "SELECT gas_attributes::text FROM actors WHERE id = $Id"
    return @{
        Id            = $Id
        Properties    = ConvertFrom-V6PsqlJson -Raw $props -Default @{}
        GasAttributes = ConvertFrom-V6PsqlJson -Raw $gas   -Default @{}
    }
}

# -----------------------------------------------------------------------------
# Stat read helper: walks a dotted path through properties / gas_attributes.
# Returns BaseValue if the leaf is a GAS attribute object.
# -----------------------------------------------------------------------------
function Get-V6StatValue {
    param($Detail, [string]$Field, [string]$PathStr)
    $obj = if ($Field -eq 'properties') { $Detail.Properties } else { $Detail.GasAttributes }
    foreach ($p in ($PathStr -split '\.')) {
        if ($null -eq $obj) { return '' }
        if ($obj.PSObject.Properties[$p]) {
            $obj = $obj.$p
        } else {
            return ''
        }
    }
    if ($obj -and ($obj | Get-Member -Name 'BaseValue' -ErrorAction SilentlyContinue)) {
        return $obj.BaseValue
    }
    if ($null -eq $obj) { return '' }
    return $obj
}

# -----------------------------------------------------------------------------
# Stat updates: build jsonb_set chain. $Updates = array of @{Field=...; Path=@(...); Value=...}
# -----------------------------------------------------------------------------
function Set-V6CharacterStats {
    param([string]$Ip, [int]$Id, [array]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return }

    $propUps = $Updates | Where-Object { $_.Field -eq 'properties' }
    $gasUps  = $Updates | Where-Object { $_.Field -eq 'gas_attributes' }

    if ($propUps -and $propUps.Count -gt 0) {
        $expr = 'properties'
        foreach ($u in $propUps) {
            $pathStr = '{' + (($u.Path) -join ',') + '}'
            $json = ($u.Value | ConvertTo-Json -Compress)
            # Escape single quotes in json (rare but possible)
            $json = $json -replace "'", "''"
            $expr = "jsonb_set($expr, '$pathStr', '$json'::jsonb)"
        }
        Invoke-V6Psql -Ip $Ip -Sql "UPDATE actors SET properties = $expr WHERE id = $Id" | Out-Null
    }
    if ($gasUps -and $gasUps.Count -gt 0) {
        $expr = 'gas_attributes'
        foreach ($u in $gasUps) {
            $pathStr = '{' + (($u.Path) -join ',') + '}'
            $json = ($u.Value | ConvertTo-Json -Compress)
            $json = $json -replace "'", "''"
            $expr = "jsonb_set($expr, '$pathStr', '$json'::jsonb)"
        }
        Invoke-V6Psql -Ip $Ip -Sql "UPDATE actors SET gas_attributes = $expr WHERE id = $Id" | Out-Null
    }
}

# -----------------------------------------------------------------------------
# Tech Tree: bulk unlock-all / lock-all
# -----------------------------------------------------------------------------
function Invoke-V6TechUnlockAll {
    param([string]$Ip, [int]$Id)
    # COALESCE + WHERE-guard: if the TechKnowledgeData array doesn't exist or
    # is empty, jsonb_agg returns NULL → jsonb_set with NULL value returns
    # NULL → would wipe the entire properties column. Belt-and-suspenders:
    # COALESCE the agg to '[]' and only run the UPDATE when the source path
    # actually exists as an array.
    $sql = @"
UPDATE actors SET properties = jsonb_set(
  properties, '{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}',
  COALESCE(
    (SELECT jsonb_agg(CASE WHEN elem->>'UnlockedState' = 'NotPurchased'
                            THEN jsonb_set(elem, '{UnlockedState}', '"Purchased"') ELSE elem END)
     FROM jsonb_array_elements(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') AS elem),
    '[]'::jsonb
  )
) WHERE id = $Id
  AND jsonb_typeof(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') = 'array'
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Invoke-V6TechLockAll {
    param([string]$Ip, [int]$Id)
    # Same NULL-wipe guard as Invoke-V6TechUnlockAll.
    $sql = @"
UPDATE actors SET properties = jsonb_set(
  properties, '{TechKnowledgePlayerComponent,m_TechKnowledge,m_TechKnowledgeData}',
  COALESCE(
    (SELECT jsonb_agg(jsonb_set(elem, '{UnlockedState}', '"NotPurchased"'))
     FROM jsonb_array_elements(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') AS elem),
    '[]'::jsonb
  )
) WHERE id = $Id
  AND jsonb_typeof(properties->'TechKnowledgePlayerComponent'->'m_TechKnowledge'->'m_TechKnowledgeData') = 'array'
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Controller-ID lookup (pawn id -> controller id)
# -----------------------------------------------------------------------------
# Most player-scoped tables (specialization_tracks, purchased_specialization_keystones,
# player_virtual_currency_balances, ...) key on the *controller* id, not the pawn id
# that the character list / faction-rep / actors tables expose. encrypted_player_state
# bridges the two.
function Get-V6ControllerId {
    param([string]$Ip, [int]$Id)
    $raw = Invoke-V6Psql -Ip $Ip -Sql "SELECT player_controller_id FROM encrypted_player_state WHERE player_pawn_id = $Id"
    if ($raw -match '\d+') { return [int]$matches[0] }
    return 0
}

# -----------------------------------------------------------------------------
# Specializations
# -----------------------------------------------------------------------------
function Get-V6Specializations {
    param([string]$Ip, [int]$Id)
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id
    $tracksRaw = '[]'
    if ($controllerId) {
        $tracksRaw = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT track_type, xp_amount, level FROM dune.specialization_tracks WHERE player_id = $controllerId ORDER BY track_type
) t
"@
    }
    $keystoneCount = 0
    if ($controllerId) {
        $kcRaw = Invoke-V6Psql -Ip $Ip -Sql "SELECT COUNT(*) FROM dune.purchased_specialization_keystones WHERE player_id = $controllerId"
        if ($kcRaw -match '\d+') { $keystoneCount = [int]$matches[0] }
    }
    return @{
        ControllerId  = $controllerId
        Tracks        = ConvertFrom-V6PsqlJson -Raw $tracksRaw -Default @()
        KeystoneCount = $keystoneCount
    }
}

function Set-V6SpecializationTrack {
    param([string]$Ip, [int]$Id, [string]$TrackType, [int]$Xp, [double]$Level)
    $valid = @('Combat','Crafting','Gathering','Exploration','Sabotage')
    if ($TrackType -notin $valid) { throw "Invalid track: $TrackType" }
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id
    if (-not $controllerId) { throw "Could not resolve controller id for actor $Id" }
    $sql = @"
INSERT INTO dune.specialization_tracks (player_id, track_type, xp_amount, level)
VALUES ($controllerId, '$TrackType', $Xp, $Level)
ON CONFLICT (player_id, track_type) DO UPDATE SET xp_amount = EXCLUDED.xp_amount, level = EXCLUDED.level
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Invoke-V6UnlockKeystonesForTrack {
    param([string]$Ip, [int]$Id, [string]$TrackPrefix)
    $valid = @('Combat_','Crafting_','Exploration_','Gathering_','Sabotage_')
    if ($TrackPrefix -notin $valid) { throw "Invalid track prefix: $TrackPrefix" }
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id
    if (-not $controllerId) { throw "Could not resolve controller id for actor $Id" }
    $sql = @"
INSERT INTO dune.purchased_specialization_keystones (player_id, keystone_id)
SELECT $controllerId, id FROM dune.specialization_keystones_map WHERE name LIKE '${TrackPrefix}%'
ON CONFLICT DO NOTHING
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Economy + Faction
# -----------------------------------------------------------------------------
function Get-V6Economy {
    param([string]$Ip, [int]$Id)
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id

    $cur = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT currency_id, balance FROM player_virtual_currency_balances
  WHERE player_controller_id = $controllerId ORDER BY currency_id
) t
"@
    $rep = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT fr.faction_id, f.name AS faction_name, fr.reputation_amount
  FROM dune.player_faction_reputation fr JOIN dune.factions f ON fr.faction_id = f.id
  WHERE fr.actor_id = $controllerId ORDER BY fr.faction_id
) t
"@
    $factions = Invoke-V6Psql -Ip $Ip -Sql "SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (SELECT id, name FROM dune.factions ORDER BY id) t"

    return @{
        ControllerId = $controllerId
        Currency     = ConvertFrom-V6PsqlJson -Raw $cur -Default @()
        FactionRep   = ConvertFrom-V6PsqlJson -Raw $rep -Default @()
        Factions     = ConvertFrom-V6PsqlJson -Raw $factions -Default @()
    }
}

function Set-V6Currency {
    param([string]$Ip, [int]$Id, [int]$CurrencyId, [int]$Balance)
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id
    if (-not $controllerId) { throw "Could not resolve controller id for actor $Id" }
    $sql = @"
INSERT INTO player_virtual_currency_balances (player_controller_id, currency_id, balance)
VALUES ($controllerId, $CurrencyId, $Balance)
ON CONFLICT (player_controller_id, currency_id) DO UPDATE SET balance = EXCLUDED.balance
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Set-V6FactionReputation {
    param([string]$Ip, [int]$Id, [int]$FactionId, [int]$Amount)
    $controllerId = Get-V6ControllerId -Ip $Ip -Id $Id
    if (-not $controllerId) { throw "Could not resolve controller id for actor $Id" }
    $sql = @"
INSERT INTO dune.player_faction_reputation (actor_id, faction_id, reputation_amount)
VALUES ($controllerId, $FactionId, $Amount)
ON CONFLICT (actor_id, faction_id) DO UPDATE SET reputation_amount = EXCLUDED.reputation_amount
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Spicefield types (dune.spicefield_types)
# -----------------------------------------------------------------------------
# One row per (map, field-size) combo. Controls how many spice fields can be
# active/primed globally, the spawn-weight, and whether spawning is enabled.
# `current_*` columns are read-only state maintained by the game.
function Get-V6SpicefieldTypes {
    param([string]$Ip)
    $raw = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.map_name, t.spicefield_type_id), '[]') FROM (
  SELECT spicefield_type_id, map_name, field_type, dimension_index,
         max_globally_active, max_globally_primed,
         current_globally_active, current_globally_primed,
         is_spawning_active, global_spawn_weight
  FROM dune.spicefield_types
) t
"@
    return ConvertFrom-V6PsqlJson -Raw $raw -Default @()
}

function Set-V6SpicefieldType {
    param(
        [string]$Ip,
        [int]$TypeId,
        [int]$MaxActive,
        [int]$MaxPrimed,
        [bool]$IsSpawningActive,
        [double]$SpawnWeight
    )
    if ($MaxActive  -lt 0) { throw "max_globally_active must be >= 0" }
    if ($MaxPrimed  -lt 0) { throw "max_globally_primed must be >= 0" }
    if ($SpawnWeight -lt 0) { throw "global_spawn_weight must be >= 0" }
    $activeFlag = if ($IsSpawningActive) { 'TRUE' } else { 'FALSE' }
    # Use invariant decimal format (e.g. "1.5", never "1,5") so psql parses it
    # regardless of host culture.
    $weightStr = ([double]$SpawnWeight).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $sql = @"
UPDATE dune.spicefield_types
   SET max_globally_active = $MaxActive,
       max_globally_primed = $MaxPrimed,
       is_spawning_active  = $activeFlag,
       global_spawn_weight = $weightStr
 WHERE spicefield_type_id = $TypeId
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# Live toggle for is_spawning_active ONLY. Used by the per-row checkbox in
# the Spicefields card — every click commits straight to the DB while the
# game is running.
#
# Guard rails (intentionally strict — this function MUST NOT mutate any
# other column under any circumstance):
#   * $TypeId must be a positive int.
#   * $Active is a [bool] parameter; PowerShell coerces strictly true/false.
#   * The SQL UPDATE touches exactly one column (is_spawning_active) and
#     emits a literal TRUE or FALSE — never NULL, never the empty string,
#     never anything else. The WHERE clause pins it to a single row by PK.
#   * No CASE, no other columns, no triggers we own.
function Set-V6SpicefieldSpawning {
    param(
        [Parameter(Mandatory)] [string]$Ip,
        [Parameter(Mandatory)] [int]$TypeId,
        [Parameter(Mandatory)] [bool]$Active
    )
    if ($TypeId -le 0) { throw "spicefield_type_id must be a positive int (got $TypeId)" }
    $flag = if ($Active) { 'TRUE' } else { 'FALSE' }
    # Final paranoia check — $flag MUST be one of two exact strings before
    # going anywhere near psql.
    if ($flag -ne 'TRUE' -and $flag -ne 'FALSE') {
        throw "Internal: is_spawning_active flag computed to '$flag' (expected TRUE or FALSE)"
    }
    $sql = "UPDATE dune.spicefield_types SET is_spawning_active = $flag WHERE spicefield_type_id = $TypeId"
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Cosmetics
# -----------------------------------------------------------------------------
function Get-V6Cosmetics {
    param([string]$Ip, [int]$Id)
    $raw = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(elem->>'m_CustomizationId' ORDER BY elem->>'m_CustomizationId'), '[]')
FROM (SELECT jsonb_array_elements(properties->'CustomizationLibraryActorComponent'
            ->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds') AS elem
      FROM actors WHERE id = $Id) sub
"@
    return ConvertFrom-V6PsqlJson -Raw $raw -Default @()
}

function Add-V6Cosmetic {
    param([string]$Ip, [int]$Id, [string]$CosmeticId)
    $safe = ($CosmeticId -replace '[^a-zA-Z0-9_]', '')
    # COALESCE guards: if the path doesn't yet exist on this actor, the inner
    # `->` chain returns SQL NULL. `NULL || ...` is NULL, and jsonb_set with a
    # NULL value returns NULL for the whole expression — which would wipe the
    # entire `properties` column (taking cosmetics, stats, tech, etc. with it).
    # We coerce the missing array to `[]` so concatenation always produces
    # valid JSONB.
    $sql = @"
UPDATE actors SET properties = jsonb_set(properties,
  '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}',
  COALESCE(properties->'CustomizationLibraryActorComponent'->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds', '[]'::jsonb)
    || '[{"m_CustomizationId": "$safe"}]'::jsonb
) WHERE id = $Id
  AND properties->'CustomizationLibraryActorComponent'->'m_UnlockedCustomizationSerializableList' IS NOT NULL
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Remove-V6Cosmetic {
    param([string]$Ip, [int]$Id, [string]$CosmeticId)
    $safe = ($CosmeticId -replace '[^a-zA-Z0-9_]', '')
    $sql = @"
UPDATE actors SET properties = jsonb_set(properties,
  '{CustomizationLibraryActorComponent,m_UnlockedCustomizationSerializableList,m_UnlockedCustomizationIds}',
  (SELECT COALESCE(jsonb_agg(elem), '[]'::jsonb) FROM jsonb_array_elements(
    properties->'CustomizationLibraryActorComponent'->'m_UnlockedCustomizationSerializableList'->'m_UnlockedCustomizationIds'
  ) AS elem WHERE elem->>'m_CustomizationId' != '$safe')
) WHERE id = $Id
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

# -----------------------------------------------------------------------------
# Inventory
# -----------------------------------------------------------------------------
function Get-V6Inventory {
    param([string]$Ip, [int]$Id)
    $invs = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT id, inventory_type, max_item_count FROM inventories
  WHERE actor_id = $Id AND inventory_type IS NOT NULL ORDER BY id
) t
"@
    $items = Invoke-V6Psql -Ip $Ip -Sql @"
SELECT COALESCE(json_agg(row_to_json(t)), '[]') FROM (
  SELECT i.id, i.inventory_id, i.template_id, i.stack_size, i.position_index, inv.inventory_type
  FROM items i JOIN inventories inv ON i.inventory_id = inv.id
  WHERE inv.actor_id = $Id ORDER BY inv.inventory_type, i.position_index
) t
"@
    return @{
        Inventories = ConvertFrom-V6PsqlJson -Raw $invs  -Default @()
        Items       = ConvertFrom-V6PsqlJson -Raw $items -Default @()
    }
}

function Add-V6InventoryItem {
    param([string]$Ip, [int]$InventoryId, [string]$TemplateId, [int]$StackSize, [bool]$IsEquipment)
    $safe = ($TemplateId -replace "'", "''")
    $stats = if ($IsEquipment) {
        '{"FCustomizationStats": [[], {}], "FItemStackAndDurabilityStats": [[], {}]}'
    } else {
        '{"FItemStackAndDurabilityStats": [[], {"DecayedMaxDurability": 0.0}]}'
    }
    $posRaw = Invoke-V6Psql -Ip $Ip -Sql "SELECT COALESCE(MAX(position_index) + 1, 0) FROM items WHERE inventory_id = $InventoryId"
    $nextPos = 0
    if ($posRaw -match '\d+') { $nextPos = [int]$matches[0] }
    $sql = @"
INSERT INTO items (inventory_id, template_id, stack_size, position_index, stats)
VALUES ($InventoryId, '$safe', $StackSize, $nextPos, '$stats'::jsonb)
"@
    Invoke-V6Psql -Ip $Ip -Sql $sql | Out-Null
}

function Remove-V6InventoryItem {
    param([string]$Ip, [int]$ItemId)
    Invoke-V6Psql -Ip $Ip -Sql "DELETE FROM items WHERE id = $ItemId" | Out-Null
}
