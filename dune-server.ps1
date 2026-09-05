#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # When set, skip the interactive menu and dispatch directly to the named
    # command. Used by the desktop app (app\DuneServer.ps1) to invoke commands
    # inside its embedded terminal pane.
    [string]$Cmd,

    # When set, pause for a keypress before the script exits so the result
    # stays on screen instead of the console window closing instantly. The
    # desktop app passes this for Console-mode commands launched in their own
    # window (Invoke-DuneCommandExternal); without it a quick command like
    # rotate-ssh-key flashes its result/warning and vanishes before it can be
    # read. Never passed for stdout-captured InApp runs.
    [switch]$PauseOnExit
)

# ============================================================
# Dune Awakening Server Management — Extended Menu
# Wraps the original battlegroup.ps1 menu and adds extra tools
# ============================================================

$script:ToolVersion = "15.0.0-phase2-test6.1"

# Cold-boot readiness budgets (seconds). A fresh battlegroup's FIRST boot can
# take 10-30 min: k3s + funcom-operators initialize, metrics-server restarts a
# few times until its serving cert is up, and images may still be pulling. The
# old 180s/120s caps aborted healthy-but-slow boots, so these are generous.
# Used by the startup/reboot cluster-readiness phases below.
$script:WaitVmIpSec      = 300
$script:WaitSshSec       = 300
$script:WaitK3sApiSec    = 600
$script:WaitDbPodsSec    = 900
$script:WaitOperatorsSec = 900
$script:WaitWebhookSec   = 300

# ============================================================
#  CRASH / EXIT CLEANUP
# ============================================================
# Any helper objects created during a run (background jobs spawned by
# Invoke-WithLiveCounter for live boot counters, etc.) must not orphan if
# the script crashes, is Ctrl+C'd, or the user closes the window. The
# EngineEvent fires on normal exit, Ctrl+C, and unhandled exceptions.
# The Pode web server is intentionally NOT killed - it runs as a separate
# detached process the user manages independently.
function Invoke-DuneCleanup {
    try {
        $jobs = @(Get-Job -ErrorAction SilentlyContinue)
        if ($jobs.Count -gt 0) {
            $jobs | Stop-Job -ErrorAction SilentlyContinue
            $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# Pause before the script exits so a command launched in its own console
# window doesn't slam shut before the user can read the result — especially a
# red warning or error (a user reported rotate-ssh-key flashed a red message
# and the window closed before they could tell whether it had worked). Only
# active when -PauseOnExit was passed (Console-mode commands), and a no-op when
# stdin is redirected so it can never hang a non-interactive / stdout-captured
# caller.
function Invoke-DunePauseBeforeClose {
    if (-not $PauseOnExit) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch {}
    try {
        Write-Host ""
        Write-Host "Press any key to close this window..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        try { Read-Host "Press Enter to close this window" | Out-Null } catch {}
    }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
    try {
        Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
        Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    } catch { }
} | Out-Null

# Resize console window so the full menu is visible
try {
    $bufWidth  = [Math]::Max($Host.UI.RawUI.BufferSize.Width, 120)
    $winHeight = 50
    $winWidth  = [Math]::Min($bufWidth, 120)
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($bufWidth, 9999)
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($winWidth, $winHeight)
} catch {}

# ============================================================
#  DISABLE CONSOLE QUICKEDIT MODE  (click-freeze guard)
# ============================================================
# Windows consoles enable QuickEdit Mode by default: a single click or drag
# inside the window enters text-selection ("mark") mode and SUSPENDS the
# running process until a key is pressed. Long flows (startup/reboot: VM ->
# cluster -> battlegroup -> map pods) would otherwise freeze silently on a
# stray click with no error and no timeout - the title bar just gains a
# "Select" prefix. Clear ENABLE_QUICK_EDIT_INPUT (0x40) while setting
# ENABLE_EXTENDED_FLAGS (0x80) so the change actually applies. Best-effort:
# any failure (no console, redirected stdin) is swallowed.
function Disable-DuneConsoleQuickEdit {
    try {
        if (-not ('Dune.ConsoleMode' -as [type])) {
            Add-Type -Namespace Dune -Name ConsoleMode -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $STD_INPUT_HANDLE        = -10
        $ENABLE_QUICK_EDIT_INPUT = 0x0040
        $ENABLE_EXTENDED_FLAGS   = 0x0080
        $h = [Dune.ConsoleMode]::GetStdHandle($STD_INPUT_HANDLE)
        if ($h -eq [System.IntPtr]::Zero -or $h -eq [System.IntPtr](-1)) { return }
        $mode = [uint32]0
        if (-not [Dune.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) { return }
        $new = ($mode -band (-bnot $ENABLE_QUICK_EDIT_INPUT)) -bor $ENABLE_EXTENDED_FLAGS
        [void][Dune.ConsoleMode]::SetConsoleMode($h, $new)
    } catch { }
}
Disable-DuneConsoleQuickEdit

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
#  WRITABLE DATA DIRECTORY  (APPDATA migration)
# ============================================================
# Writable files (config, logs, boot-times) live in %APPDATA%\DuneServer\
# so the tool can run from a read-only install location (Program Files via
# the v4 desktop app installer). Legacy files next to the script are
# auto-migrated on first run; the legacy files are left in place as a
# fallback in case migration fails or the user rolls back.
$script:DuneDataDir = Join-Path $env:APPDATA 'DuneServer'
if (-not (Test-Path $script:DuneDataDir)) {
    try { New-Item -ItemType Directory -Force -Path $script:DuneDataDir | Out-Null } catch {}
}
$script:DuneLogsDir = Join-Path $script:DuneDataDir '.logs'
if (-not (Test-Path $script:DuneLogsDir)) {
    try { New-Item -ItemType Directory -Force -Path $script:DuneLogsDir | Out-Null } catch {}
}

function Resolve-DuneDataFile {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$LegacyDir = $scriptDir
    )
    $appDataPath = Join-Path $script:DuneDataDir $FileName
    $legacyPath  = Join-Path $LegacyDir $FileName
    if (-not (Test-Path $appDataPath) -and (Test-Path $legacyPath)) {
        try {
            Copy-Item -Path $legacyPath -Destination $appDataPath -Force -ErrorAction Stop
            Write-Host "Migrated $FileName from $LegacyDir to $script:DuneDataDir" -ForegroundColor DarkGray
        } catch {
            return $legacyPath
        }
    }
    return $appDataPath
}

$configFile = Resolve-DuneDataFile 'dune-server.config'

# ============================================================
#  FIRST-RUN SETUP
# ============================================================

function Run-Setup {
    param([hashtable]$existing)

    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  Dune Awakening Server — First-Time Setup" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This will ask a few questions to configure the tool for your system."
    Write-Host "  Your answers are saved to: $configFile"
    Write-Host "  You can re-run setup any time by deleting that file."
    Write-Host ""

    # Helper: prompt with a default value
    function Ask {
        param([string]$Label, [string]$Default)
        if ($Default) {
            Write-Host "  $Label " -NoNewline
            Write-Host "[$Default]" -ForegroundColor DarkGray -NoNewline
            Write-Host ": " -NoNewline
        } else {
            Write-Host "  ${Label}: " -NoNewline
        }
        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }

    # Helper: prompt for a file path, validate it exists
    function AskPath {
        param([string]$Label, [string]$Default, [switch]$MustExist)
        while ($true) {
            $path = Ask -Label $Label -Default $Default
            if (-not $MustExist) { return $path }
            if (Test-Path $path) { return $path }
            Write-Host "    Not found: $path" -ForegroundColor Red
        }
    }

    # ── 1. Steam / Battlegroup path ──
    Write-Host "1. Battlegroup Scripts" -ForegroundColor Yellow
    Write-Host "   Where is your Dune Awakening server installed?" -ForegroundColor Gray
    Write-Host "   (The folder containing 'battlegroup-management')" -ForegroundColor Gray
    Write-Host ""
    $defaultSteam = $null
    # Try to auto-detect common Steam library locations
    $commonPaths = @(
        "C:\Program Files (x86)\Steam\steamapps\common\Dune Awakening Self-Hosted Server",
        "C:\Program Files\Steam\steamapps\common\Dune Awakening Self-Hosted Server",
        "D:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server",
        "E:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server",
        "X:\SteamLibrary\steamapps\common\Dune Awakening Self-Hosted Server"
    )
    foreach ($p in $commonPaths) {
        if (Test-Path "$p\battlegroup-management\battlegroup.ps1") { $defaultSteam = $p; break }
    }
    if ($existing.SteamPath) { $defaultSteam = $existing.SteamPath }
    $steamPath = AskPath -Label "Server install folder" -Default $defaultSteam -MustExist
    Write-Host ""

    # ── 2. SSH key ──
    Write-Host "2. SSH Key" -ForegroundColor Yellow
    Write-Host "   Path to the private key used to connect to the VM." -ForegroundColor Gray
    Write-Host ""
    $defaultKey = $null
    $keyCandidates = @(
        "$env:LOCALAPPDATA\DuneAwakeningServer\sshKey",
        "$env:USERPROFILE\.ssh\dune",
        "$steamPath\sshKey"
    )
    foreach ($k in $keyCandidates) {
        if (Test-Path $k) { $defaultKey = $k; break }
    }
    if ($existing.SshKey) { $defaultKey = $existing.SshKey }
    $sshKeyPath = AskPath -Label "SSH private key" -Default $defaultKey -MustExist
    Write-Host ""

    # ── 3. Windows Username ──
    Write-Host "3. Windows Username" -ForegroundColor Yellow
    Write-Host "   Used by setup helpers and diagnostics." -ForegroundColor Gray
    Write-Host ""
    $defaultUser = if ($existing.WindowsUser) { $existing.WindowsUser } else { $env:USERNAME }
    $winUser = Ask -Label "Windows username" -Default $defaultUser
    Write-Host ""

    # ── 4. Port Verification (optional) ──
    Write-Host "4. Port Verification" -ForegroundColor Yellow
    Write-Host "   The tool can check that your forwarded ports are reachable from the internet" -ForegroundColor Gray
    Write-Host "   each time it launches, and display a color-coded status in the menu header." -ForegroundColor Gray
    Write-Host ""
    Write-Host "   Options:" -ForegroundColor Gray
    Write-Host "     1. Built-in   - Use yougetsignal.com for TCP ports (no UDP support)" -ForegroundColor Gray
    Write-Host "     2. Custom URL - Provide your own service (supports UDP if your service does)" -ForegroundColor Gray
    Write-Host "     3. Disabled   - Skip port checks entirely" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   NOTE: UDP ports (the game-server range 7777-7810) cannot be reliably verified" -ForegroundColor Yellow
    Write-Host "   by ANY free public service. UDP has no handshake, so a 'closed' response just" -ForegroundColor Yellow
    Write-Host "   means 'no application replied' - not the same as actually closed. The built-in" -ForegroundColor Yellow
    Write-Host "   check skips UDP and shows [UDP - skipped]. The best test for UDP is connecting" -ForegroundColor Yellow
    Write-Host "   in-game from a different network." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   ==> If you DON'T choose option 2 with a UDP-capable service, the UDP game-server" -ForegroundColor Yellow
    Write-Host "       ports will NEVER show as [OPEN] in the menu - they'll always show [UDP - skipped]." -ForegroundColor Yellow
    Write-Host ""
    $defaultMode = if ($existing.PortCheckMode) { $existing.PortCheckMode } else { 'builtin' }
    $defaultChoice = switch ($defaultMode) { 'builtin' { '1' } 'custom' { '2' } 'disabled' { '3' } default { '1' } }
    $modeChoice = Ask -Label "Choose 1, 2, or 3" -Default $defaultChoice
    $portCheckMode = switch ($modeChoice) {
        '2'      { 'custom'   }
        '3'      { 'disabled' }
        default  { 'builtin'  }
    }
    $portCheckUrlTemplate = ""
    if ($portCheckMode -eq 'custom') {
        Write-Host ""
        Write-Host "   URL template with {ip}, {port}, {protocol} placeholders." -ForegroundColor Gray
        Write-Host "   Example: https://yourchecker.example.com/api?ip={ip}&port={port}&proto={protocol}" -ForegroundColor Gray
        $defaultPortCheck = if ($existing.PortCheckUrlTemplate) { $existing.PortCheckUrlTemplate } else { "" }
        $portCheckUrlTemplate = Ask -Label "Custom URL template" -Default $defaultPortCheck
        if (-not $portCheckUrlTemplate) {
            Write-Warning "No URL provided. Falling back to built-in (yougetsignal.com)."
            $portCheckMode = 'builtin'
        }
    }
    Write-Host ""

    # ── Save ──
    $config = @(
        "# Dune Awakening Server Management — Configuration"
        "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "# Delete this file to re-run setup."
        ""
        "SteamPath=$steamPath"
        "SshKey=$sshKeyPath"
        "WindowsUser=$winUser"
        "PortCheckMode=$portCheckMode"
        "PortCheckUrlTemplate=$portCheckUrlTemplate"
    )
    $config | Set-Content -Path $configFile -Encoding UTF8

    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "  Setup complete! Config saved." -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""

    # ── Optional desktop shortcut (Run as Administrator) ──
    Write-Host "5. Desktop Shortcut (optional)" -ForegroundColor Yellow
    Write-Host "   Create an icon on your desktop that launches dune-server.bat" -ForegroundColor Gray
    Write-Host "   pre-elevated (so SSH key permissions and Hyper-V calls just work)." -ForegroundColor Gray
    Write-Host ""
    $shortcutAnswer = Ask -Label "Create desktop shortcut? (Y/n)" -Default "Y"
    if ($shortcutAnswer -match '^(y|yes)$') {
        try {
            New-DuneDesktopShortcut -BatPath (Join-Path $scriptDir 'dune-server.bat')
        } catch {
            Write-Warning "Could not create shortcut: $($_.Exception.Message)"
        }
    }
    Write-Host ""

    return @{
        SteamPath            = $steamPath
        SshKey               = $sshKeyPath
        WindowsUser          = $winUser
        PortCheckMode        = $portCheckMode
        PortCheckUrlTemplate = $portCheckUrlTemplate
    }
}

function New-DuneDesktopShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BatPath,
        [string]$LinkName  = "Dune Server (Admin)",
        [string]$IconPath  = "$env:SystemRoot\System32\imageres.dll,109"
    )

    if (-not (Test-Path $BatPath)) {
        throw "dune-server.bat not found at $BatPath."
    }

    $desktop  = [Environment]::GetFolderPath('Desktop')
    $linkPath = Join-Path $desktop "$LinkName.lnk"

    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($linkPath)
    $sc.TargetPath       = $BatPath
    $sc.WorkingDirectory = Split-Path $BatPath -Parent
    $sc.WindowStyle      = 1
    $sc.Description      = "Dune Awakening - Server Management (launched as Administrator)"
    $sc.IconLocation     = $IconPath
    $sc.Save()

    # Set the "Run as Administrator" flag in the .lnk binary.
    # Per the Shell Link Binary File Format (MS-SHLLINK), byte 0x15 contains
    # the upper byte of LinkFlags; the RunAsAdmin bit is 0x20.
    $bytes = [System.IO.File]::ReadAllBytes($linkPath)
    if ($bytes.Length -gt 0x15) {
        $bytes[0x15] = $bytes[0x15] -bor 0x20
        [System.IO.File]::WriteAllBytes($linkPath, $bytes)
    }

    Write-Host "   Created: $linkPath" -ForegroundColor Green
    Write-Host "   (Double-click it - Windows will prompt for elevation.)" -ForegroundColor DarkGray
}

function Resolve-FreshSshKey {
    # Picks the most recently modified SSH private key out of:
    #   1) %LOCALAPPDATA%\DuneAwakeningServer\sshKey  (rotate-ssh-key writes here)
    #   2) the path stored in dune-server.config        (what setup asked for)
    # Returns the full path or $null if neither exists.
    [CmdletBinding()]
    param([string]$ConfiguredPath)

    $appDataKey = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey'
    $candidates = @()
    if (Test-Path $appDataKey)                          { $candidates += Get-Item $appDataKey }
    if ($ConfiguredPath -and (Test-Path $ConfiguredPath)) {
        $resolved = (Resolve-Path $ConfiguredPath).Path
        if (-not ($candidates | Where-Object { $_.FullName -eq $resolved })) {
            $candidates += Get-Item $ConfiguredPath
        }
    }
    if (-not $candidates) { return $null }
    return ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Load-Config {
    $cfg = @{}
    if (-not (Test-Path $configFile)) { return $null }
    Get-Content $configFile | ForEach-Object {
        if ($_ -match '^([^#=]+)=(.*)$') {
            $cfg[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    # Validate required keys exist
    if (-not $cfg.SteamPath -or -not $cfg.SshKey) { return $null }
    return $cfg
}

# ── Load or run setup ──
$cfg = Load-Config
if (-not $cfg) {
    try {
        $cfg = Run-Setup -existing @{}
    } catch {
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Red
        Write-Host "  Setup failed:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "==========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Stack trace:" -ForegroundColor DarkGray
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ── Apply config ──
$vmName        = 'dune-awakening'
$sshKey        = $cfg.SshKey
$sshUser       = 'dune'
# Hyper-V target for the CLI power ops. Mirrors app/server/lib/HyperV.ps1:
# 'local' (default) runs Get-VM/Start-VM/Stop-VM against this PC; 'lan' targets a
# remote Hyper-V host at HyperVHostIp via -ComputerName + a saved host admin
# credential. Unset/blank/unknown => local, so existing installs and an
# unchecked LAN option behave exactly as before.
$vmHostMode    = if ($cfg.ContainsKey('VmHostMode') -and "$($cfg['VmHostMode'])".Trim() -match '^(?i:lan)$') { 'lan' } else { 'local' }
$hvComputer    = if ($cfg.ContainsKey('HyperVHostIp')) { "$($cfg['HyperVHostIp'])".Trim() } else { '' }
if ($vmHostMode -ne 'lan') { $hvComputer = '' }
$script:DuneCliVmHostIdentity = if ($vmHostMode -eq 'lan' -and $hvComputer) {
    "lan:$($hvComputer.ToLowerInvariant())"
} else {
    "local:$($env:COMPUTERNAME.ToLowerInvariant())"
}

# HyperVLanCredential.ps1 is self-contained (only needs advapi32 P/Invoke, no
# dependency on this script's own $cfg/$configFile handling), so it's safe to
# dot-source directly. Same dev/installed dual-path fallback used for the
# remote-scripts helpers below (Get-DuneRemotePartitionScriptPath etc.).
$script:DuneHyperVLanCredLibPath = $null
foreach ($candidate in @(
    (Join-Path $scriptDir 'server\lib\HyperVLanCredential.ps1')
    (Join-Path $scriptDir 'app\server\lib\HyperVLanCredential.ps1')
)) {
    if (Test-Path -LiteralPath $candidate) { $script:DuneHyperVLanCredLibPath = $candidate; break }
}
if ($script:DuneHyperVLanCredLibPath) { . $script:DuneHyperVLanCredLibPath }

$hvSplat = @{}
if ($hvComputer) {
    $hvCredOk = $false
    if (-not $script:DuneHyperVLanCredLibPath) {
        Write-Host "WARNING: Hyper-V over LAN is enabled but the credential helper (server\lib\HyperVLanCredential.ps1) is missing - VM commands against $hvComputer will use this process's own Windows identity and likely fail. Reinstall DST." -ForegroundColor Yellow
    } else {
        $hvCredResult = Get-DuneHyperVLanCredential -HostIp $hvComputer
        if (-not $hvCredResult.ok) {
            Write-Host "WARNING: Could not read the saved Hyper-V over LAN credential: $($hvCredResult.error)" -ForegroundColor Yellow
        } elseif (-not $hvCredResult.exists -or -not $hvCredResult.matchesHost) {
            Write-Host "WARNING: Hyper-V over LAN is enabled for $hvComputer, but no saved host administrator credential matches it. VM commands will fail until one is saved in Settings - Hyper-V over LAN." -ForegroundColor Yellow
        } else {
            $hvSplat = @{ ComputerName = $hvComputer; Credential = $hvCredResult.credential }
            $hvCredOk = $true
        }
    }
    # No matching saved credential: keep -ComputerName only (today's behavior)
    # rather than skipping the LAN target entirely - the resulting Get-VM call
    # will fail with an access-denied error the user can act on, instead of
    # this script silently pretending LAN mode is off.
    if (-not $hvCredOk) { $hvSplat = @{ ComputerName = $hvComputer } }
}
$bgSetupPath   = "$($cfg.SteamPath)\battlegroup-management"
# Default existing installs (no PortCheckMode in config) to built-in.
$portCheckMode = if ($cfg.PortCheckMode) { $cfg.PortCheckMode } else { 'builtin' }
$portCheckUrl  = $cfg.PortCheckUrlTemplate
# In-pod PostgreSQL port (default 15432). Configurable via the DbPort key so
# servers whose DB listens elsewhere (e.g. 15433) still work.
$dbPort        = 15432
if ($cfg.ContainsKey('DbPort') -and "$($cfg['DbPort'])".Trim()) {
    $parsedDbPort = 0
    if ([int]::TryParse("$($cfg['DbPort'])".Trim(), [ref]$parsedDbPort) -and $parsedDbPort -ge 1 -and $parsedDbPort -le 65535) {
        $dbPort = $parsedDbPort
    }
}

# Sample ports we probe (representative of each forwarded range).
# UDP 7777-7810 is checked at first + last; TCP 31982 is single-port.
$requiredPorts = @(
    [pscustomobject]@{ Port = 7777;  Protocol = 'UDP'; Label = 'UDP  7777-7810   Game servers (first port)' }
    [pscustomobject]@{ Port = 7810;  Protocol = 'UDP'; Label = 'UDP  7777-7810   Game servers (last port)'  }
    [pscustomobject]@{ Port = 31982; Protocol = 'TCP'; Label = 'TCP  31982       RabbitMQ'                   }
)

# Per-session cache for port-check results (avoid hitting the API on every menu render).
$script:portCheckCache  = $null
$script:portCheckPubIp  = $null

function Get-PublicIp {
    try {
        $ip = (Invoke-WebRequest -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 5).Content.Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
    } catch {}
    return $null
}

# Built-in TCP check via yougetsignal.com. UDP is not supported by any free public
# service (no handshake => can't distinguish "closed" from "no application reply").
function Test-PortOpen-Builtin {
    param([string]$PublicIp, [int]$Port, [string]$Protocol)
    if ($Protocol -ne 'TCP') { return 'udp-skip' }
    try {
        $resp = Invoke-WebRequest -Uri 'https://ports.yougetsignal.com/check-port.php' `
            -Method POST -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop `
            -Body @{ remoteAddress = $PublicIp; portNumber = "$Port" } `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (dune-server-tool)' }
        $body = "$($resp.Content)"
        if ($body -match '(?i)is\s+open|"open"\s*:\s*true')   { return 'open' }
        if ($body -match '(?i)is\s+(closed|not\s+visible|not\s+open)|"open"\s*:\s*false') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Test-PortOpen-Custom {
    param([string]$Template, [string]$PublicIp, [int]$Port, [string]$Protocol)
    if (-not $Template -or -not $PublicIp) { return 'unknown' }
    $url = $Template.Replace('{ip}', $PublicIp).Replace('{port}', "$Port").Replace('{protocol}', $Protocol.ToLower())
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        $body = "$($resp.Content)"
        if ($body -match '(?i)"open"\s*:\s*true|"reachable"\s*:\s*true|"status"\s*:\s*"open"|\bopen\b')   { return 'open' }
        if ($body -match '(?i)"open"\s*:\s*false|"reachable"\s*:\s*false|"status"\s*:\s*"closed"|\bclosed\b') { return 'closed' }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Get-PortCheckStatus {
    param([bool]$Force)
    if ($portCheckMode -eq 'disabled') { return $null }
    if ($portCheckMode -eq 'custom' -and -not $portCheckUrl) { return $null }
    $pubIp = Get-PublicIp
    if (-not $pubIp) {
        return @{ PublicIp = $null; Results = @() }
    }
    if (-not $Force -and $script:portCheckCache -and $script:portCheckPubIp -eq $pubIp) {
        return @{ PublicIp = $pubIp; Results = $script:portCheckCache }
    }
    $results = @()
    foreach ($p in $requiredPorts) {
        $status = if ($portCheckMode -eq 'builtin') {
            Test-PortOpen-Builtin -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
        } else {
            Test-PortOpen-Custom -Template $portCheckUrl -PublicIp $pubIp -Port $p.Port -Protocol $p.Protocol
        }
        $results += [pscustomobject]@{ Port = $p.Port; Protocol = $p.Protocol; Label = $p.Label; Status = $status }
    }
    $script:portCheckCache = $results
    $script:portCheckPubIp = $pubIp
    return @{ PublicIp = $pubIp; Results = $results }
}

$logFile = Join-Path $script:DuneLogsDir "dune-server-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

# --- Boot-time history (per-phase timing for startup and reboot) ---
# Persists wait-times for each phase to .boot-times.json (last 20 runs per phase)
# so subsequent runs can display an estimate before each wait.
$script:BootTimesFile = Resolve-DuneDataFile '.boot-times.json'

function Get-BootTimes {
    if (-not (Test-Path $script:BootTimesFile)) { return @{ phases = @{} } }
    try {
        $obj = Get-Content $script:BootTimesFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $obj.phases) { $obj.phases = @{} }
        return $obj
    } catch { return @{ phases = @{} } }
}

function Format-PhaseEstimate {
    param([string]$Phase)
    $data = Get-BootTimes
    if (-not $data.phases.ContainsKey($Phase)) { return $null }
    $arr = @($data.phases[$Phase])
    if ($arr.Count -eq 0) { return $null }
    $recent = @($arr | Select-Object -Last 5)
    $last = [int]$recent[-1].seconds
    if ($recent.Count -eq 1) { return "(last: ~$(Format-Duration $last))" }
    $avg = [int](($recent | Measure-Object seconds -Average).Average)
    return "(last: ~$(Format-Duration $last), avg ~$(Format-Duration $avg) of last $($recent.Count))"
}

function Format-Duration {
    # Format an integer-seconds duration as MM:SS for live playback timers
    # that update in place while a long wait is in progress.
    param([int]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $m = [int][Math]::Floor($Seconds / 60)
    $s = $Seconds % 60
    return ('{0:D2}:{1:D2}' -f $m, $s)
}

function Save-PhaseTiming {
    param([string]$Phase, [int]$Seconds)
    if ($Seconds -lt 0) { return }
    try {
        $data = Get-BootTimes
        if (-not $data.phases) { $data.phases = @{} }
        $cur = @()
        if ($data.phases.ContainsKey($Phase)) { $cur = @($data.phases[$Phase]) }
        $cur += @{ ts = (Get-Date).ToString("o"); seconds = $Seconds }
        if ($cur.Count -gt 20) { $cur = @($cur | Select-Object -Last 20) }
        $data.phases[$Phase] = $cur
        $data | ConvertTo-Json -Depth 5 | Set-Content $script:BootTimesFile -Encoding UTF8
    } catch {
        Write-Host "  (warn: could not save boot timing for '$Phase': $_)" -ForegroundColor DarkYellow
    }
}

# --- Live wait counters ---
# Render an updating "Xs (last ~Ys, avg ~Zs)" counter on a single console line
# while a long wait is in progress, so the user can see both elapsed time AND
# the expected duration based on prior runs.
function Write-WaitCounter {
    param(
        [Parameter(Mandatory)][datetime]$Start,
        [Parameter(Mandatory)][string]$Label,
        [string]$EstimateText
    )
    $sec = [int]((Get-Date) - $Start).TotalSeconds
    $line = "  $Label $(Format-Duration $sec)"
    if ($EstimateText) { $line += " $EstimateText" }
    Write-Host -NoNewline ("`r" + $line.PadRight(100))
}

function Complete-WaitCounter {
    param(
        [Parameter(Mandatory)][string]$Message,
        [System.ConsoleColor]$Color = [System.ConsoleColor]::Green
    )
    Write-Host ("`r" + (' ' * 100) + "`r") -NoNewline
    Write-Host "  $Message" -ForegroundColor $Color
}

function Invoke-WithLiveCounter {
    # Runs a scriptblock as a background job and renders a live "Xs" counter
    # on the same console line while it runs. Returns @{ Elapsed; Output }.
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$EstimateText,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object[]]$ArgumentList = @()
    )
    $start = Get-Date
    $job = Start-Job -ScriptBlock $Action -ArgumentList $ArgumentList
    try {
        while ($job.State -eq 'Running') {
            Write-WaitCounter -Start $start -Label $Label -EstimateText $EstimateText
            Start-Sleep -Seconds 1
        }
    } catch {
        Stop-Job $job -ErrorAction SilentlyContinue
        throw
    }
    $output = Receive-Job $job -Wait -AutoRemoveJob -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Elapsed = [int]((Get-Date) - $start).TotalSeconds
        Output  = $output
    }
}

# --- Detect VM state ---
$script:DuneCliKvpRecoveryAttempted = @{}

function Test-DuneCliVmIp {
    param([string]$Ip)
    if (-not $Ip -or $Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $false }
    try {
        $probe = Invoke-DuneCliSshPayload -Ip $Ip `
            -RemoteCommand 'printf DUNE_VM_IP_OK' -TimeoutSec 6
        return ($probe.Exit -eq 0 -and $probe.Stdout.Trim() -eq 'DUNE_VM_IP_OK')
    } catch {
        return $false
    }
}

function Resolve-DuneCliVmIp {
    $ip = (Get-VMNetworkAdapter -VMName $vmName @hvSplat).IPAddresses |
          Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
          Select-Object -First 1
    if ($ip) { return [string]$ip }

    $fallback = if ($cfg.ContainsKey('LastKnownVmIp')) {
        "$($cfg['LastKnownVmIp'])".Trim()
    } else { '' }
    $fallbackHost = if ($cfg.ContainsKey('LastKnownVmHost')) {
        "$($cfg['LastKnownVmHost'])".Trim()
    } else { '' }
    if ($fallbackHost -ne $script:DuneCliVmHostIdentity) { return $null }
    if (-not (Test-DuneCliVmIp -Ip $fallback)) { return $null }

    if (-not $script:DuneCliKvpRecoveryAttempted.ContainsKey($fallback)) {
        $script:DuneCliKvpRecoveryAttempted[$fallback] = $true
        Invoke-DuneHyperVGuestRecoveryInstall -Ip $fallback -Phase 'kvp-recovery' -ForceKvp
    }
    return $fallback
}

function Get-VmInfo {
    $vm = Get-VM -Name $vmName @hvSplat -ErrorAction SilentlyContinue
    $exists  = [bool]$vm
    $state   = if ($exists) { $vm.State } else { 'Missing' }
    $running = $exists -and $vm.State -eq 'Running'
    $ip      = $null
    if ($running) {
        $ip = Resolve-DuneCliVmIp
    }
    return @{ Exists = $exists; State = $state; Running = $running; Ip = $ip }
}

# Issue Stop-VM as a background job, render a live MM:SS counter while the VM
# transitions to Off, and escalate to a hard power-off (-TurnOff) if the
# graceful shutdown stalls past $GracefulSec. Throws if the VM never reaches
# Off within $TotalSec. Returns elapsed seconds on success.
function Stop-VmWithEscalation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Label = "Stopping VM",
        [string]$EstimateText,
        [int]$GracefulSec = 90,
        [int]$TotalSec = 240
    )
    $start = Get-Date
    $jobs = @()
    # Background jobs run in isolated processes and can't see $hvSplat - pass the
    # Hyper-V host (empty for local) and the credential lib path in, and rebuild
    # the splat (including -Credential for a LAN host) inside the job.
    $jobs += Start-Job -ScriptBlock {
        param($n, $cn, $credLibPath)
        $sp = @{}
        if ($cn) {
            $sp = @{ ComputerName = $cn }
            if ($credLibPath -and (Test-Path -LiteralPath $credLibPath)) {
                . $credLibPath
                $c = Get-DuneHyperVLanCredential -HostIp $cn
                if ($c.ok -and $c.exists -and $c.matchesHost) { $sp['Credential'] = $c.credential }
            }
        }
        Stop-VM -Name $n -Force -ErrorAction SilentlyContinue @sp
    } -ArgumentList $Name, $hvComputer, $script:DuneHyperVLanCredLibPath
    $escalated = $false
    try {
        while ($true) {
            $vm = Get-VM -Name $Name @hvSplat -ErrorAction SilentlyContinue
            if (-not $vm -or $vm.State -eq 'Off') { break }
            $elapsed = [int]((Get-Date) - $start).TotalSeconds
            if (-not $escalated -and $elapsed -ge $GracefulSec) {
                Complete-WaitCounter -Message "Graceful shutdown still running after $(Format-Duration $elapsed) (state: $($vm.State)) - escalating to hard power-off." -Color Yellow
                $jobs += Start-Job -ScriptBlock {
                    param($n, $cn, $credLibPath)
                    $sp = @{}
                    if ($cn) {
                        $sp = @{ ComputerName = $cn }
                        if ($credLibPath -and (Test-Path -LiteralPath $credLibPath)) {
                            . $credLibPath
                            $c = Get-DuneHyperVLanCredential -HostIp $cn
                            if ($c.ok -and $c.exists -and $c.matchesHost) { $sp['Credential'] = $c.credential }
                        }
                    }
                    Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue @sp
                } -ArgumentList $Name, $hvComputer, $script:DuneHyperVLanCredLibPath
                $escalated = $true
            }
            if ($elapsed -ge $TotalSec) {
                throw "VM '$Name' did not reach Off state within $(Format-Duration $elapsed) (last state: $($vm.State))."
            }
            Write-WaitCounter -Start $start -Label "$Label (state: $($vm.State))..." -EstimateText $EstimateText
            Start-Sleep -Seconds 2
        }
    } finally {
        foreach ($j in $jobs) {
            try {
                Stop-Job -Job $j -ErrorAction SilentlyContinue | Out-Null
                Remove-Job -Job $j -Force -ErrorAction SilentlyContinue | Out-Null
            } catch {}
        }
    }
    return [int]((Get-Date) - $start).TotalSeconds
}

# --- Online-player lookup (for safety check before shutdown commands) ---
# Queries the Postgres DB inside the cluster via `kubectl exec`. Returns
# @{ Names=@(string); Error=$null|string }. On any failure returns Error set
# and Names empty so callers can decide whether to proceed or abort.
function Get-OnlinePlayers {
    if (-not $ip) { return @{ Names = @(); Error = 'VM IP not set' } }

    # Locate the Postgres pod (name typically contains "-db-", "postgres", or "-pg-")
    # Awk prints "namespace podname" space-separated; we avoid embedded double
    # quotes in the awk script because PowerShell mangles \" inside the
    # double-quoted command string.
    $pgInfo = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
        "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|-pg-)/ {print `$1, `$2; exit}'"
    $pgInfo = ($pgInfo | Out-String).Trim()
    if (-not $pgInfo) { return @{ Names = @(); Error = 'Postgres pod not found' } }
    $parts = $pgInfo -split '\s+', 2
    if ($parts.Count -lt 2) { return @{ Names = @(); Error = "Could not parse pod info: $pgInfo" } }
    $pgNs  = $parts[0].Trim()
    $pgPod = $parts[1].Trim()

    # Query online players. The cluster's postgres listens on $dbPort (default
    # 15432, configurable via the DbPort config key).
    $sql = "SELECT character_name FROM player_state WHERE online_status = 'Online' AND character_name IS NOT NULL ORDER BY character_name;"
    $cmd = "sudo k3s kubectl exec -n '$pgNs' '$pgPod' -- env PGPASSWORD=dune psql -h 127.0.0.1 -p $dbPort -U dune -d dune -t -A -c `"$sql`" 2>&1"
    $raw = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" $cmd
    $rawText = ($raw | Out-String)
    if ($LASTEXITCODE -ne 0 -or $rawText -match 'error|FATAL|ERROR') {
        return @{ Names = @(); Error = "psql failed: $($rawText.Trim())" }
    }
    $names = @($rawText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\(\d+ rows?\)$' })
    return @{ Names = $names; Error = $null }
}

# Helper used by both reboot and shutdown handlers.
# Returns $true if user confirmed (or no players online), $false to abort.
function Confirm-NoPlayersOnline {
    param([string]$ActionLabel)
    Write-Host "  Checking for online players..." -ForegroundColor DarkGray
    $players = Get-OnlinePlayers
    if ($players.Error) {
        Write-Host "  (could not enumerate players: $($players.Error))" -ForegroundColor Yellow
        $proceed = Read-Host "Continue with $ActionLabel anyway? (YES to continue)"
        return ($proceed -eq "YES")
    }
    if ($players.Names.Count -eq 0) {
        Write-Host "  No players online." -ForegroundColor Green
        return $true
    }
    Write-Host ""
    Write-Host "  WARNING: $($players.Names.Count) player(s) currently online:" -ForegroundColor Yellow
    foreach ($n in $players.Names) {
        Write-Host "    - $n" -ForegroundColor Yellow
    }
    Write-Host ""
    $proceed = Read-Host "Continue with $ActionLabel and disconnect these players? (YES to continue)"
    return ($proceed -eq "YES")
}

# Funcom's `battlegroup stop` waits for the BG CRD to report phase "Stopped" by
# positionally parsing `kubectl get battlegroup --no-headers` (awk '{print $3}').
# When the server title (spec.title) contains spaces, the title spans multiple
# whitespace tokens and shifts the real PHASE column right, so Funcom reads a
# title token as the phase, never matches "Stopped", and prints a cosmetic
# "did not report Stopped within 90s" WARNING after its 90s timeout. The stop
# still succeeds -- DST verifies that separately via the pod-termination check.
# This note reassures the operator when their title would trigger the warning.
# (Same root cause as the v12.16.1 Dashboard BG-Info fix, but inside Funcom's
# stop script, which DST calls and must not modify.)
function Show-DuneFuncomStopWarningNote {
    param([string]$Ip, [string]$SshUser, [string]$SshKey)
    try {
        $title = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$SshKey" "$SshUser@$Ip" `
            "sudo k3s kubectl get battlegroups -A --no-headers -o custom-columns=T:.spec.title 2>/dev/null | head -1"
        $title = ($title | Out-String).Trim()
        if ($title -and ($title -match '\s')) {
            Write-Host "  Note: any Funcom 'battlegroup ... did not report Stopped within 90s' warning above is" -ForegroundColor DarkGray
            Write-Host "        cosmetic -- Funcom's stop script mis-reads the phase because your server title" -ForegroundColor DarkGray
            Write-Host "        ('$title') contains spaces. DST confirmed the actual stop above (pods terminated)." -ForegroundColor DarkGray
        }
    } catch {}
}

# Count active battlegroup pods. Terminal pod objects can remain in Kubernetes
# indefinitely (especially Evicted bgd pods), so presence alone does not mean
# shutdown work remains.
function Get-DuneActiveBattlegroupPodCount {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKey
    )
    $remote = "sudo k3s kubectl get pods -A --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null | awk '`$1 ~ /(-sg-|-mq-|-sgw-|-tr-|-bgd-)/ && `$2 != `"Succeeded`" && `$2 != `"Failed`" { count++ } END { print count+0 }'"
    $raw = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$SshKey" "$SshUser@$Ip" `
        $remote
    $text = ($raw | Out-String).Trim()
    $count = 0
    if (-not [int]::TryParse($text, [ref]$count)) { return $null }
    return $count
}

# Returns $true if active battlegroup pods remain. Used to short-circuit
# `battlegroup stop` when only terminal pod history exists.
function Test-DuneBattlegroupHasPods {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKey
    )
    $count = Get-DuneActiveBattlegroupPodCount -Ip $Ip -SshUser $SshUser -SshKey $SshKey
    if ($null -eq $count) { return $true }
    return ($count -gt 0)
}

function Remove-DuneTerminalDirectorPodHistory {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKey
    )
    $remote = @'
sudo k3s kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>/dev/null |
awk -F'|' '$2 ~ /-bgd-/ && ($3 == "Succeeded" || $3 == "Failed") { print $1 "|" $2 }' |
while IFS='|' read -r ns pod; do
  [ -n "$ns" ] && [ -n "$pod" ] || continue
  sudo k3s kubectl delete pod -n "$ns" "$pod" --ignore-not-found >/dev/null && echo "DELETED|$pod"
done
'@ -replace "`r", ''
    $out = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$SshKey" "$SshUser@$Ip" $remote
    return @($out | Where-Object { ([string]$_).StartsWith('DELETED|') }).Count
}

function Get-DuneDatabaseBlockState {
    # Ask the VM whether a DatabaseOperation is holding the database open.
    #
    # Why: while any DatabaseOperation is registered the Funcom operator creates
    # NO map pods at all - the battlegroup reports DATABASE=Operation, every map
    # sits at Starting with REQUEST 1 / TARGET 1 / READY 0, and any restore also
    # fails. A field case ran ~24h on this. DST used to report only "<map> pod
    # was never found within 05:00", which reads like a scheduling or image-pull
    # problem and points nowhere near the database.
    #
    # Read-only, best-effort. Returns @{ blocked; phase; ops=@(name/phase) }.
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [string] $SshUser = $sshUser,
        [string] $SshKey  = $sshKey
    )
    $state = @{ blocked = $false; phase = ''; ops = @() }
    try {
        $cmd = @'
NS=$(sudo k3s kubectl get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -m1 '^funcom-seabass-')
[ -n "$NS" ] || exit 0
echo "phase=$(sudo k3s kubectl -n "$NS" get battlegroup -o jsonpath='{.items[0].status.database.phase}' 2>/dev/null)"
sudo k3s kubectl -n "$NS" get databaseoperations --no-headers 2>/dev/null | awk '$0 !~ /Succeeded/ {print "op=" $1 " " $2}'
'@ -replace "`r", ''
        $out = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 `
                   -i "$SshKey" "$SshUser@$Ip" $cmd 2>$null
        foreach ($line in @($out)) {
            $t = ([string]$line).Trim()
            if ($t -like 'phase=*') { $state.phase = $t.Substring(6).Trim(); continue }
            if ($t -like 'op=*')    { $state.ops += $t.Substring(3).Trim() }
        }
        $state.blocked = (($state.phase -and $state.phase -ne 'Ready') -or $state.ops.Count -gt 0)
    } catch {}
    return $state
}

function Wait-MapPodReady {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $MapName,
        [int] $TimeoutSec = 300
    )
    $expectedMap = if ($MapName -eq 'survival') { 'Survival_1' } else { 'Overmap' }
    $elapsed = 0
    $lastPod = $null
    $lastStatus = $null
    while ($elapsed -lt $TimeoutSec) {
        $line = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$Ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E -i '$MapName' | head -1"
        $line = ($line | Out-String).Trim()
        if ($line) {
            $cols = $line -split '\s+'
            $podName = $cols[1]
            $ready   = $cols[2]
            $status  = $cols[3]
            $lastPod = $podName
            $lastStatus = "$status $ready"
            if ($status -eq 'Running' -and $ready -match '^(\d+)/\1$' -and $Matches[1] -gt 0) {
                # Kubernetes Ready only means the container probe passed. After
                # a VM restart, a persisted game container can pass that probe
                # while its PostgreSQL connection is permanently broken. The
                # Funcom battlegroup CR is the authoritative world-ready signal.
                $gameRows = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$Ip" `
                    "sudo k3s kubectl get battlegroups -A -o jsonpath='{range .items[*].status.servers[*]}{.partitionMap}{`"|`"}{.phase}{`"|`"}{.ready}{`"\n`"}{end}' 2>/dev/null"
                $game = @($gameRows | ForEach-Object {
                    $parts = ([string]$_).Trim() -split '\|', 3
                    if ($parts.Count -eq 3 -and $parts[0] -eq $expectedMap) {
                        [pscustomobject]@{ Phase = $parts[1]; Ready = $parts[2] }
                    }
                } | Select-Object -First 1)
                if ($game.Count -gt 0) {
                    $lastStatus = "$status $ready; game=$($game[0].Phase) ready=$($game[0].Ready)"
                    if ($game[0].Phase -eq 'Running' -and $game[0].Ready -eq 'true') {
                        return @{ Success = $true; Elapsed = $elapsed; Pod = $podName; Ready = "$ready; game ready" }
                    }
                }
            }
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    return @{ Success = $false; Elapsed = $elapsed; Pod = $lastPod; LastStatus = $lastStatus }
}

# A hard VM stop preserves pod objects in k3s. On the next boot, containerd
# restarts those game containers in place, but the game process can retain an
# invalid PostgreSQL connection forever while Kubernetes still reports Ready.
# Start All is player-safe here because the VM was off when the command began.
function Restart-DuneCoreMapPodsAfterVmBoot {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKey
    )
    $cmd = @'
sudo k3s kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null |
while IFS='|' read -r ns pod restarts; do
  case "$pod" in
    *-sg-overmap-pod-*|*-sg-survival-1-pod-*) ;;
    *) continue ;;
  esac
  case "$restarts" in ''|*[!0-9]*) continue ;; esac
  [ "$restarts" -gt 0 ] || continue
  echo "===RECYCLE===$ns|$pod|$restarts"
  sudo k3s kubectl delete pod -n "$ns" "$pod" --wait=false
done
'@ -replace "`r", ''
    $out = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$SshKey" "$SshUser@$Ip" $cmd
    $recycled = @($out | Where-Object { ([string]$_).StartsWith('===RECYCLE===') })
    return @{
        Count = $recycled.Count
        Pods  = @($recycled | ForEach-Object { (([string]$_).Substring(13) -split '\|')[1] })
    }
}

# ============================================================
#  ON-DEMAND PARTITION CLEAR (Funcom drift workaround)
# ============================================================
#
# The Funcom server-operator periodically copies the parent ServerSet's
# spec.partitions:[N] into the child ServerSetScale (igwsss), which blocks
# the battlegroup director from triggering on-demand spawn for
# DeepDesert / SH_Arrakeen / SH_HarkoVillage. The bundled shell script
# `app/resources/remote-scripts/dune-clear-partitions.start` fixes that
# idempotently (skips any map whose pod is currently running). DST stages
# it to /tmp on the VM via scp, runs it once with sudo, then removes it
# on every Start / Restart / fix-on-demand-maps command — so users no
# longer have to invoke it manually.
#
# v11.0.3: removed the v11.0.1 install of /etc/local.d/dune-clear-partitions.start
# + the 15-min cron watchdog. The script is now run inline (single scp +
# ssh pair, no persistent VM install) which eliminates the Windows Defender
# ML false positive (Trojan:Script/Wacatac.H!ml) that flagged the v11.0.1
# installer. Existing VMs that had the boot script + cron installed by
# v11.0.1 are unaffected — those leftovers keep running harmlessly until
# the VM is rebuilt.

function Get-DuneRemotePartitionScriptPath {
    $candidates = @(
        (Join-Path $scriptDir 'resources\remote-scripts\dune-clear-partitions-install.sh')
        (Join-Path $scriptDir 'app\resources\remote-scripts\dune-clear-partitions-install.sh')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-DuneMemPressureProbePath {
    $candidates = @(
        (Join-Path $scriptDir 'resources\remote-scripts\dune-mem-pressure-probe.sh')
        (Join-Path $scriptDir 'app\resources\remote-scripts\dune-mem-pressure-probe.sh')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-DuneVmHealthLibPath {
    # The web backend's probe parser (app/server/lib/VmMemoryPressure.ps1) is
    # pure PowerShell, so the CLI dot-sources it *inside* the warning function
    # (function scope only, no global overrides) instead of maintaining a second
    # copy of the parsing + verdict rules that would inevitably drift.
    $candidates = @(
        (Join-Path $scriptDir 'server\lib\VmMemoryPressure.ps1')
        (Join-Path $scriptDir 'app\server\lib\VmMemoryPressure.ps1')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Show-DuneVmMemoryPressureWarning {
    # Run the read-only VM health probe over SSH and print red warnings for
    # anything the operator has to act on: a stuck DatabaseOperation holding the
    # server down, DiskPressure / a filling root volume, a missing game-UDP
    # bridge, per-map memory limits crushed by Funcom's experimental swap
    # preset, and genuine memory pressure (OOM-killed operators, evicted
    # Postgres, or a tiny MemAvailable with Swap: 0).
    #
    # 2026-07-26: elevated restart counts NO LONGER declare memory pressure on
    # their own. Funcom's operators restart in lockstep by design (exit 255 /
    # reason Unknown), so the old rule fired on healthy servers and told a user
    # whose server was down with 94% free RAM to buy more RAM.
    #
    # Uses the SAME bundled probe AND the same parser as the web backend so the
    # CLI Start-All and the Server Health banner never disagree. Read-only and
    # best-effort - never throws, never blocks a good start on a probe hiccup.
    param(
        [Parameter(Mandatory)][string]$Ip,
        [string]$SshUser = $sshUser,
        [string]$SshKey  = $sshKey
    )
    try {
        $local = Get-DuneMemPressureProbePath
        if (-not $local) { return }
        $raw = [System.IO.File]::ReadAllText($local)
        $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

        # Stream the base64 payload over stdin, decode, run as root. Mirrors the
        # partition-clear staging path (no scp/sftp dependency).
        $out = $b64 | & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 `
                    -i "$SshKey" "${SshUser}@${Ip}" 'base64 -d | sudo -n bash' 2>$null
        if (-not $out) { return }

        $libPath = Get-DuneVmHealthLibPath
        if (-not $libPath) { return }
        . $libPath   # function-scoped import of the shared parser

        # The CLI knows whether a public IP is configured from the same config
        # the web backend reads; without one, zero UDP DNAT rules is normal.
        $publicIpConfigured = $false
        try {
            if ($configFile -and (Test-Path -LiteralPath $configFile)) {
                $cfgText = Get-Content -LiteralPath $configFile -Raw
                $publicIpConfigured = ($cfgText -match '(?m)^\s*(ManualPublicIp|DdnsHostname|LastAppliedPublicIp)\s*=\s*\S+')
            }
        } catch {}

        $finding = ConvertFrom-DuneMemPressureProbe -Raw (($out | Out-String)) -PublicIpConfigured $publicIpConfigured
        if (-not $finding.ok) { return }

        if ($finding.pressure) {
            Write-Host ""
            Write-Host "  WARNING: $($finding.headline)" -ForegroundColor Red
            foreach ($w in @($finding.warnings)) {
                Write-Host "    $w" -ForegroundColor Yellow
            }
            Write-Host "    Full detail: Help > Create Diagnostics Package (vm-memory-pressure.txt)." -ForegroundColor DarkGray
        }
    } catch {
        # Best-effort only - a probe hiccup must never fail a good start.
    }
}

function Invoke-DuneRemotePartitionScript {
    # Stages the bundled partition-heal installer via base64/SSH, refreshes its
    # VM-side heal + boot hook + cron, runs one explicit safety mode, then removes
    # the staged copy.
    # Returns @{ ok; rc; output }. Best-effort - never throws.
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$WaitAttempts = 60,
        [ValidateSet('boot', 'cron', 'manual')][string]$Mode = 'cron'
    )
    $local = Get-DuneRemotePartitionScriptPath
    if (-not $local) {
        return @{ ok = $false; rc = -1; output = @('Bundled dune-clear-partitions-install.sh not found in install dir.') }
    }

    $stamp     = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $remoteTmp = "/tmp/dune-cp-$stamp.sh"

    # Force LF line endings — Alpine /bin/sh chokes on CRLF.
    $raw = [System.IO.File]::ReadAllText($local)
    $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"

    # Stage over an ssh exec channel (base64 on stdin) instead of scp. Modern
    # OpenSSH scp (9.0+) uses the SFTP protocol, which needs sftp-server on the
    # remote; some VM images omit it where sshd_config expects (e.g.
    # /usr/lib/ssh/sftp-server missing), so scp fails with
    # "bash: line 1: /usr/lib/ssh/sftp-server: No such file or directory".
    # base64 over ssh exec needs only a shell + busybox base64.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

    $stageOut = $b64 | & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
          -i "$sshKey" "${sshUser}@${Ip}" "base64 -d > $remoteTmp && echo DUNE_STAGED_OK" 2>&1
    if (($stageOut -join "`n") -notmatch 'DUNE_STAGED_OK') {
        return @{ ok = $false; rc = ($LASTEXITCODE); output = @("staging partition-clear script over ssh failed.", "$stageOut") }
    }
    $output = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                    -i "$sshKey" "$sshUser@$Ip" `
                    "sudo -n DUNE_CLEAR_ATTEMPTS=$WaitAttempts sh $remoteTmp $Mode; rc=`$?; rm -f $remoteTmp; exit `$rc" 2>&1
    $rc = $LASTEXITCODE
    return @{ ok = ($rc -eq 0); rc = $rc; output = @($output) }
}

function Invoke-OnDemandPartitionClear {
    # Best-effort wrapper: optionally settle for DelaySec to let the Funcom server-operator
    # finish reconciling on-demand ServerSets (otherwise the script runs before
    # partitions are pinned and finds nothing to clear), stage the bundled
    # script to /tmp on the VM, run it once with sudo, remove it, then tail
    # its log.
    #
    # Never throws — partition-clear failure is surfaced as a yellow warning
    # so a successful battlegroup start doesn't get reported as failed when
    # this auxiliary step fails.
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$DelaySec = 30,
        [string]$Phase = 'post-start',
        [ValidateSet('boot', 'cron', 'manual')][string]$Mode = 'cron',
        [switch]$Fast
    )
    Write-Host ""
    Write-Host "[$Phase] Clearing on-demand map partition pins (auto-fix so DeepDesert / Arrakeen / Harko spawn on demand)..." -ForegroundColor Cyan

    # Fast pre-probe: if no on-demand map igwsss has a non-empty partitions pin
    # (the common case for a clean cold-boot), skip the whole 45s settle + heal
    # step. Saves ~50s on every reboot when no on-demand maps are loaded.
    $probe = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=8 -i "$sshKey" "$sshUser@$Ip" `
        "sudo /usr/local/bin/k3s kubectl get igwsss --all-namespaces --no-headers -o custom-columns=NAME:.metadata.name,PARTITIONS:.spec.partitions 2>/dev/null" 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) {
        $pinned = @()
        foreach ($line in ($probe -split "`n")) {
            $trim = $line.Trim()
            if (-not $trim) { continue }
            # Match only on-demand + spin-up maps (DeepDesert / Arrakeen / HarkoVillage).
            if ($trim -notmatch 'deepdesert|arrakeen|harkovillage') { continue }
            # Partitions column is either '[]', '<none>', empty, or e.g. '[0]'.
            if ($trim -match '\[(\d+.*)\]') { $pinned += ($trim -split '\s+')[0] }
        }
        if ($pinned.Count -eq 0) {
            Write-Host "  No on-demand maps pinned - skipping settle + heal (saves ~50s)." -ForegroundColor Green
            return
        }
        Write-Host "  Pinned on-demand maps: $($pinned -join ', ') - running heal." -ForegroundColor DarkGray
    }

    if ($DelaySec -gt 0) {
        Write-Host "  Settling ${DelaySec}s so the server operator finishes reconciling on-demand ServerSets..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelaySec
    }

    $waitAttempts = if ($Fast) { 1 } else { 60 }
    $result = Invoke-DuneRemotePartitionScript -Ip $Ip -WaitAttempts $waitAttempts -Mode $Mode
    $runOut = $result.output
    $runRc  = $result.rc

    if ($runRc -ne 0) {
        Write-Host "  Warning: partition-clear script exited $runRc — server is up but on-demand maps may not auto-spawn." -ForegroundColor Yellow
        Write-Host "  Use command 21 (fix-on-demand-maps) or the Map SpinUp 'Fix partitions' button if a player can't enter DD/Arrakeen/Harko." -ForegroundColor DarkGray
        if ($runOut) { $runOut | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        return
    }
    if ($runOut) { $runOut | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }

    # Tail log after the run — capture exit code before any further ssh so we
    # don't lose it. Failure to read the log is non-fatal.
    $tail = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$Ip" `
        "tail -n 10 /var/log/dune-clear-partitions.log" 2>&1
    if ($LASTEXITCODE -eq 0 -and $tail) {
        Write-Host "  Last 10 lines of /var/log/dune-clear-partitions.log:" -ForegroundColor DarkGray
        $tail | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    Write-Host "  Done — on-demand maps will spawn for the next player." -ForegroundColor Green
}

function Get-DuneDnatWatchScriptPath {
    $candidates = @(
        (Join-Path $scriptDir 'resources\remote-scripts\dune-dnat-watch-install.sh')
        (Join-Path $scriptDir 'app\resources\remote-scripts\dune-dnat-watch-install.sh')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-DuneHyperVGuestRecoveryScriptPath {
    $candidates = @(
        (Join-Path $scriptDir 'resources\remote-scripts\dune-hyperv-guest-recovery-install.sh')
        (Join-Path $scriptDir 'app\resources\remote-scripts\dune-hyperv-guest-recovery-install.sh')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Invoke-DuneCliSshPayload {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$RemoteCommand,
        [string]$StdinData = '',
        [int]$TimeoutSec = 40
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'ssh'
    $psi.RedirectStandardInput = [bool]$StdinData
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $args = @(
        '-o','BatchMode=yes',
        '-o','StrictHostKeyChecking=no',
        '-o','LogLevel=QUIET',
        '-o','ConnectTimeout=8',
        '-o','ServerAliveInterval=5',
        '-o','ServerAliveCountMax=2',
        '-i',$sshKey,
        "$sshUser@$Ip",
        $RemoteCommand
    )
    if (-not $StdinData) { $args = @('-n') + $args }
    $psi.Arguments = (@($args) | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }) -join ' '
    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if ($StdinData) {
            $proc.StandardInput.Write($StdinData)
            $proc.StandardInput.Close()
        }
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch {}
            try { [void]$proc.WaitForExit(2000) } catch {}
            return @{ Exit = -1; Stdout = ''; Stderr = "ssh timed out after ${TimeoutSec}s" }
        }
        [void]$proc.WaitForExit()
        try { [void]$stdoutTask.Wait(5000) } catch {}
        try { [void]$stderrTask.Wait(5000) } catch {}
        $stdout = ''
        $stderr = ''
        try { $stdout = $stdoutTask.Result } catch {}
        try { $stderr = $stderrTask.Result } catch {}
        return @{
            Exit = $proc.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        $proc.Dispose()
    }
}

function Invoke-DuneHyperVGuestRecoveryInstall {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [string]$Phase = 'pre-start',
        [switch]$ForceKvp
    )
    $local = Get-DuneHyperVGuestRecoveryScriptPath
    if (-not $local) {
        Write-Host "  [$Phase] Skipped Hyper-V guest recovery (bundled script not found)." -ForegroundColor DarkYellow
        return
    }
    try {
        $raw = [IO.File]::ReadAllText($local)
        $lf = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))
        $remoteCommand = if ($ForceKvp.IsPresent) {
            'base64 -d | sudo -n env DUNE_HYPERV_FORCE_KVP_RESTART=1 sh'
        } else {
            'base64 -d | sudo -n sh'
        }
        $run = Invoke-DuneCliSshPayload -Ip $Ip -RemoteCommand $remoteCommand `
            -StdinData $b64 -TimeoutSec 40
        $runOut = (@($run.Stdout, $run.Stderr) | Where-Object { $_ }) -join "`n"
        if ($run.Exit -eq 0 -and
            $runOut -match 'DUNE_HYPERV_GUEST_RECOVERY_(OK|NOT_APPLICABLE)') {
            Write-Host "  [$Phase] Hyper-V guest memory hot-add + KVP recovery reconciled." -ForegroundColor DarkGray
        } else {
            Write-Host "  [$Phase] Hyper-V guest recovery reported a problem (non-fatal): $runOut" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  [$Phase] Hyper-V guest recovery failed (non-fatal): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Invoke-DuneDnatWatchdogInstall {
    # Best-effort: stage the bundled DNAT self-heal watchdog installer to /tmp on
    # the VM (base64 over an ssh exec channel — no scp/sftp dependency), run it
    # once with sudo, remove it. The installer writes /usr/local/bin/dune-dnat-watch.sh
    # plus an OpenRC-supervised loop. It targets one-second game-listener checks
    # while cluster-derived addresses refresh in an independent bounded worker.
    # The RabbitMQ (public:31982 -> mq-game pod) DNAT rule and game-UDP bridge
    # (VM-LAN-IP:7777-7810 -> public IP) self-heal after a pod-only battlegroup
    # restart -- which the boot script
    # /etc/local.d/dune-iptables.start misses because it only re-derives at boot.
    # Without this, a pod restart leaves the RabbitMQ rule pointing at a dead pod IP
    # (players hang on "Connecting") or drops the game bridge (remote players P34)
    # until the next reboot (observed 2026-06-23). The game bridge is BIND-DETECTED:
    # the watchdog installs it for each port with a public listener, even if a
    # separate process also binds LAN, while LAN-only ports remain untouched.
    #
    # ALL persistence (watchdog, OpenRC service, and health-check cron) lives in
    # the staged POSIX-sh script, never in this app -- so the packaged installer carries no
    # persistence-establishment pattern (that PowerShell pattern is what tripped
    # the Defender ML false positive Trojan:Script/Wacatac.H!ml in v11.0.1).
    #
    # Never throws — a watchdog-install hiccup must not fail a good start/restart.
    param(
        [Parameter(Mandatory)][string]$Ip,
        [string]$Phase = 'post-start'
    )
    $local = Get-DuneDnatWatchScriptPath
    if (-not $local) {
        Write-Host "  [$Phase] Skipped DNAT self-heal watchdog install (bundled script not found)." -ForegroundColor DarkYellow
        return
    }

    $stamp     = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $remoteTmp = "/tmp/dune-dnatw-$stamp.sh"

    # Force LF line endings — Alpine /bin/sh chokes on CRLF.
    $raw = [System.IO.File]::ReadAllText($local)
    $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lf))

    $stageOut = $b64 | & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
          -i "$sshKey" "${sshUser}@${Ip}" "base64 -d > $remoteTmp && echo DUNE_STAGED_OK" 2>&1
    if (($stageOut -join "`n") -notmatch 'DUNE_STAGED_OK') {
        Write-Host "  [$Phase] DNAT watchdog staging failed (non-fatal): $stageOut" -ForegroundColor DarkYellow
        return
    }

    $runOut = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                    -i "$sshKey" "$sshUser@$Ip" `
                    "sudo -n sh $remoteTmp; rc=`$?; rm -f $remoteTmp; exit `$rc" 2>&1
    if (($runOut -join "`n") -match 'DUNE_DNAT_WATCH_OK') {
        Write-Host "  [$Phase] DNAT self-heal watchdog installed/refreshed — supervised rapid game-listener + RabbitMQ reconciliation active." -ForegroundColor DarkGray
    } else {
        Write-Host "  [$Phase] DNAT watchdog install reported a problem (non-fatal): $runOut" -ForegroundColor DarkYellow
    }
}

function Invoke-DuneBackupDumpPodPrune {
    # Prune Funcom's leftover `*-dump-YYYYMMDD-HHMMSS-pod` objects (issue #363).
    # Keeps the most recent $KeepLast pods; deletes the rest in terminal phase.
    # Best-effort + never throws — a prune hiccup must not fail a good
    # start/reboot. Also runs at backup-schedule cadence via BackupSchedule.ps1's
    # cron block; this hook is the belt-and-suspenders for servers that have no
    # backup schedule installed (issue #363 listed start/reboot integration as
    # "cheap, already SSH'd in").
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$KeepLast = 10,
        [string]$Phase = 'post-start'
    )
    if ($KeepLast -lt 0)   { $KeepLast = 0 }
    if ($KeepLast -gt 100) { $KeepLast = 100 }
    $skip = $KeepLast + 1

    # Single-line BusyBox-safe pipeline; same logic as the cron-embedded
    # snippet so behavior is identical at both call sites.
    $cmd = "sudo kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}{`"\n`"}{end}' 2>/dev/null | awk -F'|' '`$3==`"Succeeded`" && `$2 ~ /-dump-[0-9]{8}-[0-9]{6}-pod`$/' | sort -t'|' -k2 -r | tail -n +$skip | while IFS='|' read ns nm phase; do sudo kubectl delete pod -n `"`$ns`" `"`$nm`" --ignore-not-found 2>&1 && echo DUNE_DUMP_POD_DELETED; done"
    $out = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                 -i "$sshKey" "$sshUser@$Ip" "$cmd" 2>&1
    $deleted = @($out | Where-Object { $_ -match 'DUNE_DUMP_POD_DELETED' }).Count
    if ($deleted -gt 0) {
        Write-Host "  [$Phase] Pruned $deleted leftover dump pod(s) (keeping last $KeepLast)." -ForegroundColor DarkGray
    } else {
        Write-Host "  [$Phase] No leftover dump pods to prune (keep last $KeepLast)." -ForegroundColor DarkGray
    }
}

# ============================================================
#  MENU DEFINITIONS
# ============================================================

$vmCommands = @(
    [pscustomobject]@{ Key = "a"; Name = "initial-setup";      Desc = "Run the initial VM setup" }
    [pscustomobject]@{ Key = "c"; Name = "start-vm";           Label = "Start VM Only";    Desc = "Power on the VM only (no battlegroup) - useful for maintenance or running an update" }
    [pscustomobject]@{ Key = "d"; Name = "startup";            Label = "Start All";        Desc = "Power on VM -> start battlegroup -> wait for overmap + survival maps" }
    [pscustomobject]@{ Key = "e"; Name = "shutdown";           Label = "Stop All";         Desc = "Stop battlegroup (if running) -> power off VM (e.g. shut down for the night)" }
    [pscustomobject]@{ Key = "f"; Name = "reboot";             Label = "Reboot All";       Desc = "Stop battlegroup -> restart VM -> start battlegroup (clean cycle)" }
    [pscustomobject]@{ Key = "g"; Name = "rotate-ssh-key";     Desc = "Generate a new SSH key and replace the one authorized on the VM" }
    [pscustomobject]@{ Key = "h"; Name = "change-password";    Desc = "Change the password of the 'dune' user on the VM" }
    [pscustomobject]@{ Key = "i"; Name = "change-vm-ip";       Desc = "Change the VM's IP address or how it gets one (DHCP/static)" }
)

$bgCommands = @(
    [pscustomobject]@{ Key = "1";  SubSection = $null;          Name = "status";                    Desc = "Shows the status of the selected battlegroup" }
    [pscustomobject]@{ Key = "2";  SubSection = $null;          Name = "start";                     Label = "Start BG Only";   Desc = "Starts the selected battlegroup" }
    [pscustomobject]@{ Key = "3";  SubSection = $null;          Name = "restart";                   Label = "Restart BG Only"; Desc = "Restarts the selected battlegroup" }
    [pscustomobject]@{ Key = "4";  SubSection = $null;          Name = "stop";                      Label = "Stop BG Only";    Desc = "Stops the selected battlegroup" }
    [pscustomobject]@{ Key = "5";  SubSection = $null;          Name = "update";                    Desc = "Checks for new versions and applies them" }
    [pscustomobject]@{ Key = "6";  SubSection = $null;          Name = "edit";                      Desc = "Edit the battlegroup with the utilities interface" }
    [pscustomobject]@{ Key = "7";  SubSection = $null;          Name = "edit-advanced";             Label = "Edit Director";   Desc = "(Advanced) Manually edit battlegroup directly with YAML" }
    [pscustomobject]@{ Key = "21"; SubSection = $null;          Name = "change-battlegroup-ip";     Label = "Change Player IP"; Desc = "Change the IP that players connect to" }
    [pscustomobject]@{ Key = "8";  SubSection = $null;          Name = "enable-experimental-swap";  Desc = "(Experimental) Enable experimental swap memory feature" }
    [pscustomobject]@{ Key = "9";  SubSection = "Database";     Name = "backup";                    Desc = "Take a backup of the battlegroup's database" }
    [pscustomobject]@{ Key = "10"; SubSection = "Database";     Name = "import";                    Desc = "Import a database backup into the selected battlegroup" }
    [pscustomobject]@{ Key = "11"; SubSection = "Logs";         Name = "logs-export";               Desc = "Retrieves logs from all pods in the selected battlegroup" }
    [pscustomobject]@{ Key = "12"; SubSection = "Logs";         Name = "operator-logs-export";      Desc = "Retrieves logs from all operator pods" }
    [pscustomobject]@{ Key = "13"; SubSection = "Monitoring";   Name = "open-file-browser";         Desc = "Open the battlegroup file browser to view and edit ini configs and logs" }
    [pscustomobject]@{ Key = "14"; SubSection = "Monitoring";   Name = "open-director";             Desc = "Open the battlegroup director page to view server status" }
    [pscustomobject]@{ Key = "15"; SubSection = "Monitoring";   Name = "shell-vm";                  Desc = "Connect to the VM via commandline" }
    [pscustomobject]@{ Key = "16"; SubSection = "Monitoring";   Name = "shell-pod";                 Desc = "Connect to a pod in the battlegroup via commandline" }
    [pscustomobject]@{ Key = "20"; SubSection = "Maintenance";   Name = "fix-on-demand-maps";        Desc = "Clear pinned partitions so DeepDesert / Arrakeen / Harko launch on demand" }
)

$toolCommands = @(
    [pscustomobject]@{ Key = "17"; Name = "ssh";             Desc = "Open an SSH terminal to the VM" }
)
$toolCommands += [pscustomobject]@{ Key = "18"; Name = "setup-guide";    Desc = "Open Funcom Self-Hosted Server Setup Instructions" }

# ============================================================
#  AVAILABILITY CHECKS
# ============================================================

function Get-VmCmdAvailability {
    param($cmdName, $info)
    switch ($cmdName) {
        "initial-setup" { return @{ Available = $true; Reason = $null } }
        "start-vm" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist. Run 'initial-setup' first." } }
            if ($info.Running)      { return @{ Available = $false; Reason = "VM '$vmName' is already running." } }
            return @{ Available = $true; Reason = $null }
        }
        "stop-vm" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running (currently $($info.State))." } }
            return @{ Available = $true; Reason = $null }
        }
        "reboot" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running. Use 'd. startup' to cold-start." } }
            return @{ Available = $true; Reason = $null }
        }
        "shutdown" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running." } }
            return @{ Available = $true; Reason = $null }
        }
        "startup" {
            if (-not $info.Exists) { return @{ Available = $false; Reason = "VM '$vmName' does not exist. Run 'initial-setup' first." } }
            return @{ Available = $true; Reason = $null }
        }
        default {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running." } }
            return @{ Available = $true; Reason = $null }
        }
    }
}

function Get-BgCmdAvailability {
    param($info)
    if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
    if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running." } }
    return @{ Available = $true; Reason = $null }
}

function Get-ToolCmdAvailability {
    param($cmdName, $info)
    switch ($cmdName) {
        "ssh" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running." } }
            return @{ Available = $true; Reason = $null }
        }
        default { return @{ Available = $true; Reason = $null } }
    }
}

# ============================================================
#  MAIN LOOP
# ============================================================

$directorPort = $null
$bgBinPath    = '/home/dune/.dune/bin/battlegroup'
$cmdHasRun    = $false

# Top-level trap: on any unhandled exception, clean up background helpers
# before bubbling out so the script exits with a non-zero code (the .bat
# file then pauses so the user can read the error).
trap {
    Write-Host ""
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  at: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    Write-Host "Cleaning up background helpers..." -ForegroundColor Yellow
    Invoke-DuneCleanup
    Invoke-DunePauseBeforeClose
    exit 1
}

while ($true) {
    # In -Cmd (non-interactive) mode, exit after exactly one handler runs.
    # Handlers use `continue` which would otherwise skip the bottom-of-loop
    # `if ($Cmd) { break }` and cause an infinite re-dispatch.
    if ($Cmd -and $cmdHasRun) { break }
    if ($Cmd) { $cmdHasRun = $true }

    $info = Get-VmInfo

    # Build entries list
    $entries  = @()
    $entryByKey = @{}

    foreach ($c in $vmCommands) {
        $avail = Get-VmCmdAvailability -cmdName $c.Name -info $info
        $entries += [pscustomobject]@{ Section = 'vm'; SubSection = $null; Key = $c.Key; Name = $c.Name; Label = $(if ($c.Label) { $c.Label } else { $c.Name }); Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }
    foreach ($c in $bgCommands) {
        $avail = Get-BgCmdAvailability -info $info
        $entries += [pscustomobject]@{ Section = 'battlegroup'; SubSection = $c.SubSection; Key = $c.Key; Name = $c.Name; Label = $(if ($c.Label) { $c.Label } else { $c.Name }); Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }
    foreach ($c in $toolCommands) {
        $avail = Get-ToolCmdAvailability -cmdName $c.Name -info $info
        $entries += [pscustomobject]@{ Section = 'tools'; SubSection = $null; Key = $c.Key; Name = $c.Name; Label = $(if ($c.Label) { $c.Label } else { $c.Name }); Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }

    foreach ($e in $entries) { $entryByKey[$e.Key.ToLower()] = $e }

    if ($Cmd) {
        # Non-interactive dispatch (called by the desktop app's terminal pane).
        # Skip menu render + interactive selection; look up the entry by
        # command name and fall through to the handler block.
        $entry = $entries | Where-Object { $_.Name -eq $Cmd } | Select-Object -First 1
        if (-not $entry) {
            Write-Error "Unknown command: $Cmd"
            Invoke-DunePauseBeforeClose
            exit 1
        }
    } else {
        # --- Render menu ---
        Write-Host ""
        Write-Host "===  Dune Awakening - Server Management  ===" -ForegroundColor Cyan
        Write-Host "  Brought to you by Coastal (Discord @allcoast)" -ForegroundColor DarkGray
        $vmStatusColor = if ($info.Running) { 'Green' } elseif ($info.Exists) { 'Yellow' } else { 'Red' }
        $vmStatusText  = if ($info.Running) { "Running ($($info.Ip))" } elseif ($info.Exists) { "$($info.State)" } else { "Not found" }
        Write-Host "  VM: " -NoNewline; Write-Host $vmStatusText -ForegroundColor $vmStatusColor
        Write-Host "  Required Port Forwarding:" -ForegroundColor DarkGray
        if ($portCheckMode -ne 'disabled' -and $info.Running) {
            $check = Get-PortCheckStatus -Force:$false
            if ($check -and $check.PublicIp) {
                foreach ($r in $check.Results) {
                    $tag = switch ($r.Status) {
                        'open'     { '[OPEN]'              }
                        'closed'   { '[CLOSED]'            }
                        'udp-skip' { '[UDP - skipped]'     }
                        default    { '[UNKNOWN]'           }
                    }
                    $color = switch ($r.Status) {
                        'open'     { 'Green'    }
                        'closed'   { 'Red'      }
                        'udp-skip' { 'DarkGray' }
                        default    { 'Yellow'   }
                    }
                    Write-Host ("    {0,-45} " -f $r.Label) -ForegroundColor DarkGray -NoNewline
                    Write-Host $tag -ForegroundColor $color
                }
            } else {
                Write-Host "    UDP  7777-7810   Game servers     [check failed - no public IP]" -ForegroundColor Yellow
                Write-Host "    TCP  31982       RabbitMQ         [check failed - no public IP]" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    UDP  7777-7810   Game servers" -ForegroundColor DarkGray
            Write-Host "    TCP  31982       RabbitMQ" -ForegroundColor DarkGray
            if ($portCheckMode -eq 'disabled') {
                Write-Host "    (port verification disabled)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""

        $prevSection = $null
        foreach ($e in $entries) {
            if ($e.Section -ne $prevSection) {
                if ($null -ne $prevSection) { Write-Host "" }
                switch ($e.Section) {
                    'vm'          { Write-Host "VM commands:" -ForegroundColor Yellow }
                    'battlegroup' { Write-Host "Battlegroup commands:" -ForegroundColor Yellow }
                    'tools'       { Write-Host "Tools:" -ForegroundColor Yellow }
                }
            }
            $color = if ($e.Available) { 'White' } else { 'DarkGray' }
            Write-Host ("  {0,2}. {1,-30} {2}" -f $e.Key, $e.Label, $e.Desc) -ForegroundColor $color
            $prevSection = $e.Section
        }

        Write-Host ("  {0,2}. {1,-30} {2}" -f "q", "quit", "Exit this script")
        Write-Host ""

        if (-not $info.Exists) {
            Write-Host "Some options are unavailable because VM '$vmName' does not exist. Press 'a' to run 'initial-setup'" -ForegroundColor Yellow
            Write-Host ""
        } elseif (-not $info.Running) {
            Write-Host "Some options are unavailable because VM '$vmName' is currently $($info.State). Press 'c' to run 'startup'" -ForegroundColor Yellow
            Write-Host ""
        }

        # --- Selection ---
        $entry = $null
        while ($null -eq $entry) {
            $selection = (Read-Host "Select an option").Trim().ToLower()
            if ($selection -eq 'q' -or $selection -eq 'quit') { $entry = 'quit'; break }
            if ($entryByKey.ContainsKey($selection)) {
                $entry = $entryByKey[$selection]
            } else {
                Write-Warning "Invalid selection."
            }
        }
        if ($entry -eq 'quit') { break }
    }

    if (-not $entry.Available) {
        Write-Warning $entry.Reason
        if ($Cmd) { Invoke-DunePauseBeforeClose; exit 1 } else { continue }
    }

    $cmdName = $entry.Name
    $ip  = $info.Ip

    # ========================================================
    #  VM COMMANDS
    # ========================================================

    if ($cmdName -eq "initial-setup") {
        # Funcom's initial-setup.ps1 resolves the VM image (.vmcx), vm-utilities.ps1
        # and its bootstrap dir relative to $scriptDir, expecting $scriptDir to be
        # the battlegroup-management folder - that's how their own battlegroup.ps1
        # launches it. We must NOT dot-source it into this process: it would inherit
        # THIS tool's $scriptDir (the install dir, e.g. C:\Program Files\Dune Server)
        # and look for the VM under "...\..\Virtual Machines" at the wrong location
        # ("No .vmcx file found"). Worse, the script uses `exit 1` on every error,
        # which - when dot-sourced - kills this entire window with no readable
        # message ("runs 1 thing and closes"). Instead we run it in a child pwsh
        # that replicates Funcom's environment, so every path resolves correctly and
        # any `exit` only ends the child. We then pause so the window stays open.
        $isScript = Join-Path $bgSetupPath 'initial-setup.ps1'
        if (-not (Test-Path -LiteralPath $isScript)) {
            Write-Host ""
            Write-Host "Could not find Funcom's initial-setup.ps1." -ForegroundColor Red
            Write-Host "  Expected at: $isScript" -ForegroundColor Gray
            Write-Host "  Check that 'Steam Path' in Settings points at the Self-Hosted" -ForegroundColor Yellow
            Write-Host "  Server install (the folder that contains 'battlegroup-management')." -ForegroundColor Yellow
            Read-Host "Press Enter to close this window"
            if ($Cmd) { break }
            continue
        }
        $pwshExe = (Get-Process -Id $PID).Path
        if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
        $bgEsc = $bgSetupPath.Replace("'", "''")
        # Mirror battlegroup.ps1: set $scriptDir to battlegroup-management, load
        # vm-utilities.ps1, then run initial-setup.ps1 in that same scope.
        $childScript = @"
`$scriptDir = '$bgEsc'
. '$bgEsc\vm-utilities.ps1'
. '$bgEsc\initial-setup.ps1'
"@
        Write-Host "Running Funcom initial setup..." -ForegroundColor Cyan
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -Command $childScript
        $rc = $LASTEXITCODE
        Write-Host ""
        if ($rc -and $rc -ne 0) {
            Write-Host "initial-setup exited with code $rc (see messages above)." -ForegroundColor Yellow
        } else {
            Write-Host "initial-setup finished." -ForegroundColor Green
        }
        Read-Host "Press Enter to close this window"
        if ($Cmd) { break }
        continue
    }

    if ($cmdName -eq "start-vm") {
        Write-Host "Starting VM '$vmName'..." -ForegroundColor Cyan
        Start-VM -Name $vmName @hvSplat | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName @hvSplat } while ($vm.State -ne 'Running')
        Write-Host "VM started." -ForegroundColor Green

        $ip = $null; $timeout = 120; $elapsed = 0; $dots = 0
        while (-not $ip -and $elapsed -lt $timeout) {
            $dots = ($dots % 3) + 1
            Write-Host -NoNewline "`rWaiting for VM to acquire an IP address$('.' * $dots)   "
            Start-Sleep -Seconds 1; $elapsed += 1
            $ip = Resolve-DuneCliVmIp
        }
        Write-Host ""
        if (-not $ip) { Write-Warning "Could not determine VM IP after $timeout seconds." }
        else          { Write-Host "VM ready at $ip." -ForegroundColor Green }
        continue
    }

    if ($cmdName -eq "stop-vm") {
        $vmNow = Get-VM -Name $vmName @hvSplat -ErrorAction SilentlyContinue
        if (-not $vmNow) {
            Write-Warning "VM '$vmName' not found - nothing to stop."
            continue
        }
        if ($vmNow.State -eq 'Off') {
            Write-Host "VM '$vmName' is already off." -ForegroundColor Green
            continue
        }
        # Use the same graceful-then-hard-power-off escalation as Stop All
        # instead of a bare Stop-VM -Force: the Alpine guest does not always honor
        # the Hyper-V integration shutdown request, and a plain Stop-VM then writes
        # an error (and on an already-off VM throws outright), flashing the InApp
        # window shut before it can be read.
        $estVmStop = Format-PhaseEstimate 'vm-stop'
        try {
            $vmStopSec = Stop-VmWithEscalation -Name $vmName -Label "Stopping VM" -EstimateText $estVmStop
            Save-PhaseTiming 'vm-stop' $vmStopSec
            Complete-WaitCounter -Message "VM stopped in $(Format-Duration $vmStopSec)." -Color Green
        } catch {
            Complete-WaitCounter -Message $_.Exception.Message -Color Red
            Write-Warning "Could not stop VM '$vmName': $($_.Exception.Message) Check Hyper-V Manager."
        }
        continue
    }

    if ($cmdName -eq "startup") {
        Write-Host ""
        Write-Host "=== Startup ===" -ForegroundColor Cyan
        Write-Host "  1. Start VM (skipped if already running)" -ForegroundColor DarkGray
        Write-Host "  2. Wait for SSH + k3s + DB + operator webhook readiness" -ForegroundColor DarkGray
        Write-Host "  3. Start battlegroup" -ForegroundColor DarkGray
        Write-Host "  4. Wait for overmap and survival map pods to be Ready" -ForegroundColor DarkGray
        Write-Host ""

        $t0 = Get-Date
        $vmStartedThisRun = $false

        # ---- Step 1: VM ----
        Write-Host ""
        if ($info.Running) {
            Write-Host "[1/4] VM '$vmName' already running ($($info.Ip))." -ForegroundColor Green
            $ip = $info.Ip
        } else {
            $vmStartedThisRun = $true
            Write-Host "[1/4] Starting VM '$vmName'..." -ForegroundColor Cyan
            $estVm = Format-PhaseEstimate 'vm-start'
            if ($estVm) { Write-Host "  $estVm" -ForegroundColor DarkGray }
            $t_vm = Get-Date
            Start-VM -Name $vmName @hvSplat | Out-Null
            do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName @hvSplat } while ($vm.State -ne 'Running')
            Save-PhaseTiming 'vm-start' ([int]((Get-Date) - $t_vm).TotalSeconds)
            $estIp = Format-PhaseEstimate 'vm-ip'
            $ipHint = if ($estIp) { " $estIp" } else { "" }
            Write-Host "  VM running. Waiting for IP...$ipHint" -ForegroundColor DarkGray

            $newIp = $null; $timeout = $script:WaitVmIpSec; $elapsed = 0; $dots = 0
            $t_ip = Get-Date
            while (-not $newIp -and $elapsed -lt $timeout) {
                $dots = ($dots % 3) + 1
                Write-Host -NoNewline ("`r  Waiting for IP$('.' * $dots)   ")
                Start-Sleep -Seconds 1; $elapsed += 1
                $newIp = Resolve-DuneCliVmIp
            }
            Write-Host ""
            if (-not $newIp) { Write-Warning "VM did not acquire IP within $(Format-Duration $timeout). Aborting."; continue }
            Save-PhaseTiming 'vm-ip' ([int]((Get-Date) - $t_ip).TotalSeconds)
            $ip = $newIp
            Write-Host "  VM IP: $ip" -ForegroundColor Green
        }

        # ---- Step 2: SSH + cluster readiness ----
        Write-Host ""
        Write-Host "[2/4] Waiting for cluster readiness..." -ForegroundColor Cyan
        Write-Host "  First boot can take 10-30 min (k3s, operators, and the database initializing). Please be patient." -ForegroundColor DarkGray

        # 2a. SSH responsive
        $estSsh = Format-PhaseEstimate 'ssh-ready'
        $t_ssh = Get-Date; $sshReady = $false; $maxSec = $script:WaitSshSec
        while (((Get-Date) - $t_ssh).TotalSeconds -lt $maxSec) {
            Write-WaitCounter -Start $t_ssh -Label "Waiting for SSH..." -EstimateText $estSsh
            $probe = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=3 -i "$sshKey" "$sshUser@$ip" "echo ok" 2>$null
            if ($probe -match 'ok') { $sshReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_ssh).TotalSeconds -lt $maxSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_ssh -Label "Waiting for SSH..." -EstimateText $estSsh
            }
        }
        $elapsed = [int]((Get-Date) - $t_ssh).TotalSeconds
        if (-not $sshReady) {
            Complete-WaitCounter -Message "SSH not responsive after $(Format-Duration $elapsed). Aborting." -Color Red
            Write-Host "  Likely SSH key auth failure (the tool requires passwordless key auth - it will not use a password)." -ForegroundColor Yellow
            Write-Host "  Fixes: run 'rotate-ssh-key' to generate + authorize a fresh key, OR add this key's .pub to ~/.ssh/authorized_keys on the VM:" -ForegroundColor DarkGray
            Write-Host "    Get-Content `"$sshKey.pub`" | ssh $sshUser@$ip `"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`"" -ForegroundColor DarkGray
            continue
        }
        Save-PhaseTiming 'ssh-ready' $elapsed
        Complete-WaitCounter -Message "SSH responsive ($(Format-Duration $elapsed))."

        # 2b. k3s API
        $estApi = Format-PhaseEstimate 'k3s-api'
        $t_api = Get-Date; $apiReady = $false
        while (((Get-Date) - $t_api).TotalSeconds -lt $script:WaitK3sApiSec) {
            Write-WaitCounter -Start $t_api -Label "Waiting for k3s API..." -EstimateText $estApi
            $apiOk = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get --raw='/readyz' 2>/dev/null"
            if ($apiOk -match 'ok') { $apiReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_api).TotalSeconds -lt $script:WaitK3sApiSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_api -Label "Waiting for k3s API..." -EstimateText $estApi
            }
        }
        $elapsed = [int]((Get-Date) - $t_api).TotalSeconds
        if (-not $apiReady) {
            Complete-WaitCounter -Message "k3s API not ready after $(Format-Duration $elapsed) - starting battlegroup anyway." -Color Yellow
        } else {
            Save-PhaseTiming 'k3s-api' $elapsed
            Complete-WaitCounter -Message "k3s API ready ($(Format-Duration $elapsed))."
        }

        # 2c. DB pod(s) Ready - find ACTUAL db pods by name pattern (not "all pods in namespace",
        # which would also wait on backup Jobs, file-browser deploys, etc. and time out incorrectly).
        # Awk prints "namespace podname" space-separated; embedded double quotes in
        # an awk script get mangled by PowerShell when the script is in a double-
        # quoted string passed to ssh, so we split on whitespace in PS instead.
        #
        # Exclusions matter: the `-db-` family also contains a one-shot
        # `db-dbdepl-util` Job pod plus `db-util-mon` / `db-util-pghero`
        # sidecars. A finished Job pod sits in STATUS=Completed forever, and
        # `kubectl wait --for=condition=Ready` against a Completed pod never
        # succeeds - it blocks for the ENTIRE --timeout (900s) and then fails,
        # so reboot/start appeared to hang for 15 minutes whenever that Job
        # pod hadn't been garbage-collected yet. Skip util/mon/pghero by name
        # and skip any terminal (Completed/Succeeded) pod by status ($4) so we
        # only ever wait on the real DB StatefulSet pod (db-dbdepl-sts-*).
        $estDb = Format-PhaseEstimate 'db-pods'
        $dbPodList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ && `$2 !~ /(dump|backup|fb-|migration|util|mon|pghero)/ && `$4 !~ /(Completed|Succeeded)/ {print `$1, `$2}'"
        $dbPodList = ($dbPodList | Out-String).Trim()
        # Keep only well-formed "namespace podname" lines. An early-boot kubectl
        # race can emit a partial/garbage line (seen in the field as a bare "f"),
        # which previously became the namespace and produced
        # "namespaces \"f\" not found". Require a real battlegroup namespace
        # (funcom-seabass-*) and a non-empty pod name; if none survive, fall
        # through to the no-DB-pods branch.
        $dbPods = @($dbPodList -split "`r?`n" | Where-Object {
            $_p = $_.Trim() -split '\s+', 2
            $_p.Count -eq 2 -and $_p[0] -like 'funcom-seabass-*' -and $_p[1]
        })
        if ($dbPods.Count -gt 0) {
            $dbNs = ($dbPods[0] -split '\s+', 2)[0]
            $podArgs = ($dbPods | ForEach-Object { "pod/$(($_ -split '\s+', 2)[1])" }) -join ' '
            $dbResult = Invoke-WithLiveCounter -Label "Waiting for DB pod(s) Ready..." -EstimateText $estDb `
                -ArgumentList $sshKey,$sshUser,$ip,$dbNs,$podArgs,$script:WaitDbPodsSec `
                -Action {
                    param($sshKey, $sshUser, $ip, $dbNs, $podArgs, $timeoutSec)
                    $output = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                        "sudo k3s kubectl wait --for=condition=Ready $podArgs -n '$dbNs' --timeout=${timeoutSec}s 2>&1"
                    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
                }
            $podCount = $dbPods.Count
            $podLabel = if ($podCount -eq 1) { "1 pod" } else { "$podCount pods" }
            if ($dbResult.Output.ExitCode -eq 0) {
                Save-PhaseTiming 'db-pods' $dbResult.Elapsed
                Complete-WaitCounter -Message "DB ready in $(Format-Duration $dbResult.Elapsed) ($podLabel in $dbNs)."
            } else {
                Complete-WaitCounter -Message "DB wait failed after $(Format-Duration $dbResult.Elapsed) ($podLabel in $dbNs) - proceeding anyway." -Color Yellow
                if ($dbResult.Output.Output) { $dbResult.Output.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
            }
        } else {
            Write-Host "  No DB pods detected by name pattern - skipping (operator readiness will catch DB issues)." -ForegroundColor DarkGray
        }

        # 2d. operator pods Ready
        $estOp = Format-PhaseEstimate 'operators'
        $opResult = Invoke-WithLiveCounter -Label "Waiting for operator pods Ready..." -EstimateText $estOp `
            -ArgumentList $sshKey,$sshUser,$ip,$script:WaitOperatorsSec `
            -Action {
                param($sshKey, $sshUser, $ip, $timeoutSec)
                $output = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                    "sudo k3s kubectl wait --for=condition=Ready pods --all -n funcom-operators --timeout=${timeoutSec}s 2>&1"
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
            }
        if ($opResult.Output.ExitCode -ne 0) {
            Complete-WaitCounter -Message "Operator pods not Ready after $(Format-Duration $opResult.Elapsed) - starting battlegroup anyway." -Color Yellow
            if ($opResult.Output.Output) { $opResult.Output.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        } else {
            Save-PhaseTiming 'operators' $opResult.Elapsed
            Complete-WaitCounter -Message "Operator pods Ready ($(Format-Duration $opResult.Elapsed))."
        }

        # 2e. webhook Service endpoints
        $estWh = Format-PhaseEstimate 'webhook-endpoints'
        $t_wh = Get-Date; $epReady = $false
        while (((Get-Date) - $t_wh).TotalSeconds -lt $script:WaitWebhookSec) {
            Write-WaitCounter -Start $t_wh -Label "Waiting for webhook Service endpoints..." -EstimateText $estWh
            $epOut = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl -n funcom-operators get endpoints battlegroupoperator-webhook-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null"
            if ($epOut -match '\d+\.\d+\.\d+\.\d+') { $epReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_wh).TotalSeconds -lt $script:WaitWebhookSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_wh -Label "Waiting for webhook Service endpoints..." -EstimateText $estWh
            }
        }
        $elapsed = [int]((Get-Date) - $t_wh).TotalSeconds
        if (-not $epReady) {
            Complete-WaitCounter -Message "battlegroupoperator-webhook-svc has no endpoints after $(Format-Duration $elapsed) - starting battlegroup anyway (it may need a retry if the operator webhook returns 502)." -Color Yellow
        } else {
            Save-PhaseTiming 'webhook-endpoints' $elapsed
            Complete-WaitCounter -Message "Webhook endpoints populated ($(Format-Duration $elapsed))."
        }
        Write-Host "  Settling 10s before starting battlegroup..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10

        try {
            $prunedDirectorPods = Remove-DuneTerminalDirectorPodHistory -Ip $ip -SshUser $sshUser -SshKey $sshKey
            if ($prunedDirectorPods -gt 0) {
                Write-Host "  Removed $prunedDirectorPods stale director pod record(s)." -ForegroundColor DarkGray
            }
        } catch {
            Write-Warning "  Could not clean stale director pod history: $($_.Exception.Message)"
        }

        if ($vmStartedThisRun) {
            $recycle = Restart-DuneCoreMapPodsAfterVmBoot -Ip $ip -SshUser $sshUser -SshKey $sshKey
            if ($recycle.Count -gt 0) {
                Write-Host "  Replacing $($recycle.Count) core-map pod(s) restarted in place after VM boot so game/database sessions are fresh:" -ForegroundColor Yellow
                foreach ($pod in $recycle.Pods) { Write-Host "    $pod" -ForegroundColor DarkGray }
            }
        }

        # Refresh monitoring before issuing battlegroup start; reconciliation is
        # continuous and does not depend on a later readiness/green transition.
        Invoke-DuneHyperVGuestRecoveryInstall -Ip $ip -Phase 'pre-startup'
        Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase 'pre-startup'

        # ---- Step 3: battlegroup start ----
        Write-Host ""
        $estBg = Format-PhaseEstimate 'battlegroup-start'
        $bgHint = if ($estBg) { " $estBg" } else { "" }
        Write-Host "[3/4] Starting battlegroup...$bgHint" -ForegroundColor Cyan
        $t_bg = Get-Date
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath start"
        $bgStartExit = $LASTEXITCODE
        Save-PhaseTiming 'battlegroup-start' ([int]((Get-Date) - $t_bg).TotalSeconds)

        # ---- Step 4: wait for map pods ----
        Write-Host ""
        Write-Host "[4/4] Waiting for maps to finish loading and report game-ready..." -ForegroundColor Cyan
        $mapResults = @{}
        foreach ($map in 'overmap','survival') {
            $estMap = Format-PhaseEstimate "map-$map"
            $mapHint = if ($estMap) { " $estMap" } else { "" }
            Write-Host "  Waiting for $map game readiness (timeout 300s)...$mapHint" -ForegroundColor DarkGray
            $r = Wait-MapPodReady -Ip $ip -MapName $map -TimeoutSec 300
            $mapResults[$map] = $r
            if ($r.Success) {
                Save-PhaseTiming "map-$map" ([int]$r.Elapsed)
                Write-Host "  $map -> $($r.Pod) is game-ready ($($r.Ready)) in $(Format-Duration $r.Elapsed)" -ForegroundColor Green
            } else {
                if ($r.Pod) {
                    Write-Warning "  $map ($($r.Pod)) did not become game-ready within $(Format-Duration $r.Elapsed) (last seen: $($r.LastStatus))"
                } else {
                    # No pod object at all is a DIFFERENT failure class from a pod
                    # that won't go Ready: the operator never created one. The
                    # usual cause is a DatabaseOperation still holding the
                    # database, which nothing else here would mention.
                    $dbBlock = Get-DuneDatabaseBlockState -Ip $ip
                    if ($dbBlock.blocked) {
                        Write-Warning "  $map pod was never CREATED within $(Format-Duration $r.Elapsed) - a database operation is blocking the server"
                        if ($dbBlock.phase) {
                            Write-Host ("    Battlegroup DATABASE phase is '{0}' instead of Ready, so the operator creates no map pods." -f $dbBlock.phase) -ForegroundColor Yellow
                        }
                        foreach ($op in $dbBlock.ops) {
                            Write-Host ("    unfinished database operation: {0}" -f $op) -ForegroundColor Yellow
                        }
                        Write-Host "    Fix: delete EVERY DatabaseOperation that is not Succeeded (not just the one named in the log), then start again." -ForegroundColor DarkGray
                        Write-Host "         Deleting those records does not touch the database, its PVC, or any backup." -ForegroundColor DarkGray
                    } else {
                        Write-Warning "  $map pod was never found within $(Format-Duration $r.Elapsed)"
                    }
                }
            }
        }

        $totalSec = [int]((Get-Date) - $t0).TotalSeconds
        Save-PhaseTiming 'total-startup' $totalSec
        $estTotal = Format-PhaseEstimate 'total-startup'
        Write-Host ""
        $allOk = ($mapResults.Values | Where-Object { -not $_.Success } | Measure-Object).Count -eq 0
        if ($allOk) {
            Write-Host "=== Startup complete in $(Format-Duration $totalSec) (overmap + survival Ready) ===" -ForegroundColor Green
        } else {
            Write-Host "=== Startup finished in $(Format-Duration $totalSec) with WARNINGS - see above ===" -ForegroundColor Yellow
            Write-Host "Use 'status' (1) or 'shell-pod' (16) to investigate any map that didn't reach Ready." -ForegroundColor DarkGray
        }
        if ($estTotal) { Write-Host "  $estTotal" -ForegroundColor DarkGray }

        # Auto-clear pinned on-demand partitions so DD/Arrakeen/Harko spawn for
        # the next player without manual intervention. Skipped if `bg start`
        # itself failed (no point waiting on operator that never reconciled).
        if ($bgStartExit -eq 0) {
            Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase 'post-startup' -Mode cron -Fast
            Invoke-DuneBackupDumpPodPrune -Ip $ip -Phase 'post-startup'
        } else {
            Write-Host "  Skipped on-demand partition auto-clear because battlegroup start exited $bgStartExit." -ForegroundColor DarkYellow
        }

        # Surface VM memory-pressure (OOMKilled operators / low RAM+Swap:0) as a
        # red warning after the summary - the root cause of off-schedule restarts.
        Show-DuneVmMemoryPressureWarning -Ip $ip

        $directorPort = $null
        continue
    }

    if ($cmdName -eq "reboot") {
        Write-Host ""
        Write-Host "=== Reboot ===" -ForegroundColor Cyan
        Write-Host "  1. Stop battlegroup (waits for game/mq/gateway/director pods to terminate)" -ForegroundColor DarkGray
        Write-Host "  2. Hard-stop and restart the VM" -ForegroundColor DarkGray
        Write-Host "  3. Start battlegroup again" -ForegroundColor DarkGray
        Write-Host ""
        if (-not (Confirm-NoPlayersOnline -ActionLabel "reboot")) {
            Write-Host "Aborted." -ForegroundColor Cyan; continue
        }

        $t0 = Get-Date

        # ---- Step 1: stop battlegroup ----
        Write-Host ""
        Write-Host "[1/3] Stopping battlegroup..." -ForegroundColor Cyan
        if (-not (Test-DuneBattlegroupHasPods -Ip $ip -SshUser $sshUser -SshKey $sshKey)) {
            Write-Host "  Battlegroup not running (no game/infra pods) - skipping stop." -ForegroundColor DarkGray
        } else {
            ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath stop"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "battlegroup stop returned exit code $LASTEXITCODE. Aborting reboot."
                continue
            }
        }

        # Wait for game/infra pods to fully terminate (only db/fb/operator pods should remain).
        # Pattern matches the dynamic Funcom pod families: sg-* (servers), mq-* (rabbitmq),
        # sgw-* (gateway), tr-* (traffic router), bgd-* (battlegroup director).
        $estTerm = Format-PhaseEstimate 'pods-terminate'
        $waitStart = Get-Date
        $maxWaitSec = 360
        $finalCount = $null
        while ($true) {
            $remainRaw = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E '(-sg-|-mq-|-sgw-|-tr-|-bgd-)' | wc -l"
            $remain = ($remainRaw -replace '\D','')
            if (-not $remain) { $remain = '0' }
            $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
            if ($remain -eq '0') {
                $finalCount = 0; break
            }
            if ($elapsed -gt $maxWaitSec) {
                $finalCount = [int]$remain; break
            }
            Write-WaitCounter -Start $waitStart -Label "Waiting for pods to terminate ($remain remaining)..." -EstimateText $estTerm
            for ($i = 0; $i -lt 5 -and ((Get-Date) - $waitStart).TotalSeconds -le $maxWaitSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $waitStart -Label "Waiting for pods to terminate ($remain remaining)..." -EstimateText $estTerm
            }
        }
        $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
        if ($finalCount -eq 0) {
            Save-PhaseTiming 'pods-terminate' $elapsed
            Complete-WaitCounter -Message "All game/infra pods terminated after $(Format-Duration $elapsed)."
            Show-DuneFuncomStopWarningNote -Ip $ip -SshUser $sshUser -SshKey $sshKey
        } else {
            Complete-WaitCounter -Message "$finalCount pod(s) still present after $(Format-Duration $elapsed). Proceeding with VM restart anyway." -Color Yellow
        }

        # ---- Step 2: VM restart ----
        Write-Host ""
        $estVm = Format-PhaseEstimate 'vm-start'
        $vmHint = if ($estVm) { " $estVm" } else { "" }
        Write-Host "[2/3] Restarting VM '$vmName'...$vmHint" -ForegroundColor Cyan
        $estVmStop = Format-PhaseEstimate 'vm-stop'
        try {
            $vmStopSec = Stop-VmWithEscalation -Name $vmName -Label "Stopping VM" -EstimateText $estVmStop
            Save-PhaseTiming 'vm-stop' $vmStopSec
            Complete-WaitCounter -Message "VM stopped in $(Format-Duration $vmStopSec)." -Color Green
        } catch {
            Complete-WaitCounter -Message $_.Exception.Message -Color Red
            Write-Warning "VM may still be in a stuck state - aborting reboot. Check Hyper-V Manager."
            continue
        }
        $t_vm = Get-Date
        Start-VM -Name $vmName @hvSplat | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName @hvSplat } while ($vm.State -ne 'Running')
        Save-PhaseTiming 'vm-start' ([int]((Get-Date) - $t_vm).TotalSeconds)
        $estIp = Format-PhaseEstimate 'vm-ip'
        $ipHint = if ($estIp) { " $estIp" } else { "" }
        Write-Host "  VM running. Waiting for IP...$ipHint" -ForegroundColor DarkGray

        $newIp = $null; $timeout = $script:WaitVmIpSec; $elapsed = 0; $dots = 0
        $t_ip = Get-Date
        while (-not $newIp -and $elapsed -lt $timeout) {
            $dots = ($dots % 3) + 1
            Write-Host -NoNewline ("`r  Waiting for IP$('.' * $dots)   ")
            Start-Sleep -Seconds 1; $elapsed += 1
            $newIp = Resolve-DuneCliVmIp
        }
        Write-Host ""
        if (-not $newIp) { Write-Warning "VM did not acquire IP within $(Format-Duration $timeout). Aborting."; continue }
        Save-PhaseTiming 'vm-ip' ([int]((Get-Date) - $t_ip).TotalSeconds)
        $ip = $newIp
        Write-Host "  VM IP: $ip" -ForegroundColor Green

        # Wait for SSH to be responsive
        $estSsh = Format-PhaseEstimate 'ssh-ready'
        $t_ssh = Get-Date; $sshReady = $false; $maxSec = $script:WaitSshSec
        while (((Get-Date) - $t_ssh).TotalSeconds -lt $maxSec) {
            Write-WaitCounter -Start $t_ssh -Label "Waiting for SSH..." -EstimateText $estSsh
            $probe = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=3 -i "$sshKey" "$sshUser@$ip" "echo ok" 2>$null
            if ($probe -match 'ok') { $sshReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_ssh).TotalSeconds -lt $maxSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_ssh -Label "Waiting for SSH..." -EstimateText $estSsh
            }
        }
        $elapsed = [int]((Get-Date) - $t_ssh).TotalSeconds
        if (-not $sshReady) {
            Complete-WaitCounter -Message "SSH not responsive after $(Format-Duration $elapsed). Aborting." -Color Red
            Write-Host "  Likely SSH key auth failure (the tool requires passwordless key auth - it will not use a password)." -ForegroundColor Yellow
            Write-Host "  Fixes: run 'rotate-ssh-key' to generate + authorize a fresh key, OR add this key's .pub to ~/.ssh/authorized_keys on the VM:" -ForegroundColor DarkGray
            Write-Host "    Get-Content `"$sshKey.pub`" | ssh $sshUser@$ip `"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`"" -ForegroundColor DarkGray
            continue
        }
        Save-PhaseTiming 'ssh-ready' $elapsed
        Complete-WaitCounter -Message "SSH responsive after $(Format-Duration $elapsed)."

        # Wait for k3s API + DB + operator webhook to be FULLY ready.
        # "Pod Running" is not enough: the mutating webhook needs the operator
        # pod's Ready condition true AND its Service endpoints populated, otherwise
        # 'battlegroup start' fails with: 502 Bad Gateway from the API-server proxy.

        # 2a. k3s API responsive
        $estApi = Format-PhaseEstimate 'k3s-api'
        $t_api = Get-Date; $apiReady = $false
        Write-Host "  First boot can take 10-30 min (k3s, operators, and the database initializing). Please be patient." -ForegroundColor DarkGray
        while (((Get-Date) - $t_api).TotalSeconds -lt $script:WaitK3sApiSec) {
            Write-WaitCounter -Start $t_api -Label "Waiting for k3s API..." -EstimateText $estApi
            $apiOk = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get --raw='/readyz' 2>/dev/null"
            if ($apiOk -match 'ok') { $apiReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_api).TotalSeconds -lt $script:WaitK3sApiSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_api -Label "Waiting for k3s API..." -EstimateText $estApi
            }
        }
        $elapsed = [int]((Get-Date) - $t_api).TotalSeconds
        if (-not $apiReady) {
            Complete-WaitCounter -Message "k3s API not ready after $(Format-Duration $elapsed) - starting battlegroup anyway." -Color Yellow
        } else {
            Save-PhaseTiming 'k3s-api' $elapsed
            Complete-WaitCounter -Message "k3s API ready ($(Format-Duration $elapsed))."
        }

        # 2b. DB pod(s) Ready - target actual DB pods by name pattern, not "--all" in the namespace
        # (which would also wait on backup Jobs, file-browser deployments, etc).
        # Awk prints space-separated to avoid embedded double quotes (PowerShell
        # mangles \" inside a double-quoted string passed to ssh).
        #
        # Exclude util/mon/pghero helpers and terminal (Completed/Succeeded)
        # pods: a finished `db-dbdepl-util` Job pod stays Completed forever and
        # `kubectl wait --for=condition=Ready` against it blocks for the full
        # --timeout (900s) before failing, which made start/reboot hang ~15
        # min. We only want the real DB StatefulSet pod (db-dbdepl-sts-*).
        $estDb = Format-PhaseEstimate 'db-pods'
        $dbPodList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ && `$2 !~ /(dump|backup|fb-|migration|util|mon|pghero)/ && `$4 !~ /(Completed|Succeeded)/ {print `$1, `$2}'"
        $dbPodList = ($dbPodList | Out-String).Trim()
        # Keep only well-formed "namespace podname" lines. An early-boot kubectl
        # race can emit a partial/garbage line (seen in the field as a bare "f"),
        # which previously became the namespace and produced
        # "namespaces \"f\" not found". Require a real battlegroup namespace
        # (funcom-seabass-*) and a non-empty pod name; if none survive, fall
        # through to the no-DB-pods branch.
        $dbPods = @($dbPodList -split "`r?`n" | Where-Object {
            $_p = $_.Trim() -split '\s+', 2
            $_p.Count -eq 2 -and $_p[0] -like 'funcom-seabass-*' -and $_p[1]
        })
        if ($dbPods.Count -gt 0) {
            $dbNs = ($dbPods[0] -split '\s+', 2)[0]
            $podArgs = ($dbPods | ForEach-Object { "pod/$(($_ -split '\s+', 2)[1])" }) -join ' '
            $dbResult = Invoke-WithLiveCounter -Label "Waiting for DB pod(s) Ready..." -EstimateText $estDb `
                -ArgumentList $sshKey,$sshUser,$ip,$dbNs,$podArgs,$script:WaitDbPodsSec `
                -Action {
                    param($sshKey, $sshUser, $ip, $dbNs, $podArgs, $timeoutSec)
                    $output = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                        "sudo k3s kubectl wait --for=condition=Ready $podArgs -n '$dbNs' --timeout=${timeoutSec}s 2>&1"
                    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
                }
            $podCount = $dbPods.Count
            $podLabel = if ($podCount -eq 1) { "1 pod" } else { "$podCount pods" }
            if ($dbResult.Output.ExitCode -eq 0) {
                Save-PhaseTiming 'db-pods' $dbResult.Elapsed
                Complete-WaitCounter -Message "DB ready in $(Format-Duration $dbResult.Elapsed) ($podLabel in $dbNs)."
            } else {
                Complete-WaitCounter -Message "DB wait failed after $(Format-Duration $dbResult.Elapsed) ($podLabel in $dbNs) - proceeding anyway." -Color Yellow
                if ($dbResult.Output.Output) { $dbResult.Output.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
            }
        } else {
            Write-Host "  No DB pods detected by name pattern - skipping (operator readiness will catch DB issues)." -ForegroundColor DarkGray
        }

        # 2c. ALL funcom-operators pods Ready (not just Running)
        $estOp = Format-PhaseEstimate 'operators'
        $opResult = Invoke-WithLiveCounter -Label "Waiting for operator pods Ready..." -EstimateText $estOp `
            -ArgumentList $sshKey,$sshUser,$ip,$script:WaitOperatorsSec `
            -Action {
                param($sshKey, $sshUser, $ip, $timeoutSec)
                $output = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                    "sudo k3s kubectl wait --for=condition=Ready pods --all -n funcom-operators --timeout=${timeoutSec}s 2>&1"
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
            }
        if ($opResult.Output.ExitCode -ne 0) {
            Complete-WaitCounter -Message "Operator pods not Ready after $(Format-Duration $opResult.Elapsed) - starting battlegroup anyway." -Color Yellow
            if ($opResult.Output.Output) { $opResult.Output.Output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        } else {
            Save-PhaseTiming 'operators' $opResult.Elapsed
            Complete-WaitCounter -Message "Operator pods Ready ($(Format-Duration $opResult.Elapsed))."
        }

        # 2d. Webhook Service must have endpoints populated, else API-server proxy returns 502
        $estWh = Format-PhaseEstimate 'webhook-endpoints'
        $t_wh = Get-Date; $epReady = $false
        while (((Get-Date) - $t_wh).TotalSeconds -lt $script:WaitWebhookSec) {
            Write-WaitCounter -Start $t_wh -Label "Waiting for webhook Service endpoints..." -EstimateText $estWh
            $epOut = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl -n funcom-operators get endpoints battlegroupoperator-webhook-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null"
            if ($epOut -match '\d+\.\d+\.\d+\.\d+') { $epReady = $true; break }
            for ($i = 0; $i -lt 3 -and ((Get-Date) - $t_wh).TotalSeconds -lt $script:WaitWebhookSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $t_wh -Label "Waiting for webhook Service endpoints..." -EstimateText $estWh
            }
        }
        $elapsed = [int]((Get-Date) - $t_wh).TotalSeconds
        if (-not $epReady) {
            Complete-WaitCounter -Message "battlegroupoperator-webhook-svc has no endpoints after $(Format-Duration $elapsed) - starting battlegroup anyway (it may need a retry if the operator webhook returns 502)." -Color Yellow
        } else {
            Save-PhaseTiming 'webhook-endpoints' $elapsed
            Complete-WaitCounter -Message "Webhook endpoints populated ($(Format-Duration $elapsed))."
        }
        Write-Host "  Settling 10s before starting battlegroup..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10

        # The VM reboot restarted OpenRC already; refresh the service definition
        # before battlegroup start so first-listener DNAT is readiness-independent.
        Invoke-DuneHyperVGuestRecoveryInstall -Ip $ip -Phase 'pre-reboot-start'
        Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase 'pre-reboot-start'

        # ---- Step 3: start battlegroup ----
        Write-Host ""
        $estBg = Format-PhaseEstimate 'battlegroup-start'
        $bgHint = if ($estBg) { " $estBg" } else { "" }
        Write-Host "[3/3] Starting battlegroup...$bgHint" -ForegroundColor Cyan
        $t_bg = Get-Date
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath start"
        $bgStartExit = $LASTEXITCODE
        Save-PhaseTiming 'battlegroup-start' ([int]((Get-Date) - $t_bg).TotalSeconds)

        # Reset cached director port; it'll be resolved on next 'open-director'
        $directorPort = $null

        $totalSec = [int]((Get-Date) - $t0).TotalSeconds
        Save-PhaseTiming 'total-reboot' $totalSec
        $estTotal = Format-PhaseEstimate 'total-reboot'
        Write-Host ""
        Write-Host "=== Reboot complete in $(Format-Duration $totalSec) ===" -ForegroundColor Green
        if ($estTotal) { Write-Host "  $estTotal" -ForegroundColor DarkGray }
        Write-Host "Pods may take another 1-2 min to all reach Healthy. Check with 'status'." -ForegroundColor DarkGray

        # Probe once immediately after reboot, matching the normal start/restart
        # paths. The conservative heal leaves actively starting maps alone; the
        # VM boot hook and 15-minute cron pass cover slower operator drift.
        if ($bgStartExit -eq 0) {
            Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase 'post-reboot' -Mode cron -Fast
            Invoke-DuneBackupDumpPodPrune -Ip $ip -Phase 'post-reboot'
        } else {
            Write-Host "  Skipped on-demand partition auto-clear because battlegroup start exited $bgStartExit." -ForegroundColor DarkYellow
        }

        # Same memory-pressure surfacing as startup (a reboot ends by starting
        # the battlegroup, so the OOM signature is just as relevant here).
        Show-DuneVmMemoryPressureWarning -Ip $ip
        continue
    }

    if ($cmdName -eq "shutdown") {
        Write-Host ""
        Write-Host "=== Shutdown ===" -ForegroundColor Cyan
        Write-Host "  1. Stop battlegroup (waits for game/mq/gateway/director pods to terminate)" -ForegroundColor DarkGray
        Write-Host "  2. Power off the VM" -ForegroundColor DarkGray
        Write-Host "  Use this when shutting down for the night - player data is persisted to DB." -ForegroundColor DarkGray
        $estTotalShut = Format-PhaseEstimate 'total-shutdown'
        if ($estTotalShut) { Write-Host "  Total shutdown $estTotalShut" -ForegroundColor DarkGray }
        Write-Host ""
        if (-not (Confirm-NoPlayersOnline -ActionLabel "shutdown")) {
            Write-Host "Aborted." -ForegroundColor Cyan; continue
        }
        $t0 = Get-Date

        # ---- Step 1: stop battlegroup ----
        Write-Host ""
        Write-Host "[1/2] Stopping battlegroup..." -ForegroundColor Cyan
        if (-not (Test-DuneBattlegroupHasPods -Ip $ip -SshUser $sshUser -SshKey $sshKey)) {
            Write-Host "  Battlegroup not running (no game/infra pods) - skipping stop." -ForegroundColor DarkGray
        } else {
            ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath stop"
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "battlegroup stop returned exit code $LASTEXITCODE."
                $force = Read-Host "Continue with VM shutdown anyway? (YES to continue)"
                if ($force -ne "YES") { continue }
            }
        }

        # Wait for game/infra pods to terminate so player data is fully persisted to DB.
        $estTerm = Format-PhaseEstimate 'pods-terminate'
        $waitStart = Get-Date
        $maxWaitSec = 360
        $finalCount = $null
        while ($true) {
            $remain = Get-DuneActiveBattlegroupPodCount -Ip $ip -SshUser $sshUser -SshKey $sshKey
            $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
            if ($null -ne $remain -and $remain -eq 0) { $finalCount = 0; break }
            if ($elapsed -gt $maxWaitSec) {
                $finalCount = if ($null -eq $remain) { -1 } else { [int]$remain }
                break
            }
            $remainLabel = if ($null -eq $remain) { 'count unavailable' } else { "$remain remaining" }
            Write-WaitCounter -Start $waitStart -Label "Waiting for pods to terminate ($remainLabel)..." -EstimateText $estTerm
            for ($i = 0; $i -lt 5 -and ((Get-Date) - $waitStart).TotalSeconds -le $maxWaitSec; $i++) {
                Start-Sleep -Seconds 1
                Write-WaitCounter -Start $waitStart -Label "Waiting for pods to terminate ($remainLabel)..." -EstimateText $estTerm
            }
        }
        $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
        if ($finalCount -eq 0) {
            Save-PhaseTiming 'pods-terminate' $elapsed
            Complete-WaitCounter -Message "All game/infra pods terminated after $(Format-Duration $elapsed)."
            Show-DuneFuncomStopWarningNote -Ip $ip -SshUser $sshUser -SshKey $sshKey
        } elseif ($finalCount -lt 0) {
            Complete-WaitCounter -Message "Could not determine whether game/infra pods terminated after $(Format-Duration $elapsed). Proceeding with VM shutdown anyway." -Color Yellow
        } else {
            Complete-WaitCounter -Message "$finalCount pod(s) still present after $(Format-Duration $elapsed). Proceeding with VM shutdown anyway." -Color Yellow
        }

        # ---- Step 2: power off VM ----
        Write-Host ""
        Write-Host "[2/2] Stopping VM '$vmName'..." -ForegroundColor Cyan
        $estVmStop = Format-PhaseEstimate 'vm-stop'
        if ($estVmStop) { Write-Host "  $estVmStop" -ForegroundColor DarkGray }
        try {
            $vmStopSec = Stop-VmWithEscalation -Name $vmName -Label "Stopping VM" -EstimateText $estVmStop
            Save-PhaseTiming 'vm-stop' $vmStopSec
            Complete-WaitCounter -Message "VM stopped in $(Format-Duration $vmStopSec)." -Color Green
        } catch {
            Complete-WaitCounter -Message $_.Exception.Message -Color Red
            Write-Warning "VM may still be in a stuck state - check Hyper-V Manager."
        }

        # Invalidate cached director port + port-check results (no longer meaningful)
        $directorPort = $null
        $script:portCheckCache = $null

        $totalSec = [int]((Get-Date) - $t0).TotalSeconds
        Save-PhaseTiming 'total-shutdown' $totalSec
        $estTotalDone = Format-PhaseEstimate 'total-shutdown'
        Write-Host ""
        Write-Host "=== Shutdown complete in $(Format-Duration $totalSec) ===" -ForegroundColor Green
        if ($estTotalDone) { Write-Host "  $estTotalDone" -ForegroundColor DarkGray }
        Write-Host "Use option 'd. startup' when you're ready to bring it back up." -ForegroundColor DarkGray
        continue
    }

    if ($cmdName -eq "rotate-ssh-key") {
        $vmUtilsPath = "$bgSetupPath\vm-utilities.ps1"
        if (Test-Path -LiteralPath $vmUtilsPath) {
            . $vmUtilsPath
            Update-SshKey -Ip $ip | Out-Null
        } else {
            # LAN mode or missing local Funcom install — generate + authorize
            # without Funcom's vm-utilities.ps1. Mirrors the bootstrap logic in
            # HyperVLanInstall.ps1 Initialize-DuneLanGuest.
            $keyPath = $sshKey
            if (-not $keyPath) { $keyPath = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey' }
            # Guard: if $keyPath is a directory (e.g. config stored the parent
            # folder instead of the file), append the expected filename.
            if ((Test-Path -LiteralPath $keyPath) -and (Get-Item -LiteralPath $keyPath).PSIsContainer) {
                $keyPath = Join-Path $keyPath 'sshKey'
            }
            $keyDir = Split-Path -Parent $keyPath
            if ($keyDir -and -not (Test-Path $keyDir)) { New-Item -ItemType Directory -Force -Path $keyDir | Out-Null }
            if ((Test-Path -LiteralPath $keyPath) -and -not (Get-Item -LiteralPath $keyPath).PSIsContainer) {
                Remove-Item -LiteralPath $keyPath -Force
            }
            if (Test-Path -LiteralPath "$keyPath.pub") { Remove-Item -LiteralPath "$keyPath.pub" -Force }
            Write-Host "  Generating new SSH key at $keyPath ..." -ForegroundColor Yellow
            & ssh-keygen -t ed25519 -f $keyPath -N '""' -q -C "dst@$($env:COMPUTERNAME)" 2>&1 | Out-Null
            if (-not (Test-Path -LiteralPath $keyPath)) {
                Write-Host "  FATAL: Could not generate SSH key." -ForegroundColor Red
                Write-Host ""; continue
            }
            Write-Host "  Key generated." -ForegroundColor Green
            # Base64-encode the public key to avoid shell-quoting issues with
            # the key content (spaces, +, = chars) — same approach as
            # Initialize-DuneLanGuest.
            $pub = (Get-Content -Raw -LiteralPath "$keyPath.pub").Trim()
            $b64Pub = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$pub`n"))
            Write-Host ""
            Write-Host "  Authorizing on $sshUser@$ip ..." -ForegroundColor Yellow
            Write-Host "  Enter the '$sshUser' password when prompted:" -ForegroundColor Cyan
            & ssh -o StrictHostKeyChecking=no "$sshUser@$ip" "mkdir -p `$HOME/.ssh && chmod 700 `$HOME/.ssh && echo $b64Pub | base64 -d >> `$HOME/.ssh/authorized_keys && chmod 600 `$HOME/.ssh/authorized_keys"
        }

        # --- Guard: confirm the freshly-rotated key actually authenticates -----
        # Update-SshKey regenerates the local key, then authorizes it on the VM
        # by SSHing in with the dune *password*. If that password prompt is
        # closed or cancelled, the local key is replaced but its public half
        # never reaches dune@VM:~/.ssh/authorized_keys — leaving DST locked out
        # of every key-based operation (status, commands, diagnostics all fail
        # with "Permission denied (publickey)"). Verify non-interactively and,
        # if it failed, tell the user exactly how to recover instead of silently
        # stranding them.
        $verifyKey = Resolve-FreshSshKey -ConfiguredPath $sshKey
        if (-not $verifyKey) { $verifyKey = $sshKey }
        $rotateProbe = ''
        if ($verifyKey -and (Test-Path -LiteralPath $verifyKey)) {
            $rotateProbe = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o LogLevel=QUIET -i "$verifyKey" "$sshUser@$ip" "echo dune-ok" 2>&1
        }
        if ($rotateProbe -match 'dune-ok') {
            Write-Host ""
            Write-Host "  Verified: the new SSH key authenticates to $sshUser@$ip." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  WARNING: the new SSH key is NOT authorized on the VM yet." -ForegroundColor Red
            Write-Host "  The key was regenerated locally, but its public half never reached" -ForegroundColor Yellow
            Write-Host "  ${sshUser}@${ip}:~/.ssh/authorized_keys - usually because the dune" -ForegroundColor Yellow
            Write-Host "  password prompt above was closed or cancelled. DST cannot manage the" -ForegroundColor Yellow
            Write-Host "  server (status, commands, diagnostics) until this is fixed." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Recover by running this and entering the '$sshUser' password when asked:" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    Get-Content `"$verifyKey.pub`" | ssh $sshUser@$ip `"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`"" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  ...or simply run 'rotate-ssh-key' again and be sure to type the dune" -ForegroundColor DarkGray
            Write-Host "  password when the console asks for it." -ForegroundColor DarkGray
        }

        continue
    }

    if ($cmdName -eq "change-password") {
        $pw1Sec = Read-Host "Enter new password for 'dune'" -AsSecureString
        $pw2Sec = Read-Host "Confirm new password" -AsSecureString
        $pw1 = [System.Net.NetworkCredential]::new('', $pw1Sec).Password
        $pw2 = [System.Net.NetworkCredential]::new('', $pw2Sec).Password
        if ([string]::IsNullOrEmpty($pw1)) { Write-Warning "Password cannot be empty"; continue }
        if ($pw1 -ne $pw2) { Write-Warning "Passwords do not match"; continue }

        $vmUtilsPath = "$bgSetupPath\vm-utilities.ps1"
        if (Test-Path -LiteralPath $vmUtilsPath) {
            . $vmUtilsPath
            if (Set-VmPassword -Ip $ip -NewPassword $pw1Sec) { Write-Host "Password changed successfully" -ForegroundColor Green }
        } else {
            # LAN mode — change password over SSH with the existing key
            $keyPath = Resolve-FreshSshKey -ConfiguredPath $sshKey
            if (-not $keyPath) { $keyPath = $sshKey }
            if (-not $keyPath -or -not (Test-Path -LiteralPath $keyPath)) {
                Write-Host "  Cannot change password: no SSH key available. Generate or locate a key first." -ForegroundColor Red
                continue
            }
            $payload = "${sshUser}:${pw1}`n"
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
            $out = & ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o IdentitiesOnly=yes -i "$keyPath" "$sshUser@$ip" "echo $b64 | base64 -d | sudo -n chpasswd" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Password changed successfully" -ForegroundColor Green
            } else {
                Write-Host "  Failed to change password: $($out | Out-String)" -ForegroundColor Red
            }
        }
        continue
    }

    if ($cmdName -eq "change-vm-ip") {
        $vmIpScript = Join-Path $bgSetupPath 'vm-ip.ps1'
        if (-not (Test-Path -LiteralPath $vmIpScript)) {
            Write-Warning "vm-ip.ps1 not found at $vmIpScript - your self-hosted server install may be too old to change the VM IP from here."
            continue
        }
        . $vmIpScript
        if (Set-VmIp -Ip $ip -SshKey $sshKey) {
            Write-Host "VM IP configuration updated." -ForegroundColor Green
            Write-Host "  The VM may take a few seconds to reappear on its new address; DST will pick it up on the next status refresh." -ForegroundColor DarkGray
        }
        continue
    }

    # ========================================================
    #  BATTLEGROUP COMMANDS
    # ========================================================

    if ($cmdName -eq "open-file-browser") {
        Start-Process "http://${ip}:18888/"
        continue
    }

    if ($cmdName -eq "open-director") {
        if (-not $directorPort) {
            $directorNodePort = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>&1"
            if ($directorNodePort -match '^\d+$') { $directorPort = $directorNodePort.Trim() }
        }
        if (-not $directorPort) { Write-Warning "Could not determine Director port."; continue }
        Start-Process "http://${ip}:${directorPort}/"
        continue
    }

    if ($cmdName -eq "shell-vm") {
        Write-Host "Opening shell in the VM. Type 'exit' to return." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip"
        continue
    }

    if ($cmdName -eq "shell-pod") {
        $bgPrefix = "funcom-seabass-"
        $nsList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | grep '^$bgPrefix'"
        $namespaces = @($nsList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($namespaces.Count -eq 0) { Write-Warning "No battlegroup found."; continue }
        if ($namespaces.Count -eq 1) { $ns = $namespaces[0] }
        else {
            Write-Host ""
            for ($i = 0; $i -lt $namespaces.Count; $i++) { Write-Host ("  {0,2}. {1}" -f ($i + 1), ($namespaces[$i] -replace "^$bgPrefix",'')) }
            $ns = $null
            while ($null -eq $ns) {
                $sel = Read-Host "Select battlegroup (1-$($namespaces.Count))"
                if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $namespaces.Count) { $ns = $namespaces[[int]$sel - 1] }
                else { Write-Warning "Invalid selection." }
            }
        }
        $podList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "sudo kubectl get pods -n '$ns' --no-headers -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.role"
        $pods = @($podList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
            $parts = $_ -split '\s+', 2
            [pscustomobject]@{
                Name    = $parts[0]
                Role    = if ($parts.Count -gt 1 -and $parts[1] -ne '<none>') { $parts[1] } else { '' }
                Display = $parts[0] -replace "^$($ns -replace '^funcom-seabass-','')-",''
            }
        })
        if ($pods.Count -eq 0) { Write-Warning "No pods found."; continue }
        Write-Host ""; Write-Host "Pods in ${ns}:"
        $maxLen = ($pods | ForEach-Object { $_.Display.Length } | Measure-Object -Maximum).Maximum
        for ($i = 0; $i -lt $pods.Count; $i++) { Write-Host ("  {0,2}. {1,-$maxLen}  {2}" -f ($i + 1), $pods[$i].Display, $pods[$i].Role) }
        $pod = $null
        while ($null -eq $pod) {
            $sel = Read-Host "Select pod (1-$($pods.Count))"
            if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $pods.Count) { $pod = $pods[[int]$sel - 1].Name }
            else { Write-Warning "Invalid selection." }
        }
        Write-Host "Opening shell in $pod. Type 'exit' to return." -ForegroundColor Cyan
        $shellCmd = 'sudo kubectl exec -it ''{0}'' -n ''{1}'' -- /bin/bash || sudo kubectl exec -it ''{0}'' -n ''{1}'' -- /bin/sh' -f $pod, $ns
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" $shellCmd
        continue
    }

    if ($cmdName -eq "edit-advanced") {
        Write-Host ""
        Write-Host "WARNING:" -ForegroundColor Red -NoNewline
        Write-Host " You are about to edit the live battlegroup YAML directly in Kubernetes." -ForegroundColor Yellow
        Write-Host "         Mistakes can permanently break the battlegroup." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type YES to continue"
        if ($confirm -ne "YES") { Write-Host "Aborted." -ForegroundColor Cyan; continue }
    }

    # Before invoking any vim-driven editor, ensure the VM's ~/.vimrc has
    # `set mouse=a` so the scroll wheel actually moves the cursor through
    # the buffer (instead of vim silently eating wheel events while still
    # capturing them away from the host console's scrollback). Idempotent:
    # only appends if the directive isn't already present.
    if ($cmdName -eq "edit" -or $cmdName -eq "edit-advanced") {
        $vimrcEnsure = "grep -qs '^set mouse=a' ~/.vimrc || echo 'set mouse=a' >> ~/.vimrc"
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" $vimrcEnsure 2>$null | Out-Null
    }

    if ($cmdName -eq "logs-export") {
        ssh -t -o StrictHostKeyChecking=no -i "$sshKey" "$sshUser@$ip" "$bgBinPath logs-export"
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $localDir = Join-Path $env:USERPROFILE "Documents\BattlegroupLogs\Battlegroup_$timestamp"
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
        Write-Host "Downloading log files..." -ForegroundColor Cyan
        $tarPath = Join-Path $env:TEMP "dune-bg-logs.tar.gz"
        $proc = Start-Process -FilePath "ssh" -ArgumentList @("-o","StrictHostKeyChecking=no","-o","LogLevel=QUIET","-i","`"$sshKey`"","$sshUser@$ip","tar -czf - -C /tmp/dune-bg-logs .") -RedirectStandardOutput $tarPath -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Write-Host "Error: Failed to download log files." -ForegroundColor Red; Remove-Item $tarPath -ErrorAction SilentlyContinue; continue }
        tar -xzf $tarPath -C $localDir; Remove-Item $tarPath
        Write-Host "Logs saved to: $localDir" -ForegroundColor Green
        continue
    }

    if ($cmdName -eq "operator-logs-export") {
        ssh -t -o StrictHostKeyChecking=no -i "$sshKey" "$sshUser@$ip" "$bgBinPath operator-logs-export"
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $localDir = Join-Path $env:USERPROFILE "Documents\OperatorLogs\Operators_$timestamp"
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null
        Write-Host "Downloading operator log files..." -ForegroundColor Cyan
        $tarPath = Join-Path $env:TEMP "dune-operator-logs.tar.gz"
        $proc = Start-Process -FilePath "ssh" -ArgumentList @("-o","StrictHostKeyChecking=no","-o","LogLevel=QUIET","-i","`"$sshKey`"","$sshUser@$ip","tar -czf - -C /tmp/dune-operator-logs .") -RedirectStandardOutput $tarPath -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Write-Host "Error: Failed to download operator log files." -ForegroundColor Red; Remove-Item $tarPath -ErrorAction SilentlyContinue; continue }
        tar -xzf $tarPath -C $localDir; Remove-Item $tarPath
        Write-Host "Operator logs saved to: $localDir" -ForegroundColor Green
        continue
    }

    # ========================================================
    #  TOOLS COMMANDS
    # ========================================================

    if ($cmdName -eq "ssh") {
        Write-Host "Connecting to VM via SSH... Type 'exit' to return." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip"
        continue
    }

    if ($cmdName -eq "setup-guide") {
        Start-Process "https://duneawakening.com/self-hosted-servers/"
        continue
    }

    if ($cmdName -eq "fix-on-demand-maps") {
        # Manual on-demand-map repair — also (re)installs the boot script + cron
        # if missing, then runs the partition-clear script with no settling
        # delay (operator has already had whatever time it needed by the time
        # the user invokes this).
        Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase 'fix-on-demand-maps' -Mode manual
        continue
    }

    # --- Fallback: delegate to battlegroup CLI on VM ---

    # SteamCMD orphan-workdir pre-flight (only for `update`).
    # Any interrupted `battlegroup update` (network blip, killed shell, VM
    # reboot mid-download) leaves a root-owned empty
    # /home/dune/.dune/download/steamapps/downloading/$SteamCmdAppId directory
    # (plus workdir under .../temp/) that SteamCMD refuses to overwrite,
    # producing `Error! App '<id>' state is 0x206 after update job.` and
    # `Steam download failed. Auto-retrying once` on every subsequent attempt.
    # Funcom's script doesn't clean these up. Wipe them before invoking
    # `battlegroup update` so the fetch always starts from a clean slate.
    # Confirmed cause of failed updates on gd.py (2026-07-04) and Coastal's
    # UAT (2026-07-05); manual `rm -rf` clears it in both cases.
    if ($cmdName -eq 'update') {
        $SteamCmdAppId = '4754530'  # Dune: Awakening Dedicated Server
        $preflight = @"
if [ -d /home/dune/.dune/download/steamapps/downloading/$SteamCmdAppId ] || [ -d /home/dune/.dune/download/steamapps/temp ]; then
  echo '[dst] Cleaning SteamCMD orphan workdir before update (prevents state=0x206)...'
  rm -rf /home/dune/.dune/download/steamapps/downloading/$SteamCmdAppId /home/dune/.dune/download/steamapps/temp
fi
"@
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" $preflight
    }

    if ($cmdName -eq 'start' -or $cmdName -eq 'restart') {
        # Refresh monitoring before issuing start/restart, not after readiness.
        Invoke-DuneHyperVGuestRecoveryInstall -Ip $ip -Phase "pre-$cmdName"
        Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase "pre-$cmdName"
    }

    ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath $cmdName"
    $bgFallbackExit = $LASTEXITCODE

    # Battlegroup commands (status/start/restart/stop) can change observable
    # port state, so invalidate the cached external port-check results to
    # force a fresh check on the next menu render.
    $script:portCheckCache = $null

    # After a successful bg start / restart, auto-clear the on-demand-map
    # partition pins so DD/Arrakeen/Harko spawn for the next player without
    # the user having to invoke fix-on-demand-maps manually.
    if ($bgFallbackExit -eq 0 -and ($cmdName -eq 'start' -or $cmdName -eq 'restart')) {
        # Run in fast mode: no fixed settle delay and only one remote wait pass.
        # The persistent VM watchdog / manual Fix Partitions command covers
        # slower post-reconcile drift without making every start feel hung.
        Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase "post-$cmdName" -Mode cron -Fast
    }

    # One-shot web/CLI commands are complete once the battlegroup command and
    # fast partition cleanup return. The web dashboard resolves links itself, so
    # do not hold this detached console for up to 60 more seconds discovering a
    # Director port it will never use.
    if ($Cmd) { break }

    # Interactive menu only: resolve Director port for the next menu render.
    if ($cmdName -eq "start" -or $cmdName -eq "restart") {
        $elapsed = 0; $timeout = 60
        while (-not $directorPort -and $elapsed -lt $timeout) {
            $directorNodePort = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>&1"
            if ($directorNodePort -match '^\d+$') { $directorPort = $directorNodePort.Trim() }
            else { Start-Sleep -Seconds 5; $elapsed += 5 }
        }
        if (-not $directorPort) { Write-Warning "Could not determine Director port after $timeout seconds." }
    }

}

Stop-Transcript | Out-Null
Invoke-DunePauseBeforeClose
