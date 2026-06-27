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
# Pattern cribbed from app/lib/K8s.ps1 (Add-V6Sietch).
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
    try { $pods = @($status.serverGroupStatus.pods) } catch {}
    if (-not $pods -or $pods.Count -eq 0) {
        try { $pods = @($status.pods) } catch {}
    }
    foreach ($p in $pods) {
        if (-not $p) { continue }
        $map = $null; $guid = $null
        if ($p.PSObject.Properties['partitionMap']) { $map = [string]$p.partitionMap }
        if ($p.PSObject.Properties['serverGuid'])   { $guid = [string]$p.serverGuid }
        if ($map -and $guid -and ($map -match $Pattern)) { $guids += $guid }
    }
    return ,$guids
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
    $running = ($present -and $totalReplicas -ge 1 -and -not $hasDisabledPartition -and -not $missingPartitionBinding -and -not $stuckDedicatedScaling)

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
