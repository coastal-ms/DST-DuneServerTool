<#
.SYNOPSIS
    Cleanly removes the DST Friend Helper bridge from the host's PC.

.DESCRIPTION
    Reverses every step taken by Install-Bridge.ps1: unregisters the
    scheduled task, and removes any legacy firewall rule / URL ACL left over
    from older (Tailscale-era) all-interfaces installs. Each step is
    best-effort — missing artifacts are not errors.

    The scheduled task is a per-user task and unregisters without admin. The
    legacy firewall/URL-ACL cleanup needs admin; if not elevated it is skipped
    silently (those artifacts are not created by current installs anyway).
#>

[CmdletBinding()]
param(
    [int]$Port = 47900,
    [string]$TaskName = 'DST Friend Helper Bridge'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$url = "http://+:$Port/"

Write-Host "Stopping + unregistering scheduled task '$TaskName' ..."
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  removed."
} else {
    Write-Host "  (not present)"
}

Write-Host "Removing any legacy firewall rule ('*Friend Helper Bridge*') ..."
try {
    $legacy = Get-NetFirewallRule -DisplayName '*Friend Helper Bridge*' -ErrorAction SilentlyContinue
    if ($legacy) { $legacy | Remove-NetFirewallRule -ErrorAction SilentlyContinue; Write-Host "  removed." }
    else { Write-Host "  (not present)" }
} catch { Write-Host "  (skipped — needs admin)" }

Write-Host "Removing any legacy URL ACL '$url' ..."
try {
    & netsh http delete urlacl url=$url 2>&1 | Out-Null
    Write-Host "  done."
} catch { Write-Host "  (skipped)" }

Write-Host ""
Write-Host "Bridge uninstalled." -ForegroundColor Green
