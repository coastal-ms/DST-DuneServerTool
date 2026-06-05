<#
.SYNOPSIS
    Cleanly removes the DST Friend Helper bridge from Neil's PC.

.DESCRIPTION
    Reverses every step taken by Install-Bridge.ps1: unregisters the
    scheduled task, removes the firewall rule, and deletes the URL ACL.
    Each step is best-effort — missing artifacts are not errors.

    Must be run elevated (admin).
#>

[CmdletBinding()]
param(
    [int]$Port = 47900,
    [string]$TaskName = 'DST Friend Helper Bridge'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Elevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($id)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Uninstall-Bridge.ps1 must be run from an elevated (admin) PowerShell."
    }
}

Assert-Elevated

$ruleName = "DST Friend Helper Bridge ($Port/TCP, Tailscale)"
$url = "http://+:$Port/"

Write-Host "Stopping + unregistering scheduled task '$TaskName' ..."
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "  removed."
} else {
    Write-Host "  (not present)"
}

Write-Host "Removing firewall rule '$ruleName' ..."
if (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $ruleName
    Write-Host "  removed."
} else {
    Write-Host "  (not present)"
}

Write-Host "Removing URL ACL '$url' ..."
$out = & netsh http delete urlacl url=$url 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  removed."
} else {
    Write-Host "  (not present or already removed)"
}

Write-Host ""
Write-Host "Bridge uninstalled." -ForegroundColor Green
