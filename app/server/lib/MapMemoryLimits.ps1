# -----------------------------------------------------------------------------
# MapMemoryLimits.ps1
#
# Read and repair the battlegroup's per-map memory limits
# (spec.serverGroup.template.spec.sets[i].resources.limits.memory).
#
# Why this exists: Funcom's experimental swap preset (experimental_swap.sh,
# installed by the 20 GB VM preset) rewrites every map's memory limit to a
# crushed value - Hagga 12Gi -> 1Gi, Overmap 2Gi -> 200Mi, Deep Desert 15Gi ->
# 10Gi and so on. Those values are STICKY: resizing the VM from 20 GB to 49 GB
# does not revert them and produces no feedback either way, so an operator with
# plenty of RAM can be running Overland capped at 1 GB and only see it as
# "maps start, then misbehave under load".
#
# Until now the only detection/repair for this was scripts/dune-swap-doctor.sh,
# a maintainer-only file that is not shipped in the installer and is not
# referenced anywhere in the application - so the people who need it cannot run
# it. This module carries the same template defaults (Get-DuneMapMemoryDefaults
# in VmMemoryPressure.ps1) and the same "only patch values BELOW the default"
# rule, reachable from the UI.
#
# Deliberately narrower than the shell script: it only patches memory limits.
# It never stops k3s, never touches swap, /etc/fstab or kubelet configs - those
# are disruptive host-level changes that should stay a manual, supervised
# operation.
#
# Public entry points:
#   - Get-DuneMapMemoryLimitReport  -> current vs default for every map.
#   - Restore-DuneMapMemoryLimits   -> patch drifted maps back to default.
# -----------------------------------------------------------------------------

function _Get-DuneMapLimitContext {
    # Resolve VM + battlegroup once for both entry points. Mirrors
    # Get-DuneMapsContext's failure shapes so the routes can pass status through.
    if (-not (Get-Command Get-DuneMapsContext -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='Maps helper not loaded.' }
    }
    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return $ctx }
    if (-not (Get-Command Get-V6Battlegroup -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='Kubernetes helper not loaded.' }
    }
    $info = $null
    try { $info = Get-V6Battlegroup -Ip $ctx.vm.ip } catch {
        return @{ ok=$false; status=503; message="Could not read the battlegroup: $($_.Exception.Message)" }
    }
    if (-not $info -or -not $info.Name) {
        return @{ ok=$false; status=503; message='No battlegroup found on the VM.' }
    }
    return @{ ok=$true; vm=$ctx.vm; info=$info }
}

function _Get-DuneMapLimitSets {
    # Returns @( @{ Idx; Map; Limit; HasResources } ) straight off the CR.
    param([Parameter(Mandatory)]$Bg)
    $out = @()
    $sets = $Bg.spec.serverGroup.template.spec.sets
    if (-not $sets) { return ,$out }
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $s = $sets[$i]
        $limit = ''
        $hasRes = $false
        if ($s.PSObject.Properties['resources'] -and $null -ne $s.resources) {
            $hasRes = $true
            if ($s.resources.PSObject.Properties['limits'] -and $null -ne $s.resources.limits -and
                $s.resources.limits.PSObject.Properties['memory']) {
                $limit = [string]$s.resources.limits.memory
            }
        }
        $out += @{ Idx = $i; Map = [string]$s.map; Limit = $limit; HasResources = $hasRes }
    }
    return ,$out
}

function Get-DuneMapMemoryLimitReport {
    # Current per-map memory limit vs the Funcom world-template default, plus
    # the subset that has drifted BELOW its default (the repairable set).
    $ctx = _Get-DuneMapLimitContext
    if (-not $ctx.ok) { return $ctx }

    $entries = @()
    foreach ($s in (_Get-DuneMapLimitSets -Bg $ctx.info.Bg)) {
        $e = New-DuneMapLimitEntry -Map $s.Map -Limit $s.Limit
        $e.idx = $s.Idx
        $entries += $e
    }
    $drifted = @($entries | Where-Object { $_.drifted })
    return @{
        ok          = $true
        battlegroup = $ctx.info.Name
        namespace   = $ctx.info.Ns
        ip          = $ctx.vm.ip
        entries     = $entries
        drifted     = $drifted
        swapMode    = (@($entries | Where-Object { $_.swapModeValue }).Count -gt 0)
    }
}

function Restore-DuneMapMemoryLimits {
    # Patch every map whose limit is BELOW its Funcom template default back to
    # that default. Values ABOVE the default are left alone - an operator who
    # deliberately raised Hagga should keep their setting.
    $report = Get-DuneMapMemoryLimitReport
    if (-not $report.ok) { return $report }

    $drifted = @($report.drifted)
    if ($drifted.Count -eq 0) {
        return @{
            ok       = $true
            noop     = $true
            patched  = @()
            message  = 'Every per-map memory limit already matches (or exceeds) its Funcom template default. Nothing to change.'
        }
    }

    $patches = @()
    foreach ($d in $drifted) {
        $patches += @{
            op    = 'replace'
            path  = "/spec/serverGroup/template/spec/sets/$($d.idx)/resources"
            value = @{ limits = @{ memory = $d.expected } }
        }
    }

    $patchJson = $patches | ConvertTo-Json -Depth 30 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    $cmd = "sudo kubectl patch battlegroup $($report.battlegroup) -n $($report.namespace) --type=json -p `"`$(echo $b64 | base64 -d)`" 2>&1"
    $out = Invoke-V6Ssh -Ip $report.ip -Cmd $cmd -TimeoutSec 60
    $outText = (($out -join "`n")).Trim()
    $success = ($outText -match 'patched' -and $outText -notmatch 'error|Error|ERROR')

    return @{
        ok      = $success
        noop    = $false
        patched = @($drifted | ForEach-Object { @{ map=$_.map; from=$_.limit; to=$_.expected } })
        raw     = $outText
        message = if ($success) {
            "Restored $($drifted.Count) map memory limit(s) to Funcom template defaults. Restart the battlegroup so the map pods come up with the new limits."
        } else {
            "kubectl patch may have failed: $outText"
        }
    }
}
