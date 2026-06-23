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
    [string]$TaskName = 'DST Friend Helper Bridge',
    # When set, register the task to run "whether the user is logged on or not"
    # (LogonType S4U) with a boot trigger, so the bridge survives sign-out — used
    # by DST's "Stay online when signed out" service mode. The bridge is
    # loopback-only and needs no profile secrets, so S4U (no password) is enough.
    [switch]$RunWhenSignedOut
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Ensure-ScheduledTask {
    param(
        [string]$TaskName,
        [int]$Port,
        [string]$BridgeScriptPath,
        [switch]$RunWhenSignedOut
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

    # Action: when signed-out (S4U / session 0) there is no interactive desktop to
    # flash a console on, so launch pwsh DIRECTLY on the supervisor (the VBS shim
    # exists only to hide the console in an interactive session and can misbehave
    # without a desktop). When running interactively, keep the hidden-VBS launch.
    if ($RunWhenSignedOut) {
        $action = New-ScheduledTaskAction -Execute $pwsh `
            -Argument ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $supervisorPs1)
    } else {
        $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launcherVbs`""
    }

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
    # Service mode also needs the bridge up BEFORE anyone signs in (boot), so it's
    # already serving the portal/phone for a host that reboots while signed out.
    $triggers = if ($RunWhenSignedOut) {
        @((New-ScheduledTaskTrigger -AtStartup), $logonTrigger, $keepAlive)
    } else {
        @($logonTrigger, $keepAlive)
    }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -RestartCount 999 `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)

    # S4U = "run whether the user is logged on or not" WITHOUT storing a password.
    # The bridge only binds loopback and proxies to DST, so it needs no network
    # credentials or profile secrets — S4U is sufficient and survives sign-out.
    $principal = if ($RunWhenSignedOut) {
        New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType S4U `
            -RunLevel Limited
    } else {
        New-ScheduledTaskPrincipal `
            -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive `
            -RunLevel Limited
    }

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
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

Ensure-ScheduledTask -TaskName $TaskName -Port $Port -BridgeScriptPath $bridgeScript -RunWhenSignedOut:$RunWhenSignedOut

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
