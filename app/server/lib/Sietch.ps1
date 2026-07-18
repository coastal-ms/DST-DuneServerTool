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
    $names = @{}
    try { $names = Get-V6SietchNames -Ip $ctx.vm.ip } catch { $names = @{} }

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
        named            = [bool]($names.Keys.Count -gt 0)
        sietches         = @($info.Sietches | ForEach-Object {
            $partId = [int]$_.PartitionId
            @{
                setIndex     = $_.SetIndex
                sietchNumber = $_.SietchNumber
                map          = $_.Map
                partitionId  = $partId
                partitions   = @($_.Partitions)
                replicas     = $_.Replicas
                memoryLimit  = $_.Memory
                name         = if ($names.ContainsKey($partId)) { [string]$names[$partId] } else { $null }
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
        if (-not $res.Success) {
            $why = if ($res.Error) { $res.Error } else { 'the battlegroup rejected the change.' }
            return @{ ok=$false; status=502; message="Add sietch failed: $why"; raw=$res.Raw }
        }
        return @{
            ok           = $true
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
        if (-not $res.Success) {
            $why = if ($res.Error) { $res.Error } else { 'the battlegroup rejected the change.' }
            return @{ ok=$false; status=502; message="Remove sietch failed: $why"; raw=$res.Raw }
        }
        return @{
            ok               = $true
            removedPartition = $res.RemovedPartition
            raw              = $res.Raw
            message          = "Removed sietch (partition $($res.RemovedPartition)). Restart the battlegroup to apply."
        }
    } catch {
        return @{ ok=$false; status=500; message="Remove failed: $($_.Exception.Message)" }
    }
}

# Toggle the GLOBAL Bgd.ServerDisplayName line in the live UserEngine.ini (the
# same file DST's Game Config > Server Display Name manages, at
# .../Saved/UserSettings/UserEngine.ini). CommentOut=$true disables the global
# name so per-sietch names win; $false re-enables it (Funcom global-name cascade).
function Set-DuneSietchGlobalNameOverride {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][bool]$CommentOut)
    $glob = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings'
    if ($CommentOut) {
        $sed = 's/^\([[:space:]]*\)\(Bgd\.ServerDisplayName[[:space:]]*=\)/\1;\2/'
    } else {
        $sed = 's/^\([[:space:]]*\);\+[[:space:]]*\(Bgd\.ServerDisplayName[[:space:]]*=\)/\1\2/'
    }
    $sh = "dir=`$(ls -t $glob/UserGame.ini 2>/dev/null | head -1 | xargs -r dirname); f=`"`$dir/UserEngine.ini`"; if [ -f `"`$f`" ]; then sudo sed -i '$sed' `"`$f`" && echo ok || echo sed_failed; else echo no_ini; fi"
    return ((Invoke-V6Ssh -Ip $Ip -Cmd $sh -TimeoutSec 30) -join ' ').Trim()
}

# Kick off a clean battlegroup restart detached so the HTTP request returns
# promptly; the UI polls Server Health for the result (~2-3 min to converge).
function _Invoke-DuneSietchRestart {
    param([Parameter(Mandatory)][string]$Ip)
    $cmd = 'nohup /home/dune/.dune/bin/battlegroup restart >/tmp/dst-sietch-restart.log 2>&1 & echo started'
    return ((Invoke-V6Ssh -Ip $Ip -Cmd $cmd -TimeoutSec 30) -join ' ').Trim()
}

# Reconfigure Hagga (Survival_1) to run exactly $Count sietches, optionally naming
# each, then clean-restart the battlegroup. Single entry point for the Sietches
# config page. Names apply only when $ApplyNames AND $Count>=2; reverting to 1 (or
# unchecking) clears per-partition names and re-enables the global INI name.
function Set-DuneSietchConfig {
    param(
        [Parameter(Mandatory)][int]$Count,
        [string[]]$Names,
        [bool]$ApplyNames = $false
    )
    $ctx = Get-DuneSietchContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }
    if ($Count -lt 1 -or $Count -gt 6) { return @{ ok=$false; status=400; message='Sietch count must be between 1 and 6.' } }

    $useNames = ($ApplyNames -and $Count -ge 2)
    $crdNames = if ($useNames) { $Names } else { $null }

    try {
        # 1. INI: checked -> comment out global name (per-sietch names win);
        #    unchecked/revert -> re-enable it (Funcom global-name cascade).
        $iniState = Set-DuneSietchGlobalNameOverride -Ip $ctx.vm.ip -CommentOut $useNames

        # 2. CRD: set active+max servers to N (+ per-partition names or clear).
        $res = Set-V6SietchConfig -Ip $ctx.vm.ip -Count $Count -Names $crdNames
        if (-not $res.Success) {
            $why = if ($res.Error) { $res.Error } else { 'the battlegroup rejected the change.' }
            return @{ ok=$false; status=502; message="Apply sietch config failed: $why"; raw=$res.Raw }
        }

        # 3. Clean battlegroup restart (detached; UI polls Server Health).
        $restart = _Invoke-DuneSietchRestart -Ip $ctx.vm.ip

        $noun = if ($Count -ne 1) { "$Count Hagga sietches" } else { '1 Hagga sietch' }
        return @{
            ok       = $true
            count    = $res.Count
            sietches = $res.Sietches
            named    = $useNames
            iniState = $iniState
            restart  = $restart
            message  = "Configured $noun. A clean battlegroup restart is underway - watch Server Health; it takes a couple of minutes to come back."
        }
    } catch {
        return @{ ok=$false; status=500; message="Apply sietch config failed: $($_.Exception.Message)" }
    }
}
