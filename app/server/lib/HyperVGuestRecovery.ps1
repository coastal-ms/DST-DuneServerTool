# Hyper-V guest recovery: dynamic-memory hot-add and KVP/IP resilience.

$script:DuneHyperVGuestRecoveryLastIp = ''
$script:DuneHyperVGuestRecoveryLastAttempt = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryLastSuccess = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryLastKvpRestart = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryRetrySeconds = 60
$script:DuneHyperVGuestRecoveryKvpStateKey = '__cache:hyperv-guest-kvp-restart'

function Get-DuneSharedKvpRestartTime {
    $table = $null
    try { $table = $script:DuneApiLockTable } catch {}
    if ($table -and $table.ContainsKey($script:DuneHyperVGuestRecoveryKvpStateKey)) {
        return [datetime]$table[$script:DuneHyperVGuestRecoveryKvpStateKey]
    }
    return [datetime]$script:DuneHyperVGuestRecoveryLastKvpRestart
}

function Set-DuneSharedKvpRestartTime {
    param([datetime]$Value)
    $script:DuneHyperVGuestRecoveryLastKvpRestart = $Value
    $table = $null
    try { $table = $script:DuneApiLockTable } catch {}
    if ($table) {
        $table[$script:DuneHyperVGuestRecoveryKvpStateKey] = $Value
    }
}

function Test-DuneValidVmIpv4 {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip.Trim(), [ref]$parsed)) { return $false }
    return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            -not [System.Net.IPAddress]::IsLoopback($parsed) -and
            $parsed.ToString() -ne '0.0.0.0')
}

function Get-DuneVmHostIdentity {
    try {
        if ((Get-DuneVmHostMode) -eq 'lan') {
            $hostIp = Get-DuneHyperVHostIp
            if ($hostIp) { return "lan:$($hostIp.Trim().ToLowerInvariant())" }
        }
    } catch {}
    return "local:$($env:COMPUTERNAME.ToLowerInvariant())"
}

function Get-DuneLastKnownVmIp {
    try {
        $raw = Read-DuneConfigRaw
        $storedHost = if ($raw.Contains('LastKnownVmHost')) {
            [string]$raw['LastKnownVmHost']
        } else { '' }
        if ($storedHost.Trim() -ne (Get-DuneVmHostIdentity)) { return '' }
        $ip = if ($raw.Contains('LastKnownVmIp')) { [string]$raw['LastKnownVmIp'] } else { '' }
        if (Test-DuneValidVmIpv4 -Ip $ip) { return $ip.Trim() }
    } catch {}
    return ''
}

function Set-DuneLastKnownVmIp {
    param([string]$Ip)
    if (-not (Test-DuneValidVmIpv4 -Ip $Ip)) { return $false }
    $normalized = $Ip.Trim()
    $save = {
        if ((Get-DuneLastKnownVmIp) -eq $normalized) { return $false }
        [void](Save-DuneConfig -Config @{
            LastKnownVmIp = $normalized
            LastKnownVmHost = Get-DuneVmHostIdentity
        })
        return $true
    }
    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        return Invoke-WithDuneLock -Name 'config' -Script $save
    }
    return & $save
}

function Test-DuneKnownVmIp {
    param([string]$Ip)
    if (-not (Test-DuneValidVmIpv4 -Ip $Ip)) { return $false }
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = Invoke-V6Ssh -Ip $Ip -Cmd 'printf DUNE_VM_IP_OK' -TimeoutSec 4
        return ((($out -join "`n").Trim()) -eq 'DUNE_VM_IP_OK')
    } catch {
        return $false
    }
}

function Get-DuneHyperVGuestRecoveryInstallerPath {
    $candidates = @()
    if ($script:AppDir) {
        $candidates += (Join-Path $script:AppDir 'resources\remote-scripts\dune-hyperv-guest-recovery-install.sh')
    }
    $candidates += (Join-Path $PSScriptRoot '..\..\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh')
    foreach ($candidate in $candidates) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        } catch {}
    }
    return $null
}

function Invoke-DuneHyperVGuestRecovery {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [switch]$ForceKvp,
        [switch]$InsideLock
    )

    if (-not $InsideLock.IsPresent -and
        (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue)) {
        return Invoke-WithDuneLock -Name 'hyperv-guest-recovery' -TimeoutSec 35 -Script {
            Invoke-DuneHyperVGuestRecovery -Ip $Ip -ForceKvp:$ForceKvp -InsideLock
        }
    }

    if (-not (Test-DuneValidVmIpv4 -Ip $Ip)) {
        return @{ ok = $false; skipped = $true; reason = 'invalid-ip' }
    }
    $now = [datetime]::UtcNow
    if ($ForceKvp.IsPresent -and
        (($now - (Get-DuneSharedKvpRestartTime)).TotalSeconds -lt
            $script:DuneHyperVGuestRecoveryRetrySeconds)) {
        return @{ ok = $false; skipped = $true; reason = 'kvp-restart-backoff' }
    }
    if (-not $ForceKvp.IsPresent -and
        $script:DuneHyperVGuestRecoveryLastIp -eq $Ip -and
        $script:DuneHyperVGuestRecoveryLastSuccess -ne [datetime]::MinValue) {
        return @{ ok = $true; cached = $true }
    }
    if (-not $ForceKvp.IsPresent -and
        (($now - $script:DuneHyperVGuestRecoveryLastAttempt).TotalSeconds -lt
            $script:DuneHyperVGuestRecoveryRetrySeconds)) {
        return @{ ok = $false; skipped = $true; reason = 'retry-backoff' }
    }
    if ($ForceKvp.IsPresent) {
        Set-DuneSharedKvpRestartTime -Value $now
    } else {
        $script:DuneHyperVGuestRecoveryLastAttempt = $now
    }

    $installer = Get-DuneHyperVGuestRecoveryInstallerPath
    if (-not $installer) {
        return @{ ok = $false; skipped = $true; reason = 'installer-missing' }
    }
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; skipped = $true; reason = 'ssh-helper-missing' }
    }
    try {
        $raw = [IO.File]::ReadAllText($installer)
        $lf = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))
        $remoteCommand = if ($ForceKvp.IsPresent) {
            'base64 -d | sudo -n env DUNE_HYPERV_FORCE_KVP_RESTART=1 sh'
        } else {
            'base64 -d | sudo -n sh'
        }
        $out = Invoke-V6Ssh -Ip $Ip -Cmd $remoteCommand `
            -StdinData $b64 -TimeoutSec 30
        $text = ($out -join "`n").Trim()
        if ($text -notmatch 'DUNE_HYPERV_GUEST_RECOVERY_(OK|NOT_APPLICABLE)') {
            throw "VM recovery installer did not report success: $text"
        }
        $script:DuneHyperVGuestRecoveryLastIp = $Ip
        $script:DuneHyperVGuestRecoveryLastSuccess = [datetime]::UtcNow
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Hyper-V guest recovery reconciled for $Ip"
        }
        return @{ ok = $true; cached = $false; output = $text }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Hyper-V guest recovery failed for $Ip`: $($_.Exception.Message)" 'WARN'
        }
        return @{ ok = $false; error = $_.Exception.Message }
    }
}
