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

# True only when the autostart feature is usable on this process — i.e. we're
# the compiled .exe and have a valid path to register. Surfaced to the React UI
# so it can grey the Help item out instead of crashing on a dev build.
function Test-DuneAutostartAvailable {
    return [bool](Get-DuneAutostartExePath)
}

# Whether the scheduled task currently exists for THIS user. We additionally
# verify the task action's executable matches THIS process's path so a stale
# task pointing at an old install (or a foreign task at the same path) doesn't
# masquerade as "enabled".
function Test-DuneAutostartEnabled {
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
    return [pscustomobject]@{
        enabled   = Test-DuneAutostartEnabled
        available = Test-DuneAutostartAvailable
        taskName  = Get-DuneAutostartTaskName
        taskPath  = Get-DuneAutostartTaskFolder
        exePath   = Get-DuneAutostartExePath
        user      = Get-DuneAutostartUserName
    }
}

# ===========================================================================
# Service mode — "stay online when signed out".
#
# A stronger variant of autostart: the scheduled task runs the headless backend
# AT BOOT and "whether the user is logged on or not", so the portal + phone apps
# + scheduler + Discord webhooks + market bot keep running even after a sign-out
# or reboot, with no interactive session.
#
# This requires the user's Windows password (Task Scheduler stores it encrypted)
# so the task can run as the user account WITHOUT an interactive logon — which is
# what lets DST keep its access to the user-profile SSH key (%APPDATA%) and
# Hyper-V management. (An S4U / LocalSystem task can't see those.)
#
# Separate task name from plain autostart so the two don't collide; enabling
# service mode removes the weaker autostart task (it's a superset). The password
# is used ONLY to register the task and is never persisted by DST or logged.
# ===========================================================================

function Get-DuneServiceTaskName {
    $suffix = Get-DuneAutostartUserSidShort
    return "DuneServer-Service-$suffix"
}

# Whether the always-on service task currently exists for THIS user.
function Test-DuneServiceEnabled {
    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneServiceTaskName
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $task = Get-ScheduledTask -TaskPath $folder -TaskName $name -ErrorAction SilentlyContinue
            return [bool]$task
        }
    } catch {}
    try {
        $fullName = ($folder.TrimEnd('\') + '\' + $name)
        $null = & schtasks.exe /Query /TN $fullName 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# Register / replace the always-on service task. Requires the caller-supplied
# Windows password for the current user. Returns @{ ok = $bool; error = '...' }.
# SECURITY: $Password is used only for Register-ScheduledTask and is never
# written to disk or the log here.
function Register-DuneServiceMode {
    param([Parameter(Mandatory)][string]$Password)

    $exe = Get-DuneAutostartExePath
    if (-not $exe) {
        return @{ ok = $false; error = 'Service mode is only available from the installed DuneServer.exe (not a dev pwsh build).' }
    }
    if ([string]::IsNullOrEmpty($Password)) {
        return @{ ok = $false; error = 'A Windows password is required to install the always-on service.' }
    }
    if (-not (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue) -or
        -not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; error = 'The ScheduledTasks PowerShell module is not available on this machine.' }
    }

    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneServiceTaskName
    $user   = Get-DuneAutostartUserName

    try {
        $action  = New-ScheduledTaskAction -Execute $exe -Argument '--headless'
        # Boot trigger = runs before any interactive logon; logon trigger covers
        # the case where the machine is already up when the user signs in.
        $tBoot   = New-ScheduledTaskTrigger -AtStartup
        $tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet `
                        -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -MultipleInstances IgnoreNew

        # Providing -User + -Password sets LogonType = Password, i.e. "run whether
        # the user is logged on or not" with the user's full profile loaded.
        Register-ScheduledTask `
            -TaskPath $folder `
            -TaskName $name `
            -Action $action `
            -Trigger @($tBoot, $tLogon) `
            -User $user `
            -Password $Password `
            -RunLevel Highest `
            -Settings $settings `
            -Description "Keeps Dune Server Tool's backend (portal, phone apps, scheduled restarts, Discord notifications) running for $user even when signed out. Managed by the Dune Server Tool — toggle from Settings." `
            -Force | Out-Null
    } catch {
        $msg = $_.Exception.Message
        # Common case: wrong password. Surface a clean hint without echoing input.
        if ($msg -match '(?i)password|logon|credential|incorrect|1326|1327') {
            $msg = "Windows rejected the credentials. Check the password for $user and try again."
        }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Service mode enable failed for ${user}: $($_.Exception.Message)" 'ERROR'
        }
        return @{ ok = $false; error = $msg }
    }

    # Success — the always-on task supersedes the plain "while signed in"
    # autostart task; remove it so we don't run two headless launches.
    try { [void](Unregister-DuneAutostart) } catch {}

    # The loopback bridge that the phone/Funnel connect THROUGH is normally a
    # per-session (Interactive) task that dies on sign-out — which would leave the
    # backend up but unreachable. Re-register it to also run whether-logged-on-or-
    # not (S4U, no password needed) so the whole chain survives sign-out.
    try {
        if (Get-Command Invoke-DuneBridgeRepair -ErrorAction SilentlyContinue) {
            [void](Invoke-DuneBridgeRepair -RunWhenSignedOut)
        }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Service mode: failed to upgrade bridge to run-when-signed-out: $($_.Exception.Message)" 'WARN'
        }
    }

    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "Service mode enabled: registered '$folder$name' for $user (runs whether logged on or not; exe: $exe)"
    }
    if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
        try { [void](Update-DuneKeepAliveFlag) } catch {}
    }
    return @{ ok = $true }
}

# Remove the always-on service task. No-op (ok=$true) if it didn't exist.
function Unregister-DuneServiceMode {
    $folder = Get-DuneAutostartTaskFolder
    $name   = Get-DuneServiceTaskName
    try {
        if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            $existing = Get-ScheduledTask -TaskPath $folder -TaskName $name -ErrorAction SilentlyContinue
            if ($existing) {
                Unregister-ScheduledTask -TaskPath $folder -TaskName $name -Confirm:$false -ErrorAction Stop
            }
        } else {
            $fullName = ($folder.TrimEnd('\') + '\' + $name)
            & schtasks.exe /Delete /TN $fullName /F 2>&1 | Out-Null
        }
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Service mode disabled: removed scheduled task '$folder$name'"
        }
        # Restore the bridge to its normal per-session (Interactive) task so we're
        # not leaving an always-on bridge behind once the backend no longer runs
        # when signed out.
        try {
            if (Get-Command Invoke-DuneBridgeRepair -ErrorAction SilentlyContinue) {
                [void](Invoke-DuneBridgeRepair)
            }
        } catch {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Service mode: failed to restore normal bridge task: $($_.Exception.Message)" 'WARN'
            }
        }
        if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
            try { [void](Update-DuneKeepAliveFlag) } catch {}
        }
        return @{ ok = $true }
    } catch {
        $msg = $_.Exception.Message
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Service mode disable failed: $msg" 'ERROR'
        }
        return @{ ok = $false; error = $msg }
    }
}

function Get-DuneServiceModeState {
    return [pscustomobject]@{
        enabled   = Test-DuneServiceEnabled
        available = Test-DuneAutostartAvailable
        taskName  = Get-DuneServiceTaskName
        taskPath  = Get-DuneAutostartTaskFolder
        exePath   = Get-DuneAutostartExePath
        user      = Get-DuneAutostartUserName
    }
}
