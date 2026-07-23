# HyperV — resolve where DST's Hyper-V cmdlets should run (local vs a remote
# host on the LAN) and probe remote connectivity.
#
# Backbone of the "Hyper-V over LAN" setup option (12.20.0). When VmHostMode is
# 'lan', every Hyper-V call site (VM discovery, power ops, RAM readout) targets
# the LAN host via -ComputerName instead of localhost. The ~90% of DST that runs
# over SSH to the guest VM's IP is unchanged either way — only the thin Hyper-V
# layer is redirected.
#
# The precondition is an explicit host administrator credential, collected once
# and persisted in Windows Credential Manager (HyperVLanCredential.ps1) - NOT
# "remote Hyper-V management already works under DST's own Windows identity".
# In a workgroup the host's admin account is routinely a different local
# account than the one DST runs as, so relying on the current identity silently
# fails (confirmed by field testing: Get-VM -ComputerName under DST's identity
# failed with "Could not query Hyper-V" while the explicit-credential WinRM
# probe on the install step succeeded against the very same host).

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
# byte-for-byte), @{ ComputerName = <ip>; Credential = <PSCredential> } for a
# LAN host. Usage:
#   $hv = Get-DuneHyperVSplat
#   Get-VM -Name 'dune-awakening' @hv
#
# Deliberately THROWS (rather than silently returning @{ ComputerName = <ip> }
# with no credential) when LAN mode is on but no saved credential matches the
# configured host. Falling back to an implicit "current identity" call here is
# exactly the bug this fixes - every caller already runs inside a try/catch
# (Get-DuneVmStatus, Get-DuneSietchOverview, etc.), so the thrown message
# surfaces as an actionable error instead of a generic RPC/access-denied
# exception from Hyper-V itself.
function Get-DuneHyperVSplat {
    $cn = Get-DuneHyperVComputerName
    if (-not $cn) { return @{} }

    $cred = Get-DuneHyperVLanCredential -HostIp $cn
    if (-not $cred.ok) {
        throw "Hyper-V over LAN credential unavailable: $($cred.error)"
    }
    if (-not $cred.exists -or -not $cred.matchesHost) {
        throw "Hyper-V over LAN is enabled for host $cn, but no saved host administrator credential matches it. Add or update the credential in Settings - Hyper-V over LAN (or the Setup Wizard's Hyper-V host step), then try again."
    }
    return @{ ComputerName = $cn; Credential = $cred.credential }
}

# Probe whether DST can manage Hyper-V on a given LAN host. Returns a hashtable:
#   ok      - [bool] the remote Hyper-V host answered
#   vmFound - [bool] a VM named 'dune-awakening' already exists there
#   reason  - human-readable status / failure explanation for the UI
# Classifies the common remote-Hyper-V failures (host unreachable, access denied)
# into actionable text rather than surfacing a raw RPC exception.
#
# Credential resolution, in order:
#   1. Explicit -User/-Password (the Connect step testing a NEW credential
#      before it's saved - never persisted by this function).
#   2. The saved credential for $HostIp, if one matches.
#   3. Neither - fails fast with an actionable "enter a credential" reason
#      instead of silently trying the current Windows identity (the original
#      bug: that identity is routinely wrong for a separate LAN host).
function Test-DuneHyperVLan {
    param(
        # AllowEmptyString: Mandatory string parameters otherwise reject an
        # empty string at BINDING time (before the function body runs), which
        # would skip the "No Hyper-V host IP provided" friendly message below
        # entirely and surface a raw ParameterBindingValidationException
        # instead - exactly the kind of non-actionable failure this function
        # exists to avoid.
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostIp,
        [string]$User = '',
        [string]$Password = ''
    )

    $HostIp = ($HostIp | Out-String).Trim()
    if (-not $HostIp) {
        return @{ ok = $false; vmFound = $false; reason = 'No Hyper-V host IP provided.' }
    }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; vmFound = $false; reason = 'The Hyper-V PowerShell module is not installed on this PC. It is required to manage a remote Hyper-V host. Enable Hyper-V (or the Hyper-V Management Tools) via Windows Features.' }
    }

    $cred = $null
    $usingSaved = $false
    if ($User -and $Password) {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        $cred = [System.Management.Automation.PSCredential]::new($User, $sec)
    } else {
        $saved = Get-DuneHyperVLanCredential -HostIp $HostIp
        if ($saved.ok -and $saved.matchesHost -and $saved.credential) {
            $cred = $saved.credential
            $usingSaved = $true
        }
    }
    if (-not $cred) {
        return @{ ok = $false; vmFound = $false; reason = "No Hyper-V host administrator credential provided for $HostIp. Enter the host's administrator username and password (e.g. HOST\Administrator in a workgroup) below, then test again." }
    }

    try {
        $vms = @(Get-VM -ComputerName $HostIp -Credential $cred -ErrorAction Stop)
        $dune = $vms | Where-Object { $_.Name -eq 'dune-awakening' } | Select-Object -First 1
        if ($dune) {
            return @{ ok = $true; vmFound = $true; reason = "Connected to $HostIp. Found the 'dune-awakening' VM (state: $($dune.State))." }
        }
        return @{ ok = $true; vmFound = $false; reason = "Connected to $HostIp, but no VM named 'dune-awakening' exists there yet. Install it on that host, then DST can manage it over the LAN." }
    } catch {
        $msg = $_.Exception.Message
        $credHint = if ($usingSaved) { 'the saved credential' } else { 'the credential entered' }
        $reason =
            if ($msg -match '(?i)access is denied|access denied|logon failure|credentials|0x80070005') {
                "Reached $HostIp but access was denied using $credHint. That account must be an administrator (Hyper-V Administrators) on the remote host, and remote Hyper-V management must be allowed there. In a workgroup, use HOST\username for the host's own local account - it is often not the same account DST itself runs as."
            } elseif ($msg -match '(?i)RPC server is unavailable|cannot be found|cannot connect|unable to connect|no such host|actively refused|timed out|0x800706ba') {
                "Could not reach Hyper-V on $HostIp. Confirm the host is on, its IP is correct, and that Hyper-V remote management is allowed through its firewall."
            } else {
                "Could not query Hyper-V on ${HostIp}: $msg"
            }
        return @{ ok = $false; vmFound = $false; reason = $reason }
    }
}
