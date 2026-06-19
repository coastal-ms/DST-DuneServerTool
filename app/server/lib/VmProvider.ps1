# VmProvider.ps1 — platform-neutral VM lifecycle + host facts.
#
# DST manages a single VM that runs the Dune: Awakening dedicated server (k3s).
# On Windows that VM is a Hyper-V guest; on Linux it is a libvirt/KVM domain.
# Either way DST only ever READS the VM's state/IP/RAM and POWERS it on/off — it
# never provisions one. This module is the single seam where those operations
# branch by OS, so the rest of the codebase (Status, Sietch, Setup, the CLI)
# stays platform-agnostic.
#
# Windows code paths are the original Hyper-V calls, moved here verbatim, so the
# shipping Windows behaviour is unchanged. Linux paths shell out to `virsh`.
#
# Returned VM-info shape (superset used by all callers):
#   @{ exists; name; state; running; ip; uptime; assignedRamGB; provider; error }

# ---------------------------------------------------------------------------
# Config-backed settings (all optional; sane defaults).
# ---------------------------------------------------------------------------

function Get-DuneVmName {
    $name = $null
    try {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.Contains('VmName') -and $cfg['VmName']) { $name = [string]$cfg['VmName'] }
        }
    } catch { }
    if (-not $name) { $name = 'dune-awakening' }
    return $name
}

function Get-DuneLibvirtUri {
    $uri = $null
    try {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.Contains('LibvirtUri') -and $cfg['LibvirtUri']) { $uri = [string]$cfg['LibvirtUri'] }
        }
    } catch { }
    if (-not $uri) { $uri = 'qemu:///system' }
    return $uri
}

# When ServerHost is set, DST talks to that host directly over SSH and treats VM
# discovery as unnecessary (remote box, or an always-on local guest with a fixed
# address). Returns $null when unset.
function Get-DuneServerHostOverride {
    try {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.Contains('ServerHost') -and $cfg['ServerHost']) {
                return ([string]$cfg['ServerHost']).Trim()
            }
        }
    } catch { }
    return $null
}

# ---------------------------------------------------------------------------
# Tooling availability — replaces the bare `Get-Command Get-VM` preflight.
# ---------------------------------------------------------------------------

function Test-DuneVmToolingAvailable {
    if (Test-DuneIsWindows) {
        return [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    }
    return [bool](Get-Command virsh -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# virsh helper (Linux).
# ---------------------------------------------------------------------------

function Invoke-DuneVirsh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $uri = Get-DuneLibvirtUri
    $full = @('-c', $uri) + $Arguments
    $out = ''
    $exit = -1
    try {
        $out = (& virsh @full 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    } catch {
        $out = $_.Exception.Message
        $exit = -1
    }
    return [pscustomobject]@{ Exit = $exit; Output = $out.TrimEnd() }
}

function _ConvertFrom-DuneVirshState {
    param([string]$Raw)
    $s = ($Raw | Out-String).Trim().ToLowerInvariant()
    switch -Regex ($s) {
        '^running'        { return @{ state = 'Running';  running = $true  } }
        '^idle'           { return @{ state = 'Running';  running = $true  } }
        '^paused'         { return @{ state = 'Paused';   running = $false } }
        '^pmsuspended'    { return @{ state = 'Suspended';running = $false } }
        '^in shutdown'    { return @{ state = 'Stopping'; running = $false } }
        '^shut off'       { return @{ state = 'Off';      running = $false } }
        '^crashed'        { return @{ state = 'Crashed';  running = $false } }
        default           { return @{ state = 'Unknown';  running = $false } }
    }
}

# Pull the first IPv4 a libvirt domain exposes. Tries the guest agent first
# (exact, needs qemu-guest-agent in the VM), then the DHCP lease table, then the
# host ARP cache — mirrors how a human would hunt the address down.
function _Get-DuneVirshDomainIp {
    param([string]$Name)
    foreach ($source in @('agent', 'lease', 'arp')) {
        $r = Invoke-DuneVirsh -Arguments @('domifaddr', $Name, '--source', $source)
        if ($r.Exit -eq 0 -and $r.Output) {
            foreach ($line in ($r.Output -split "`n")) {
                # e.g. "vnet0  52:54:00:..  ipv4  192.168.122.42/24"
                if ($line -match 'ipv4\s+(\d{1,3}(?:\.\d{1,3}){3})') { return $Matches[1] }
                if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})/\d+') { return $Matches[1] }
            }
        }
    }
    return $null
}

function _Get-DuneVirshAssignedRamGB {
    param([string]$Name)
    $r = Invoke-DuneVirsh -Arguments @('dominfo', $Name)
    if ($r.Exit -ne 0 -or -not $r.Output) { return 0 }
    $usedKiB = 0; $maxKiB = 0
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match '^\s*Used memory:\s*([0-9]+)\s*KiB') { $usedKiB = [int64]$Matches[1] }
        elseif ($line -match '^\s*Max memory:\s*([0-9]+)\s*KiB') { $maxKiB = [int64]$Matches[1] }
    }
    $kib = if ($usedKiB -gt 0) { $usedKiB } else { $maxKiB }
    if ($kib -le 0) { return 0 }
    return [math]::Round($kib / 1048576, 1)   # KiB -> GiB
}

# ---------------------------------------------------------------------------
# Get-DuneVmInfo — the central read. Branches Windows/Linux.
# ---------------------------------------------------------------------------

function Get-DuneVmInfo {
    param([string]$Name)
    $name = if ($Name) { $Name } else { Get-DuneVmName }

    # Explicit host override (any OS, but only set on Linux today): manage the
    # configured host directly; no hypervisor query. State is assumed running
    # since the operator pointed us at a live server — SSH-level checks elsewhere
    # surface real reachability.
    $override = Get-DuneServerHostOverride
    if ($override) {
        return @{
            exists        = $true
            name          = $name
            state         = 'Running'
            running       = $true
            ip            = $override
            uptime        = 0
            assignedRamGB = 0
            provider      = 'static'
        }
    }

    if (Test-DuneIsWindows) {
        # --- Hyper-V (original Status.ps1 logic, verbatim) ---
        try {
            $vm = Get-VM -Name $name -ErrorAction Stop
            $ip = ($vm | Get-VMNetworkAdapter).IPAddresses |
                  Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            return @{
                exists        = $true
                name          = $name
                state         = $vm.State.ToString()
                running       = ($vm.State -eq 'Running')
                ip            = $ip
                uptime        = if ($vm.Uptime) { [int]$vm.Uptime.TotalSeconds } else { 0 }
                assignedRamGB = [math]::Round($vm.MemoryAssigned / 1GB, 1)
                provider      = 'hyperv'
            }
        } catch {
            return @{
                exists        = $false
                name          = $name
                state         = 'NotFound'
                running       = $false
                ip            = $null
                uptime        = 0
                assignedRamGB = 0
                provider      = 'hyperv'
                error         = $_.Exception.Message
            }
        }
    }

    # --- libvirt / KVM (Linux) ---
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
        return @{
            exists        = $false
            name          = $name
            state         = 'NotFound'
            running       = $false
            ip            = $null
            uptime        = 0
            assignedRamGB = 0
            provider      = 'libvirt'
            error         = 'virsh not found. Install libvirt-clients, or set ServerHost in dune-server.config to manage an existing host over SSH.'
        }
    }

    $st = Invoke-DuneVirsh -Arguments @('domstate', $name)
    if ($st.Exit -ne 0) {
        # Domain not defined, or libvirt unreachable (permissions / daemon down).
        $msg = if ($st.Output -match '(?i)failed to (get domain|connect)') { $st.Output } else { "libvirt domain '$name' not found ($($st.Output))" }
        return @{
            exists        = $false
            name          = $name
            state         = 'NotFound'
            running       = $false
            ip            = $null
            uptime        = 0
            assignedRamGB = 0
            provider      = 'libvirt'
            error         = $msg
        }
    }

    $stateMap = _ConvertFrom-DuneVirshState -Raw $st.Output
    $ip = if ($stateMap.running) { _Get-DuneVirshDomainIp -Name $name } else { $null }
    return @{
        exists        = $true
        name          = $name
        state         = $stateMap.state
        running       = $stateMap.running
        ip            = $ip
        uptime        = 0
        assignedRamGB = _Get-DuneVirshAssignedRamGB -Name $name
        provider      = 'libvirt'
    }
}

# ---------------------------------------------------------------------------
# Host physical RAM (GB). Windows: CIM. Linux: /proc/meminfo.
# ---------------------------------------------------------------------------

function Get-DuneHostRamGB {
    if (Test-DuneIsWindows) {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            return [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        } catch { return 0 }
    }
    try {
        $line = Get-Content -LiteralPath '/proc/meminfo' -ErrorAction Stop |
                Where-Object { $_ -match '^MemTotal:\s*([0-9]+)\s*kB' } | Select-Object -First 1
        if ($line -match '^MemTotal:\s*([0-9]+)\s*kB') {
            return [math]::Round([int64]$Matches[1] / 1048576, 1)   # kB -> GiB
        }
    } catch { }
    return 0
}

# ---------------------------------------------------------------------------
# Power control. Windows: Start-VM/Stop-VM. Linux: virsh start/shutdown/destroy.
# Returns @{ ok; message }.
# ---------------------------------------------------------------------------

function Start-DuneVm {
    param([string]$Name)
    if (-not $Name) { $Name = Get-DuneVmName }
    if (Get-DuneServerHostOverride) {
        return @{ ok = $true; message = 'ServerHost is a managed/remote host; no local VM to power on.' }
    }
    if (Test-DuneIsWindows) {
        try { Start-VM -Name $Name -ErrorAction Stop | Out-Null; return @{ ok = $true; message = "Started $Name" } }
        catch { return @{ ok = $false; message = $_.Exception.Message } }
    }
    $r = Invoke-DuneVirsh -Arguments @('start', $Name)
    if ($r.Exit -eq 0 -or $r.Output -match '(?i)already active') { return @{ ok = $true; message = "Started $Name" } }
    return @{ ok = $false; message = $r.Output }
}

function Stop-DuneVm {
    param([string]$Name, [switch]$Force)
    if (-not $Name) { $Name = Get-DuneVmName }
    if (Get-DuneServerHostOverride) {
        return @{ ok = $true; message = 'ServerHost is a managed/remote host; no local VM to power off.' }
    }
    if (Test-DuneIsWindows) {
        try {
            if ($Force) { Stop-VM -Name $Name -TurnOff -Force -ErrorAction Stop | Out-Null }
            else        { Stop-VM -Name $Name -Force -ErrorAction Stop | Out-Null }
            return @{ ok = $true; message = "Stopped $Name" }
        } catch { return @{ ok = $false; message = $_.Exception.Message } }
    }
    # virsh shutdown = graceful (ACPI); destroy = forced power-off.
    $verb = if ($Force) { 'destroy' } else { 'shutdown' }
    $r = Invoke-DuneVirsh -Arguments @($verb, $Name)
    if ($r.Exit -eq 0 -or $r.Output -match '(?i)not running|domain is not running') { return @{ ok = $true; message = "Stopped $Name" } }
    return @{ ok = $false; message = $r.Output }
}
