# Platform.ps1 — single source of truth for OS detection + cross-platform
# config/state/cache directory resolution.
#
# Why this exists:
#   DST began life Windows-only. Hyper-V, the WebView2 shell, Task Scheduler
#   autostart, and a pile of `Join-Path $env:APPDATA 'DuneServer'` paths were all
#   written against Windows. The Linux port keeps the Windows code paths
#   byte-for-byte identical and branches new behaviour behind the predicates
#   defined here, so nothing Windows does can regress.
#
# Robust across hosts:
#   * PowerShell 7 (pwsh, the backend's normal host on every platform) defines
#     the automatic variables $IsWindows / $IsLinux / $IsMacOS.
#   * Windows PowerShell 5.1 (the ps2exe build host) does NOT define them, so a
#     bare `$IsWindows` there is $null. We treat "not defined" as Windows, which
#     is correct because 5.1 only exists on Windows.

if (Test-Path variable:global:IsWindows) {
    # PowerShell 6+ : trust the automatic variables.
    $script:DuneIsWindows = [bool]$IsWindows
    $script:DuneIsLinux   = [bool]$IsLinux
    $script:DuneIsMacOS   = [bool]$IsMacOS
} else {
    # Windows PowerShell 5.1 : the automatic vars don't exist; it's Windows.
    $script:DuneIsWindows = $true
    $script:DuneIsLinux   = $false
    $script:DuneIsMacOS   = $false
}

# Coarse label for logs / diagnostics.
$script:DunePlatform = if ($script:DuneIsWindows) { 'Windows' }
                       elseif ($script:DuneIsLinux) { 'Linux' }
                       elseif ($script:DuneIsMacOS) { 'macOS' }
                       else { 'Unknown' }

function Test-DuneIsWindows { return [bool]$script:DuneIsWindows }
function Test-DuneIsLinux   { return [bool]$script:DuneIsLinux }
function Test-DuneIsMacOS   { return [bool]$script:DuneIsMacOS }

function Get-DunePlatform   { return $script:DunePlatform }

# ---------------------------------------------------------------------------
# Directory helpers.
#
# On Windows these resolve under %APPDATA% / %LOCALAPPDATA%. On Linux the entry
# point (DuneServer-Linux.ps1) remaps those same env vars to the XDG base dirs
# BEFORE any lib loads, so the historical `Join-Path $env:APPDATA 'DuneServer'`
# expressions scattered through the codebase already resolve correctly. These
# helpers are the preferred entry point for NEW code; existing call sites keep
# working unchanged through the env-var shim.
#
#   Get-DuneConfigDir -> %APPDATA%\DuneServer        (~/.config/DuneServer)
#   Get-DuneStateDir  -> %LOCALAPPDATA%\DuneServer    (~/.local/state/DuneServer)
# ---------------------------------------------------------------------------

function Get-DuneConfigDir {
    [CmdletBinding()]
    param([switch]$Create)
    $base = $env:APPDATA
    if (-not $base) {
        # Defensive fallback if the shim somehow didn't run (e.g. a bare unit
        # test). Mirror the entry point's XDG choice.
        $userHome = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath('UserProfile') }
        $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userHome '.config' }
    }
    $dir = Join-Path $base 'DuneServer'
    if ($Create -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-DuneStateDir {
    [CmdletBinding()]
    param([switch]$Create)
    $base = $env:LOCALAPPDATA
    if (-not $base) {
        $userHome = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath('UserProfile') }
        $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $userHome '.local/state' }
    }
    $dir = Join-Path $base 'DuneServer'
    if ($Create -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}
