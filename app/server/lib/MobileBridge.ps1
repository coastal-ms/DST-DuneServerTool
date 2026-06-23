# MobileBridge.ps1 — manage the DST mobile-app bridge.
#
# The mobile app (and a friend's browser) reach the localhost-only DST API over a
# public transport — Tailscale Funnel (preferred) or a Cloudflare named-tunnel +
# Access custom domain. The transport connects OUT from this PC to a small
# reverse-proxy "bridge" (helper/bridge/DstHelperBridge.ps1) that listens on a
# STABLE LOOPBACK port (47900) and forwards to DST's dynamic loopback port.
# Because the transport connects from localhost, the bridge binds 127.0.0.1 only
# — nothing inbound is exposed, so there is NO URL ACL, NO Windows Firewall rule,
# and NO admin requirement. A self-healing scheduled task keeps the daemon
# running, created by helper/bridge/Install-Bridge.ps1.
#
# This module is the single source of truth for the bridge PORT (so pairing,
# install, and status never drift), plus:
#   * Get-DuneBridgeStatus     — actionable LOCAL health snapshot (used by the UI).
#   * Invoke-DuneBridgeRepair  — (re)run the bundled installer (no admin needed).
#   * Initialize-DuneMobileBridge — best-effort startup auto-heal when the task or
#     listener is missing.

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

function Get-DuneBridgeStatus {
    $port = $script:DuneMobileBridgePort

    $elevated = Test-DuneBridgeElevated

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
    if (-not $hasTask)      { [void]$issues.Add('The mobile bridge background task is not installed.') }
    if (-not $listening)    { [void]$issues.Add("Nothing is listening on bridge port $port.") }
    elseif (-not $healthOk) { [void]$issues.Add('The bridge is running but not responding yet (DST may still be starting).') }

    # The bridge is the LOCAL piece; remote reachability is provided separately by
    # the public transport (Tailscale Funnel or the Cloudflare named-tunnel domain).
    # "ready" here means the local loopback proxy is up and answering.
    $ready = ($listening -and $healthOk)

    return @{
        ready        = $ready
        port         = $port
        elevated     = $elevated
        canRepair    = $true
        task         = $hasTask
        taskState    = $taskState
        listening    = $listening
        healthOk     = $healthOk
        issues       = @($issues)
    }
}

# (Re)install the bridge by running the bundled, idempotent installer. Binds
# loopback only, so NO admin is required (no URL ACL, no firewall rule).
# Returns @{ ok; error?; status? }.
function Invoke-DuneBridgeRepair {
    param([switch]$NoWait)

    $installer = Get-DuneBridgeInstallerPath
    if (-not $installer) {
        return @{ ok = $false; error = 'Could not find the bridge installer (helper\bridge\Install-Bridge.ps1) in the DST installation.' }
    }
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $pwsh = if ($pwshCmd) { $pwshCmd.Source } else { $null }
    if (-not $pwsh) {
        $psCmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($psCmd) { $pwsh = $psCmd.Source }
    }
    if (-not $pwsh) {
        return @{ ok = $false; error = 'PowerShell executable not found to run the bridge installer.' }
    }

    # Build a single, properly-quoted argument string. Start-Process -ArgumentList
    # with an ARRAY does not quote elements that contain spaces, and the installer
    # path is under "C:\Program Files\Dune Server\..." — passing it as an array
    # element split the path and made pwsh exit 64 (usage error). A quoted string
    # is the only reliable way to pass a space-containing -File path.
    $argString = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $installer, $script:DuneMobileBridgePort
    try {
        if ($NoWait) {
            Start-Process -FilePath $pwsh -ArgumentList $argString -WindowStyle Hidden | Out-Null
            return @{ ok = $true; started = $true }
        }
        $p = Start-Process -FilePath $pwsh -ArgumentList $argString -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            return @{ ok = $false; error = "Bridge setup exited with code $($p.ExitCode)." }
        }
    } catch {
        return @{ ok = $false; error = "Bridge setup failed: $($_.Exception.Message)" }
    }
    Start-Sleep -Milliseconds 800
    return @{ ok = $true; status = (Get-DuneBridgeStatus) }
}

# Startup auto-heal. Best-effort and non-blocking: only acts when something is
# actually missing (task or listener), and never throws into the startup path.
# Repairs in the background so it doesn't delay the app window. No admin needed
# (loopback bind, user-level scheduled task).
function Initialize-DuneMobileBridge {
    param([string]$ServerDir)
    try {
        $st = Get-DuneBridgeStatus
        if ($st.task -and $st.listening) { return }  # already healthy
        [void](Invoke-DuneBridgeRepair -NoWait)
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "MobileBridge: auto-heal triggered (task=$($st.task) listening=$($st.listening))."
        }
    } catch {}
}
