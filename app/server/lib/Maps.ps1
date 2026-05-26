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
# K8s.ps1 is dot-sourced via Characters.ps1's load order, which also pulls
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
    @{ Key='deepdesert'; Pattern='^DeepDesert'; Label='Deep Desert' }
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
