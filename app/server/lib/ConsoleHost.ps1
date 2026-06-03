# ConsoleHost — links the DuneServer console + the DuneShell app window so they
# share a single lifecycle, and lets the user pick how the console presents
# itself (minimized vs. system tray) while the app window is open.
#
# Invariants (one console + one app window per machine, see DuneServer.ps1):
#   * Closing the app window shuts the server (console) down — real-time, via a
#     watcher runspace that calls $listener.Stop().
#   * Closing the console / picking tray "Quit" also closes the app window —
#     symmetric cleanup in Stop-DuneConsoleLifecycle.
#
# Elevation note: DuneServer.exe runs ELEVATED, DuneShell.exe runs non-elevated.
# An elevated process is allowed to WaitForExit/Stop-Process a non-elevated one,
# so the (admin) console must be the watcher — never the other way around.

# Cache the Win32 console-window P/Invoke. A distinct type name avoids clashing
# with DuneServer.DuneNativeWin (added only in the compiled-exe startup path).
function Get-DuneConsoleNativeType {
    if (-not ('DuneServer.DuneConsoleNative' -as [type])) {
        Add-Type -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@ -Name 'DuneConsoleNative' -Namespace 'DuneServer' -ErrorAction Stop
    }
    return [DuneServer.DuneConsoleNative]
}

# Cross-runspace signal: the app-window watcher runs in its own runspace and
# can't read $script:DuneAppDetached from the main runspace. The "Web Portal"
# detach route writes this marker so the watcher knows to skip its usual
# "shell exited -> stop listener" teardown. The marker is also a breadcrumb
# for the NEXT launch: if it exists when a fresh DuneServer starts, the prior
# console was detached and must be killed before we proceed.
function Get-DuneDetachStateFile {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    return (Join-Path $dir 'detached.flag')
}

function Set-DuneAppDetached {
    $script:DuneAppDetached = $true
    try {
        $file = Get-DuneDetachStateFile
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $payload = @{
            pid       = $PID
            timestamp = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress
        Set-Content -LiteralPath $file -Value $payload -Encoding UTF8 -Force
    } catch { }
}

function Clear-DuneAppDetached {
    $script:DuneAppDetached = $false
    try {
        $file = Get-DuneDetachStateFile
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# Two-button first-run dialog. Returns 'console' or 'tray' ('console' on any
# failure so we never end up with a hidden, unmanaged console).
function Show-DuneConsolePresencePrompt {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch { return 'console' }
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Dune Server Tool'
        $form.FormBorderStyle = 'FixedDialog'
        $form.StartPosition = 'CenterScreen'
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.TopMost = $true
        $form.ClientSize = New-Object System.Drawing.Size(460, 180)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "While the app window is open, how should the Dune Server console behave?`r`n`r`nClosing the app window always shuts the server down. You can change this after the next update."
        $lbl.SetBounds(16, 14, 428, 80)
        $form.Controls.Add($lbl)

        $btnMin = New-Object System.Windows.Forms.Button
        $btnMin.Text = 'Minimize to taskbar'
        $btnMin.SetBounds(20, 120, 200, 40)
        $btnMin.DialogResult = [System.Windows.Forms.DialogResult]::No
        $form.Controls.Add($btnMin)

        $btnTray = New-Object System.Windows.Forms.Button
        $btnTray.Text = 'Send to system tray'
        $btnTray.SetBounds(240, 120, 200, 40)
        $btnTray.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($btnTray)

        $form.AcceptButton = $btnMin
        $result = $form.ShowDialog()
        try { $form.Dispose() } catch {}
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return 'tray' }
        return 'console'
    } catch { return 'console' }
}

# Decide the console mode for THIS launch. Prompts once per tool version
# ("remember until next update"): the stored choice is reused only while its
# saved version matches the current one, otherwise we re-ask.
function Resolve-DuneConsoleMode {
    $raw       = Read-DuneConfigRaw
    $stored    = if ($raw.Contains('ConsolePresence')) { [string]$raw['ConsolePresence'] } else { '' }
    $storedVer = if ($raw.Contains('ConsolePresenceVersion')) { [string]$raw['ConsolePresenceVersion'] } else { '' }
    $cur       = [string]$script:DuneToolVersion
    $valid     = ($stored -eq 'console' -or $stored -eq 'tray')

    if ($valid -and $storedVer -eq $cur) { return $stored }

    # Only a real (compiled-exe) console is worth prompting about; dev pwsh runs
    # just default to a minimized console without nagging or persisting.
    if (-not $script:DuneIsCompiledExe) { return 'console' }

    $mode = Show-DuneConsolePresencePrompt
    try { Save-DuneConfig @{ ConsolePresence = $mode; ConsolePresenceVersion = $cur } | Out-Null } catch {}
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "Console presence chosen: $mode (remembered for v$cur)"
    }
    return $mode
}

# System-tray host on a dedicated STA thread (a NotifyIcon needs a message
# pump, which the blocking server loop can't provide). Self-terminates when the
# listener goes down, so it cleans up no matter why the server stopped.
# Returns $true only when the tray thread was started.
function Start-DuneTrayIcon {
    param([Parameter(Mandatory)]$Listener)
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Listener', $Listener)
        $rs.SessionStateProxy.SetVariable('IconPath', $script:DuneIconPath)
        $rs.SessionStateProxy.SetVariable('AppExe',   $script:DuneShellExe)
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            try {
                Add-Type -AssemblyName System.Windows.Forms
                Add-Type -AssemblyName System.Drawing

                # Trap exceptions raised inside the message pump (e.g. a
                # PipelineStoppedException injected if the host force-stops this
                # runspace during shutdown) so WinForms never pops its own
                # unhandled-exception dialog. Must be set before any UI is built.
                try {
                    [System.Windows.Forms.Application]::SetUnhandledExceptionMode(
                        [System.Windows.Forms.UnhandledExceptionMode]::CatchException)
                    [System.Windows.Forms.Application]::add_ThreadException({
                        param($eventSender, $eventArgs)
                        try { [System.Windows.Forms.Application]::ExitThread() } catch {}
                    })
                } catch {}

                $ni = New-Object System.Windows.Forms.NotifyIcon
                $icon = $null
                try {
                    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
                        if ($IconPath -match '\.ico$') { $icon = New-Object System.Drawing.Icon $IconPath }
                        else { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($IconPath) }
                    }
                } catch {}
                if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Application }
                $ni.Icon = $icon
                $ni.Text = 'Dune Server Tool'
                $ni.Visible = $true

                $openApp = {
                    try { if ($AppExe -and (Test-Path -LiteralPath $AppExe)) { Start-Process -FilePath $AppExe } } catch {}
                }
                $menu = New-Object System.Windows.Forms.ContextMenuStrip
                $miOpen = $menu.Items.Add('Open Dune Server Tool')
                $miOpen.add_Click($openApp)
                $miQuit = $menu.Items.Add('Quit (stop server)')
                $miQuit.add_Click({
                    try { $ni.Visible = $false } catch {}
                    try { $Listener.Stop() } catch {}
                })
                $ni.ContextMenuStrip = $menu
                $ni.add_MouseDoubleClick($openApp)

                # When the listener stops (app closed, Quit, shutdown) tear down.
                $timer = New-Object System.Windows.Forms.Timer
                $timer.Interval = 500
                $timer.add_Tick({
                    $up = $false
                    try { $up = $Listener.IsListening } catch { $up = $false }
                    if (-not $up) {
                        try { $timer.Stop() } catch {}
                        try { $ni.Visible = $false; $ni.Dispose() } catch {}
                        [System.Windows.Forms.Application]::ExitThread()
                    }
                })
                $timer.Start()

                [System.Windows.Forms.Application]::Run()
                try { $ni.Dispose() } catch {}
            } catch {}
        })
        $script:DuneTrayPs     = $ps
        $script:DuneTrayRs     = $rs
        $script:DuneTrayHandle = $ps.BeginInvoke()
        return $true
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Tray icon failed to start: $($_.Exception.Message)" 'WARN'
        }
        return $false
    }
}

# Arm the app-window watcher + apply the chosen console presentation. Called
# from Start-DuneHttpServer once the listener is bound. No-op unless an app
# window was launched (browser-fallback launches have nothing to watch).
function Start-DuneConsoleLifecycle {
    param([Parameter(Mandatory)]$Listener)

    if (-not $script:DuneAppProc) { return }
    $mode = if ($script:DuneConsoleMode) { $script:DuneConsoleMode } else { 'console' }
    Clear-DuneAppDetached

    # 1. Real-time linkage: app window closes -> stop listener -> server exits.
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('AppProc',  $script:DuneAppProc)
        $rs.SessionStateProxy.SetVariable('Listener', $Listener)
        $rs.SessionStateProxy.SetVariable('DetachStateFile', (Get-DuneDetachStateFile))
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            # Follow the chain of app windows rather than nuking the server the
            # instant the FIRST watched window exits. DuneShell is single-instance
            # (Global mutex): right after an update/relaunch the server launches a
            # fresh DuneShell that may exit immediately because an older window
            # still owns the mutex. Stopping the listener on that instantaneous
            # exit kills a brand-new server out from under the surviving window
            # ("Connecting... attempt N" forever). So: when the watched window
            # exits, only stop the server if NO DuneShell survives a short grace
            # window; if one does, re-arm on it and keep serving.
            #
            # ALSO: the "Web Portal" sidebar button sets a detach flag via
            # /api/portal/open-in-browser before asking the shell to close. In
            # that case we exit WITHOUT stopping the listener so the server
            # stays up for the user's browser tab. The flag is written to a
            # file because this watcher runs in a separate runspace and can't
            # see $script:DuneAppDetached directly.
            $proc = $AppProc
            while ($true) {
                try { $proc.WaitForExit() } catch {}

                # Intentional detach takes priority over the survivor chain —
                # no need to wait 6s if the user explicitly asked to detach.
                $detached = $false
                try {
                    if ($DetachStateFile -and (Test-Path -LiteralPath $DetachStateFile)) {
                        $detached = $true
                    }
                } catch { $detached = $false }
                if ($detached) { return }

                $survivor = $null
                $deadline = (Get-Date).AddSeconds(6)
                while ((Get-Date) -lt $deadline) {
                    try {
                        $alive = @(Get-Process -Name 'DuneShell' -ErrorAction SilentlyContinue |
                                   Sort-Object StartTime -Descending)
                    } catch { $alive = @() }
                    if ($alive.Count -gt 0) { $survivor = $alive[0]; break }
                    Start-Sleep -Milliseconds 400
                }
                if ($survivor) { $proc = $survivor; continue }
                break
            }
            try { $Listener.Stop() } catch {}
        })
        $script:DuneWatcherPs     = $ps
        $script:DuneWatcherRs     = $rs
        $script:DuneWatcherHandle = $ps.BeginInvoke()
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "App-window watcher armed (PID $($script:DuneAppProc.Id)); closing the app window stops the server (unless the Web Portal button detaches it)"
        }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Failed to arm app-window watcher: $($_.Exception.Message)" 'WARN'
        }
    }

    # 2. Console presentation (compiled exe only; dev pwsh has no own console).
    if (-not $script:DuneIsCompiledExe) { return }
    try {
        $native = Get-DuneConsoleNativeType
        $hwnd = $native::GetConsoleWindow()
        if ($hwnd -ne [System.IntPtr]::Zero) {
            if ($mode -eq 'tray') {
                if (Start-DuneTrayIcon -Listener $Listener) {
                    [void]$native::ShowWindow($hwnd, 0)   # SW_HIDE
                } else {
                    [void]$native::ShowWindow($hwnd, 7)   # SW_SHOWMINNOACTIVE (tray failed)
                }
            } else {
                [void]$native::ShowWindow($hwnd, 7)       # SW_SHOWMINNOACTIVE
            }
        }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Console presentation failed: $($_.Exception.Message)" 'WARN'
        }
    }
}

# Symmetric teardown, run from DuneServer.ps1's finally. If the server stopped
# for a reason OTHER than the app window closing (tray Quit, console close),
# kill the app window too so no orphan lingers; then dispose helper runspaces.
#
# Both helpers self-terminate: the watcher returns once the app proc exits, the
# tray thread exits once its timer sees the listener is down. We wait briefly
# for that graceful exit rather than calling PowerShell.Stop(): stopping the
# tray pipeline mid message-pump injects a PipelineStoppedException that WinForms
# turns into a .NET unhandled-exception dialog on shutdown.
function Stop-DuneConsoleLifecycle {
    try {
        # When detached, the user already closed the app window themselves and
        # explicitly asked us to keep going. Don't try to kill a process that's
        # already gone, and don't disturb anything else.
        if (-not $script:DuneAppDetached) {
            if ($script:DuneAppProc -and -not $script:DuneAppProc.HasExited) {
                try { Stop-Process -Id $script:DuneAppProc.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}

    foreach ($trip in @(
        ,@($script:DuneWatcherPs, $script:DuneWatcherRs, $script:DuneWatcherHandle)
        ,@($script:DuneTrayPs,    $script:DuneTrayRs,    $script:DuneTrayHandle)
    )) {
        $p = $trip[0]; $r = $trip[1]; $h = $trip[2]
        try { if ($h -and -not $h.IsCompleted) { [void]$h.AsyncWaitHandle.WaitOne(2000) } } catch {}
        try { if ($p -and $h) { $p.EndInvoke($h) } } catch {}
        try { if ($p) { $p.Dispose() } } catch {}
        try { if ($r) { $r.Dispose() } } catch {}
    }
    $script:DuneWatcherPs = $null; $script:DuneWatcherRs = $null; $script:DuneWatcherHandle = $null
    $script:DuneTrayPs    = $null; $script:DuneTrayRs    = $null; $script:DuneTrayHandle    = $null

    # Clear the detach marker on a clean shutdown so the next launch starts
    # from a known state. The next launch ALSO clears it after handling, so
    # this is just defense-in-depth (the marker is only meaningful while a
    # detached server is alive in the background).
    Clear-DuneAppDetached
}
