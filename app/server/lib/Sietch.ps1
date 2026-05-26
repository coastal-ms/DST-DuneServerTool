# Sietches — list / add / remove additional Survival_1 shards.
#
# Wraps app/lib/K8s.ps1 (Get-V6SietchList, Add-V6Sietch, Remove-V6Sietch).
# K8s.ps1 in turn needs Db-Postgres.ps1 (Invoke-V6Ssh + Get-V6SshKeyPath).
# Both are loaded lazily via the dot-source block below — same pattern as
# Maps.ps1.

$script:DuneSietchRamPerGB  = 12   # README: ~12 GB per sietch
$script:DuneSietchBaseGB    = 6    # database + RabbitMQ + control plane

$script:DuneK8sPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\K8s.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\K8s.ps1')
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneK8sPath = $full; break }
}
if ($script:DuneK8sPath -and -not (Get-Command Get-V6SietchList -ErrorAction SilentlyContinue)) {
    . $script:DuneK8sPath
}

function Get-DuneSietchContext {
    $ctx = @{ ok = $true }
    try { $vm = Get-DuneVmStatus } catch {
        return @{ ok=$false; status=503; message="VM status unavailable: $($_.Exception.Message)" }
    }
    if (-not $vm)        { return @{ ok=$false; status=503; message='VM status unavailable.' } }
    if (-not $vm.exists) { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running){ return @{ ok=$false; status=503; message="VM state: $($vm.state) - start the VM first." } }
    if (-not $vm.ip)     { return @{ ok=$false; status=503; message='VM is running but has no IP yet.' } }

    $cfg = Read-DuneConfig
    if (-not $cfg.SshKey -or -not (Test-Path -LiteralPath $cfg.SshKey)) {
        return @{ ok=$false; status=503; message='SSH key not configured. Set SshKey in dune-server.config or via Settings.' }
    }
    $ctx.vm = $vm
    return $ctx
}

function _Get-DuneVmAssignedRamGB {
    try {
        $vm = Get-VM -Name 'dune-awakening' -ErrorAction Stop
        return [math]::Round($vm.MemoryAssigned / 1GB, 1)
    } catch { return 0 }
}

function _Get-DuneHostRamGB {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        return [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    } catch { return 0 }
}

function Get-DuneSietchOverview {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    try {
        $info = Get-V6SietchList -Ip $ctx.vm.ip
    } catch {
        return @{ ok=$false; status=502; message="kubectl query failed: $($_.Exception.Message)" }
    }

    $vmRam   = _Get-DuneVmAssignedRamGB
    $hostRam = _Get-DuneHostRamGB
    $count   = [int]$info.SietchCount
    $estimatedAfterAddGB = $script:DuneSietchBaseGB + ($script:DuneSietchRamPerGB * ($count + 1))
    $willExceedHost = ($hostRam -gt 0 -and $estimatedAfterAddGB -gt $hostRam)

    return @{
        ok               = $true
        ns               = $info.Ns
        name             = $info.Name
        sietchCount      = $count
        sietches         = @($info.Sietches | ForEach-Object {
            @{
                setIndex    = $_.SetIndex
                map         = $_.Map
                partitions  = @($_.Partitions)
                replicas    = $_.Replicas
                memoryLimit = $_.Memory
            }
        })
        vmRamGB              = $vmRam
        hostRamGB            = $hostRam
        ramPerSietchGB       = $script:DuneSietchRamPerGB
        baseInfraGB          = $script:DuneSietchBaseGB
        estimatedAfterAddGB  = $estimatedAfterAddGB
        willExceedHostRam    = [bool]$willExceedHost
        maxPartitionId       = [int]$info.MaxPartitionId
    }
}

function Add-DuneSietch {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    try {
        $res = Add-V6Sietch -Ip $ctx.vm.ip
        return @{
            ok           = [bool]$res.Success
            partitionId  = $res.PartitionId
            sietchNumber = $res.SietchNumber
            raw          = $res.Raw
            message      = "Added sietch #$($res.SietchNumber) (partition $($res.PartitionId)). Restart the battlegroup to apply."
        }
    } catch {
        return @{ ok=$false; status=500; message="Add failed: $($_.Exception.Message)" }
    }
}

function Remove-DuneLastSietch {
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    try {
        $res = Remove-V6Sietch -Ip $ctx.vm.ip
        return @{
            ok               = [bool]$res.Success
            removedPartition = $res.RemovedPartition
            raw              = $res.Raw
            message          = "Removed sietch (partition $($res.RemovedPartition)). Restart the battlegroup to apply."
        }
    } catch {
        return @{ ok=$false; status=500; message="Remove failed: $($_.Exception.Message)" }
    }
}
