# MobileBridge.ps1 — manage the DST mobile-app bridge.
#
# The mobile app reaches the localhost-only DST API through a small reverse-proxy
# "bridge" (helper/bridge/DstHelperBridge.ps1) that listens on a STABLE port on
# the Tailscale interface and forwards to DST's dynamic loopback port. Three host
# pieces make that work, all created by helper/bridge/Install-Bridge.ps1:
#   1. a URL ACL so the bridge can bind http://+:<port>/ without admin at runtime,
#   2. an inbound Windows Firewall rule scoped to the Tailscale interface,
#   3. a self-healing scheduled task that keeps the daemon running.
#
# This module is the single source of truth for the bridge PORT (so pairing,
# install, and status never drift), plus:
#   * Get-DuneBridgeStatus     — actionable health snapshot (used by the UI).
#   * Invoke-DuneBridgeRepair  — (re)run the bundled installer; elevation-guarded.
#   * Initialize-DuneMobileBridge — best-effort startup auto-heal for the common
#     case where Tailscale wasn't up at install time so the firewall step failed.

# Canonical bridge port. Must match Install-Bridge.ps1's default and the mobile
# app's manual-entry default. Change here only.
$script:DuneMobileBridgePort     = 47900
$script:DuneMobileBridgeTaskName = 'DST Friend Helper Bridge'
$script:DuneMobileBridgeRuleLike = '*Friend Helper Bridge*'

function Get-DuneMobileBridgePort {
    return $script:DuneMobileBridgePort
}

# Resolve the bundled Install-Bridge.ps1 across dev and installed layouts.
#   installed: {app}\server\lib  -> ..\..\helper\bridge
#   dev:       app\server\lib    -> ..\..\..\helper\bridge
function Get-DuneBridgeInstallerPath {
    foreach ($cand in @(
        (Join-Path $PSScriptRoot '..\..\helper\bridge\Install-Bridge.ps1'),
        (Join-Path $PSScriptRoot '..\..\..\helper\bridge\Install-Bridge.ps1')
    )) {
        try { return (Resolve-Path -LiteralPath $cand -ErrorAction Stop).Path } catch {}
    }
    return $null
}

function Test-DuneBridgeElevated {
    if (Get-Command Test-DuneAdminElevated -ErrorAction SilentlyContinue) {
        return [bool](Test-DuneAdminElevated)
    }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-DuneBridgeTailscaleInfo {
    $up = $false; $ip = $null
    try {
        if (Get-Command Get-DuneTailscaleStatus -ErrorAction SilentlyContinue) {
            $ts = Get-DuneTailscaleStatus
            if ($ts -and $ts.installed -and $ts.available -and $ts.self -and $ts.self.tailscaleIPs -and $ts.self.tailscaleIPs.Count -gt 0) {
                $up = $true
                $ip = [string]$ts.self.tailscaleIPs[0]
            }
        }
    } catch {}
    return @{ up = $up; ip = $ip }
}

# Health snapshot. Safe to call when NOT elevated — every probe degrades to a
# negative rather than throwing. Returns a hashtable the UI renders directly.
function Get-DuneBridgeStatus {
    $port = $script:DuneMobileBridgePort

    $elevated = Test-DuneBridgeElevated
    $ts = Get-DuneBridgeTailscaleInfo

    $hasRule = $false
    try { $hasRule = [bool](Get-NetFirewallRule -DisplayName $script:DuneMobileBridgeRuleLike -ErrorAction SilentlyContinue) } catch {}

    $hasTask = $false; $taskState = 'Absent'
    try {
        $task = Get-ScheduledTask -TaskName $script:DuneMobileBridgeTaskName -ErrorAction SilentlyContinue
        if ($task) { $hasTask = $true; $taskState = [string]$task.State }
    } catch {}

    $listening = $false
    try { $listening = [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) } catch {}

    $healthOk = $false
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/_dst/health" -TimeoutSec 4 -ErrorAction Stop
        $healthOk = [bool]$h.ok
    } catch {}

    $issues = New-Object System.Collections.Generic.List[string]
    if (-not $ts.up)      { [void]$issues.Add('Tailscale is not installed or not connected on this PC.') }
    if (-not $hasRule)    { [void]$issues.Add('The Windows Firewall rule for the mobile bridge is missing.') }
    if (-not $hasTask)    { [void]$issues.Add('The mobile bridge background task is not installed.') }
    if (-not $listening)  { [void]$issues.Add("Nothing is listening on bridge port $port.") }
    elseif (-not $healthOk) { [void]$issues.Add('The bridge is running but not responding yet (DST may still be starting).') }

    $ready = ($ts.up -and $hasRule -and $listening -and $healthOk)

    return @{
        ready        = $ready
        port         = $port
        elevated     = $elevated
        canRepair    = $elevated
        tailscaleUp  = $ts.up
        tailscaleIp  = $ts.ip
        firewallRule = $hasRule
        task         = $hasTask
        taskState    = $taskState
        listening    = $listening
        healthOk     = $healthOk
        issues       = @($issues)
    }
}

# (Re)install the bridge by running the bundled, idempotent installer. Requires
# elevation (firewall + URL ACL). Returns @{ ok; error?; status? }.
function Invoke-DuneBridgeRepair {
    param([switch]$NoWait)

    if (-not (Test-DuneBridgeElevated)) {
        return @{ ok = $false; error = 'Dune Server Tool is not running as Administrator, so it cannot change the Windows Firewall. Restart DST as administrator and try again.' }
    }
    $ts = Get-DuneBridgeTailscaleInfo
    if (-not $ts.up) {
        return @{ ok = $false; error = 'Tailscale is not installed or not connected on this PC. Install Tailscale and sign in, then repair the bridge.' }
    }
    $installer = Get-DuneBridgeInstallerPath
    if (-not $installer) {
        return @{ ok = $false; error = 'Could not find the bridge installer (helper\bridge\Install-Bridge.ps1) in the DST installation.' }
    }
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell.exe -ErrorAction SilentlyContinue)?.Source }
    if (-not $pwsh) {
        return @{ ok = $false; error = 'PowerShell executable not found to run the bridge installer.' }
    }

    $args = @('-NoLogo','-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File', $installer, '-Port', $script:DuneMobileBridgePort)
    try {
        if ($NoWait) {
            Start-Process -FilePath $pwsh -ArgumentList $args -WindowStyle Hidden | Out-Null
            return @{ ok = $true; started = $true }
        }
        $p = Start-Process -FilePath $pwsh -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            return @{ ok = $false; error = "Bridge setup exited with code $($p.ExitCode)." }
        }
    } catch {
        return @{ ok = $false; error = "Bridge setup failed: $($_.Exception.Message)" }
    }
    Start-Sleep -Milliseconds 800
    return @{ ok = $true; status = (Get-DuneBridgeStatus) }
}

# Startup auto-heal. Best-effort and non-blocking: only acts when elevated AND
# Tailscale is up AND something is actually missing, and never throws into the
# startup path. Repairs in the background so it doesn't delay the app window.
function Initialize-DuneMobileBridge {
    param([string]$ServerDir)
    try {
        if (-not (Test-DuneBridgeElevated)) { return }
        $st = Get-DuneBridgeStatus
        if (-not $st.tailscaleUp) { return }
        if ($st.firewallRule -and $st.task -and $st.listening) { return }  # already healthy
        [void](Invoke-DuneBridgeRepair -NoWait)
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "MobileBridge: auto-heal triggered (rule=$($st.firewallRule) task=$($st.task) listening=$($st.listening))."
        }
    } catch {}
}
