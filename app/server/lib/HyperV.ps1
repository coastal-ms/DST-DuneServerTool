# HyperV — resolve where DST's Hyper-V cmdlets should run (local vs a remote
# host on the LAN) and probe remote connectivity.
#
# Backbone of the "Hyper-V over LAN" setup option (12.20.0). When VmHostMode is
# 'lan', every Hyper-V call site (VM discovery, power ops, RAM readout) targets
# the LAN host via -ComputerName instead of localhost. The ~90% of DST that runs
# over SSH to the guest VM's IP is unchanged either way — only the thin Hyper-V
# layer is redirected.
#
# The precondition (surfaced in the wizard) is that remote Hyper-V management
# from THIS PC already works — i.e. the same access Hyper-V Manager needs to
# connect to the remote host. DST does not configure WinRM/DCOM/CredSSP itself;
# it verifies the channel and uses it.

# The value to pass as -ComputerName on Hyper-V cmdlets. Empty string = local
# (omit the parameter). Returns the LAN host IP only when VmHostMode='lan' AND a
# non-empty HyperVHostIp is configured; any other state falls back to local, so a
# half-configured or unchecked LAN option can never crash a Hyper-V call.
function Get-DuneHyperVComputerName {
    if ((Get-DuneVmHostMode) -ne 'lan') { return '' }
    $ip = Get-DuneHyperVHostIp
    if (-not $ip) { return '' }
    return $ip
}

# Splattable argument set for Hyper-V cmdlets: @{} for local (today's behavior,
# byte-for-byte), @{ ComputerName = <ip> } for a LAN host. Usage:
#   $hv = Get-DuneHyperVSplat
#   Get-VM -Name 'dune-awakening' @hv
function Get-DuneHyperVSplat {
    $cn = Get-DuneHyperVComputerName
    if ($cn) { return @{ ComputerName = $cn } }
    return @{}
}

# Probe whether DST can manage Hyper-V on a given LAN host. Returns a hashtable:
#   ok      - [bool] the remote Hyper-V host answered
#   vmFound - [bool] a VM named 'dune-awakening' already exists there
#   reason  - human-readable status / failure explanation for the UI
# Classifies the common remote-Hyper-V failures (host unreachable, access denied)
# into actionable text rather than surfacing a raw RPC exception.
function Test-DuneHyperVLan {
    param([Parameter(Mandatory)][string]$HostIp)

    $HostIp = ($HostIp | Out-String).Trim()
    if (-not $HostIp) {
        return @{ ok = $false; vmFound = $false; reason = 'No Hyper-V host IP provided.' }
    }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; vmFound = $false; reason = 'The Hyper-V PowerShell module is not installed on this PC. It is required to manage a remote Hyper-V host. Enable Hyper-V (or the Hyper-V Management Tools) via Windows Features.' }
    }

    try {
        $vms = @(Get-VM -ComputerName $HostIp -ErrorAction Stop)
        $dune = $vms | Where-Object { $_.Name -eq 'dune-awakening' } | Select-Object -First 1
        if ($dune) {
            return @{ ok = $true; vmFound = $true; reason = "Connected to $HostIp. Found the 'dune-awakening' VM (state: $($dune.State))." }
        }
        return @{ ok = $true; vmFound = $false; reason = "Connected to $HostIp, but no VM named 'dune-awakening' exists there yet. Install it on that host, then DST can manage it over the LAN." }
    } catch {
        $msg = $_.Exception.Message
        $reason =
            if ($msg -match '(?i)access is denied|access denied|0x80070005') {
                "Reached $HostIp but access was denied. The Windows account DST runs as must be an administrator (Hyper-V Administrators) on the remote host, and remote Hyper-V management must be allowed — the same access Hyper-V Manager needs to connect."
            } elseif ($msg -match '(?i)RPC server is unavailable|cannot be found|cannot connect|unable to connect|no such host|actively refused|timed out|0x800706ba') {
                "Could not reach Hyper-V on $HostIp. Confirm the host is on, its IP is correct, and that Hyper-V Manager on this PC can connect to it (remote management / firewall). DST uses the same channel."
            } else {
                "Could not query Hyper-V on ${HostIp}: $msg"
            }
        return @{ ok = $false; vmFound = $false; reason = $reason }
    }
}
