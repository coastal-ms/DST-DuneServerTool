<#
.SYNOPSIS
    Installs the DST mobile/remote bridge as a Scheduled Task on the host's PC.

.DESCRIPTION
    Registers a Scheduled Task that runs a *supervisor loop* under PowerShell 7
    (pwsh.exe) at user logon. The supervisor relaunches DstHelperBridge.ps1
    within seconds whenever it exits (crash, error, or external kill), so the
    bridge self-heals without depending on a restart/keepalive trigger firing. A
    2-minute keepalive trigger plus the logon trigger are kept as a backstop for
    the rarer case of the supervisor process itself being killed (IgnoreNew
    avoids duplicates while it is healthy).

    The bridge binds LOOPBACK (127.0.0.1) only and is reached remotely via a
    Cloudflare quick tunnel (cloudflared connects out from this PC). Because
    nothing is exposed on the LAN/public interfaces, this installer needs NO
    admin rights, NO URL ACL, and NO Windows Firewall rule.

.PARAMETER Port
    TCP loopback port to bind. Default 47900. Must match the DST app's bridge port.

.PARAMETER TaskName
    Scheduled task name. Default 'DST Friend Helper Bridge'.
#>

[CmdletBinding()]
param(
    [int]$Port = 47900,
    [string]$TaskName = 'DST Friend Helper Bridge'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Ensure-ScheduledTask {
    param(
        [string]$TaskName,
        [int]$Port,
        [string]$BridgeScriptPath
    )
    Write-Host "Registering scheduled task '$TaskName' ..."

    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) {
        throw "pwsh.exe (PowerShell 7+) not found in PATH. Install from https://aka.ms/powershell"
    }

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # The task action is a *supervisor loop*, not the daemon directly. It
    # relaunches DstHelperBridge.ps1 within seconds whenever the daemon exits
    # for any reason — crash, unhandled error, or an external kill (which exits
    # 0xC000013A and is logged by Task Scheduler as a stop, not a failure, so
    # RestartOnFailure never fires for it). Because the supervisor is the
    # long-lived task process, the daemon dying no longer ends the task, so
    # recovery does not depend on a keepalive/repetition trigger firing. The
    # 5-second sleep prevents a tight crash loop if the daemon can't start. The
    # bridge re-reads last-url.txt and binds a fresh loopback listener on every
    # launch, so relaunching is always safe.
    $supervisorCmd = "while (`$true) { try { & '$BridgeScriptPath' -Port $Port } catch { } Start-Sleep -Seconds 5 }"
    $action = New-ScheduledTaskAction `
        -Execute $pwsh `
        -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$supervisorCmd`""

    # Two triggers cover the cases the supervisor loop cannot heal by itself
    # (i.e. the supervisor process itself ending):
    #   1. AtLogOn      — start when the host user signs in (reboot / re-login).
    #   2. Keepalive    — re-fire every 2 minutes, indefinitely. Combined with
    #                     MultipleInstances=IgnoreNew below this is a no-op while
    #                     the supervisor is healthy, but relaunches it within
    #                     ~2 min if the supervisor process itself was killed.
    # A large finite RepetitionDuration is used because [TimeSpan]::MaxValue
    # trips a known Register-ScheduledTask bug.
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $keepAlive    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 2) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -RestartCount 999 `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)

    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel Limited

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger @($logonTrigger, $keepAlive) `
        -Settings $settings `
        -Principal $principal `
        -Description 'Reverse-proxies mobile/remote requests on loopback to the locally running DST instance (reached externally via a Cloudflare quick tunnel). Self-healing: a supervisor loop relaunches the daemon within seconds if it crashes or is killed; a 2-minute keepalive trigger restarts the supervisor itself if it dies; IgnoreNew prevents duplicates while it is healthy.' | Out-Null
}

$bridgeScript = Join-Path $PSScriptRoot 'DstHelperBridge.ps1'
if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "DstHelperBridge.ps1 not found next to installer at $bridgeScript"
}

# Best-effort cleanup of the legacy all-interfaces exposure from older
# (Tailscale-era) installs: the firewall rule and URL ACL are no longer used now
# that the bridge binds loopback only. Ignore failures (not present / not admin).
try {
    $legacyRule = Get-NetFirewallRule -DisplayName '*Friend Helper Bridge*' -ErrorAction SilentlyContinue
    if ($legacyRule) { $legacyRule | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
} catch {}
try { & netsh http delete urlacl url="http://+:$Port/" 2>&1 | Out-Null } catch {}

Ensure-ScheduledTask -TaskName $TaskName -Port $Port -BridgeScriptPath $bridgeScript

Write-Host ""
Write-Host "Bridge installed." -ForegroundColor Green
Write-Host "  Port:          $Port/TCP (loopback only; reached via Cloudflare tunnel)"
Write-Host "  Task:          $TaskName"
Write-Host "  Script:        $bridgeScript"
Write-Host ""
Write-Host "Starting the task now..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Host "  Task state:    $state"
Write-Host ""
Write-Host "Verify with:"
Write-Host "  curl http://127.0.0.1:$Port/_dst/health"
