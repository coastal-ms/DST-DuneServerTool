# Native folder / file picker for the Settings path boxes.
#
# The portal runs in a browser, which cannot return a real filesystem path
# from a file input (security sandbox). Because the HttpListener is local,
# we instead pop a native Windows picker (FolderBrowserDialog /
# OpenFileDialog) server-side and hand the chosen path back to the UI.
#
# WinForms dialogs require an STA apartment, and the HTTP handler thread is
# not guaranteed to be STA, so we run the dialog inside a dedicated STA
# runspace. A hidden TopMost owner form forces the dialog to the
# foreground (otherwise it can open behind the browser window).
#
# This call is intentionally synchronous: the request blocks until the user
# picks or cancels. Folder-picking is a deliberate, quick user action, and
# the portal is single-user/local, so briefly holding the request loop is
# acceptable.

function Invoke-DunePathPicker {
    [CmdletBinding()]
    param(
        [ValidateSet('folder', 'file')][string]$Mode = 'folder',
        [string]$InitialPath = '',
        [string]$Title = '',
        [string]$Filter = 'All files (*.*)|*.*'
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    try {
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            param($Mode, $InitialPath, $Title, $Filter)

            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            Add-Type -AssemblyName System.Drawing | Out-Null

            # Win32 interop to force our owner window to the foreground. A plain
            # TopMost owner form is NOT enough here: DST's UI is hosted in a
            # separate process (DuneShell.exe / WebView2), so when the user
            # clicks Browse that process holds the foreground. Windows'
            # foreground lock then prevents this (DuneServer.exe) process from
            # raising a new window above it, so the picker opens BEHIND the app.
            # AttachThreadInput briefly ties our input queue to the current
            # foreground thread, which lets SetForegroundWindow actually take.
            if (-not ('DuneFg' -as [type])) {
                Add-Type -Namespace '' -Name 'DuneFg' -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
            }

            $forceForeground = {
                param($hWnd)
                try {
                    $fg = [DuneFg]::GetForegroundWindow()
                    $procId = [uint32]0
                    $fgThread  = [DuneFg]::GetWindowThreadProcessId($fg, [ref]$procId)
                    $myThread  = [DuneFg]::GetCurrentThreadId()
                    $attached  = $false
                    if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
                        $attached = [DuneFg]::AttachThreadInput($myThread, $fgThread, $true)
                    }
                    [void][DuneFg]::ShowWindow($hWnd, 5)   # SW_SHOW
                    [void][DuneFg]::BringWindowToTop($hWnd)
                    [void][DuneFg]::SetForegroundWindow($hWnd)
                    if ($attached) { [void][DuneFg]::AttachThreadInput($myThread, $fgThread, $false) }
                } catch { }
            }

            # Hidden, off-screen, top-most owner so the picker is forced to
            # the foreground instead of opening behind the app window.
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost       = $true
            $owner.ShowInTaskbar = $false
            $owner.StartPosition = 'Manual'
            $owner.Location      = New-Object System.Drawing.Point(-3000, -3000)
            $owner.Size          = New-Object System.Drawing.Size(1, 1)
            $owner.Show()
            $owner.Activate()
            & $forceForeground $owner.Handle

            $result = [pscustomobject]@{ cancelled = $true; path = '' }
            try {
                if ($Mode -eq 'file') {
                    $dlg = New-Object System.Windows.Forms.OpenFileDialog
                    if ($Title)  { $dlg.Title  = $Title }
                    if ($Filter) { $dlg.Filter = $Filter }
                    $dlg.CheckFileExists = $true
                    $dlg.Multiselect     = $false
                    if ($InitialPath) {
                        $dir = $InitialPath
                        if (Test-Path -LiteralPath $InitialPath -PathType Leaf) {
                            $dir = Split-Path -Parent $InitialPath
                            $dlg.FileName = Split-Path -Leaf $InitialPath
                        }
                        if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
                    }
                        & $forceForeground $owner.Handle
                        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                            $result.cancelled = $false
                            $result.path      = $dlg.FileName
                        }
                } else {
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    if ($Title) { $dlg.Description = $Title }
                    try { $dlg.UseDescriptionForTitle = $true } catch { }
                    if ($InitialPath) {
                        $dir = $InitialPath
                        if (Test-Path -LiteralPath $InitialPath -PathType Leaf) { $dir = Split-Path -Parent $InitialPath }
                        if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.SelectedPath = $dir }
                    }
                    & $forceForeground $owner.Handle
                    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
                        $result.cancelled = $false
                        $result.path      = $dlg.SelectedPath
                    }
                }
            } finally {
                try { $owner.Close() }   catch { }
                try { $owner.Dispose() } catch { }
            }
            $result
        })
        $null = $ps.AddArgument($Mode)
        $null = $ps.AddArgument($InitialPath)
        $null = $ps.AddArgument($Title)
        $null = $ps.AddArgument($Filter)

        $out = $ps.Invoke()
        $ps.Dispose()
        if ($out -and $out.Count -gt 0) { return $out[$out.Count - 1] }
        return [pscustomobject]@{ cancelled = $true; path = '' }
    } finally {
        try { $rs.Close() }   catch { }
        try { $rs.Dispose() } catch { }
    }
}

# POST /api/browse-path
# Body: { mode: 'folder'|'file', current?: string, title?: string, filter?: string }
# Returns: { ok: true, cancelled: bool, path: string }
Register-DuneRoute -Method POST -Path '/api/browse-path' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $mode    = 'folder'
        $current = ''
        $title   = ''
        $filter  = 'All files (*.*)|*.*'

        if ($body -is [hashtable]) {
            if ($body.Contains('mode')    -and $body['mode'])    { $mode    = [string]$body['mode'] }
            if ($body.Contains('current') -and $body['current']) { $current = [string]$body['current'] }
            if ($body.Contains('title')   -and $body['title'])   { $title   = [string]$body['title'] }
            if ($body.Contains('filter')  -and $body['filter'])  { $filter  = [string]$body['filter'] }
        }
        if ($mode -ne 'file' -and $mode -ne 'folder') { $mode = 'folder' }

        $pick = Invoke-DunePathPicker -Mode $mode -InitialPath $current -Title $title -Filter $filter
        Write-DuneJson -Response $res -Body @{
            ok        = $true
            cancelled = [bool]$pick.cancelled
            path      = [string]$pick.path
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
