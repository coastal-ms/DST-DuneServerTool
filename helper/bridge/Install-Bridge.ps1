<#
.SYNOPSIS
    Installs the DST Friend Helper bridge as a Scheduled Task on the host's PC.

.DESCRIPTION
    Performs three setup steps (all idempotent):
      1. Registers a URL ACL so a non-admin user can bind http://+:<port>/.
      2. Creates an inbound Windows Firewall rule scoped to the Tailscale
         interface only (no LAN / no public exposure).
      3. Registers a Scheduled Task that runs DstHelperBridge.ps1 under
         PowerShell 7 (pwsh.exe) at user logon, self-healing via a 2-minute
         keepalive trigger (relaunches the daemon if it dies; IgnoreNew avoids
         duplicates while it is healthy).

    Must be run elevated (admin) — both the URL ACL and the firewall rule
    require admin rights to create.

.PARAMETER Port
    TCP port to bind. Default 47900. Must match Install/Friend config.

.PARAMETER TaskName
    Scheduled task name. Default 'DST Friend Helper Bridge'.

.PARAMETER TailscaleInterfaceAlias
    Windows interface alias for Tailscale. Default 'Tailscale'.
#>

[CmdletBinding()]
param(
    [int]$Port = 47900,
    [string]$TaskName = 'DST Friend Helper Bridge',
    [string]$TailscaleInterfaceAlias = 'Tailscale'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Elevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Install-Bridge.ps1 must be run from an elevated (admin) PowerShell."
    }
}

function Ensure-UrlAcl {
    param([int]$Port)
    $url = "http://+:$Port/"
    $user = "$env:USERDOMAIN\$env:USERNAME"
    Write-Host "Registering URL ACL: $url for $user ..."
    # `netsh http add urlacl` is idempotent-ish: it errors if the ACL exists.
    # Delete-then-add is the simplest path to a clean state.
    & netsh http delete urlacl url=$url 2>&1 | Out-Null
    $out = & netsh http add urlacl url=$url user=$user 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "netsh add urlacl failed: $out"
    }
}

function Ensure-FirewallRule {
    param(
        [int]$Port,
        [string]$InterfaceAlias
    )
    $ruleName = "DST Friend Helper Bridge ($Port/TCP, Tailscale)"
    Write-Host "Configuring firewall rule '$ruleName' (Tailscale only) ..."

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-NetFirewallRule -DisplayName $ruleName
    }

    # Resolve the interface alias to its index. Fail loudly with a helpful
    # message if Tailscale isn't installed / interface is named differently.
    $iface = Get-NetIPInterface -InterfaceAlias $InterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $iface) {
        throw "No network interface with alias '$InterfaceAlias' found. Is Tailscale installed and running? `nList available interfaces: Get-NetIPInterface | Select-Object InterfaceAlias"
    }

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -InterfaceAlias $InterfaceAlias `
        -Profile Any `
        -Description 'Allow inbound to DST Friend Helper Bridge on the Tailscale interface only.' | Out-Null
}

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

    $action = New-ScheduledTaskAction `
        -Execute $pwsh `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$BridgeScriptPath`" -Port $Port"

    # Two triggers keep the daemon alive across crashes, kills, and sleep/wake:
    #   1. AtLogOn      — start when the host user signs in.
    #   2. Keepalive    — re-fire every 2 minutes, indefinitely. Combined with
    #                     MultipleInstances=IgnoreNew below this is a no-op while
    #                     the daemon is healthy, but relaunches it within ~2 min
    #                     if it has died. RestartOnFailure alone is insufficient:
    #                     an externally-killed daemon (exit 0xC000013A) is logged
    #                     as a stop, not a failure, so it never restarted.
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
        -Description 'Reverse-proxies friend helper requests over Tailscale to the locally running DST instance. Self-healing: a 2-minute keepalive trigger relaunches the daemon if it dies; IgnoreNew prevents duplicates while it is healthy.' | Out-Null
}

Assert-Elevated

$bridgeScript = Join-Path $PSScriptRoot 'DstHelperBridge.ps1'
if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "DstHelperBridge.ps1 not found next to installer at $bridgeScript"
}

Ensure-UrlAcl -Port $Port
Ensure-FirewallRule -Port $Port -InterfaceAlias $TailscaleInterfaceAlias
Ensure-ScheduledTask -TaskName $TaskName -Port $Port -BridgeScriptPath $bridgeScript

Write-Host ""
Write-Host "Bridge installed." -ForegroundColor Green
Write-Host "  Port:          $Port/TCP (Tailscale interface only)"
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
