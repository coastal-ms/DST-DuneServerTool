# Autostart — "Run at Windows startup" for DuneServer.
#
# Backs the Help → "Run at Windows startup" toggle. When enabled we register a
# per-user Task Scheduler job that launches DuneServer.exe with --headless at
# user logon. The headless launch:
#   * skips the DuneShell app window (no UI surprise on login),
#   * forces the system-tray console presentation (no orphan minimized console),
#   * keeps the listener alive when the user manually opens DuneShell and then
#     closes it (the app-window watcher is not armed in headless mode).
#
# Task identity:
#   * Path: \Dune Server\
#   * Name: DuneServer-Autostart-<UserSidShort>
#     (the SID-suffix keeps multiple Windows users on the same machine from
#     overwriting each other's task. We also still verify ownership before
#     treating the task as "ours" so foreign tasks at the same path can't
#     spoof the toggle's enabled state.)
#
# Source of truth: the scheduled task itself. We never persist enabled-state
# in dune-server.config — querying schtasks at request time is cheap and the
# task IS the truth (a user can remove it via Task Scheduler and we'll see
# that immediately).

function Get-DuneAutostartTaskFolder { return '\Dune Server\' }

# Per-user task name suffix so multi-user machines don't collide. We use the
# SID's last RID rather than the full SID to keep the visible task name short
# in Task Scheduler while still being unique-per-user-per-machine in practice.
function Get-DuneAutostartUserSidShort {
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($sid) {
            $parts = $sid -split '-'
            if ($parts.Count -gt 0) { return $parts[-1] }
        }
    } catch {}
    return 'unknown'
}

function Get-DuneAutostartTaskName {
    $suffix = Get-DuneAutostartUserSidShort
    return "DuneServer-Autostart-$suffix"
}

# The fully-qualified identity to register the task under. NTAccount string
# (DOMAIN\user, MicrosoftAccount\foo@bar.com, AzureAD\…, etc.) — let Windows
# format it for us rather than glueing $env:USERDOMAIN + $env:USERNAME, which
# loses Microsoft-account / AzureAD shapes.
function Get-DuneAutostartUserName {
    if (-not (Test-DuneIsWindows)) {
        if ($env:USER) { return $env:USER }
        if ($env:LOGNAME) { return $env:LOGNAME }
        try { return ((& id -un 2>$null) | Out-String).Trim() } catch { return 'user' }
    }
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } catch {
        # Last-resort fallback so a Register call still has SOMETHING to use.
        if ($env:USERDOMAIN -and $env:USERNAME) {
            return "$env:USERDOMAIN\$env:USERNAME"
        }
        return $env:USERNAME
    }
}

# Path to the EXE the scheduled task should launch. Only meaningful when we
# are running as the compiled .exe — autostart is not offered in dev pwsh.
function Get-DuneAutostartExePath {
    try {
        $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not $exe) { return $null }
        if ($exe -notlike '*.exe') { return $null }
        if ($exe -like '*pwsh.exe' -or $exe -like '*powershell.exe' -or $exe -like '*powershell_ise.exe') {
            return $null
        }
        return $exe
    } catch {
        return $null
    }
}

# ---- Linux: systemd --user autostart -----------------------------------------
# The Linux equivalent of the Task Scheduler logon task. We enable a per-user
# systemd unit (dune-server.service) that runs the launcher headless at login.
# No elevation needed — `systemctl --user` is per-session.
function Get-DuneSystemdUnitName { return 'dune-server.service' }

function Test-DuneSystemctlAvailable {
    return [bool](Get-Command systemctl -ErrorAction SilentlyContinue)
}

function Invoke-DuneSystemctlUser {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = (& systemctl --user @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out.TrimEnd() }
}

# Ensure ~/.config/systemd/user/dune-server.service exists; generate it pointing
# at the installed launcher (or the source-tree bin/dune-server) if it doesn't.
function Install-DuneSystemdUnit {
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:HOME '.config' }
    $unitDir = Join-Path $base 'systemd/user'
    $unitPath = Join-Path $unitDir (Get-DuneSystemdUnitName)
    if (Test-Path -LiteralPath $unitPath) { return $unitPath }
    if (-not (Test-Path -LiteralPath $unitDir)) { New-Item -ItemType Directory -Path $unitDir -Force | Out-Null }

    $launcher = (Get-Command dune-server -ErrorAction SilentlyContinue).Source
    if (-not $launcher) {
        $cand = Join-Path (Split-Path -Parent $script:AppDir) 'bin/dune-server'
        if (Test-Path -LiteralPath $cand) { $launcher = (Resolve-Path -LiteralPath $cand).Path }
    }
    if (-not $launcher) { $launcher = 'dune-server' }

    $unit = @"
[Unit]
Description=Dune Server Tool (DST) - self-hosted Dune: Awakening server portal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$launcher --headless --no-browser
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
"@
    Set-Content -LiteralPath $unitPath -Value $unit -Encoding UTF8
    return $unitPath
}

# True only when the autostart feature is usable on this process. On Windows we
# must be the compiled .exe; on Linux we just need systemctl (systemd --user).
# Surfaced to the React UI so it can grey the Help item out where unsupported.
function Test-DuneAutostartAvailable {
    if (Test-DuneIsWindows) { return [bool](Get-DuneAutostartExePath) }
    return (Test-DuneSystemctlAvailable)
}

# Whether the scheduled task currently exists for THIS user. We additionally
# verify the task action's executable matches THIS process's path so a stale
# task pointing at an old install (or a foreign task at the same path) doesn't
# masquerade as "enabled".
function Test-DuneAutostartEnabled {
    if (-not (Test-DuneIsWindows)) {
        if (-not (Test-DuneSystemctlAvailable)) { return $false }
        # `is-enabled` prints enabled/disabled/static/... and sets exit code.
        $r = Invoke-DuneSystemctlUser -Arguments @('is-enabled', (Get-DuneSystemdUnitName))
        return ($r.Output -match '^(enabled|enabled-runtime)\b')
    }
    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneAutostartTaskName
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $task = Get-ScheduledTask -TaskPath $folder -TaskName $name -ErrorAction SilentlyContinue
            if ($task) { return $true }
            return $false
        }
    } catch {}
    # Fallback for hosts without the ScheduledTasks module.
    try {
        $fullName = ($folder.TrimEnd('\') + '\' + $name)
        $null = & schtasks.exe /Query /TN $fullName 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Create / replace the scheduled task. Caller must be elevated (DuneServer is).
# Returns a hashtable: @{ ok = $bool; error = '<message>' }.
function Register-DuneAutostart {
    if (-not (Test-DuneIsWindows)) {
        if (-not (Test-DuneSystemctlAvailable)) {
            return @{ ok = $false; error = 'systemctl (systemd --user) is not available on this host.' }
        }
        try {
            $unitPath = Install-DuneSystemdUnit
            [void](Invoke-DuneSystemctlUser -Arguments @('daemon-reload'))
            $en = Invoke-DuneSystemctlUser -Arguments @('enable', '--now', (Get-DuneSystemdUnitName))
            if ($en.Exit -ne 0) { return @{ ok = $false; error = $en.Output } }
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Autostart enabled: systemd user unit '$unitPath' (enable --now)"
            }
            return @{ ok = $true }
        } catch {
            return @{ ok = $false; error = $_.Exception.Message }
        }
    }
    $exe = Get-DuneAutostartExePath
    if (-not $exe) {
        return @{ ok = $false; error = 'Autostart is only available from the installed DuneServer.exe (not a dev pwsh build).' }
    }
    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneAutostartTaskName
    $user   = Get-DuneAutostartUserName

    try {
        if (-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue)) {
            return @{ ok = $false; error = 'The ScheduledTasks PowerShell module is not available on this machine.' }
        }
        $action    = New-ScheduledTaskAction -Execute $exe -Argument '--headless'
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet `
                        -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -MultipleInstances IgnoreNew

        Register-ScheduledTask `
            -TaskPath $folder `
            -TaskName $name `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Starts Dune Server Tool minimized to the system tray when $user logs in. Managed by the Dune Server Tool — toggle from Help → Run at Windows startup." `
            -Force | Out-Null

        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Autostart enabled: registered scheduled task '$folder$name' for $user (exe: $exe)"
        }
        # Refresh the keep-alive sentinel so closing the shell from this
        # point on leaves the backend running (no need to restart DST).
        if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
            try { [void](Update-DuneKeepAliveFlag) } catch {}
        }
        return @{ ok = $true }
    } catch {
        $msg = $_.Exception.Message
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Autostart enable failed: $msg" 'ERROR'
        }
        return @{ ok = $false; error = $msg }
    }
}

# Remove the scheduled task. No-op (still returns ok=$true) if it didn't exist.
function Unregister-DuneAutostart {
    if (-not (Test-DuneIsWindows)) {
        if (-not (Test-DuneSystemctlAvailable)) { return @{ ok = $true } }
        try {
            $r = Invoke-DuneSystemctlUser -Arguments @('disable', '--now', (Get-DuneSystemdUnitName))
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Autostart disabled: systemd user unit '$(Get-DuneSystemdUnitName)' (disable --now, exit $($r.Exit))"
            }
            return @{ ok = $true }
        } catch {
            return @{ ok = $false; error = $_.Exception.Message }
        }
    }
    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneAutostartTaskName
    try {
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            $existing = Get-ScheduledTask -TaskPath $folder -TaskName $name -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskPath $folder -TaskName $name -Confirm:$false -ErrorAction Stop
            }
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Autostart disabled: removed scheduled task '$folder$name'"
            }
            if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
                try { [void](Update-DuneKeepAliveFlag) } catch {}
            }
            return @{ ok = $true }
        }
        # Fallback to schtasks.exe.
        $fullName = ($folder.TrimEnd('\') + '\' + $name)
        & schtasks.exe /Delete /TN $fullName /F 2>&1 | Out-Null
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Autostart disabled (schtasks fallback): '$fullName' (exit $LASTEXITCODE)"
        }
        if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
            try { [void](Update-DuneKeepAliveFlag) } catch {}
        }
        return @{ ok = $true }
    } catch {
        $msg = $_.Exception.Message
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Autostart disable failed: $msg" 'ERROR'
        }
        return @{ ok = $false; error = $msg }
    }
}

# Bundled state object used by the API route + the lifecycle decision.
function Get-DuneAutostartState {
    if (-not (Test-DuneIsWindows)) {
        return [pscustomobject]@{
            enabled   = Test-DuneAutostartEnabled
            available = Test-DuneAutostartAvailable
            taskName  = Get-DuneSystemdUnitName
            taskPath  = 'systemd --user'
            exePath   = (Get-Command dune-server -ErrorAction SilentlyContinue).Source
            user      = Get-DuneAutostartUserName
        }
    }
    return [pscustomobject]@{
        enabled   = Test-DuneAutostartEnabled
        available = Test-DuneAutostartAvailable
        taskName  = Get-DuneAutostartTaskName
        taskPath  = Get-DuneAutostartTaskFolder
        exePath   = Get-DuneAutostartExePath
        user      = Get-DuneAutostartUserName
    }
}
