# Maps — on-demand control of individual map deployments in the battlegroup
# CRD (currently: DeepDesert).
#
# The battlegroup operator owns the map pod replicas — scaling the Deployment
# directly is reconciled away. We patch the battlegroup CRD's spec instead:
#
#   spec.serverGroup.template.spec.sets[i].replicas = 1
#   spec.database.template.spec.deployment.spec.worldPartitions[*]
#     .partitions[*].disable = false
#
# Pattern cribbed from app/lib/K8s.ps1 (Set-V6SietchConfig).
#
# K8s.ps1 is dot-sourced via Bootstrap.ps1 (which loads Db-Postgres.ps1, which
# Db-Postgres.ps1 (Invoke-V6Ssh, Get-V6Battlegroup). If those haven't loaded
# yet (parse-test contexts) we no-op gracefully.

# Dot-source the existing K8s helpers (untouched from v6.0.x).
$script:DuneK8sPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\K8s.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\K8s.ps1')
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneK8sPath = $full; break }
}
if ($script:DuneK8sPath -and -not (Get-Command Get-V6Battlegroup -ErrorAction SilentlyContinue)) {
    . $script:DuneK8sPath
}

# Map name prefix → human label. Add new entries here to support more maps.
$script:DuneOnDemandMaps = @(
    @{ Key='deepdesert';   Pattern='^DeepDesert';     Label='Deep Desert'    }
    @{ Key='arakeen';      Pattern='^SH_Arrakeen';     Label='Arrakeen'        }
    @{ Key='harkovillage'; Pattern='^SH_HarkoVillage'; Label='Harko Village' }
)

function Get-DuneMapsContext {
    $ctx = @{ ok = $true }
    try { $vm = Get-DuneVmStatus } catch {
        return @{ ok=$false; status=503; message="VM status unavailable: $($_.Exception.Message)" }
    }
    if (-not $vm)         { return @{ ok=$false; status=503; message='VM status unavailable.' } }
    if (-not $vm.exists)  { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running) { return @{ ok=$false; status=503; message="VM state: $($vm.state) - start the VM first." } }
    if (-not $vm.ip)      { return @{ ok=$false; status=503; message='VM is running but has no IP yet.' } }

    $cfg = Read-DuneConfig
    if (-not $cfg.SshKey -or -not (Test-Path -LiteralPath $cfg.SshKey)) {
        return @{ ok=$false; status=503; message='SSH key not configured. Set SshKey in dune-server.config or via Settings.' }
    }
    $ctx.vm = $vm
    return $ctx
}

function _Find-DuneMapSets {
    # Returns @( @{ Idx; Map; Partitions; HasPartitionsField; Replicas; DedicatedScaling } )
    # NOTE: don't use $matches as a local — that's an automatic regex variable.
    param([Parameter(Mandatory)]$Bg, [Parameter(Mandatory)][string]$Pattern)
    $matchList = @()
    $sets = $Bg.spec.serverGroup.template.spec.sets
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $s = $sets[$i]
        if ([string]$s.map -match $Pattern) {
            $isDedicated = $false
            if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
            $replicas = $null
            if ($s.PSObject.Properties['replicas']) { $replicas = [int]$s.replicas }
            $hasPartField = $false
            $partIds = @()
            if ($s.PSObject.Properties['partitions']) {
                $hasPartField = $true
                if ($null -ne $s.partitions) { $partIds = @($s.partitions | Where-Object { $null -ne $_ }) }
            }
            $matchList += @{
                Idx                = $i
                Map                = [string]$s.map
                Partitions         = $partIds
                HasPartitionsField = $hasPartField
                Replicas           = $replicas
                DedicatedScaling   = $isDedicated
            }
        }
    }
    return ,$matchList
}

function _Get-DuneMapPlayersOnline {
    # Counts active players currently connected to any of the given pod
    # serverGuids (which uniquely identify a running ServerSet pod). Empty
    # serverGuids list returns 0 (no DD pod running = nobody can be there).
    # On any DB error returns -1 (caller treats as "unknown").
    param([Parameter(Mandatory)][string]$Ip, [string[]]$ServerGuids)
    if (-not $ServerGuids -or $ServerGuids.Count -eq 0) {
        return @{ count = 0; ids = @() }
    }
    try {
        $quoted = ($ServerGuids | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ','
        $sql = "SELECT player_pawn_id::text FROM encrypted_player_state WHERE online_status::text <> 'Offline' AND server_id IN ($quoted);"
        $raw = Invoke-V6Psql -Ip $Ip -Sql $sql
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{ count = 0; ids = @() } }
        if ($raw -match 'ERROR') { return @{ count = -1; ids = @(); error = $raw } }
        $ids = @($raw -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        return @{ count = $ids.Count; ids = $ids }
    } catch {
        return @{ count = -1; ids = @(); error = $_.Exception.Message }
    }
}

function _Get-DuneMapServerGuids {
    # Picks out the serverGuid values from BG status.pods whose partitionMap
    # matches the on-demand map's name pattern. Returns @() if none running.
    param([Parameter(Mandatory)]$Bg, [Parameter(Mandatory)][string]$Pattern)
    $guids = @()
    $status = $null
    try { $status = $Bg.status } catch {}
    if (-not $status) { return ,$guids }
    $pods = @()
    try { $pods = @($status.servers) } catch {}
    if (-not $pods -or $pods.Count -eq 0) { try { $pods = @($status.serverGroupStatus.pods) } catch {} }
    if (-not $pods -or $pods.Count -eq 0) { try { $pods = @($status.pods) } catch {} }
    foreach ($p in $pods) {
        if (-not $p) { continue }
        $map = $null; $guid = $null
        if ($p.PSObject.Properties['partitionMap']) { $map = [string]$p.partitionMap }
        if ($p.PSObject.Properties['serverGuid'])   { $guid = [string]$p.serverGuid }
        if ($map -and $guid -and ($map -match $Pattern)) { $guids += $guid }
    }

    return $guids
}

function _Get-DuneMapLiveServers {
    param([Parameter(Mandatory)]$Bg, [Parameter(Mandatory)][string]$Pattern)
    $servers = @()
    try { $servers = @($Bg.status.servers) } catch {}
    if (-not $servers -or $servers.Count -eq 0) { try { $servers = @($Bg.status.serverGroupStatus.pods) } catch {} }
    if (-not $servers -or $servers.Count -eq 0) { try { $servers = @($Bg.status.pods) } catch {} }
    return @($servers | Where-Object {
        $_ -and $_.PSObject.Properties['partitionMap'] -and "$($_.partitionMap)" -match $Pattern
    })
}

function _Find-DuneMapWorldPartitions {
    # Returns the indices (in spec.database.template.spec.deployment.spec.worldPartitions)
    # whose .map matches the pattern.
    param([Parameter(Mandatory)]$Bg, [Parameter(Mandatory)][string]$Pattern)
    $wps = $Bg.spec.database.template.spec.deployment.spec.worldPartitions
    $list = @()
    for ($k = 0; $k -lt $wps.Count; $k++) {
        if ([string]$wps[$k].map -match $Pattern) {
            $list += @{
                Idx        = $k
                Map        = [string]$wps[$k].map
                Partitions = @($wps[$k].partitions)
            }
        }
    }
    return ,$list
}

function Get-DuneOnDemandMapState {
    # Inspects the live BG CRD and returns the state of an on-demand map
    # (e.g. DeepDesert): is the set present, what are the current replicas,
    # are any partitions disabled, are the partition IDs bound to the set,
    # is dedicatedScaling disabled (required for self-provisioning), and
    # how many players are currently connected to the matching pod(s).
    param([Parameter(Mandatory)][string]$Key)
    $def = $script:DuneOnDemandMaps | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $def) { throw "Unknown on-demand map: $Key" }

    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message; key=$Key; label=$def.Label } }

    $info = Get-V6Battlegroup -Ip $ctx.vm.ip
    $sets = _Find-DuneMapSets         -Bg $info.Bg -Pattern $def.Pattern
    $wps  = _Find-DuneMapWorldPartitions -Bg $info.Bg -Pattern $def.Pattern
    $liveServers = @(_Get-DuneMapLiveServers -Bg $info.Bg -Pattern $def.Pattern)

    $totalReplicas = 0
    $hasDisabledPartition = $false
    $missingPartitionBinding = $false
    $stuckDedicatedScaling = $false
    foreach ($s in $sets) {
        if ($s.Replicas) { $totalReplicas += [int]$s.Replicas }
        if (-not $s.Partitions -or $s.Partitions.Count -eq 0) { $missingPartitionBinding = $true }
        if ($s.DedicatedScaling) { $stuckDedicatedScaling = $true }
    }
    foreach ($wp in $wps) {
        foreach ($p in $wp.Partitions) {
            if ($p.PSObject.Properties['disable'] -and [bool]$p.disable) { $hasDisabledPartition = $true }
        }
    }

    $present = ($sets.Count -gt 0)
    $targetInstances = 1
    if ($Key -eq 'deepdesert') {
        $ids = @{}
        foreach ($wp in $wps) {
            foreach ($p in @($wp.Partitions)) {
                if ($p.PSObject.Properties['id'] -and [int]$p.id -gt 0) { $ids[[int]$p.id] = $true }
            }
        }
        $targetInstances = [math]::Max(1, $ids.Count)
    }
    $readyInstances = @($liveServers | Where-Object {
        -not $_.PSObject.Properties['ready'] -or [bool]$_.ready
    }).Count
    # Director-driven sets legitimately keep template replicas=0 and
    # dedicatedScaling=true while status.servers reports live instances.
    $running = ($present -and $readyInstances -ge $targetInstances)

    # Player count comes from the DB and is only meaningful when at least
    # one matching pod is running (otherwise nobody can be connected).
    $playersOnline = 0
    $playerIds     = @()
    $playersError  = $null
    if ($running) {
        $guids = _Get-DuneMapServerGuids -Bg $info.Bg -Pattern $def.Pattern
        if ($guids.Count -gt 0) {
            $pr = _Get-DuneMapPlayersOnline -Ip $ctx.vm.ip -ServerGuids $guids
            if ($pr.count -lt 0) {
                $playersOnline = $null
                $playersError  = $pr.error
            } else {
                $playersOnline = [int]$pr.count
                $playerIds     = @($pr.ids)
            }
        }
    }

    return @{
        ok                       = $true
        key                      = $Key
        label                    = $def.Label
        present                  = $present
        setCount                 = $sets.Count
        totalReplicas            = $totalReplicas
        hasDisabledPart          = $hasDisabledPartition
        missingPartitionBinding  = $missingPartitionBinding
        stuckDedicatedScaling    = $stuckDedicatedScaling
        running                  = $running
        activeInstances          = $liveServers.Count
        readyInstances           = $readyInstances
        targetInstances          = $targetInstances
        playersOnline            = $playersOnline
        playerIds                = $playerIds
        playersError             = $playersError
        sets                     = @($sets | ForEach-Object { @{
            idx=$_.Idx; map=$_.Map; replicas=$_.Replicas; dedicatedScaling=$_.DedicatedScaling
            partitionCount=$_.Partitions.Count
        } })
    }
}

function Start-DuneOnDemandMap {
    # Patches the BG CRD to bring an on-demand map online:
    #   - binds each matching set's `partitions` field to the IDs from
    #     the corresponding worldPartitions[*].partitions[*].id (e.g.
    #     DeepDesert_1 -> [8]). Without this binding the operator has
    #     nothing to schedule and the pod is never created.
    #   - flips `dedicatedScaling` from true to false: the operator only
    #     auto-provisions pods (target = replicas) when this flag is false;
    #     `dedicatedScaling: true` sets stay at TARGET=0 because they expect
    #     to be scaled externally by the Director. The two always-on sets
    #     (Survival_1, Overmap) are already false in the template.
    #   - sets every matching set's `replicas` to 1 (if currently 0/missing)
    #   - clears any `disable: true` flag on matching world-partitions
    # No-op if it's already running.
    param([Parameter(Mandatory)][string]$Key)
    $def = $script:DuneOnDemandMaps | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $def) { throw "Unknown on-demand map: $Key" }

    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message; key=$Key } }

    $info = Get-V6Battlegroup -Ip $ctx.vm.ip
    $sets = _Find-DuneMapSets         -Bg $info.Bg -Pattern $def.Pattern
    $wps  = _Find-DuneMapWorldPartitions -Bg $info.Bg -Pattern $def.Pattern

    if ($sets.Count -eq 0) {
        return @{
            ok      = $false
            status  = 404
            key     = $Key
            message = "No '$($def.Label)' set found in the battlegroup CRD. Add it via the Battlegroup editor first."
        }
    }

    # Build map -> partition-id list lookup from worldPartitions, so each
    # matching set can bind to the right ID(s).
    $idsByMap = @{}
    foreach ($wp in $wps) {
        $list = @()
        foreach ($p in $wp.Partitions) {
            if ($p.PSObject.Properties['id']) { $list += [int]$p.id }
        }
        $idsByMap[$wp.Map] = $list
    }

    $patches = @()
    foreach ($s in $sets) {
        # Bind partitions field if missing or empty.
        if (-not $s.Partitions -or $s.Partitions.Count -eq 0) {
            $ids = @()
            if ($idsByMap.ContainsKey($s.Map)) { $ids = $idsByMap[$s.Map] }
            if ($ids.Count -gt 0) {
                if ($s.HasPartitionsField) {
                    $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$($s.Idx)/partitions"; value=$ids }
                } else {
                    $patches += @{ op='add';     path="/spec/serverGroup/template/spec/sets/$($s.Idx)/partitions"; value=$ids }
                }
            }
        }
        # dedicatedScaling=true sets are Director-driven and won't self-provision pods
        # (the ServerSet stays at REQUEST=N, TARGET=0). For on-demand maps we want the
        # serveroperator to provision the pod from `replicas` directly, so flip the flag
        # to false on every matching set.
        if ($s.DedicatedScaling) {
            $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$($s.Idx)/dedicatedScaling"; value=$false }
        }
        if (-not $s.Replicas -or [int]$s.Replicas -lt 1) {
            if ($null -eq $s.Replicas) {
                $patches += @{ op='add'; path="/spec/serverGroup/template/spec/sets/$($s.Idx)/replicas"; value=1 }
            } else {
                $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$($s.Idx)/replicas"; value=1 }
            }
        }
    }
    foreach ($wp in $wps) {
        for ($pi = 0; $pi -lt $wp.Partitions.Count; $pi++) {
            $p = $wp.Partitions[$pi]
            if ($p.PSObject.Properties['disable'] -and [bool]$p.disable) {
                $patches += @{
                    op    = 'replace'
                    path  = "/spec/database/template/spec/deployment/spec/worldPartitions/$($wp.Idx)/partitions/$pi/disable"
                    value = $false
                }
            }
        }
    }

    if ($patches.Count -eq 0) {
        return @{
            ok        = $true
            key       = $Key
            noop      = $true
            message   = "$($def.Label) is already configured to run (replicas >= 1, partitions bound, enabled). Pod state may still be Pending if it's still starting."
            patchOps  = 0
        }
    }

    $patchJson = $patches | ConvertTo-Json -Depth 30 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($info.Name) -n $($info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $cmd -TimeoutSec 60
    $outText = (($out -join "`n")).Trim()

    $success = ($outText -match 'patched' -and $outText -notmatch 'error|Error|ERROR')
    return @{
        ok       = $success
        key      = $Key
        label    = $def.Label
        patchOps = $patches.Count
        raw      = $outText
        message  = if ($success) {
            "$($def.Label) is starting. The pod may take 60-120 seconds to reach Ready."
        } else {
            "kubectl patch may have failed: $outText"
        }
    }
}

function _Invoke-DunePartitionAutomationInstaller {
    # Stage app/resources/remote-scripts/dune-clear-partitions-install.sh to the
    # VM and run it with sudo. The installer (re)writes the heal script
    # (/usr/local/bin/dune-clear-partitions.sh), the OpenRC boot hook
    # (/etc/local.d/dune-clear-partitions.start), and a */15 cron entry, then
    # runs the heal once in the mode given by $RunMode. All persistence logic
    # lives in the POSIX sh installer (Defender-safe); DST only stages-and-runs
    # it.
    #
    # The heal cycles a map ({replicas:0, partitions:[]}) ONLY when its
    # partitions are pinned AND no pod is Ready, so a stuck post-shutdown zombie
    # on a warm/spin-up map is cleared without ever kicking a live player. The
    # director then restores the warm floor.
    #
    # $RunMode picks the mode for the immediate run-once: 'cron' (conservative,
    # the default for the automatic app-start sync) or 'manual' (aggressive, the
    # explicit Fix Partitions button). The OpenRC boot hook always runs 'boot'.
    #
    # Returns @{ ok; output; logTail } on a completed run, or @{ ok=$false;
    # status; message } on a context/staging error (no 'output' key).
    param([ValidateSet('cron','manual','boot')][string]$RunMode = 'cron')

    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    $ip = $ctx.vm.ip

    $candidates = @(
        (Join-Path $PSScriptRoot '..\..\resources\remote-scripts\dune-clear-partitions-install.sh')                  # installed layout
        (Join-Path (Split-Path -Parent $PSScriptRoot) '..\resources\remote-scripts\dune-clear-partitions-install.sh') # dev layout fallback
    )
    $local = $null
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { $local = $p; break } }
    if (-not $local) {
        return @{ ok=$false; status=500; message='Bundled dune-clear-partitions-install.sh not found in install dir.' }
    }

    $stamp     = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $remoteTmp = "/tmp/dune-cp-install-$stamp.sh"

    # Force LF — Alpine /bin/sh chokes on CRLF.
    $raw = [System.IO.File]::ReadAllText($local)
    $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"

    # Stage over an ssh exec channel (base64 piped on stdin) rather than scp:
    # modern OpenSSH scp needs sftp-server, which some VM images don't ship.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

    $stageRaw = Invoke-V6Ssh -Ip $ip -Cmd "base64 -d > $remoteTmp && echo DUNE_STAGED_OK" -StdinData $b64 -TimeoutSec 60
    $staged   = (($stageRaw -join "`n"))
    if ($staged -notmatch 'DUNE_STAGED_OK') {
        return @{ ok=$false; status=500; message="Staging partition-heal installer over ssh failed: $($staged.Trim())" }
    }

    # $RunMode is restricted by ValidateSet to a known literal, so it is safe to
    # interpolate as the installer's first argument (chooses the run-once mode).
    $runRaw = Invoke-V6Ssh -Ip $ip -Cmd "sudo -n sh $remoteTmp $RunMode; rc=`$?; rm -f $remoteTmp; exit `$rc" -TimeoutSec 180
    $output = (($runRaw -join "`n")).Trim()

    $tailRaw = Invoke-V6Ssh -Ip $ip -Cmd 'tail -n 12 /var/log/dune-clear-partitions.log' -TimeoutSec 30
    $logTail = (($tailRaw -join "`n")).Trim()

    return @{
        ok      = ($output -match 'DUNE_CLEAR_PARTITIONS_OK')
        output  = $output
        logTail = $logTail
    }
}

function Invoke-DuneFixOnDemandPartitions {
    # Manual "Fix Partitions" action. (Re)installs the autonomous partition
    # self-heal (boot hook + */15 cron) on the VM and runs it once now in the
    # aggressive 'manual' mode (explicit user intent), clearing any stuck
    # DeepDesert / SH_Arrakeen / SH_HarkoVillage pin — even on a warm/spin-up
    # map — as long as no pod is Ready (a live session is never disturbed).
    #
    # v12.13.12: replaced the one-shot clear with the install-and-run installer
    # so the heal also keeps running autonomously (at VM boot and on a cron
    # tick) with DST closed — the previous one-shot only fired while the app was
    # open and could not clear a warm map (it skipped any set with a pod).
    $r = _Invoke-DunePartitionAutomationInstaller -RunMode 'manual'
    if (-not $r.ContainsKey('output')) { return $r }   # context / staging error
    return @{
        ok      = $r.ok
        output  = $r.output
        logTail = $r.logTail
        message = if ($r.ok) {
            'Partition self-heal ran and is now installed to run automatically (at VM boot and every 15 minutes). It clears a stuck map pin without disturbing a live session, so it is safe to run again any time a map refuses to launch.'
        } else {
            "Partition heal installer did not confirm success. Last log lines: $($r.logTail)"
        }
    }
}

function Sync-DunePartitionAutomation {
    # Idempotently ensure the autonomous partition self-heal (boot hook + */15
    # cron) is installed/refreshed on the VM. Called at server startup so the
    # heal works even with DST closed — e.g. after a host crash + VM reboot,
    # where the boot hook clears a warm map's stuck post-shutdown pin on its own.
    #
    # The immediate run-once uses the CONSERVATIVE 'cron' mode (not aggressive
    # 'boot'): DST can be launched in the middle of live play, so the app-start
    # pass must never cycle a map that is merely mid-spin-up. Only the OpenRC
    # boot hook (real VM boot, no players) and the manual Fix button run
    # aggressively.
    $r = _Invoke-DunePartitionAutomationInstaller -RunMode 'cron'
    if (-not $r.ContainsKey('output')) { return $r }
    return @{
        ok      = $r.ok
        logTail = $r.logTail
        message = if ($r.ok) {
            'Partition self-heal automation ensured on VM (boot hook + 15-min cron).'
        } else {
            "Partition self-heal automation install unconfirmed: $($r.logTail)"
        }
    }
}

function Stop-DuneOnDemandMap {
    # Gracefully shuts down an on-demand map by patching every matching
    # set's `replicas` to 0. Leaves `dedicatedScaling`, `partitions`, and
    # `worldPartitions.disable` alone so the next spin-up only has to flip
    # replicas back to 1.
    #
    # Safety: if any players are currently connected to a matching pod
    # (online_status <> 'Offline' AND server_id IN <pod guids>) the call
    # refuses with status 409 unless -Force is supplied. Frontend turns
    # that into a confirm-then-retry prompt.
    param(
        [Parameter(Mandatory)][string]$Key,
        [switch]$Force
    )
    $def = $script:DuneOnDemandMaps | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $def) { throw "Unknown on-demand map: $Key" }

    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message; key=$Key } }

    $info = Get-V6Battlegroup -Ip $ctx.vm.ip
    $sets = _Find-DuneMapSets -Bg $info.Bg -Pattern $def.Pattern

    if ($sets.Count -eq 0) {
        return @{
            ok      = $false
            status  = 404
            key     = $Key
            message = "No '$($def.Label)' set found in the battlegroup CRD."
        }
    }

    # Check active players on the matching pod(s) before pulling the rug.
    $playersOnline = 0
    $playerIds     = @()
    $guids = _Get-DuneMapServerGuids -Bg $info.Bg -Pattern $def.Pattern
    if ($guids.Count -gt 0) {
        $pr = _Get-DuneMapPlayersOnline -Ip $ctx.vm.ip -ServerGuids $guids
        if ($pr.count -ge 0) {
            $playersOnline = [int]$pr.count
            $playerIds     = @($pr.ids)
        }
    }

    if ($playersOnline -gt 0 -and -not $Force) {
        $who = if ($playerIds.Count -gt 0) { " (player_pawn_id: $($playerIds -join ', '))" } else { '' }
        return @{
            ok                   = $false
            status               = 409
            key                  = $Key
            label                = $def.Label
            requiresConfirmation = $true
            playersOnline        = $playersOnline
            playerIds            = $playerIds
            message              = "$playersOnline player(s) currently connected to $($def.Label)$who. Confirm to force shutdown — they'll be disconnected."
        }
    }

    # Build replicas=0 patches for every matching set whose replicas > 0.
    $patches = @()
    foreach ($s in $sets) {
        $r = if ($null -eq $s.Replicas) { 0 } else { [int]$s.Replicas }
        if ($r -gt 0) {
            $patches += @{ op='replace'; path="/spec/serverGroup/template/spec/sets/$($s.Idx)/replicas"; value=0 }
        }
    }

    if ($patches.Count -eq 0) {
        return @{
            ok            = $true
            key           = $Key
            label         = $def.Label
            noop          = $true
            patchOps      = 0
            playersOnline = $playersOnline
            message       = "$($def.Label) is already stopped (all matching sets have replicas = 0)."
        }
    }

    $patchJson = $patches | ConvertTo-Json -Depth 30 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($info.Name) -n $($info.Ns) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $cmd -TimeoutSec 60
    $outText = (($out -join "`n")).Trim()

    $success = ($outText -match 'patched' -and $outText -notmatch 'error|Error|ERROR')
    return @{
        ok            = $success
        key           = $Key
        label         = $def.Label
        patchOps      = $patches.Count
        forced        = [bool]$Force
        playersOnline = $playersOnline
        raw           = $outText
        message       = if ($success) {
            if ($Force -and $playersOnline -gt 0) {
                "$($def.Label) is shutting down. $playersOnline player(s) were forcibly disconnected."
            } else {
                "$($def.Label) is shutting down. Pod will terminate in a few seconds."
            }
        } else {
            "kubectl patch may have failed: $outText"
        }
    }
}

# ---------------------------------------------------------------------------
# Pod restart — delete the Kubernetes pod(s) backing a map's ServerSet so the
# operator recreates them fresh. Used by the Map SpinUp page's "Restart" buttons.
# Pod names follow <bg-id>-sg<map-suffix>-pod-<n> (see
# app/resources/remote-scripts/dune-clear-partitions-install.sh), so we match on the
# fixed "-sg-<map>-pod-" infix from the allow-list below — never on user input.
# This disconnects anyone currently on the map; the operator brings the pod(s)
# back in ~60-120 s. Survival_1 hosts the persistent Hagga overworld.
# ---------------------------------------------------------------------------
$script:DuneRestartablePods = @(
    @{ Key='survival';   Infix='-sg-survival-1-pod-';   Label='Hagga (Survival_1)' }
    @{ Key='deepdesert'; Infix='-sg-deepdesert-1-pod-'; Label='Deep Desert'        }
)

function Restart-DuneMapPods {
    param([Parameter(Mandatory)][string]$Key)
    $def = $script:DuneRestartablePods | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $def) { throw "Unknown restartable pod: $Key" }

    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message; key=$Key } }

    # Single SSH round-trip: list every pod whose name contains the fixed
    # "-sg-<map>-pod-" infix, delete each (non-blocking), and bracket the
    # output with sentinels so we can parse found / deleted counts. The infix
    # is injected via placeholder replace (not PS interpolation) and only ever
    # comes from the static allow-list above, so there's no shell injection.
    $bash = @'
set -u
KUBE="sudo kubectl"
INFIX='__INFIX__'
PODS=$($KUBE get pods -A --no-headers 2>/dev/null | awk -v f="$INFIX" 'index($2,f){print $1" "$2}')
echo "===PODS==="
if [ -n "$PODS" ]; then echo "$PODS"; fi
echo "===DELETE==="
if [ -n "$PODS" ]; then
  echo "$PODS" | while read -r ns pod; do
    [ -z "$ns" ] || [ -z "$pod" ] && continue
    $KUBE -n "$ns" delete pod "$pod" --wait=false 2>&1
  done
fi
echo "===END==="
'@
    $bash = $bash.Replace('__INFIX__', [string]$def.Infix)

    $out = Invoke-V6Ssh -Ip $ctx.vm.ip -Cmd $bash -TimeoutSec 90
    $raw = (($out -join "`n")).Trim()

    $idxPods = $raw.IndexOf('===PODS===')
    $idxDel  = $raw.IndexOf('===DELETE===')
    $idxEnd  = $raw.IndexOf('===END===')
    if ($idxPods -lt 0 -or $idxDel -lt 0 -or $idxEnd -lt 0) {
        return @{ ok=$false; status=500; key=$Key; label=$def.Label; raw=$raw; message="Pod restart returned malformed output (missing sentinels): $raw" }
    }
    $podsBlock = $raw.Substring($idxPods + '===PODS==='.Length, $idxDel - ($idxPods + '===PODS==='.Length))
    $delBlock  = $raw.Substring($idxDel  + '===DELETE==='.Length, $idxEnd - ($idxDel + '===DELETE==='.Length))

    $podNames = @(
        $podsBlock -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ } |
            ForEach-Object { ($_ -split '\s+')[1] } |
            Where-Object { $_ }
    )
    $podsFound = $podNames.Count
    $deleted   = @($delBlock -split "`n" | Where-Object { $_ -match '\bdeleted\b' }).Count

    if ($podsFound -eq 0) {
        return @{
            ok=$true; key=$Key; label=$def.Label; noop=$true
            podsFound=0; podsDeleted=0; raw=$raw
            message="No running $($def.Label) pod(s) found — nothing to restart."
        }
    }

    $errish  = ($delBlock -match 'error|Error|ERROR|forbidden|not found')
    $success = ($deleted -gt 0 -and -not $errish)
    return @{
        ok=$success; key=$Key; label=$def.Label
        podsFound=$podsFound; podsDeleted=$deleted; pods=$podNames; raw=$raw
        message = if ($success) {
            "Restarting $($def.Label): deleted $deleted pod(s) — the operator recreates them in ~60-120 s. Anyone on the map was disconnected."
        } else {
            ("Pod restart may have failed (found $podsFound, deleted $deleted): " + $delBlock.Trim())
        }
    }
}

# Game-server pods use <bg-id>-sg-<map>-pod-<n>. Restrict the rolling INI reload
# to that exact operator-owned shape so database, RabbitMQ, director, and other
# cluster services can never enter the restart set.
$script:DuneGameServerPodNameRegex = '-sg-[a-z0-9-]+-pod-[0-9]+$'

function Test-DuneGameServerPodName {
    param([string]$Name)
    return [bool]("$Name" -match $script:DuneGameServerPodNameRegex)
}

# Clean battlegroup restart. Delegates to the SAME command the Commands screen
# runs ('restart') rather than issuing its own SSH, so every caller gets the
# identical, already-proven path - including the stale bot run-flag clear that a
# battlegroup restart requires. Returns immediately; the launched command runs
# detached and the UI polls Server Health while it converges (~2-3 min).
#
# Shared by Game Config's "Apply INIs & restart" and the Landsraad control card.
# -----------------------------------------------------------------------------
# Active map partitions — which (map, dimension) pairs actually matter right now.
#
# dune.spicefield_types carries one row per (map, field-size, dimension), so a
# battlegroup that has ever run two instances of a map keeps rows for both
# dimensions forever. Displaying them ungated shows every size twice with
# nothing to tell the rows apart, which reads as duplicate data.
#
# A pair is considered active when it is LIVE (present in the battlegroup CR's
# status.servers) or PINNED (the director keeps it warm via MinServers). Live
# alone is not enough: on-demand maps like Deep Desert are legitimately down most
# of the time, and gating on live only would hide them right when an operator
# wants to tune them. Pinned alone is not enough either: always-on maps such as
# Survival_1 never appear in director.ini and so can never be pinned.
#
# ASSUMPTION: dimensionIndex is the instance index, so MinServers = N pins
# dimensions 0..N-1. That matches a multi-sietch Hagga producing dimension 1,
# but it is inferred from observed data rather than documented by Funcom.
# -----------------------------------------------------------------------------

# Spicefield rows key maps as HaggaBasin / DeepDesert; the battlegroup CR and
# director.ini use Survival_1 / DeepDesert_1. Normalise onto the CR's ids so one
# naming scheme drives Game Servers, Map Spin-Up and the spice readout.
$script:DuneSpiceMapToServerMap = @{
    'HaggaBasin' = 'Survival_1'
    'DeepDesert' = 'DeepDesert_1'
}

function ConvertTo-DuneServerMapId {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($script:DuneSpiceMapToServerMap.ContainsKey($Name)) {
        return $script:DuneSpiceMapToServerMap[$Name]
    }
    return $Name
}

function Get-DuneActiveMapPartitions {
    # Returns @{ ok; partitions = @( @{ mapId; dimensionIndex; live; pinned } ) }
    # Best-effort: a failure to read either source degrades to "unknown", and the
    # caller is expected to show everything rather than hide real data.
    param([string]$Ip)

    $live = @()
    $bg = $null
    try { $bg = (Get-V6Battlegroup -Ip $Ip).Bg } catch {}
    if ($bg) {
        $servers = @()
        try { $servers = @($bg.status.servers) } catch {}
        foreach ($s in $servers) {
            if (-not $s) { continue }
            $mapId = ''
            if ($s.PSObject.Properties['partitionMap']) { $mapId = [string]$s.partitionMap }
            if (-not $mapId) { continue }
            $dim = 0
            if ($s.PSObject.Properties['dimensionIndex']) { $dim = [int]$s.dimensionIndex }
            $live += @{ mapId = $mapId; dimensionIndex = $dim }
        }
    }

    $pins = @{}
    try {
        $spin = Get-DuneSpinUpMaps
        if ($spin.ok) {
            foreach ($m in @($spin.maps)) {
                if ([int]$m.minServers -ge 1) { $pins["$($m.map)"] = [int]$m.minServers }
            }
        }
    } catch {}

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($l in $live) {
        $out.Add([ordered]@{
            mapId          = $l.mapId
            dimensionIndex = $l.dimensionIndex
            live           = $true
            pinned         = $pins.ContainsKey($l.mapId)
        })
    }
    foreach ($mapId in $pins.Keys) {
        for ($d = 0; $d -lt $pins[$mapId]; $d++) {
            $already = $out | Where-Object { $_.mapId -eq $mapId -and [int]$_.dimensionIndex -eq $d }
            if ($already) { continue }
            $out.Add([ordered]@{
                mapId          = $mapId
                dimensionIndex = $d
                live           = $false
                pinned         = $true
            })
        }
    }

    return @{
        ok         = ($null -ne $bg)
        partitions = $out.ToArray()
    }
}

function Get-DuneUserSettingsTextSha256 {
    param([AllowEmptyString()][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DuneUserSettingsMergeDecision {
    param(
        [AllowEmptyString()][string]$Installed,
        [AllowEmptyString()][string]$Pvc,
        [AllowNull()][string]$Baseline,
        [bool]$HasBaseline = $true,
        [Parameter(Mandatory)][string]$FileName
    )

    if (-not $HasBaseline) {
        if ($Installed -cne $Pvc) {
            return @{
                ok = $false
                error = "$FileName differs between the installed source and VM Utilities, but no last-deployed baseline exists. No file was changed; reconcile the two copies before retrying."
            }
        }
        return @{ ok = $true; content = $Installed; action = 'initialize-baseline' }
    }
    if ($Installed -ceq $Pvc) {
        return @{ ok = $true; content = $Installed; action = 'identical' }
    }
    if ($Installed -ceq $Baseline) {
        return @{ ok = $true; content = $Pvc; action = 'preserve-vm-utilities' }
    }
    if ($Pvc -ceq $Baseline) {
        return @{ ok = $true; content = $Installed; action = 'deploy-installed' }
    }
    return @{
        ok = $false
        error = "$FileName changed independently in both DST and VM Utilities since the last successful deployment. No file was changed; resolve the conflict explicitly before retrying."
    }
}

function Read-DuneRemoteUserSettingsText {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Path
    )
    $encoded = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo base64 -w0 -- '$Path'" -TimeoutSec 30) -join '').Trim()
    try {
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    } catch {
        throw "Could not read $Path exactly; deployment was blocked."
    }
}

function Get-DuneUserSettingsReconciliationSnapshot {
    param([Parameter(Mandatory)][string]$Ip)

    $authority = Resolve-DuneGameConfigPaths -Ip $Ip
    if ("$($authority.source)" -ne 'installed') {
        throw 'The installed INIs are not verified authoritative; the battlegroup was not changed.'
    }

    $pvcDir = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'ls -t /var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserGame.ini 2>/dev/null | head -1 | xargs -r dirname'" -TimeoutSec 30) -join '').Trim()
    if ($pvcDir -notmatch '^/var/lib/rancher/k3s/storage/[^/]+/Saved/UserSettings$') {
        throw 'The current VM Utilities UserSettings directory could not be identified; deployment was blocked.'
    }
    $pvcGame = "$pvcDir/UserGame.ini"
    $pvcEngine = "$pvcDir/UserEngine.ini"
    $pairState = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'if test -f ''$pvcGame'' && test -f ''$pvcEngine''; then echo both; else echo incomplete; fi'" -TimeoutSec 30) -join '').Trim()
    if ($pairState -ne 'both') {
        throw 'The current VM Utilities UserGame.ini/UserEngine.ini pair is incomplete; deployment was blocked.'
    }

    $installedDir = "$($authority.game)" -replace '/[^/]+$', ''
    $baselineGame = "$installedDir/.dst-last-deployed-UserGame.ini"
    $baselineEngine = "$installedDir/.dst-last-deployed-UserEngine.ini"
    $baselineState = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'g=0; e=0; test -f ''$baselineGame'' && g=1; test -f ''$baselineEngine'' && e=1; echo `$g`$e'" -TimeoutSec 30) -join '').Trim()
    if ($baselineState -notin @('00', '11')) {
        throw 'The last-deployed UserSettings baseline is incomplete; deployment was blocked without changing either copy.'
    }

    return @{
        files = @(
            @{
                name = 'UserGame.ini'
                installedPath = "$($authority.game)"
                pvcPath = $pvcGame
                baselinePath = $baselineGame
                installed = Read-DuneRemoteUserSettingsText -Ip $Ip -Path "$($authority.game)"
                pvc = Read-DuneRemoteUserSettingsText -Ip $Ip -Path $pvcGame
                baseline = if ($baselineState -eq '11') { Read-DuneRemoteUserSettingsText -Ip $Ip -Path $baselineGame } else { $null }
            },
            @{
                name = 'UserEngine.ini'
                installedPath = "$($authority.engine)"
                pvcPath = $pvcEngine
                baselinePath = $baselineEngine
                installed = Read-DuneRemoteUserSettingsText -Ip $Ip -Path "$($authority.engine)"
                pvc = Read-DuneRemoteUserSettingsText -Ip $Ip -Path $pvcEngine
                baseline = if ($baselineState -eq '11') { Read-DuneRemoteUserSettingsText -Ip $Ip -Path $baselineEngine } else { $null }
            }
        )
        baselineExists = ($baselineState -eq '11')
    }
}

function Write-DuneRemoteUserSettingsStage {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Content
    )
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
    Invoke-V6Ssh -Ip $Ip -Cmd "base64 -d | sudo tee '$Path' > /dev/null" -StdinData $encoded -TimeoutSec 30 | Out-Null
}

function Get-DuneUserSettingsDeployTransactionScript {
    param(
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Stamp
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('set -Eeuo pipefail')
    $lines.Add("for tool in flock ln mv sha256sum sleep stat chown chmod; do command -v `"`$tool`" >/dev/null 2>&1 || { echo `"required UserSettings tool missing: `$tool`" >&2; exit 74; }; done")
    $lines.Add("exec 9>'/home/dune/.dune/download/scripts/setup/config/.dst-usersettings-deploy.lock'")
    $lines.Add("flock -n 9 || { echo 'another UserSettings deployment is active' >&2; exit 73; }")
    $lines.Add('wait_inode_closed() {')
    $lines.Add('  sudo sh -c ''')
    $lines.Add('    path=$1')
    $lines.Add('    target=$(stat -Lc "%d:%i" "$path") || exit 1')
    $lines.Add('    attempts=0')
    $lines.Add('    while [ "$attempts" -lt 15 ]; do')
    $lines.Add('      open=0')
    $lines.Add('      for dir in /proc/[0-9]*/fd; do')
    $lines.Add('        [ -d "$dir" ] || continue')
    $lines.Add('        for fd in "$dir"/*; do')
    $lines.Add('          [ -e "$fd" ] || continue')
    $lines.Add('          current=$(stat -Lc "%d:%i" "$fd" 2>/dev/null || true)')
    $lines.Add('          if [ "$current" = "$target" ]; then open=1; break 2; fi')
    $lines.Add('        done')
    $lines.Add('      done')
    $lines.Add('      [ "$open" -eq 0 ] && exit 0')
    $lines.Add('      attempts=$((attempts + 1))')
    $lines.Add('      sleep 1')
    $lines.Add('    done')
    $lines.Add('    echo "UserSettings file is still open after 15 seconds: $path" >&2')
    $lines.Add('    exit 1')
    $lines.Add('  '' sh "$1"')
    $lines.Add('}')
    $lines.Add('restore_without_overwrite() {')
    $lines.Add('  current=$1')
    $lines.Add('  merged_hash=$2')
    $lines.Add('  rollback_src=$3')
    $lines.Add('  rollback_backup=$4')
    $lines.Add('  conflict_copy=$5')
    $lines.Add('  test -f "$rollback_src" || rollback_src=$rollback_backup')
    $lines.Add('  if test -e "$current"; then')
    $lines.Add('    sudo mv "$current" "$conflict_copy" || return 0')
    $lines.Add('    if echo "$merged_hash  $conflict_copy" | sudo sha256sum -c - >/dev/null 2>&1; then')
    $lines.Add('      test ! -f "$rollback_src" || sudo ln "$rollback_src" "$current" 2>/dev/null || true')
    $lines.Add('    else')
    $lines.Add('      sudo ln "$conflict_copy" "$current" 2>/dev/null || true')
    $lines.Add('    fi')
    $lines.Add('  else')
    $lines.Add('    test ! -f "$rollback_src" || sudo ln "$rollback_src" "$current" 2>/dev/null || true')
    $lines.Add('  fi')
    $lines.Add('  test ! -f "$rollback_src" || sudo mv "$rollback_src" "$rollback_backup"')
    $lines.Add('}')
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $lines.Add("installed_mutated_$i=0")
        $lines.Add("pvc_mutated_$i=0")
        $lines.Add("baseline_mutated_$i=0")
    }
    $lines.Add('rollback() {')
    $lines.Add('  rc=$1')
    $lines.Add('  trap - ERR')
    $lines.Add('  set +e')
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $file = $Files[$i]
        if ($file.installedChanged) {
            $lines.Add("  if test `"`$installed_mutated_$i`" = 1; then")
            $lines.Add("    restore_without_overwrite '$($file.installedPath)' '$($file.mergedHash)' '$($file.installedBackup).tmp' '$($file.installedBackup)' '$($file.installedPath).dst-concurrent-$Stamp'")
            $lines.Add("    installed_mutated_$i=0")
            $lines.Add('  fi')
        }
        if ($file.pvcChanged) {
            $lines.Add("  if test `"`$pvc_mutated_$i`" = 1; then")
            $lines.Add("    restore_without_overwrite '$($file.pvcPath)' '$($file.mergedHash)' '$($file.pvcBackup).tmp' '$($file.pvcBackup)' '$($file.pvcPath).dst-concurrent-$Stamp'")
            $lines.Add("    pvc_mutated_$i=0")
            $lines.Add('  fi')
        }
        $lines.Add("  if test `"`$baseline_mutated_$i`" = 1; then")
        if ($file.baselineExists) {
            $lines.Add("    restore_without_overwrite '$($file.baselinePath)' '$($file.mergedHash)' '$($file.baselineBackup).tmp' '$($file.baselineBackup)' '$($file.baselinePath).dst-concurrent-$Stamp'")
            $lines.Add("    baseline_mutated_$i=0")
        } else {
            $lines.Add("    if test -e '$($file.baselinePath)'; then")
            $lines.Add("      sudo mv '$($file.baselinePath)' '$($file.baselinePath).dst-concurrent-$Stamp'")
            $lines.Add("      if ! echo '$($file.mergedHash)  $($file.baselinePath).dst-concurrent-$Stamp' | sudo sha256sum -c - >/dev/null 2>&1; then")
            $lines.Add("        sudo ln '$($file.baselinePath).dst-concurrent-$Stamp' '$($file.baselinePath)' 2>/dev/null || true")
            $lines.Add('      fi')
            $lines.Add('    fi')
            $lines.Add("    baseline_mutated_$i=0")
        }
        $lines.Add('  fi')
        $lines.Add("  sudo rm -f '$($file.installedStagePath)' '$($file.pvcStagePath)' '$($file.baselineStagePath)'")
    }
    $lines.Add('  exit "$rc"')
    $lines.Add('}')
    $lines.Add("trap 'rollback `$?' ERR")
    $lines.Add("trap 'rollback 129' HUP")
    $lines.Add("trap 'rollback 130' INT")
    $lines.Add("trap 'rollback 143' TERM")

    # Validate every observed input and staged output before changing a live
    # destination. Each stage lives beside its target so mv is an atomic rename.
    foreach ($file in $Files) {
        $lines.Add("echo '$($file.installedHash)  $($file.installedPath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("echo '$($file.pvcHash)  $($file.pvcPath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("echo '$($file.mergedHash)  $($file.installedStagePath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("echo '$($file.mergedHash)  $($file.pvcStagePath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("sudo cp -p '$($file.installedStagePath)' '$($file.baselineStagePath)'")
        $lines.Add("echo '$($file.mergedHash)  $($file.baselineStagePath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("sudo chown `"`$(sudo stat -c '%u:%g' '$($file.installedPath)')`" '$($file.installedStagePath)'")
        $lines.Add("sudo chmod `"`$(sudo stat -c '%a' '$($file.installedPath)')`" '$($file.installedStagePath)'")
        $lines.Add("sudo chown `"`$(sudo stat -c '%u:%g' '$($file.pvcPath)')`" '$($file.pvcStagePath)'")
        $lines.Add("sudo chmod `"`$(sudo stat -c '%a' '$($file.pvcPath)')`" '$($file.pvcStagePath)'")
        if ($file.baselineExists) {
            $lines.Add("echo '$($file.baselineHash)  $($file.baselinePath)' | sudo sha256sum -c - >/dev/null")
        }
    }

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $file = $Files[$i]
        if ($file.installedChanged) {
            $lines.Add("installed_mutated_$i=1")
            $lines.Add("sudo mv '$($file.installedPath)' '$($file.installedBackup).tmp'")
            $lines.Add("wait_inode_closed '$($file.installedBackup).tmp'")
            $lines.Add("echo '$($file.installedHash)  $($file.installedBackup).tmp' | sudo sha256sum -c - >/dev/null")
            $lines.Add("sudo ln '$($file.installedStagePath)' '$($file.installedPath)'")
            $lines.Add("echo '$($file.mergedHash)  $($file.installedPath)' | sudo sha256sum -c - >/dev/null")
            $lines.Add("sudo mv -f '$($file.installedBackup).tmp' '$($file.installedBackup)'")
        }
        if ($file.pvcChanged) {
            $lines.Add("pvc_mutated_$i=1")
            $lines.Add("sudo mv '$($file.pvcPath)' '$($file.pvcBackup).tmp'")
            $lines.Add("wait_inode_closed '$($file.pvcBackup).tmp'")
            $lines.Add("echo '$($file.pvcHash)  $($file.pvcBackup).tmp' | sudo sha256sum -c - >/dev/null")
            $lines.Add("sudo ln '$($file.pvcStagePath)' '$($file.pvcPath)'")
            $lines.Add("echo '$($file.mergedHash)  $($file.pvcPath)' | sudo sha256sum -c - >/dev/null")
            $lines.Add("sudo mv -f '$($file.pvcBackup).tmp' '$($file.pvcBackup)'")
        }
    }

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $file = $Files[$i]
        $lines.Add("echo '$($file.mergedHash)  $($file.installedPath)' | sudo sha256sum -c - >/dev/null")
        $lines.Add("echo '$($file.mergedHash)  $($file.pvcPath)' | sudo sha256sum -c - >/dev/null")
        if ($file.baselineExists) {
            $lines.Add("baseline_mutated_$i=1")
            $lines.Add("sudo mv '$($file.baselinePath)' '$($file.baselineBackup).tmp'")
            $lines.Add("echo '$($file.baselineHash)  $($file.baselineBackup).tmp' | sudo sha256sum -c - >/dev/null")
            $lines.Add("sudo ln '$($file.baselineStagePath)' '$($file.baselinePath)'")
            $lines.Add("sudo mv -f '$($file.baselineBackup).tmp' '$($file.baselineBackup)'")
        } else {
            $lines.Add("baseline_mutated_$i=1")
            $lines.Add("sudo ln '$($file.baselineStagePath)' '$($file.baselinePath)'")
        }
        $lines.Add("echo '$($file.mergedHash)  $($file.baselinePath)' | sudo sha256sum -c - >/dev/null")
    }
    $lines.Add('trap - ERR HUP INT TERM')
    foreach ($file in $Files) {
        $lines.Add("sudo rm -f '$($file.installedStagePath)' '$($file.pvcStagePath)' '$($file.baselineStagePath)'")
    }
    $lines.Add("echo '__DST_USERSETTINGS_DEPLOYED__'")
    return ($lines -join "`n")
}

function Invoke-DuneUserSettingsDeployTransaction {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$Stamp
    )
    $cmd = Get-DuneUserSettingsDeployTransactionScript -Files $Files -Stamp $Stamp
    $output = @(Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 120)
    if (-not ($output -match '^__DST_USERSETTINGS_DEPLOYED__$')) {
        $detail = ($output -join "`n").Trim()
        $suffix = if ($detail) { " Remote detail: $detail" } else { '' }
        throw "UserSettings deployment or verified readback failed; changed files were rolled back and the battlegroup was not restarted.$suffix"
    }
    return ($output -join "`n")
}

function Invoke-DuneDeployInstalledUserSettings {
    param([Parameter(Mandatory)][string]$Ip)

    if (-not (Get-Command Resolve-DuneGameConfigPaths -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; error='Game Config authority validation is unavailable; installed INIs were not deployed.' }
    }
    $stagedPaths = New-Object 'System.Collections.Generic.List[string]'
    try {
        $snapshot = Get-DuneUserSettingsReconciliationSnapshot -Ip $Ip
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
        $files = New-Object 'System.Collections.Generic.List[object]'
        $actions = @{}
        foreach ($source in @($snapshot.files)) {
            $decision = Get-DuneUserSettingsMergeDecision `
                -Installed "$($source.installed)" -Pvc "$($source.pvc)" `
                -Baseline $source.baseline -HasBaseline $snapshot.baselineExists `
                -FileName "$($source.name)"
            if (-not $decision.ok) {
                return @{ ok=$false; error=$decision.error; conflict=$true }
            }
            $actions["$($source.name)"] = "$($decision.action)"
            $files.Add(@{
                source = $source
                merged = "$($decision.content)"
            })
        }
        $transactionFiles = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $files) {
            $source = $entry.source
            $merged = "$($entry.merged)"
            $installedStagePath = "$($source.installedPath).dst-stage-$stamp"
            $pvcStagePath = "$($source.pvcPath).dst-stage-$stamp"
            $baselineStagePath = "$($source.baselinePath).dst-stage-$stamp"
            Write-DuneRemoteUserSettingsStage -Ip $Ip -Path $installedStagePath -Content $merged
            $stagedPaths.Add($installedStagePath)
            Write-DuneRemoteUserSettingsStage -Ip $Ip -Path $pvcStagePath -Content $merged
            $stagedPaths.Add($pvcStagePath)
            $installedChanged = ($merged -cne "$($source.installed)")
            $pvcChanged = ($merged -cne "$($source.pvc)")
            $transactionFiles.Add(@{
                name = "$($source.name)"
                installedPath = "$($source.installedPath)"
                pvcPath = "$($source.pvcPath)"
                baselinePath = "$($source.baselinePath)"
                installedStagePath = $installedStagePath
                pvcStagePath = $pvcStagePath
                baselineStagePath = $baselineStagePath
                installedHash = Get-DuneUserSettingsTextSha256 -Value "$($source.installed)"
                pvcHash = Get-DuneUserSettingsTextSha256 -Value "$($source.pvc)"
                mergedHash = Get-DuneUserSettingsTextSha256 -Value $merged
                baselineHash = if ($snapshot.baselineExists) { Get-DuneUserSettingsTextSha256 -Value "$($source.baseline)" } else { '' }
                baselineExists = [bool]$snapshot.baselineExists
                installedChanged = $installedChanged
                pvcChanged = $pvcChanged
                installedBackup = "$($source.installedPath).dst-reconcile-bak-$stamp"
                pvcBackup = "$($source.pvcPath).dst-reconcile-bak-$stamp"
                baselineBackup = "$($source.baselinePath).dst-reconcile-bak-$stamp"
            })
        }
        $output = Invoke-DuneUserSettingsDeployTransaction -Ip $Ip -Files $transactionFiles.ToArray() -Stamp $stamp
        return @{ ok=$true; exitCode=0; output=$output; actions=$actions; baselineInitialized=(-not $snapshot.baselineExists) }
    } catch {
        $failureMessage = $_.Exception.Message
        $cleanupFailures = New-Object 'System.Collections.Generic.List[string]'
        foreach ($path in $stagedPaths) {
            try {
                Invoke-V6Ssh -Ip $Ip -Cmd "sudo rm -f '$path'" -TimeoutSec 20 | Out-Null
            } catch {
                $cleanupFailures.Add($_.Exception.Message)
            }
        }
        if ($cleanupFailures.Count -gt 0) {
            $failureMessage = "$failureMessage Temporary staging cleanup also failed: $($cleanupFailures -join '; ')"
        }
        return @{ ok=$false; error=$failureMessage }
    }
}

function Invoke-DuneBattlegroupRestart {
    param([string]$Ip)

    # Restarting the BG cycles game state, so an in-flight seed or list-tick from
    # a prior run is moot; leaving the flag set would block fresh runs afterwards.
    if (Get-Command Clear-DuneBotStaleRunFlags -ErrorAction SilentlyContinue) {
        try { Clear-DuneBotStaleRunFlags } catch {}
    }

    # Retail's installed setup/config directory is authoritative. Push it to the
    # battlegroup before rebuilding startup arguments or restarting. Failing
    # closed here prevents a restart that claims to apply settings but actually
    # boots an older PVC copy.
    $iniDeploy = $null
    if ($Ip) {
        try { $iniDeploy = Invoke-DuneDeployInstalledUserSettings -Ip $Ip }
        catch { $iniDeploy = @{ ok=$false; error=$_.Exception.Message } }
        if (-not $iniDeploy.ok) {
            return @{
                ok        = $false
                iniDeploy = $iniDeploy
                message   = "INI deployment failed; the battlegroup was not restarted. $($iniDeploy.error)"
            }
        }
    }

    # Console variables are staged in UserEngine.ini and only reach the servers as
    # startup commands. Rebuild those commands from whatever the INI says right
    # now - however it was edited - so the restart applies the user's current
    # values and no stale command can outrank the file. Best-effort: a failure
    # here must not block the restart the user asked for.
    $startupApply = $null
    if ($Ip -and (Get-Command Sync-DuneStartupConsoleVariableOverrides -ErrorAction SilentlyContinue)) {
        try { $startupApply = Sync-DuneStartupConsoleVariableOverrides -Ip $Ip }
        catch { $startupApply = @{ ok = $false; error = $_.Exception.Message } }
    }

    $result = Invoke-DuneCommandExternal -Name 'restart'
    $message = 'Battlegroup restart launched - watch Server Health; it takes a couple of minutes to come back.'
    if ($startupApply -is [hashtable] -and $startupApply.ContainsKey('ok') -and -not $startupApply['ok']) {
        # Never report a clean apply when the startup commands were not rebuilt:
        # the restart still happens, but the user's console variables will not be
        # in force and silence here reads as "applied successfully".
        $message = "Battlegroup restart launched, but the console-variable startup commands could NOT be rebuilt: $($startupApply['error']) Your console variables are not in force until this succeeds."
    }
    return @{
        ok           = $true
        result       = $result
        iniDeploy    = $iniDeploy
        startupApply = $startupApply
        message      = $message
    }
}

function Restart-DuneGameServerPodsRolling {
    param([Parameter(Mandatory)][string]$Ip)

    # One remote script performs an all-pods health preflight before deleting
    # anything, then restarts game pods sequentially. The next pod is not touched
    # until the prior map is genuinely back.
    #
    # "Back" means the BATTLEGROUP CR reports that map ready, not just that the
    # pod passed its Kubernetes readiness probe. The pod goes Running/Ready as
    # soon as the container is up, but the game server then loads the world and
    # only later moves Startup -> Running with ready=true in the CR. Gating on
    # the pod condition alone reported success while both maps were still in
    # Startup, and let the next pod be deleted while the previous map was still
    # loading - which defeats the point of rolling one at a time and puts two
    # concurrent world loads on the host at once.
    $bash = @'
    set -u
    KUBE="sudo kubectl"
    ROWS=$($KUBE get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null)
    TARGETS=$(printf '%s\n' "$ROWS" | awk -F'|' '$2 ~ /__DUNE_GAME_SERVER_POD_REGEX__/ {print}' | sort -t'|' -k1,1 -k2,2)
    COUNT=$(printf '%s\n' "$TARGETS" | awk 'NF {n++} END {print n+0}')
    echo "===COUNT===$COUNT"
    if [ "$COUNT" -eq 0 ]; then
      echo "===NO_PODS==="
      exit 0
    fi
    BAD=$(printf '%s\n' "$TARGETS" | awk -F'|' '$3 != "Running" || $4 != "" || $5 != "True" {print $1"|"$2"|"$3"|"$4"|"$5}')
    if [ -n "$BAD" ]; then
      echo "===UNHEALTHY==="
      printf '%s\n' "$BAD"
      exit 0
    fi
    # Map slug carried by the pod name, e.g. ...-sg-survival-1-pod-1 -> survival-1.
    # The CR's partitionMap for that map is Survival_1, so compare lowercased
    # with underscores folded to hyphens.
    map_ready() {
      _ns="$1"; _slug="$2"
      $KUBE -n "$_ns" get battlegroups -o jsonpath='{range .items[*].status.servers[*]}{.partitionMap}{"|"}{.ready}{"\n"}{end}' 2>/dev/null |
        awk -F'|' -v want="$_slug" '
          { m = tolower($1); gsub(/_/, "-", m); if (m == want && $2 == "true") { found = 1 } }
          END { exit found ? 0 : 1 }
        '
    }
    printf '%s\n' "$TARGETS" | while IFS='|' read -r ns pod phase deleting ready; do
      [ -n "$ns" ] && [ -n "$pod" ] || continue
      SLUG=$(printf '%s' "$pod" | sed -n 's/.*-sg-\(.*\)-pod-[0-9][0-9]*$/\1/p')
      echo "===RESTARTING===$ns|$pod"
      if ! $KUBE -n "$ns" delete pod "$pod" --wait=true --timeout=90s 2>&1; then
        echo "===FAILED===$ns|$pod|delete"
        exit 21
      fi
      DEADLINE=$((SECONDS + 300))
      REPLACEMENT_READY=false
      while [ "$SECONDS" -lt "$DEADLINE" ]; do
        STATE=$($KUBE -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
        if [ "$STATE" = "Running|True" ]; then
          REPLACEMENT_READY=true
          break
        fi
        sleep 5
      done
      if [ "$REPLACEMENT_READY" != "true" ]; then
        echo "===FAILED===$ns|$pod|ready-timeout"
        exit 22
      fi
      # Container is up; now wait for the game server to finish loading the world
      # and for the battlegroup to report this map ready. Loading a large map can
      # take minutes, so this gets its own, longer deadline.
      if [ -n "$SLUG" ]; then
        MAP_DEADLINE=$((SECONDS + 900))
        MAP_READY=false
        while [ "$SECONDS" -lt "$MAP_DEADLINE" ]; do
          if map_ready "$ns" "$SLUG"; then
            MAP_READY=true
            break
          fi
          sleep 5
        done
        if [ "$MAP_READY" != "true" ]; then
          echo "===FAILED===$ns|$pod|map-ready-timeout"
          exit 23
        fi
      fi
      echo "===READY===$ns|$pod"
    done
    PIPE_STATUS=$?
    if [ "$PIPE_STATUS" -ne 0 ]; then exit "$PIPE_STATUS"; fi
    echo "===COMPLETE===$COUNT"
'@
    $bash = $bash.Replace('__DUNE_GAME_SERVER_POD_REGEX__', $script:DuneGameServerPodNameRegex)

    try {
        $out = Invoke-V6Ssh -Ip $Ip -Cmd $bash -TimeoutSec 3600
    } catch {
        return @{ ok=$false; status=502; restarted=0; message="Rolling game-pod reload failed: $($_.Exception.Message)" }
    }
    $raw = (($out -join "`n")).Trim()
    $count = 0
    if ($raw -match '===COUNT===(\d+)') { $count = [int]$Matches[1] }
    if ($raw -match '===NO_PODS===') {
        return @{ ok=$true; noop=$true; found=0; restarted=0; pods=@(); raw=$raw; message='No running game-server pods were found.' }
    }
    if ($raw -match '===UNHEALTHY===') {
        $bad = @($raw -split "`n" | Where-Object { $_ -match '^[a-z0-9.-]+\|[a-z0-9.-]+\|' })
        return @{
            ok=$false; status=409; found=$count; restarted=0; pods=@(); unhealthy=$bad; raw=$raw
            message='Rolling reload was not started because one or more game-server pods are not healthy and Ready.'
        }
    }
    $ready = @(
        $raw -split "`n" |
            Where-Object { $_ -match '^===READY===([^|]+)\|(.+)$' } |
            ForEach-Object {
                if ($_ -match '^===READY===([^|]+)\|(.+)$') { "$($Matches[1])/$($Matches[2])" }
            }
    )
    if ($raw -match '===FAILED===([^|]+)\|([^|]+)\|([^\r\n]+)') {
        return @{
            ok=$false; status=502; found=$count; restarted=$ready.Count; pods=$ready; raw=$raw
            message="Rolling reload stopped at $($Matches[1])/$($Matches[2]) during $($Matches[3]). Already-restarted pods finished loading."
        }
    }
    if ($raw -notmatch '===COMPLETE===(\d+)' -or $ready.Count -ne $count) {
        return @{
            ok=$false; status=502; found=$count; restarted=$ready.Count; pods=$ready; raw=$raw
            message="Rolling reload returned incomplete output (expected $count Ready pod(s), saw $($ready.Count))."
        }
    }
    return @{
        ok=$true; found=$count; restarted=$ready.Count; pods=$ready; raw=$raw
        message="Reloaded $($ready.Count) game-server pod(s) one at a time. Every map finished loading and reported ready."
    }
}
