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

$script:ToolVersion = "12.18.11"

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
function Get-VmInfo {
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    $exists  = [bool]$vm
    $state   = if ($exists) { $vm.State } else { 'Missing' }
    $running = $exists -and $vm.State -eq 'Running'
    $ip      = $null
    if ($running) {
        $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
              Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
              Select-Object -First 1
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
    $jobs += Start-Job -ScriptBlock {
        param($n) Stop-VM -Name $n -Force -ErrorAction SilentlyContinue
    } -ArgumentList $Name
    $escalated = $false
    try {
        while ($true) {
            $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
            if (-not $vm -or $vm.State -eq 'Off') { break }
            $elapsed = [int]((Get-Date) - $start).TotalSeconds
            if (-not $escalated -and $elapsed -ge $GracefulSec) {
                Complete-WaitCounter -Message "Graceful shutdown still running after $(Format-Duration $elapsed) (state: $($vm.State)) - escalating to hard power-off." -Color Yellow
                $jobs += Start-Job -ScriptBlock {
                    param($n) Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue
                } -ArgumentList $Name
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

# Returns $true if any battlegroup pod (sg/mq/sgw/tr/bgd) is currently
# present on the VM. Used to short-circuit `battlegroup stop` calls when
# nothing is running -- otherwise the VM-side helper script runs its own
# 90-second polling loop even when the namespace is already empty.
function Test-DuneBattlegroupHasPods {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $SshUser,
        [Parameter(Mandatory)] [string] $SshKey
    )
    $raw = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$SshKey" "$SshUser@$Ip" `
        "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E '(-sg-|-mq-|-sgw-|-tr-|-bgd-)' | wc -l"
    $n = ($raw -replace '\D','')
    if (-not $n) { return $false }
    return ([int]$n -gt 0)
}

function Wait-MapPodReady {
    param(
        [Parameter(Mandatory)] [string] $Ip,
        [Parameter(Mandatory)] [string] $MapName,
        [int] $TimeoutSec = 300
    )
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
                return @{ Success = $true; Elapsed = $elapsed; Pod = $podName; Ready = $ready }
            }
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    return @{ Success = $false; Elapsed = $elapsed; Pod = $lastPod; LastStatus = $lastStatus }
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

function Show-DuneVmMemoryPressureWarning {
    # Run the read-only VM memory-pressure probe over SSH and print a red
    # warning if the node is thrashing for memory: Funcom operators OOM-killed
    # (exit 137 / OOMKilled, high restart counts), Postgres evicted, or a tiny
    # MemAvailable with Swap: 0. This is the root cause of the "battlegroup
    # restarted outside its schedule" / "ping surge under load" reports and is
    # otherwise invisible without hand-reading exported logs.
    #
    # Uses the SAME bundled probe the web backend uses
    # (app/server/lib/VmMemoryPressure.ps1 + dune-mem-pressure-probe.sh) so the
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
        $lines = @($out)

        # --- lightweight parse (mirrors ConvertFrom-DuneMemPressureProbe) -----
        $memTotalK = $null; $memAvailK = $null; $swapTotalK = $null
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($line in $lines) {
            $t = ([string]$line).Trim()
            if (-not $t) { continue }
            if ($t -like 'mem_total_k=*')  { $memTotalK  = [long]($t.Substring(12)); continue }
            if ($t -like 'mem_avail_k=*')  { $memAvailK  = [long]($t.Substring(12)); continue }
            if ($t -like 'swap_total_k=*') { $swapTotalK = [long]($t.Substring(13)); continue }
            if ($t -like 'op=*' -or $t -like 'db=*') {
                $kind = $t.Substring(0, 2)
                $rec  = $t.Substring(3)
                $parts = $rec -split '~'
                $name = $parts[0]
                $restarts = 0; $exits = @(); $reasons = @(); $podReason = ''
                foreach ($seg in ($parts | Select-Object -Skip 1)) {
                    $c = $seg.IndexOf(':'); if ($c -lt 1) { continue }
                    $tag = $seg.Substring(0, $c); $val = $seg.Substring($c + 1)
                    switch ($tag) {
                        'PR' { $podReason = $val.Trim() }
                        'R'  { $nums = @($val -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }); if ($nums.Count) { $restarts = ($nums | Measure-Object -Maximum).Maximum } }
                        'E'  { $exits   = @($val -split '\s+' | Where-Object { $_ -ne '' }) }
                        'X'  { $reasons = @($val -split '\s+' | Where-Object { $_ -ne '' }) }
                    }
                }
                $oom = ($exits -contains '137') -or ($reasons -contains 'OOMKilled') -or ($podReason -match '(?i)Evicted|OOMKilled')
                $short = $name -replace '^sh-[a-z0-9]+-[a-z0-9]+-', ''
                $records.Add([pscustomobject]@{ kind=$kind; name=$short; restarts=$restarts; oom=$oom })
            }
        }

        $lowMem = $false; $swapZero = ($null -ne $swapTotalK -and $swapTotalK -eq 0)
        $availPct = $null
        if ($null -ne $memTotalK -and $memTotalK -gt 0 -and $null -ne $memAvailK) {
            $availPct = [math]::Round(($memAvailK * 100.0 / $memTotalK), 1)
            $lowMem = ($memAvailK -lt 1048576 -or $availPct -lt 8)
        }
        $oomPods = @($records | Where-Object { $_.oom })
        $churn   = @($records | Where-Object { -not $_.oom -and $_.restarts -gt 5 })
        $memPressure = ($oomPods.Count -gt 0) -or ($lowMem -and $swapZero) -or ($churn.Count -gt 0)
        if (-not $memPressure) { return }

        function _fmtKiB($k) {
            if ($null -eq $k) { return '?' }
            $u = @('KiB','MiB','GiB','TiB'); $v = [double]$k; $i = 0
            while ($v -ge 1024 -and $i -lt 3) { $v /= 1024; $i++ }
            if ($i -eq 0) { return ('{0:0} {1}' -f $v, $u[$i]) }
            return ('{0:0.0} {1}' -f $v, $u[$i])
        }

        $maxRestarts = 0
        if ($records.Count -gt 0) { $maxRestarts = ($records | Measure-Object -Property restarts -Maximum).Maximum }
        $headline = if ($oomPods.Count -gt 0 -and $maxRestarts -gt 0) {
            "VM low on memory - Funcom operators killed ${maxRestarts}x; consider raising the VM's RAM"
        } elseif ($lowMem -and $swapZero) {
            "VM low on memory (Swap: 0) - consider raising the VM's RAM or lowering per-map memory limits"
        } else {
            "Possible VM memory pressure - operators/DB have elevated restarts"
        }

        Write-Host ""
        Write-Host "  WARNING: $headline" -ForegroundColor Red
        if ($lowMem) {
            Write-Host ("    MemAvailable {0} ({1}%) with Swap: {2}." -f (_fmtKiB $memAvailK), $availPct, $(if ($swapZero) { '0 (no cushion)' } else { (_fmtKiB $swapTotalK) })) -ForegroundColor Yellow
        }
        foreach ($p in $oomPods) {
            $label = if ($p.kind -eq 'db') { 'database' } else { 'operator' }
            Write-Host ("    {0} '{1}' OOM-killed x{2} (exit 137 / OOMKilled)." -f $label, $p.name, $p.restarts) -ForegroundColor Yellow
        }
        foreach ($p in $churn) {
            Write-Host ("    pod '{0}' restarted x{1} (elevated)." -f $p.name, $p.restarts) -ForegroundColor Yellow
        }
        Write-Host "    Fix: raise the VM's RAM in Hyper-V, or lower per-map memory limits. Full detail: Help > Create GitHub Issue + Save Logs (vm-memory-pressure.txt)." -ForegroundColor DarkGray
    } catch {
        # Best-effort only - a probe hiccup must never fail a good start.
    }
}

function Invoke-DuneRemotePartitionScript {
    # Stages the bundled dune-clear-partitions.start to /tmp on the VM via an
    # ssh exec + base64 stream (no scp/sftp dependency), runs it once with sudo,
    # removes the staged copy. No persistent install, no boot script, no cron.
    # Returns @{ ok; rc; output }. Best-effort - never throws.
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$WaitAttempts = 60
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
                    "sudo -n DUNE_CLEAR_ATTEMPTS=$WaitAttempts sh $remoteTmp; rc=`$?; rm -f $remoteTmp; exit `$rc" 2>&1
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
    $result = Invoke-DuneRemotePartitionScript -Ip $Ip -WaitAttempts $waitAttempts
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

function Invoke-DuneDnatWatchdogInstall {
    # Best-effort: stage the bundled DNAT self-heal watchdog installer to /tmp on
    # the VM (base64 over an ssh exec channel — no scp/sftp dependency), run it
    # once with sudo, remove it. The installer writes /usr/local/bin/dune-dnat-watch.sh
    # plus a 1-minute root cron entry so the RabbitMQ (public:31982 -> mq-game pod)
    # DNAT rule AND the game-UDP bridge (VM-LAN-IP:7777-7810 -> public IP) self-heal
    # after a pod-only battlegroup restart -- which the boot script
    # /etc/local.d/dune-iptables.start misses because it only re-derives at boot.
    # Without this, a pod restart leaves the RabbitMQ rule pointing at a dead pod IP
    # (players hang on "Connecting") or drops the game bridge (remote players P34)
    # until the next reboot (observed 2026-06-23). The game bridge is BIND-DETECTED:
    # the watchdog installs it only when the game binds the public IP and NOT the
    # LAN IP/wildcard, and removes it otherwise, so it never black-holes a same-LAN
    # / self join the way the unconditional rule removed in v12.16.9 did.
    #
    # ALL persistence (the watchdog file + cron line) lives in the staged POSIX-sh
    # script, never in this app — so the packaged installer carries no
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
        Write-Host "  [$Phase] DNAT self-heal watchdog installed/refreshed — RabbitMQ login + game-UDP bridge auto-recover after pod restarts." -ForegroundColor DarkGray
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
$toolCommands += [pscustomobject]@{ Key = "19"; Name = "report-issue";   Desc = "Report a bug in this tool (opens prefilled GitHub issue in browser)" }

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
        Start-VM -Name $vmName | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Running')
        Write-Host "VM started." -ForegroundColor Green

        $ip = $null; $timeout = 120; $elapsed = 0; $dots = 0
        while (-not $ip -and $elapsed -lt $timeout) {
            $dots = ($dots % 3) + 1
            Write-Host -NoNewline "`rWaiting for VM to acquire an IP address$('.' * $dots)   "
            Start-Sleep -Seconds 1; $elapsed += 1
            $ip = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                  Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        }
        Write-Host ""
        if (-not $ip) { Write-Warning "Could not determine VM IP after $timeout seconds." }
        else          { Write-Host "VM ready at $ip." -ForegroundColor Green }
        continue
    }

    if ($cmdName -eq "stop-vm") {
        $vmNow = Get-VM -Name $vmName -ErrorAction SilentlyContinue
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

        # ---- Step 1: VM ----
        Write-Host ""
        if ($info.Running) {
            Write-Host "[1/4] VM '$vmName' already running ($($info.Ip))." -ForegroundColor Green
            $ip = $info.Ip
        } else {
            Write-Host "[1/4] Starting VM '$vmName'..." -ForegroundColor Cyan
            $estVm = Format-PhaseEstimate 'vm-start'
            if ($estVm) { Write-Host "  $estVm" -ForegroundColor DarkGray }
            $t_vm = Get-Date
            Start-VM -Name $vmName | Out-Null
            do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Running')
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
                $newIp = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                          Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
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
        Write-Host "[4/4] Waiting for map pods to be Ready..." -ForegroundColor Cyan
        $mapResults = @{}
        foreach ($map in 'overmap','survival') {
            $estMap = Format-PhaseEstimate "map-$map"
            $mapHint = if ($estMap) { " $estMap" } else { "" }
            Write-Host "  Waiting for $map pod (timeout 300s)...$mapHint" -ForegroundColor DarkGray
            $r = Wait-MapPodReady -Ip $ip -MapName $map -TimeoutSec 300
            $mapResults[$map] = $r
            if ($r.Success) {
                Save-PhaseTiming "map-$map" ([int]$r.Elapsed)
                Write-Host "  $map -> $($r.Pod) is Ready ($($r.Ready)) in $(Format-Duration $r.Elapsed)" -ForegroundColor Green
            } else {
                if ($r.Pod) {
                    Write-Warning "  $map ($($r.Pod)) did not become Ready within $(Format-Duration $r.Elapsed) (last seen: $($r.LastStatus))"
                } else {
                    Write-Warning "  $map pod was never found within $(Format-Duration $r.Elapsed)"
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
            Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase 'post-startup' -Fast
            Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase 'post-startup'
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
        Start-VM -Name $vmName | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Running')
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
            $newIp = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                      Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
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

        # Auto-clear on-demand partitions so DD/Arrakeen/Harko spawn on demand
        # post-reboot. 45s settling delay because (unlike startup) we did not
        # already wait on overmap/survival Ready — the server-operator may
        # still be reconciling on-demand ServerSets.
        if ($bgStartExit -eq 0) {
            Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 45 -Phase 'post-reboot'
            Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase 'post-reboot'
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
            $remainRaw = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E '(-sg-|-mq-|-sgw-|-tr-|-bgd-)' | wc -l"
            $remain = ($remainRaw -replace '\D','')
            if (-not $remain) { $remain = '0' }
            $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
            if ($remain -eq '0') { $finalCount = 0; break }
            if ($elapsed -gt $maxWaitSec) { $finalCount = [int]$remain; break }
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
        . "$bgSetupPath\vm-utilities.ps1"
        Update-SshKey -Ip $ip | Out-Null

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
        . "$bgSetupPath\vm-utilities.ps1"
        $pw1Sec = Read-Host "Enter new password for 'dune'" -AsSecureString
        $pw2Sec = Read-Host "Confirm new password" -AsSecureString
        $pw1 = [System.Net.NetworkCredential]::new('', $pw1Sec).Password
        $pw2 = [System.Net.NetworkCredential]::new('', $pw2Sec).Password
        if ([string]::IsNullOrEmpty($pw1)) { Write-Warning "Password cannot be empty"; continue }
        if ($pw1 -ne $pw2) { Write-Warning "Passwords do not match"; continue }
        if (Set-VmPassword -Ip $ip -NewPassword $pw1Sec) { Write-Host "Password changed successfully" -ForegroundColor Green }
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

    if ($cmdName -eq "report-issue") {
        Write-Host ""
        Write-Host "=== Report an Issue ===" -ForegroundColor Cyan
        Write-Host "  Opening a prefilled bug report in your browser." -ForegroundColor DarkGray
        Write-Host "  This tracker is for bugs in the TOOL ITSELF (the app/CLI)," -ForegroundColor Yellow
        Write-Host "  including the diagnostics it shows you (Dashboard battlegroup" -ForegroundColor Yellow
        Write-Host "  status, Setup 'SSH key' checks, Server Health). If you see one" -ForegroundColor Yellow
        Write-Host "  of those messages, copy it into the report." -ForegroundColor Yellow
        Write-Host "  Not for raw router/port-forwarding or Funcom game-server issues -" -ForegroundColor Yellow
        Write-Host "  for those, ping @allcoast on Discord." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  TIP: For the easiest bug report, launch the desktop app and" -ForegroundColor Cyan
        Write-Host "       click Help -> Create GitHub Issue + Save Logs. That" -ForegroundColor Cyan
        Write-Host "       saves a redacted dst-diagnostics-<ts>.zip on your Desktop" -ForegroundColor Cyan
        Write-Host "       you can drag straight into the issue comment." -ForegroundColor Cyan
        Write-Host ""

        # GitHub issue forms accept URL params keyed by the input id in the
        # YAML form. Prefill what we already know so the user only fills in
        # what they hit. Values must be URL-encoded.
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        function Get-EncodedParam([string]$v) {
            if ([string]::IsNullOrEmpty($v)) { return "" }
            return [System.Web.HttpUtility]::UrlEncode($v)
        }
        $envStr = "Windows $([System.Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)"

        # WebView2 runtime version (registry probe — same one the app uses).
        $wv2Version = '(not installed / not detected)'
        foreach ($p in @(
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
            'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
            'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
        )) {
            try {
                $v = (Get-ItemProperty -Path $p -Name 'pv' -ErrorAction Stop).pv
                if ($v -and $v -ne '0.0.0.0') { $wv2Version = $v; break }
            } catch {}
        }

        # Build the auto-collected diagnostics block.
        $diagLines = New-Object System.Collections.Generic.List[string]
        $diagLines.Add("Tool version       : v$script:ToolVersion")
        $diagLines.Add("Entry point        : $($MyInvocation.MyCommand.Path)")
        $diagLines.Add("PowerShell         : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
        $diagLines.Add("OS                 : Windows $([System.Environment]::OSVersion.Version)")
        $diagLines.Add("WebView2 runtime   : $wv2Version")
        $diagLines.Add("UserDataFolder     : $(Join-Path $env:LOCALAPPDATA 'DuneServer\webview2')")
        $diagLines.Add("Config dir         : $(Join-Path $env:APPDATA 'DuneServer')")
        $diagLines.Add("")

        # WebView2 debug log written by the desktop app. The desktop app writes
        # it to %APPDATA%\DuneServer\webview2-debug.log; we tail the last ~3KB
        # so the URL stays under GitHub's practical issue-create length limit.
        $wv2Log = Join-Path $env:APPDATA 'DuneServer\webview2-debug.log'
        if (Test-Path $wv2Log) {
            $diagLines.Add("=== WebView2 debug log (tail) ===")
            $diagLines.Add("Path: $wv2Log")
            try {
                $content = [System.IO.File]::ReadAllText($wv2Log)
                $maxBytes = 3072
                if ($content.Length -gt $maxBytes) {
                    $content = "...(truncated, showing last $maxBytes chars of $($content.Length))...`r`n" +
                               $content.Substring($content.Length - $maxBytes)
                }
                $diagLines.Add($content)
            } catch {
                $diagLines.Add("(could not read log: $($_.Exception.Message))")
            }
        } else {
            $diagLines.Add("(no WebView2 debug log present at $wv2Log — desktop app may not have been launched on this machine yet)")
        }

        $diagText = ($diagLines -join "`r`n")

        $params = @(
            "template=bug_report.yml"
            "tool_version=" + (Get-EncodedParam "v$script:ToolVersion")
            "env="          + (Get-EncodedParam $envStr)
            "diagnostics="  + (Get-EncodedParam $diagText)
        ) -join "&"
        $url = "https://github.com/coastal-ms/DST-DuneServerTool/issues/new?$params"

        # GitHub returns 414 if the URL is too long. Trim diagnostics and
        # retry if needed (very unlikely with our 3KB cap, but defensive).
        if ($url.Length -gt 7500) {
            $diagText = ($diagLines | Select-Object -First 10) -join "`r`n"
            $diagText += "`r`n`r`n(diagnostics truncated for URL length — see %APPDATA%\DuneServer\webview2-debug.log for full log)"
            $params = @(
                "template=bug_report.yml"
                "tool_version=" + (Get-EncodedParam "v$script:ToolVersion")
                "env="          + (Get-EncodedParam $envStr)
                "diagnostics="  + (Get-EncodedParam $diagText)
            ) -join "&"
            $url = "https://github.com/coastal-ms/DST-DuneServerTool/issues/new?$params"
        }

        Write-Host "  Pre-filled: tool_version, env, diagnostics ($(($diagText -split "`r?`n").Count) lines)" -ForegroundColor DarkGray
        Write-Host "  $url" -ForegroundColor DarkGray
        Start-Process $url
        continue
    }

    if ($cmdName -eq "fix-on-demand-maps") {
        # Manual on-demand-map repair — also (re)installs the boot script + cron
        # if missing, then runs the partition-clear script with no settling
        # delay (operator has already had whatever time it needed by the time
        # the user invokes this).
        Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase 'fix-on-demand-maps'
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
        Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 0 -Phase "post-$cmdName" -Fast
        # Install/refresh the DNAT self-heal watchdog so the RabbitMQ + game-port
        # rules recover automatically after a pod-only restart (no host reboot).
        Invoke-DuneDnatWatchdogInstall -Ip $ip -Phase "post-$cmdName"
    }

    # After start/restart, resolve director port
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

    if ($Cmd) { break }
}

Stop-Transcript | Out-Null
Invoke-DunePauseBeforeClose
