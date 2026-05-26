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
    # Returns @( @{ Idx; Map; Partitions; Replicas; DedicatedScaling } )
    param([Parameter(Mandatory)]$Bg, [Parameter(Mandatory)][string]$Pattern)
    $matches = @()
    $sets = $Bg.spec.serverGroup.template.spec.sets
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $s = $sets[$i]
        if ([string]$s.map -match $Pattern) {
            $isDedicated = $false
            if ($s.PSObject.Properties['dedicatedScaling']) { $isDedicated = [bool]$s.dedicatedScaling }
            $replicas = $null
            if ($s.PSObject.Properties['replicas']) { $replicas = [int]$s.replicas }
            $matches += @{
                Idx              = $i
                Map              = [string]$s.map
                Partitions       = @($s.partitions)
                Replicas         = $replicas
                DedicatedScaling = $isDedicated
            }
        }
    }
    return ,$matches
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
    # are any partitions disabled.
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
    foreach ($s in $sets) { if ($s.Replicas) { $totalReplicas += [int]$s.Replicas } }
    foreach ($wp in $wps) {
        foreach ($p in $wp.Partitions) {
            if ($p.PSObject.Properties['disable'] -and [bool]$p.disable) { $hasDisabledPartition = $true }
        }
    }

    $present = ($sets.Count -gt 0)
    $running = ($present -and $totalReplicas -ge 1 -and -not $hasDisabledPartition)

    return @{
        ok                = $true
        key               = $Key
        label             = $def.Label
        present           = $present
        setCount          = $sets.Count
        totalReplicas     = $totalReplicas
        hasDisabledPart   = $hasDisabledPartition
        running           = $running
        sets              = @($sets | ForEach-Object { @{
            idx=$_.Idx; map=$_.Map; replicas=$_.Replicas; dedicatedScaling=$_.DedicatedScaling
            partitionCount=$_.Partitions.Count
        } })
    }
}

function Start-DuneOnDemandMap {
    # Patches the BG CRD to bring an on-demand map online:
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

    $patches = @()
    foreach ($s in $sets) {
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
            message   = "$($def.Label) is already configured to run (replicas >= 1, partitions enabled). Pod state may still be Pending if it's still starting."
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
