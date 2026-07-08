<#
.SYNOPSIS
    Installs the DST mobile/remote bridge as a Scheduled Task on the host's PC.

.DESCRIPTION
    Registers a Scheduled Task that runs a *supervisor loop* under PowerShell 7
    (pwsh.exe) at user logon. The supervisor relaunches DstHelperBridge.ps1
    within seconds whenever it exits (crash, error, or external kill), so the
    bridge self-heals without depending on a restart/keepalive trigger firing. A
    single logon trigger (re)establishes the supervisor after every sign-in; there
    is deliberately NO periodic keepalive trigger, because relaunching the hidden
    helper on a timer in an interactive session can briefly flash a console window
    on the desktop (IgnoreNew still avoids duplicates while it is healthy).

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

    # ----- Silent launch via a VBScript shim -----------------------------------
    # `-WindowStyle Hidden` does NOT reliably suppress the console for a console
    # app (pwsh) started by Task Scheduler in an interactive session: Windows
    # allocates a visible conhost window before the flag applies, so the bridge
    # console kept flashing/staying open. WshShell.Run(cmd, 0, False) creates the
    # process with the window hidden FROM THE START (window style 0), which is the
    # only reliable way to keep it silent (same shim the DST Discord bot uses).
    #
    # The supervisor loop and the VBS shim are generated into a user-writable dir
    # (the install dir under Program Files is read-only at runtime). The supervisor
    # is a real .ps1 file (no console-escaping nightmares): a process-wide mutex
    # makes only ONE supervisor survive (a duplicate exits immediately); it then
    # relaunches the daemon within ~5s whenever it exits. The daemon has its OWN
    # single-instance mutex too (see DstHelperBridge.ps1).
    $dataDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    $supervisorPs1 = Join-Path $dataDir 'bridge-supervisor.ps1'
    $launcherVbs   = Join-Path $dataDir 'run-bridge-hidden.vbs'

    $supervisorBody = @"
`$c = `$false
`$sm = [System.Threading.Mutex]::new(`$true, 'Global\DstBridgeSup_$Port', [ref]`$c)
try { if (-not `$c -and -not `$sm.WaitOne(0)) { return } } catch {}
while (`$true) {
    try { & '$BridgeScriptPath' -Port $Port } catch {}
    Start-Sleep -Seconds 5
}
"@
    Set-Content -LiteralPath $supervisorPs1 -Value $supervisorBody -Encoding UTF8 -Force

    $pwshForVbs = $pwsh -replace '"', '""'
    $supForVbs  = $supervisorPs1 -replace '"', '""'
    $vbsBody = @"
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run """$pwshForVbs"" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$supForVbs""", 0, False
"@
    Set-Content -LiteralPath $launcherVbs -Value $vbsBody -Encoding ASCII -Force

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcherVbs`""

    # A single AtLogOn trigger starts the supervisor when the host user signs in
    # (reboot / re-login). We deliberately do NOT register a periodic keepalive
    # trigger: in an interactive session Task Scheduler relaunches the VBS -> pwsh
    # action every time such a trigger fires, and even the window-hidden shim
    # briefly allocates a console host that can FLASH on the desktop. The
    # supervisor's own loop already relaunches the daemon within ~5s if it crashes,
    # and AtLogOn re-establishes the supervisor after every sign-in, so a periodic
    # relaunch is not worth the visible flash it costs.
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

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
        -Trigger $logonTrigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Reverse-proxies mobile/remote requests on loopback to the locally running DST instance (reached externally via a Cloudflare quick tunnel). Self-healing: a supervisor loop relaunches the daemon within seconds if it crashes or is killed, and an AtLogOn trigger re-establishes the supervisor after each sign-in; IgnoreNew prevents duplicates while it is healthy.' | Out-Null
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
