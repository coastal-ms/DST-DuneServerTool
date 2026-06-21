# Pods.ps1
# Read-only Kubernetes pod inspector for the Pods page (mirrors the dune-admin
# "pods" view, but built straight from kubectl over SSH - no shared code).
#
# Two reads:
#   Get-DunePodsList                       -> all pods across namespaces
#   Get-DunePodEvents -Namespace -Name     -> events + a describe tail for one pod
#
# VM-gated through Get-DuneBackupContext (defined in BackupSchedule.ps1). All
# kubectl calls run via `sudo kubectl` over SSH, same transport the broadcast
# and backup features already use.

# List every pod in the cluster with the columns the UI needs. Uses JSON output
# so we don't have to parse kubectl's whitespace-aligned table.
function Get-DunePodsList {
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        return @{ ok = $false; status = $ctx.status; message = $ctx.message }
    }
    $cmd = 'sudo kubectl get pods --all-namespaces -o json 2>/dev/null'
    try {
        $raw = Invoke-V6Ssh -Ip $ctx.ip -Cmd $cmd -TimeoutSec 30
    } catch {
        return @{ ok = $false; status = 502; message = "kubectl get pods failed: $($_.Exception.Message)" }
    }
    $text = if ($raw) { ($raw -join "`n").Trim() } else { '' }
    if (-not $text) {
        return @{ ok = $false; status = 502; message = 'No output from kubectl (cluster may not be ready).' }
    }
    $obj = $null
    try { $obj = $text | ConvertFrom-Json -ErrorAction Stop } catch {
        return @{ ok = $false; status = 502; message = "Could not parse kubectl JSON: $($_.Exception.Message)" }
    }

    $pods = @()
    foreach ($item in @($obj.items)) {
        $ns   = [string]$item.metadata.namespace
        $name = [string]$item.metadata.name
        $node = if ($item.spec.PSObject.Properties['nodeName']) { [string]$item.spec.nodeName } else { '' }
        $phase = if ($item.status.PSObject.Properties['phase']) { [string]$item.status.phase } else { '' }
        $podIp = if ($item.status.PSObject.Properties['podIP']) { [string]$item.status.podIP } else { '' }
        $start = if ($item.status.PSObject.Properties['startTime']) { [string]$item.status.startTime } else { '' }

        $containers = @($item.status.containerStatuses)
        $total = if ($item.spec.PSObject.Properties['containers']) { @($item.spec.containers).Count } else { $containers.Count }
        $readyCount = 0
        $restarts = 0
        $waitReason = ''
        foreach ($c in $containers) {
            if ($c.ready) { $readyCount++ }
            try { $restarts += [int]$c.restartCount } catch {}
            if ($c.state -and $c.state.PSObject.Properties['waiting'] -and $c.state.waiting -and $c.state.waiting.PSObject.Properties['reason']) {
                if (-not $waitReason) { $waitReason = [string]$c.state.waiting.reason }
            }
            if ($c.state -and $c.state.PSObject.Properties['terminated'] -and $c.state.terminated -and $c.state.terminated.PSObject.Properties['reason']) {
                if (-not $waitReason) { $waitReason = [string]$c.state.terminated.reason }
            }
        }
        # A pod whose containers are waiting/terminated shows the reason (e.g.
        # CrashLoopBackOff) as its display status, matching `kubectl get pods`.
        $display = if ($waitReason) { $waitReason } else { $phase }

        $pods += [pscustomobject]@{
            namespace = $ns
            name      = $name
            ready     = "$readyCount/$total"
            status    = $display
            phase     = $phase
            restarts  = $restarts
            node      = $node
            ip        = $podIp
            startTime = $start
        }
    }

    $pods = $pods | Sort-Object namespace, name
    return @{ ok = $true; pods = @($pods); count = @($pods).Count }
}

# Events + a describe tail for a single pod. Namespace/name are validated to
# safe k8s identifier characters before being interpolated into the SSH command.
function Get-DunePodEvents {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Name
    )
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        return @{ ok = $false; status = $ctx.status; message = $ctx.message }
    }
    if ($Namespace -notmatch '^[a-z0-9][a-z0-9.-]{0,253}$') {
        return @{ ok = $false; status = 400; message = 'Invalid namespace.' }
    }
    if ($Name -notmatch '^[a-z0-9][a-z0-9.-]{0,253}$') {
        return @{ ok = $false; status = 400; message = 'Invalid pod name.' }
    }

    $eventsCmd = "sudo kubectl get events -n $Namespace --field-selector involvedObject.name=$Name -o json 2>/dev/null"
    $events = @()
    try {
        $raw = Invoke-V6Ssh -Ip $ctx.ip -Cmd $eventsCmd -TimeoutSec 30
        $text = if ($raw) { ($raw -join "`n").Trim() } else { '' }
        if ($text) {
            $obj = $text | ConvertFrom-Json -ErrorAction Stop
            foreach ($e in @($obj.items)) {
                $last = ''
                foreach ($p in @('lastTimestamp','eventTime','firstTimestamp')) {
                    if ($e.PSObject.Properties[$p] -and $e.$p) { $last = [string]$e.$p; break }
                }
                $src = ''
                if ($e.PSObject.Properties['source'] -and $e.source -and $e.source.PSObject.Properties['component']) {
                    $src = [string]$e.source.component
                } elseif ($e.PSObject.Properties['reportingComponent']) {
                    $src = [string]$e.reportingComponent
                }
                $events += [pscustomobject]@{
                    type    = if ($e.PSObject.Properties['type']) { [string]$e.type } else { '' }
                    reason  = if ($e.PSObject.Properties['reason']) { [string]$e.reason } else { '' }
                    message = if ($e.PSObject.Properties['message']) { [string]$e.message } else { '' }
                    count   = if ($e.PSObject.Properties['count']) { [int]$e.count } else { 1 }
                    time    = $last
                    source  = $src
                }
            }
        }
    } catch {
        return @{ ok = $false; status = 502; message = "kubectl get events failed: $($_.Exception.Message)" }
    }

    # Best-effort describe tail (handy when there are no events). Non-fatal.
    $describe = ''
    try {
        $descCmd = "sudo kubectl describe pod -n $Namespace $Name 2>/dev/null | tail -n 60"
        $rawd = Invoke-V6Ssh -Ip $ctx.ip -Cmd $descCmd -TimeoutSec 30
        $describe = if ($rawd) { ($rawd -join "`n").Trim() } else { '' }
    } catch {}

    # Newest first.
    $events = $events | Sort-Object { try { [datetime]::Parse($_.time) } catch { [datetime]::MinValue } } -Descending
    return @{
        ok        = $true
        namespace = $Namespace
        name      = $Name
        events    = @($events)
        describe  = $describe
    }
}
