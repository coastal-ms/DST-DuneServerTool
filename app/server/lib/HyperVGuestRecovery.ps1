# Hyper-V guest recovery: dynamic-memory hot-add and KVP/IP resilience.

$script:DuneHyperVGuestRecoveryLastIp = ''
$script:DuneHyperVGuestRecoveryLastAttempt = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryLastSuccess = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryLastKvpRestart = [datetime]::MinValue
$script:DuneHyperVGuestRecoveryRetrySeconds = 60
$script:DuneHyperVGuestRecoveryKvpStateKey = '__cache:hyperv-guest-kvp-restart'
$script:DuneHyperVShutdownComponentId = [guid]'9f8233ac-be49-4c79-8ee3-e7e1985b2077'
$script:DuneHyperVLifecycleVmName = 'dune-awakening'

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

function Invoke-DuneHyperVGuestRecoveryScript {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [ValidateSet('recovery','lifecycle-status','lifecycle-install','lifecycle-uninstall')]
        [string]$Action = 'recovery',
        [switch]$ForceKvp,
        [int]$TimeoutSec = 30
    )
    if (-not (Test-DuneValidVmIpv4 -Ip $Ip)) {
        throw 'A valid VM IPv4 address is required.'
    }
    $installer = Get-DuneHyperVGuestRecoveryInstallerPath
    if (-not $installer) { throw 'Hyper-V guest recovery installer is missing.' }
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        throw 'SSH helper is unavailable.'
    }

    $raw = [IO.File]::ReadAllText($installer)
    $lf = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))
    $envArgs = @("DUNE_HYPERV_ACTION=$Action")
    if ($ForceKvp.IsPresent) { $envArgs += 'DUNE_HYPERV_FORCE_KVP_RESTART=1' }
    $remoteCommand = "base64 -d | sudo -n env $($envArgs -join ' ') sh"
    $out = Invoke-V6Ssh -Ip $Ip -Cmd $remoteCommand `
        -StdinData $b64 -TimeoutSec $TimeoutSec
    return (($out -join "`n").Trim())
}

function ConvertFrom-DuneHyperVLifecycleStatus {
    param([string]$Text)
    if ($Text -notmatch 'DUNE_HYPERV_LIFECYCLE_STATUS') {
        throw "Guest lifecycle status did not report a valid result: $Text"
    }
    $values = @{}
    foreach ($match in [regex]::Matches($Text, '(?<key>[a-z_]+)=(?<value>[^\s]*)')) {
        $values[$match.Groups['key'].Value] = $match.Groups['value'].Value
    }
    $asBool = {
        param([string]$Key)
        return ($values.ContainsKey($Key) -and $values[$Key] -eq 'true')
    }
    return @{
        supported          = & $asBool 'supported'
        hvUtils            = & $asBool 'hv_utils'
        shutdownChannel    = & $asBool 'shutdown_channel'
        installed          = & $asBool 'installed'
        runlevel            = & $asBool 'runlevel'
        serviceStarted      = & $asBool 'service_started'
        desired             = if ($values.ContainsKey('desired')) { $values.desired } else { '' }
        lastShutdownResult  = if ($values.ContainsKey('last_shutdown_result')) { $values.last_shutdown_result } else { '' }
        lastShutdownPhase   = if ($values.ContainsKey('last_shutdown_phase')) { $values.last_shutdown_phase } else { '' }
        lastShutdownAt      = if ($values.ContainsKey('last_shutdown_at')) { $values.last_shutdown_at } else { '' }
        lastStartResult     = if ($values.ContainsKey('last_start_result')) { $values.last_start_result } else { '' }
        lastStartPhase      = if ($values.ContainsKey('last_start_phase')) { $values.last_start_phase } else { '' }
        lastStartAt         = if ($values.ContainsKey('last_start_at')) { $values.last_start_at } else { '' }
    }
}

function Get-DuneHyperVLifecycleStatePath {
    Join-Path $env:APPDATA 'DuneServer\hyperv-lifecycle-state.json'
}

function Read-DuneHyperVLifecycleState {
    $path = Get-DuneHyperVLifecycleStatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop)
    } catch {
        throw "Hyper-V lifecycle rollback state is unreadable: $($_.Exception.Message)"
    }
}

function Save-DuneHyperVLifecycleState {
    param([Parameter(Mandatory)][hashtable]$State)
    $path = Get-DuneHyperVLifecycleStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
    }
    $tmp = "$path.new.$PID"
    try {
        $json = $State | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Remove-DuneHyperVLifecycleState {
    $path = Get-DuneHyperVLifecycleStatePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    }
}

function Get-DuneHyperVLifecycleHostSnapshot {
    $hv = Get-DuneHyperVSplat
    $vm = Get-VM -Name $script:DuneHyperVLifecycleVmName @hv -ErrorAction Stop
    $services = @(Get-VMIntegrationService -VMName $script:DuneHyperVLifecycleVmName @hv -ErrorAction Stop)
    $shutdown = $services | Where-Object {
        $componentId = ("$($_.Id)" -split '\\')[-1]
        try { ([guid]$componentId) -eq $script:DuneHyperVShutdownComponentId } catch { $false }
    } | Select-Object -First 1
    if (-not $shutdown) {
        throw "Hyper-V did not expose Operating System Shutdown identity $($script:DuneHyperVShutdownComponentId) for '$($script:DuneHyperVLifecycleVmName)'."
    }
    return @{
        Hv                    = $hv
        Vm                    = $vm
        ShutdownService       = $shutdown
        HostIdentity          = Get-DuneVmHostIdentity
        VmId                  = "$($vm.Id)"
        AutomaticStopAction   = "$($vm.AutomaticStopAction)"
        ShutdownEnabled       = [bool]$shutdown.Enabled
    }
}

function Test-DuneHyperVLifecycleStateIdentity {
    param($State, [hashtable]$HostSnapshot)
    if (-not $State) { return $false }
    return (
        [int]$State.schema -eq 1 -and
        [string]$State.hostIdentity -eq [string]$HostSnapshot.HostIdentity -and
        [string]$State.vmId -eq [string]$HostSnapshot.VmId
    )
}

function Get-DuneHyperVLifecycleGuestIp {
    param([hashtable]$HostSnapshot)
    if ("$($HostSnapshot.Vm.State)" -ne 'Running') { return '' }
    $hv = $HostSnapshot.Hv
    $ip = (Get-VMNetworkAdapter -VMName $script:DuneHyperVLifecycleVmName `
        @hv -ErrorAction Stop).IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1
    if ($null -ne $ip) { return [string]$ip }
    return ''
}

function Get-DuneHyperVLifecycleStatus {
    $hostSnapshot = Get-DuneHyperVLifecycleHostSnapshot
    $ip = Get-DuneHyperVLifecycleGuestIp -HostSnapshot $hostSnapshot
    $guest = @{
        reachable = $false
        supported = $false
        reason = if ($ip) { 'Guest lifecycle status has not been checked.' } else { 'VM is not running or has no Hyper-V IPv4 address.' }
    }
    if ($ip) {
        try {
            $guestText = Invoke-DuneHyperVGuestRecoveryScript -Ip $ip `
                -Action lifecycle-status -TimeoutSec 15
            $guest = ConvertFrom-DuneHyperVLifecycleStatus -Text $guestText
            $guest.reachable = $true
            $guest.reason = if ($guest.supported) { '' } else {
                'The Alpine guest does not expose both hv_utils and the Hyper-V shutdown VMBus channel.'
            }
        } catch {
            $guest = @{ reachable = $false; supported = $false; reason = $_.Exception.Message }
        }
    }
    $saved = $null
    $savedError = ''
    try { $saved = Read-DuneHyperVLifecycleState } catch { $savedError = $_.Exception.Message }
    $stateMatches = if ($saved) {
        Test-DuneHyperVLifecycleStateIdentity -State $saved -HostSnapshot $hostSnapshot
    } else { $false }
    return @{
        ok = $true
        host = @{
            identity = $hostSnapshot.HostIdentity
            vmId = $hostSnapshot.VmId
            vmName = $script:DuneHyperVLifecycleVmName
            vmState = "$($hostSnapshot.Vm.State)"
            shutdownServiceId = "$($script:DuneHyperVShutdownComponentId)"
            shutdownEnabled = $hostSnapshot.ShutdownEnabled
            automaticStopAction = $hostSnapshot.AutomaticStopAction
            compliant = ($hostSnapshot.ShutdownEnabled -and
                $hostSnapshot.AutomaticStopAction -eq 'ShutDown')
        }
        guest = $guest
        rollbackStatePresent = [bool]$saved
        rollbackStateMatches = $stateMatches
        rollbackStateError = $savedError
        configured = (
            $hostSnapshot.ShutdownEnabled -and
            $hostSnapshot.AutomaticStopAction -eq 'ShutDown' -and
            [bool]$guest.reachable -and [bool]$guest.supported -and
            [bool]$guest.installed -and [bool]$guest.runlevel -and
            [bool]$guest.serviceStarted
        )
        ip = $ip
    }
}

function Set-DuneHyperVLifecycleHostValues {
    param(
        [Parameter(Mandatory)][hashtable]$HostSnapshot,
        [Parameter(Mandatory)][bool]$ShutdownEnabled,
        [Parameter(Mandatory)][string]$AutomaticStopAction
    )
    if ([bool]$HostSnapshot.ShutdownService.Enabled -ne $ShutdownEnabled) {
        if ($ShutdownEnabled) {
            Enable-VMIntegrationService `
                -VMIntegrationService $HostSnapshot.ShutdownService `
                -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            Disable-VMIntegrationService `
                -VMIntegrationService $HostSnapshot.ShutdownService `
                -Confirm:$false -ErrorAction Stop | Out-Null
        }
    }
    if ([string]$HostSnapshot.AutomaticStopAction -ne $AutomaticStopAction) {
        $hv = $HostSnapshot.Hv
        Set-VM -Name $script:DuneHyperVLifecycleVmName `
            @hv -AutomaticStopAction $AutomaticStopAction `
            -Confirm:$false -ErrorAction Stop | Out-Null
    }
    $readback = Get-DuneHyperVLifecycleHostSnapshot
    if ($readback.ShutdownEnabled -ne $ShutdownEnabled -or
        $readback.AutomaticStopAction -ne $AutomaticStopAction) {
        throw 'Hyper-V lifecycle host settings failed exact readback.'
    }
    return $readback
}

function Invoke-DuneHyperVLifecycleReconcile {
    param([switch]$InsideLock)
    if (-not $InsideLock.IsPresent -and
        (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue)) {
        return Invoke-WithDuneLock -Name 'hyperv-lifecycle' -TimeoutSec 120 -Script {
            Invoke-DuneHyperVLifecycleReconcile -InsideLock
        }
    }

    $before = Get-DuneHyperVLifecycleStatus
    if (-not $before.ip) { throw 'The VM must be running with a Hyper-V IPv4 address before lifecycle reconciliation.' }
    if (-not $before.guest.reachable) { throw "The Alpine guest is unreachable: $($before.guest.reason)" }
    if (-not $before.guest.supported) { throw $before.guest.reason }

    $hostSnapshot = Get-DuneHyperVLifecycleHostSnapshot
    $saved = Read-DuneHyperVLifecycleState
    $createdState = $false
    if ($saved -and -not (Test-DuneHyperVLifecycleStateIdentity -State $saved -HostSnapshot $hostSnapshot)) {
        throw 'Saved Hyper-V lifecycle rollback state belongs to a different host or VM. Remove or correct that state before reconciling.'
    }
    if (-not $saved) {
        Save-DuneHyperVLifecycleState -State @{
            schema = 1
            hostIdentity = $hostSnapshot.HostIdentity
            vmId = $hostSnapshot.VmId
            priorShutdownEnabled = $hostSnapshot.ShutdownEnabled
            priorAutomaticStopAction = $hostSnapshot.AutomaticStopAction
            recordedAt = [datetime]::UtcNow.ToString('o')
        }
        $saved = Read-DuneHyperVLifecycleState
        $createdState = $true
    }

    $guestWasInstalled = [bool]$before.guest.installed
    $guestInstalled = $false
    try {
        $guestText = Invoke-DuneHyperVGuestRecoveryScript -Ip $before.ip `
            -Action lifecycle-install -TimeoutSec 120
        if ($guestText -notmatch 'DUNE_HYPERV_LIFECYCLE_STATUS' -or
            $guestText -notmatch 'installed=true' -or
            $guestText -notmatch 'runlevel=true' -or
            $guestText -notmatch 'service_started=true') {
            throw "Guest lifecycle installation failed exact readback: $guestText"
        }
        $guestInstalled = $true
        [void](Set-DuneHyperVLifecycleHostValues -HostSnapshot $hostSnapshot `
            -ShutdownEnabled $true -AutomaticStopAction 'ShutDown')
        $result = Get-DuneHyperVLifecycleStatus
        if (-not $result.configured) { throw 'Lifecycle reconciliation completed without a compliant final status.' }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Hyper-V VM lifecycle reconciled for $($result.host.identity)"
        }
        return $result
    } catch {
        $primary = $_.Exception.Message
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        try {
            [void](Set-DuneHyperVLifecycleHostValues -HostSnapshot (Get-DuneHyperVLifecycleHostSnapshot) `
                -ShutdownEnabled ([bool]$hostSnapshot.ShutdownEnabled) `
                -AutomaticStopAction ([string]$hostSnapshot.AutomaticStopAction))
        } catch { $rollbackErrors.Add("host: $($_.Exception.Message)") }
        if ($guestInstalled -and -not $guestWasInstalled) {
            try {
                $undo = Invoke-DuneHyperVGuestRecoveryScript -Ip $before.ip `
                    -Action lifecycle-uninstall -TimeoutSec 45
                if ($undo -notmatch 'DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK') {
                    throw "unexpected uninstall result: $undo"
                }
            } catch { $rollbackErrors.Add("guest: $($_.Exception.Message)") }
        }
        if ($createdState -and $rollbackErrors.Count -eq 0) {
            try { Remove-DuneHyperVLifecycleState } catch {
                $rollbackErrors.Add("state: $($_.Exception.Message)")
            }
        }
        $suffix = if ($rollbackErrors.Count) {
            " Rollback errors: $($rollbackErrors -join '; ')"
        } else { '' }
        throw "Hyper-V lifecycle reconciliation failed: $primary.$suffix"
    }
}

function Remove-DuneHyperVLifecycle {
    param([switch]$InsideLock)
    if (-not $InsideLock.IsPresent -and
        (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue)) {
        return Invoke-WithDuneLock -Name 'hyperv-lifecycle' -TimeoutSec 90 -Script {
            Remove-DuneHyperVLifecycle -InsideLock
        }
    }

    $status = Get-DuneHyperVLifecycleStatus
    $hostSnapshot = Get-DuneHyperVLifecycleHostSnapshot
    $saved = Read-DuneHyperVLifecycleState
    if (-not $saved) {
        if (-not $status.guest.installed -and -not $status.host.compliant) {
            return $status
        }
        throw 'Lifecycle rollback state is missing; refusing to guess original Hyper-V settings.'
    }
    if (-not (Test-DuneHyperVLifecycleStateIdentity -State $saved -HostSnapshot $hostSnapshot)) {
        throw 'Lifecycle rollback state belongs to a different host or VM; refusing to change either system.'
    }
    if (-not $status.ip) { throw 'The VM must be running to remove its lifecycle integration safely.' }

    $guestWasInstalled = [bool]$status.guest.installed
    $guestRemoved = $false
    try {
        if ($guestWasInstalled) {
            $guestText = Invoke-DuneHyperVGuestRecoveryScript -Ip $status.ip `
                -Action lifecycle-uninstall -TimeoutSec 45
            if ($guestText -notmatch 'DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK') {
                throw "Guest lifecycle uninstall failed exact readback: $guestText"
            }
            $guestRemoved = $true
        }
        [void](Set-DuneHyperVLifecycleHostValues -HostSnapshot $hostSnapshot `
            -ShutdownEnabled ([bool]$saved.priorShutdownEnabled) `
            -AutomaticStopAction ([string]$saved.priorAutomaticStopAction))
        Remove-DuneHyperVLifecycleState
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Hyper-V VM lifecycle integration removed for $($hostSnapshot.HostIdentity)"
        }
        return Get-DuneHyperVLifecycleStatus
    } catch {
        $primary = $_.Exception.Message
        $compensationErrors = [System.Collections.Generic.List[string]]::new()
        try {
            [void](Set-DuneHyperVLifecycleHostValues `
                -HostSnapshot (Get-DuneHyperVLifecycleHostSnapshot) `
                -ShutdownEnabled ([bool]$hostSnapshot.ShutdownEnabled) `
                -AutomaticStopAction ([string]$hostSnapshot.AutomaticStopAction))
        } catch { $compensationErrors.Add("host: $($_.Exception.Message)") }
        if ($guestRemoved) {
            try {
                [void](Invoke-DuneHyperVGuestRecoveryScript -Ip $status.ip `
                    -Action lifecycle-install -TimeoutSec 120)
            } catch { $compensationErrors.Add("guest: $($_.Exception.Message)") }
        }
        $suffix = if ($compensationErrors.Count) {
            " Compensation errors: $($compensationErrors -join '; ')"
        } else { '' }
        throw "Hyper-V lifecycle uninstall failed: $primary.$suffix"
    }
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

    try {
        $text = Invoke-DuneHyperVGuestRecoveryScript -Ip $Ip `
            -Action recovery -ForceKvp:$ForceKvp -TimeoutSec 30
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
        if ($_.Exception.Message -eq 'Hyper-V guest recovery installer is missing.') {
            return @{ ok = $false; skipped = $true; reason = 'installer-missing' }
        }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Hyper-V guest recovery failed for $Ip`: $($_.Exception.Message)" 'WARN'
        }
        return @{ ok = $false; error = $_.Exception.Message }
    }
}
