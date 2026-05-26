# Links — resolve in-VM web URLs (File Browser, Battlegroup Director).
#
# File Browser is always at http://<vm-ip>:18888/ when the VM is up.
# Director runs inside Kubernetes; the nodePort that maps to its 11717
# service port is dynamic. We resolve it via SSH→kubectl and cache the
# result for 60 seconds so polling the Server Health page stays cheap.

$script:DuneDirectorPortCache  = $null
$script:DuneDirectorPortCacheT = $null
$script:DuneDirectorPortCacheI = $null  # last-resolved VM IP

function Get-DuneLinksContext {
    $ctx = @{ ok = $true }
    try {
        $vm = Get-DuneVmStatus
    } catch {
        return @{ ok=$false; status=503; message="VM status unavailable: $($_.Exception.Message)" }
    }
    if (-not $vm)            { return @{ ok=$false; status=503; message='VM status unavailable.' } }
    if (-not $vm.exists)     { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running)    { return @{ ok=$false; status=503; message="VM state: $($vm.state) - start the VM first." } }
    if (-not $vm.ip)         { return @{ ok=$false; status=503; message='VM is running but has no IP yet.' } }
    $ctx.vm = $vm
    return $ctx
}

function Get-DuneDirectorPort {
    param([Parameter(Mandatory)][string]$Ip, [switch]$Force)

    if (-not $Force `
        -and $script:DuneDirectorPortCache `
        -and $script:DuneDirectorPortCacheI -eq $Ip `
        -and ((Get-Date) - $script:DuneDirectorPortCacheT).TotalSeconds -lt 60) {
        return $script:DuneDirectorPortCache
    }

    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        throw 'SSH helper not loaded.'
    }

    $raw = Invoke-V6Ssh -Ip $Ip -TimeoutSec 10 -Cmd `
        "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>/dev/null"
    if (-not $raw) { return $null }
    $m = [regex]::Match([string]($raw -join ' '), '\d{4,6}')
    if (-not $m.Success) { return $null }
    $port = [int]$m.Value

    $script:DuneDirectorPortCache  = $port
    $script:DuneDirectorPortCacheT = Get-Date
    $script:DuneDirectorPortCacheI = $Ip
    return $port
}

function Get-DuneLinks {
    param([switch]$Force)

    $result = @{
        vmRunning = $false
        bgRunning = $false
        fileBrowser = @{ available=$false; url=$null; reason='VM not running' }
        director    = @{ available=$false; url=$null; reason='Battlegroup not running' }
    }

    $ctx = Get-DuneLinksContext
    if (-not $ctx.ok) {
        $result.fileBrowser.reason = $ctx.message
        $result.director.reason    = $ctx.message
        return $result
    }

    $vm = $ctx.vm
    $result.vmRunning = $true
    $result.fileBrowser = @{
        available = $true
        url       = "http://$($vm.ip):18888/"
        reason    = $null
    }

    # Director needs BG running.
    $bgRunning = $false
    try {
        $snap = $null
        if (Get-Command Get-DuneBattlegroupSnapshot -ErrorAction SilentlyContinue) {
            $snap = Get-DuneBattlegroupSnapshot
        }
        if ($snap -and $snap.available) {
            $state = $null
            if (Get-Command Get-BgStateFromStatusText -ErrorAction SilentlyContinue) {
                $state = Get-BgStateFromStatusText $snap.output
            }
            if ($state -eq 'Running') { $bgRunning = $true }
        }
    } catch { }
    $result.bgRunning = $bgRunning

    if (-not $bgRunning) {
        $result.director.reason = 'Battlegroup not running'
        return $result
    }

    try {
        $port = Get-DuneDirectorPort -Ip $vm.ip -Force:$Force
        if ($port) {
            $result.director = @{
                available = $true
                url       = "http://$($vm.ip):$port/"
                reason    = $null
            }
        } else {
            $result.director.reason = 'Director service port not found yet — try again in a moment.'
        }
    } catch {
        $result.director.reason = "Director port lookup failed: $($_.Exception.Message)"
    }

    return $result
}
