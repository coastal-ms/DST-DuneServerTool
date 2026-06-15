# Console window control — backs Help → Show / Hide backend console.
#
# Loopback-only: a remote viewer (Tailscale / LAN) with a valid token must NOT
# be able to twiddle the host machine's backend console window. Both endpoints
# reject non-loopback callers with 403.
#
# Compiled-exe-only: dev pwsh has no console of its own to show/hide. The GET
# handler returns available=false in that case so the menu item can be hidden.
#
# Why this exists: until 12.0.24, once tray mode came up the backend console
# was permanently locked at SW_HIDE (see ConsoleHost.ps1) and there was no
# user-facing path to reveal it. Users who wanted to watch the server work
# in real time had no way to bring the console back to a visible window.

function Test-DuneConsoleLoopbackRequest {
    param($req)
    try {
        $remote = $req.RemoteEndPoint.Address
        if ($remote) { return [System.Net.IPAddress]::IsLoopback($remote) }
    } catch {}
    return $false
}

# Reach into the same console hwnd ConsoleHost.ps1 already manages. The native
# type was added by Get-DuneConsoleNativeType either at startup or on first use
# in tray mode; we call the same factory so we share its cached P/Invoke
# instead of redefining a parallel one.
function Get-DuneConsoleHwnd {
    try {
        $native = Get-DuneConsoleNativeType
        return @{ native = $native; hwnd = $native::GetConsoleWindow() }
    } catch {
        return $null
    }
}

# Lazily P/Invoke IsWindowVisible + IsIconic + SetForegroundWindow alongside
# the existing GetConsoleWindow/ShowWindow pair. Same namespace, distinct type
# name so we don't clash with the startup-path or ConsoleHost-path natives.
function Get-DuneConsoleExtraNativeType {
    if (-not ('DuneServer.DuneConsoleExtraNative' -as [type])) {
        Add-Type -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@ -Name 'DuneConsoleExtraNative' -Namespace 'DuneServer' -ErrorAction Stop
    }
    return [DuneServer.DuneConsoleExtraNative]
}

function Get-DuneConsoleState {
    $isCompiled = $false
    try { if ($script:DuneIsCompiledExe) { $isCompiled = $true } } catch {}

    $state = @{
        available = $isCompiled
        visible   = $false
        minimized = $false
    }
    if (-not $isCompiled) { return $state }

    $info = Get-DuneConsoleHwnd
    if (-not $info -or $info.hwnd -eq [System.IntPtr]::Zero) { return $state }
    try {
        $extra = Get-DuneConsoleExtraNativeType
        $state.visible   = [bool]$extra::IsWindowVisible($info.hwnd)
        $state.minimized = [bool]$extra::IsIconic($info.hwnd)
    } catch {}
    return $state
}

# SW_HIDE = 0, SW_SHOWNORMAL = 1, SW_SHOW = 5, SW_RESTORE = 9.
# When asked to show: SW_RESTORE un-minimizes AND brings to normal size, then
# we SetForegroundWindow so it actually pops up where the user is looking
# instead of flashing in the taskbar.
function Set-DuneConsoleVisible {
    param([bool]$Visible)

    $info = Get-DuneConsoleHwnd
    if (-not $info -or $info.hwnd -eq [System.IntPtr]::Zero) {
        return @{ ok = $false; error = 'No console window handle available (running headless or as dev pwsh).' }
    }
    try {
        if ($Visible) {
            [void]$info.native::ShowWindow($info.hwnd, 9)  # SW_RESTORE
            try { [void](Get-DuneConsoleExtraNativeType)::SetForegroundWindow($info.hwnd) } catch {}
        } else {
            [void]$info.native::ShowWindow($info.hwnd, 0)  # SW_HIDE
        }
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

# GET /api/console — current state.
Register-DuneRoute -Method GET -Path '/api/console' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneConsoleLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Backend console can only be managed from the host machine.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneConsoleState)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/console  body: { visible: bool }
Register-DuneRoute -Method POST -Path '/api/console' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneConsoleLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Backend console can only be managed from the host machine.'
            return
        }

        $visible = $null
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('visible')) { $visible = [bool]$body.visible }
        } elseif ($body -and $body.PSObject.Properties.Name -contains 'visible') {
            $visible = [bool]$body.visible
        }
        if ($null -eq $visible) {
            Write-DuneError -Response $res -Status 400 -Message "Missing required field 'visible' (bool)."
            return
        }

        $state = Get-DuneConsoleState
        if (-not $state.available) {
            Write-DuneError -Response $res -Status 400 -Message 'Backend console control is only available from the installed DuneServer.exe (not a dev pwsh build).'
            return
        }

        $result = Set-DuneConsoleVisible -Visible $visible
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status 500 -Message $result.error
            return
        }

        Write-DuneJson -Response $res -Body (Get-DuneConsoleState)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
