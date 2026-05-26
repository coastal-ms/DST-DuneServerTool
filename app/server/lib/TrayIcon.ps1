# TrayIcon.ps1 - System tray (NotifyIcon) for Dune Server.
#
# Runs the WinForms NotifyIcon + message loop on a dedicated STA runspace so
# the main thread can keep blocking on HttpListener.GetContextAsync().
#
# Shared state with the main thread is a synchronized hashtable:
#   $sync.Url            (string) current portal URL (incl. token)
#   $sync.LogPath        (string) path to log file
#   $sync.QuitRequested  (bool)   set true by tray "Quit" menu
#   $sync.Listener       (object) live HttpListener - tray Quit calls .Stop()
#   $sync.Version        (string) version string for tooltip
#
# Public:
#   Start-DuneTrayIcon -State $sync -IconPath '...' -Version '...'
#   Stop-DuneTrayIcon  -State $sync

function Start-DuneTrayIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$IconPath,
        [string]$Version = ''
    )

    if (-not (Test-Path -LiteralPath $IconPath)) {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "TrayIcon: icon not found at $IconPath" 'WARN'
        }
        return
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync',     $State)
    $rs.SessionStateProxy.SetVariable('iconPath', $IconPath)
    $rs.SessionStateProxy.SetVariable('version',  $Version)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing

            $icon   = New-Object System.Drawing.Icon($iconPath)
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon    = $icon
            $notify.Visible = $true
            $notify.Text    = if ($version) { "Dune Server v$version" } else { 'Dune Server' }

            $menu = New-Object System.Windows.Forms.ContextMenuStrip

            $miOpen = $menu.Items.Add('Open Portal')
            $miOpen.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
            $miOpen.Add_Click({
                if ($sync.Url) {
                    try { Start-Process $sync.Url | Out-Null } catch { }
                }
            })

            $miCopy = $menu.Items.Add('Copy URL')
            $miCopy.Add_Click({
                if ($sync.Url) {
                    try { [System.Windows.Forms.Clipboard]::SetText($sync.Url) } catch { }
                }
            })

            [void]$menu.Items.Add('-')

            $miLog = $menu.Items.Add('View Server Log')
            $miLog.Add_Click({
                if ($sync.LogPath -and (Test-Path -LiteralPath $sync.LogPath)) {
                    try { Start-Process notepad.exe -ArgumentList "`"$($sync.LogPath)`"" | Out-Null } catch { }
                }
            })

            $miFolder = $menu.Items.Add('Open Data Folder')
            $miFolder.Add_Click({
                try {
                    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer'
                    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    Start-Process explorer.exe -ArgumentList $dir | Out-Null
                } catch { }
            })

            [void]$menu.Items.Add('-')

            $miAbout = $menu.Items.Add('About Dune Server')
            $miAbout.Add_Click({
                $url = if ($sync.Url) { $sync.Url } else { '(not started)' }
                [System.Windows.Forms.MessageBox]::Show(
                    "Dune Server v$version`n`nWeb portal for the Dune Awakening self-hosted dedicated server.`n`nListening on:`n$url",
                    'Dune Server',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            })

            [void]$menu.Items.Add('-')

            $miQuit = $menu.Items.Add('Quit')
            $miQuit.Add_Click({
                $sync.QuitRequested = $true
                try { if ($sync.Listener) { $sync.Listener.Stop() } } catch { }
                try { $notify.Visible = $false; $notify.Dispose() } catch { }
                [System.Windows.Forms.Application]::Exit()
            })

            $notify.ContextMenuStrip = $menu

            $notify.Add_MouseDoubleClick({
                if ($sync.Url) {
                    try { Start-Process $sync.Url | Out-Null } catch { }
                }
            })

            $sync.TrayReady = $true
            [System.Windows.Forms.Application]::Run()
        } catch {
            $sync.TrayError = $_.Exception.Message
        }
    })

    $handle = $ps.BeginInvoke()
    $State.TrayHandle   = $handle
    $State.TrayPwsh     = $ps
    $State.TrayRunspace = $rs
}

function Stop-DuneTrayIcon {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    try {
        if ($State.TrayPwsh) {
            # Use BeginInvoke against a no-op to flush, then stop.
            try { [System.Windows.Forms.Application]::Exit() } catch { }
            try { $State.TrayPwsh.Stop() } catch { }
            try { $State.TrayPwsh.Dispose() } catch { }
        }
        if ($State.TrayRunspace) {
            try { $State.TrayRunspace.Close()   } catch { }
            try { $State.TrayRunspace.Dispose() } catch { }
        }
    } catch { }
}
