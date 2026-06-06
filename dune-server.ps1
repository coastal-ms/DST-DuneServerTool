#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # When set, skip the interactive menu and dispatch directly to the named
    # command. Used by the desktop app (app\DuneServer.ps1) to invoke commands
    # inside its embedded terminal pane.
    [string]$Cmd
)

# ============================================================
# Dune Awakening Server Management — Extended Menu
# Wraps the original battlegroup.ps1 menu and adds extra tools
# ============================================================

$script:ToolVersion = "11.4.1"

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

    # ── 3. dune-admin.exe ──
    Write-Host "3. Dune Admin Tool (optional)" -ForegroundColor Yellow
    Write-Host "   The dune-admin tool (by Icehunter) provides extra utilities for managing" -ForegroundColor Gray
    Write-Host "   your battlegroup. Repo: https://github.com/Icehunter/dune-admin" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   You can either:" -ForegroundColor Gray
    Write-Host "     1. Download latest release now (recommended)" -ForegroundColor Gray
    Write-Host "     2. Point at an existing dune-admin.exe you already have" -ForegroundColor Gray
    Write-Host "     3. Skip — option 21 will be hidden" -ForegroundColor Gray
    Write-Host ""
    $existingAdmin = $existing.DuneAdminExe
    $defaultAdminChoice = if ($existingAdmin -and (Test-Path $existingAdmin)) { '2' } else { '1' }
    $adminChoice = Ask -Label "Choose 1, 2, or 3" -Default $defaultAdminChoice
    $adminExe = ""
    if ($adminChoice -eq '1') {
        $defaultInstallDir = if ($existingAdmin) { Split-Path $existingAdmin -Parent } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'dune-admin' }
        $installDir = Ask -Label "Install directory" -Default $defaultInstallDir
        try {
            $adminExe = Install-DuneAdminLatest -InstallDir $installDir
            if ($adminExe) {
                Write-Host "   dune-admin installed at $adminExe" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Download failed: $($_.Exception.Message)"
            Write-Host "   You can re-run setup later or manually grab a release from:" -ForegroundColor Gray
            Write-Host "   https://github.com/Icehunter/dune-admin/releases" -ForegroundColor Gray
            $adminExe = ""
        }
    } elseif ($adminChoice -eq '2') {
        $defaultAdmin = $null
        $adminCandidates = @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) 'dune-admin\dune-admin.exe'),
            "$env:USERPROFILE\dune-admin\dune-admin.exe",
            "$env:USERPROFILE\Desktop\dune-admin-main\dune-admin.exe",
            "$scriptDir\dune-admin\dune-admin.exe"
        )
        foreach ($a in $adminCandidates) {
            if (Test-Path $a) { $defaultAdmin = $a; break }
        }
        if ($existingAdmin) { $defaultAdmin = $existingAdmin }
        $adminExe = Ask -Label "dune-admin.exe path" -Default $defaultAdmin
        if ($adminExe -and -not (Test-Path $adminExe)) {
            Write-Warning "File not found - dune-admin option will be hidden until the file exists."
        }
    }

    # ── Copy SSH key alongside dune-admin.exe ──
    # dune-admin needs to SSH to the VM the same way this tool does, so
    # seed its install folder with the same key. We prefer the live key
    # at %LOCALAPPDATA%\DuneAwakeningServer\sshKey (where rotate-ssh-key
    # writes new keys) over the configured $sshKeyPath, which can drift
    # if the user rotates after picking a different path in setup.
    if ($adminExe) {
        try {
            $adminDir = Split-Path $adminExe -Parent
            $srcKey   = Resolve-FreshSshKey -ConfiguredPath $sshKeyPath
            if ($srcKey -and $adminDir) {
                Copy-SshKeyToDir -SourceKey $srcKey -DestDir $adminDir | Out-Null
            }
        } catch {
            Write-Warning "Could not copy SSH key to dune-admin folder: $($_.Exception.Message)"
        }
    }
    Write-Host ""

    # ── 4. Windows username ──
    Write-Host "4. Windows Username" -ForegroundColor Yellow
    Write-Host "   Used to launch dune-admin without admin elevation." -ForegroundColor Gray
    Write-Host ""
    $defaultUser = if ($existing.WindowsUser) { $existing.WindowsUser } else { $env:USERNAME }
    $winUser = Ask -Label "Windows username" -Default $defaultUser
    Write-Host ""

    # ── 5. Port verification (optional) ──
    Write-Host "5. Port Verification" -ForegroundColor Yellow
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
        "DuneAdminExe=$adminExe"
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
    Write-Host "6. Desktop Shortcut (optional)" -ForegroundColor Yellow
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
        DuneAdminExe         = $adminExe
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

function Install-DuneAdminLatest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallDir
    )

    Write-Host ""
    Write-Host "   Fetching latest release info from Icehunter/dune-admin..." -ForegroundColor Cyan

    $headers = @{ 'User-Agent' = 'Simple-Dune-Server-Management-Tool' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Icehunter/dune-admin/releases/latest' -Headers $headers -TimeoutSec 15
    $tag = $release.tag_name
    Write-Host "   Latest release: $tag" -ForegroundColor DarkGray

    $asset = $release.assets | Where-Object { $_.name -like '*windows_amd64.zip' } | Select-Object -First 1
    if (-not $asset) {
        throw "No Windows amd64 .zip asset found in release $tag."
    }
    Write-Host "   Asset: $($asset.name) ($([Math]::Round($asset.size/1MB,1)) MB)" -ForegroundColor DarkGray

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }

    $tempZip = Join-Path $env:TEMP $asset.name
    Write-Host "   Downloading..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tempZip -Headers $headers -UseBasicParsing -TimeoutSec 120

    Write-Host "   Extracting to $InstallDir..." -ForegroundColor Cyan
    Expand-Archive -Path $tempZip -DestinationPath $InstallDir -Force
    Remove-Item $tempZip -ErrorAction SilentlyContinue

    $exe = Get-ChildItem -Path $InstallDir -Filter 'dune-admin.exe' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
    if (-not $exe) {
        throw "dune-admin.exe was not found in the extracted contents at $InstallDir."
    }
    return $exe
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

function Copy-SshKeyToDir {
    # Copies an SSH private key (and its .pub if present) into a destination
    # directory, skipping when source and destination point at the same place.
    # Returns $true on success, $false on skip, throws on failure.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceKey,
        [Parameter(Mandatory)][string]$DestDir
    )

    if (-not (Test-Path $SourceKey)) { return $false }
    if (-not (Test-Path $DestDir))   { return $false }

    $srcDir  = (Resolve-Path (Split-Path $SourceKey -Parent)).Path
    $dstDir  = (Resolve-Path $DestDir).Path
    if ($srcDir -eq $dstDir) { return $false }

    $keyName = Split-Path $SourceKey -Leaf
    $destKey = Join-Path $DestDir $keyName
    Copy-Item -Path $SourceKey -Destination $destKey -Force
    Write-Host "   Copied SSH key -> $destKey" -ForegroundColor DarkGray

    $pubSrc = "$SourceKey.pub"
    if (Test-Path $pubSrc) {
        Copy-Item -Path $pubSrc -Destination (Join-Path $DestDir "$keyName.pub") -Force
    }
    return $true
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
$duneAdminExe  = $cfg.DuneAdminExe
# The Settings UI now stores a FOLDER for dune-admin (folder picker), but the
# launch path below needs the full dune-admin.exe path. Mirror the in-app
# normalization (Get-DuneAdminConfiguredPath): if the value already ends in
# .exe use it as-is (back-compat with older configs); otherwise treat it as
# the install folder and append dune-admin.exe.
if ($duneAdminExe) {
    $duneAdminExe = ([string]$duneAdminExe).Trim()
    if ($duneAdminExe -and $duneAdminExe -notmatch '\.exe$') {
        $duneAdminExe = Join-Path ($duneAdminExe.TrimEnd('\','/')) 'dune-admin.exe'
    }
}
# dune-admin serves its web UI embedded (same-origin with its own API). Open the
# LOCAL instance — NOT the hosted layout.tools site, which is a different origin
# from the local API and triggers "Failed to fetch" + a sign-in wall.
#
# The port is PER-USER. dune-admin defaults to :8080 but its setup wizard writes
# whatever the user picked into config.yaml listen_addr (e.g. :18080 when the
# 'amp' control plane is chosen, since CubeCoders AMP squats 8080). NEVER assume
# 8080 — always resolve through Get-DuneAdminWebState, which re-reads config.yaml
# fresh each call (so a port chosen mid-session is picked up).
function Get-DuneAdminWebState {
    $port = 8080
    $cfgPath = Join-Path (Join-Path $env:USERPROFILE '.dune-admin') 'config.yaml'
    $configured = Test-Path -LiteralPath $cfgPath
    if ($configured) {
        try {
            $laMatch = Select-String -LiteralPath $cfgPath -Pattern '^\s*listen_addr\s*:\s*(.+?)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($laMatch) {
                $la = $laMatch.Matches[0].Groups[1].Value.Trim().Trim('"').Trim("'")
                $p = ($la -split ':')[-1]
                $pn = 0
                if ([int]::TryParse($p, [ref]$pn) -and $pn -gt 0) { $port = $pn }
            }
        } catch { }
    }
    return [pscustomobject]@{
        Configured = [bool]$configured
        Port       = $port
        Url        = "http://localhost:$port/#/players"
    }
}

# dune-admin is the priority tool on this host. When CubeCoders AMP (or anything
# else) already owns dune-admin's configured port on the IPv4 wildcard
# (0.0.0.0:<port>), dune-admin can only fall back to the IPv6 wildcard
# ([::]:<port>) — which forces the ugly [::1] loopback URL and breaks hosts with
# IPv6 disabled. So give dune-admin its OWN IPv4 loopback port: if the configured
# port is held by a foreign process at cold-launch time, move dune-admin to the
# next free port and pin it to 127.0.0.1 (loopback-only bind => a normal
# 'localhost' name, no AMP contention). No-op when the configured port is free,
# so normal (non-AMP) users are NEVER touched. Returns the port to serve on.
function Set-DuneAdminOwnLoopbackPort {
    $cfgPath = Join-Path (Join-Path $env:USERPROFILE '.dune-admin') 'config.yaml'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }

    $port = [int](Get-DuneAdminWebState).Port

    # Who (if anyone) is already listening on the configured port? The caller only
    # invokes us on the cold path (dune-admin NOT running), so any listener here
    # is a foreign process (e.g. AMP) that will block dune-admin's bind.
    $blocked = @(Get-DunePortOwnerNames -Port $port).Count -gt 0
    if (-not $blocked) { return $port }   # port free -> leave config untouched

    # Find the next free loopback port. Prefer 18080 (the value dune-admin's own
    # AMP control-plane setup uses), then scan upward.
    $candidates = @(18080) + (18081..18099)
    $freePort = $null
    foreach ($cand in $candidates) {
        if ($cand -eq $port) { continue }
        if (@(Get-DunePortOwnerNames -Port $cand).Count -eq 0) { $freePort = $cand; break }
    }
    if (-not $freePort) {
        Write-Host "Could not find a free port to move dune-admin to (tried 18080-18099)." -ForegroundColor Yellow
        return $port
    }

    # Rewrite (or add) listen_addr. Bind 0.0.0.0 so the remote-portal helper
    # bridge (helper/) can route the friend's WebView2 to dune-admin over
    # Tailscale. If the configured port WAS contested (e.g. AMP), we've already
    # relocated to a free port above — binding 0.0.0.0 on that new port is safe
    # because nothing else holds it. dune-admin still has its own auth gate.
    try {
        $newAddr = "0.0.0.0:$freePort"
        $lines = @(Get-Content -LiteralPath $cfgPath)
        $found = $false
        $lines = $lines | ForEach-Object {
            if ($_ -match '^\s*listen_addr\s*:') { $found = $true; "listen_addr: $newAddr" } else { $_ }
        }
        if (-not $found) { $lines += "listen_addr: $newAddr" }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($cfgPath, ($lines -join "`n") + "`n", $utf8)
        Write-Host "Port $port is held by another process (likely AMP) — moved dune-admin to 0.0.0.0:$freePort." -ForegroundColor Cyan
        return $freePort
    } catch {
        Write-Warning "Could not update dune-admin listen_addr: $($_.Exception.Message)"
        return $port
    }
}

# Force dune-admin's listen_addr to bind ALL interfaces (0.0.0.0) on its current
# port. Needed for the friend remote-portal helper to reach dune-admin through
# DST's bridge — a 127.0.0.1 bind only answers the host's loopback, so even
# though DST's listener routes through Tailscale, the iframe inside DST web UI
# pointed at the host's tailnet name:port hits dune-admin which doesn't answer
# on that interface. Idempotent (no rewrite if already 0.0.0.0:port). Returns
# $true if any change was made, $false otherwise.
function Set-DuneAdminBindAllInterfaces {
    $cfgPath = Join-Path (Join-Path $env:USERPROFILE '.dune-admin') 'config.yaml'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $false }
    try {
        $port = [int](Get-DuneAdminWebState).Port
        if (-not $port -or $port -le 0) { return $false }
        $newAddr = "0.0.0.0:$port"
        $lines = @(Get-Content -LiteralPath $cfgPath)
        $found = $false
        $changed = $false
        $lines = $lines | ForEach-Object {
            if ($_ -match '^\s*listen_addr\s*:\s*(\S+)') {
                $found = $true
                $current = $matches[1].Trim()
                if ($current -ne $newAddr) { $changed = $true; "listen_addr: $newAddr" } else { $_ }
            } else { $_ }
        }
        if (-not $found) { $changed = $true; $lines += "listen_addr: $newAddr" }
        if ($changed) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($cfgPath, ($lines -join "`n") + "`n", $utf8)
            Write-Host "dune-admin bind set to $newAddr (all interfaces, for remote-portal friend access)." -ForegroundColor Cyan
        }
        return $changed
    } catch {
        Write-Warning "Could not set dune-admin listen_addr to all interfaces: $($_.Exception.Message)"
        return $false
    }
}

# Open a Windows Firewall hole for dune-admin's port on the Private + Domain
# profiles so the friend can reach it over Tailscale (Tailscale's tun adapter
# is Private). Idempotent — won't add a duplicate rule on subsequent launches.
function Add-DuneAdminFirewallRule {
    try {
        $port = [int](Get-DuneAdminWebState).Port
        if (-not $port -or $port -le 0) { return }
        $ruleName = "DST_DuneAdmin_Inbound_$port"
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if ($existing) { return }
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Description "Allow inbound TCP to dune-admin (managed by DST for remote-portal helper access)." `
            -Direction Inbound -Action Allow -Protocol TCP `
            -LocalPort $port -Profile Private,Domain `
            -ErrorAction Stop | Out-Null
        Write-Host "Firewall: opened inbound TCP $port for dune-admin (Private+Domain profiles)." -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not add dune-admin firewall rule: $($_.Exception.Message)"
    }
}

# Short-timeout TCP probe: is anything listening on 127.0.0.1:<port> yet?
function Test-DuneAdminListening {
    param([int]$Port, [int]$TimeoutMs = 800)
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) {
            $client.EndConnect($iar); return $true
        }
        return $false
    } catch { return $false } finally { if ($client) { try { $client.Close() } catch { } } }
}

# Which processes own the TCP listener(s) on <port>? Returns an array of
# ProcessNames (no .exe). More than one can listen on the same port via
# different interfaces (e.g. dune-admin on 127.0.0.1 AND CubeCoders AMP on
# 0.0.0.0). Returns @() if nothing is listening / owners can't be resolved.
function Get-DunePortOwnerNames {
    param([int]$Port)
    $names = @()
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            $op = $c.OwningProcess
            if ($op) {
                $proc = Get-Process -Id $op -ErrorAction SilentlyContinue
                if ($proc -and ($names -notcontains $proc.ProcessName)) { $names += $proc.ProcessName }
            }
        }
    } catch { }
    return $names
}

# Picks the loopback host literal that actually routes to dune-admin on <port>.
#
# Why this is needed: when CubeCoders AMP already holds the IPv4 wildcard
# (0.0.0.0:8080), dune-admin can only bind the IPv6 wildcard ([::]:8080). In
# that split, 'localhost' resolves to 127.0.0.1 FIRST and lands on AMP's panel,
# not dune-admin — even though dune-admin IS listening on the same port number.
# So we inspect the actual listeners and, when there's a cross-family conflict,
# return the loopback literal ([::1] or 127.0.0.1) that dune-admin owns
# exclusively. With no conflict we keep friendly 'localhost'.
function Get-DuneAdminUrlHost {
    param([int]$Port, [string]$AdminProcName = 'dune-admin')
    $hostLit = 'localhost'
    try {
        $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        $adminV4 = $false; $adminV6 = $false; $otherV4 = $false; $otherV6 = $false
        foreach ($c in $conns) {
                $isV6 = ([string]$c.LocalAddress).Contains(':')
                $pn = $null
                if ($c.OwningProcess) { $pn = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
                $isAdmin = ($pn -and $AdminProcName -and ($pn -ieq $AdminProcName))
                if ($isAdmin) { if ($isV6) { $adminV6 = $true } else { $adminV4 = $true } }
                else         { if ($isV6) { $otherV6 = $true } else { $otherV4 = $true } }
        }
        if ($otherV4 -or $otherV6) {
                if ($adminV6 -and -not $otherV6)      { $hostLit = '[::1]' }
                elseif ($adminV4 -and -not $otherV4)  { $hostLit = '127.0.0.1' }
        }
    } catch { }
    return $hostLit
}

$duneAdminWeb = (Get-DuneAdminWebState).Url
$bgSetupPath   = "$($cfg.SteamPath)\battlegroup-management"
$windowsUser   = $cfg.WindowsUser
# Default existing installs (no PortCheckMode in config) to built-in.
$portCheckMode = if ($cfg.PortCheckMode) { $cfg.PortCheckMode } else { 'builtin' }
$portCheckUrl  = $cfg.PortCheckUrlTemplate

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

    # Query online players. The cluster's postgres listens on 15432 (not default 5432).
    $sql = "SELECT character_name FROM player_state WHERE online_status = 'Online' AND character_name IS NOT NULL ORDER BY character_name;"
    $cmd = "sudo k3s kubectl exec -n '$pgNs' '$pgPod' -- env PGPASSWORD=dune psql -h 127.0.0.1 -p 15432 -U dune -d dune -t -A -c `"$sql`" 2>&1"
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
        (Join-Path $scriptDir 'resources\remote-scripts\dune-clear-partitions.start')
        (Join-Path $scriptDir 'app\resources\remote-scripts\dune-clear-partitions.start')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Invoke-DuneRemotePartitionScript {
    # Stages the bundled dune-clear-partitions.start to /tmp on the VM via scp,
    # runs it once with sudo, removes the staged copy. No persistent install,
    # no boot script, no cron. Returns @{ ok; rc; output }. Best-effort —
    # never throws.
    param(
        [Parameter(Mandatory)][string]$Ip
    )
    $local = Get-DuneRemotePartitionScriptPath
    if (-not $local) {
        return @{ ok = $false; rc = -1; output = @('Bundled dune-clear-partitions.start not found in install dir.') }
    }

    $stamp     = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $localTmp  = Join-Path $env:TEMP "dune-cp-$stamp.sh"
    $remoteTmp = "/tmp/dune-cp-$stamp.sh"

    # Force LF line endings — Alpine /bin/sh chokes on CRLF.
    $raw = [System.IO.File]::ReadAllText($local)
    $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllBytes($localTmp, [Text.Encoding]::UTF8.GetBytes($lf))

    try {
        & scp -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
              -i "$sshKey" $localTmp "${sshUser}@${Ip}:${remoteTmp}" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{ ok = $false; rc = $LASTEXITCODE; output = @("scp of partition-clear script failed (exit $LASTEXITCODE).") }
        }
        $output = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET `
                        -i "$sshKey" "$sshUser@$Ip" `
                        "sudo -n sh $remoteTmp; rc=`$?; rm -f $remoteTmp; exit `$rc" 2>&1
        $rc = $LASTEXITCODE
        return @{ ok = ($rc -eq 0); rc = $rc; output = @($output) }
    } finally {
        Remove-Item -LiteralPath $localTmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OnDemandPartitionClear {
    # Best-effort wrapper: settle for DelaySec to let the Funcom server-operator
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
        [string]$Phase = 'post-start'
    )
    Write-Host ""
    Write-Host "[$Phase] Clearing on-demand map partition pins (auto-fix so DeepDesert / Arrakeen / Harko spawn on demand)..." -ForegroundColor Cyan

    if ($DelaySec -gt 0) {
        Write-Host "  Settling ${DelaySec}s so the server operator finishes reconciling on-demand ServerSets..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $DelaySec
    }

    $result = Invoke-DuneRemotePartitionScript -Ip $Ip
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

# ============================================================
#  MENU DEFINITIONS
# ============================================================

$vmCommands = @(
    [pscustomobject]@{ Key = "a"; Name = "initial-setup";      Desc = "Run the initial VM setup" }
    [pscustomobject]@{ Key = "c"; Name = "start-vm";           Desc = "Power on the VM only (no battlegroup) - useful for maintenance" }
    [pscustomobject]@{ Key = "d"; Name = "startup";            Desc = "Power on VM -> start battlegroup -> wait for overmap + survival maps" }
    [pscustomobject]@{ Key = "e"; Name = "shutdown";           Desc = "Stop battlegroup -> power off VM (e.g. shut down for the night)" }
    [pscustomobject]@{ Key = "f"; Name = "reboot";             Desc = "Stop battlegroup -> restart VM -> start battlegroup (clean cycle)" }
    [pscustomobject]@{ Key = "g"; Name = "rotate-ssh-key";     Desc = "Generate a new SSH key and replace the one authorized on the VM" }
    [pscustomobject]@{ Key = "h"; Name = "change-password";    Desc = "Change the password of the 'dune' user on the VM" }
)

$bgCommands = @(
    [pscustomobject]@{ Key = "1";  SubSection = $null;          Name = "status";                    Desc = "Shows the status of the selected battlegroup" }
    [pscustomobject]@{ Key = "2";  SubSection = $null;          Name = "start";                     Desc = "Starts the selected battlegroup" }
    [pscustomobject]@{ Key = "3";  SubSection = $null;          Name = "restart";                   Desc = "Restarts the selected battlegroup" }
    [pscustomobject]@{ Key = "4";  SubSection = $null;          Name = "stop";                      Desc = "Stops the selected battlegroup" }
    [pscustomobject]@{ Key = "5";  SubSection = $null;          Name = "update";                    Desc = "Checks for new versions and applies them" }
    [pscustomobject]@{ Key = "6";  SubSection = $null;          Name = "edit";                      Desc = "Edit the battlegroup with the utilities interface" }
    [pscustomobject]@{ Key = "7";  SubSection = $null;          Name = "edit-advanced";             Desc = "(Advanced) Manually edit battlegroup directly with YAML" }
    [pscustomobject]@{ Key = "8";  SubSection = $null;          Name = "enable-experimental-swap";  Desc = "(Experimental) Enable experimental swap memory feature" }
    [pscustomobject]@{ Key = "9";  SubSection = "Database";     Name = "backup";                    Desc = "Take a backup of the battlegroup's database" }
    [pscustomobject]@{ Key = "10"; SubSection = "Database";     Name = "import";                    Desc = "Import a database backup into the selected battlegroup" }
    [pscustomobject]@{ Key = "11"; SubSection = "Logs";         Name = "logs-export";               Desc = "Retrieves logs from all pods in the selected battlegroup" }
    [pscustomobject]@{ Key = "12"; SubSection = "Logs";         Name = "operator-logs-export";      Desc = "Retrieves logs from all operator pods" }
    [pscustomobject]@{ Key = "13"; SubSection = "Monitoring";   Name = "open-file-browser";         Desc = "Open the battlegroup file browser to view and edit ini configs and logs" }
    [pscustomobject]@{ Key = "14"; SubSection = "Monitoring";   Name = "open-director";             Desc = "Open the battlegroup director page to view server status" }
    [pscustomobject]@{ Key = "15"; SubSection = "Monitoring";   Name = "shell-vm";                  Desc = "Connect to the VM via commandline" }
    [pscustomobject]@{ Key = "16"; SubSection = "Monitoring";   Name = "shell-pod";                 Desc = "Connect to a pod in the battlegroup via commandline" }
    [pscustomobject]@{ Key = "21"; SubSection = "Maintenance";   Name = "fix-on-demand-maps";        Desc = "Clear pinned partitions so DeepDesert / Arrakeen / Harko launch on demand" }
)

$toolCommands = @(
    [pscustomobject]@{ Key = "17"; Name = "ssh";             Desc = "Open an SSH terminal to the VM" }
)
if ($duneAdminExe) {
    $toolCommands += [pscustomobject]@{ Key = "18"; Name = "dune-admin";      Desc = "Launch dune-admin.exe  +  Open dune-admin web UI" }
}
$toolCommands += [pscustomobject]@{ Key = "19"; Name = "setup-guide";    Desc = "Open Funcom Self-Hosted Server Setup Instructions" }
$toolCommands += [pscustomobject]@{ Key = "20"; Name = "report-issue";   Desc = "Report a bug in this tool (opens prefilled GitHub issue in browser)" }

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
        "dune-admin" {
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
        $entries += [pscustomobject]@{ Section = 'vm'; SubSection = $null; Key = $c.Key; Name = $c.Name; Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }
    foreach ($c in $bgCommands) {
        $avail = Get-BgCmdAvailability -info $info
        $entries += [pscustomobject]@{ Section = 'battlegroup'; SubSection = $c.SubSection; Key = $c.Key; Name = $c.Name; Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }
    foreach ($c in $toolCommands) {
        $avail = Get-ToolCmdAvailability -cmdName $c.Name -info $info
        $entries += [pscustomobject]@{ Section = 'tools'; SubSection = $null; Key = $c.Key; Name = $c.Name; Desc = $c.Desc; Available = $avail.Available; Reason = $avail.Reason }
    }

    foreach ($e in $entries) { $entryByKey[$e.Key.ToLower()] = $e }

    if ($Cmd) {
        # Non-interactive dispatch (called by the desktop app's terminal pane).
        # Skip menu render + interactive selection; look up the entry by
        # command name and fall through to the handler block.
        $entry = $entries | Where-Object { $_.Name -eq $Cmd } | Select-Object -First 1
        if (-not $entry) {
            Write-Error "Unknown command: $Cmd"
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
            Write-Host ("  {0,2}. {1,-30} {2}" -f $e.Key, $e.Name, $e.Desc) -ForegroundColor $color
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
        if ($Cmd) { exit 1 } else { continue }
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
        Write-Host "Stopping VM '$vmName'..." -ForegroundColor Cyan
        Stop-VM -Name $vmName -Force | Out-Null
        Write-Host "VM stopped." -ForegroundColor Green
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
        $estDb = Format-PhaseEstimate 'db-pods'
        $dbPodList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ && `$2 !~ /(dump|backup|fb-|migration)/ {print `$1, `$2}'"
        $dbPodList = ($dbPodList | Out-String).Trim()
        if ($dbPodList) {
            $dbPods = $dbPodList -split "`r?`n" | Where-Object { $_.Trim() }
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
            Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 15 -Phase 'post-startup'
        } else {
            Write-Host "  Skipped on-demand partition auto-clear because battlegroup start exited $bgStartExit." -ForegroundColor DarkYellow
        }

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
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath stop"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "battlegroup stop returned exit code $LASTEXITCODE. Aborting reboot."
            continue
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
        $estDb = Format-PhaseEstimate 'db-pods'
        $dbPodList = ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ && `$2 !~ /(dump|backup|fb-|migration)/ {print `$1, `$2}'"
        $dbPodList = ($dbPodList | Out-String).Trim()
        if ($dbPodList) {
            $dbPods = $dbPodList -split "`r?`n" | Where-Object { $_.Trim() }
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
        } else {
            Write-Host "  Skipped on-demand partition auto-clear because battlegroup start exited $bgStartExit." -ForegroundColor DarkYellow
        }
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
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath stop"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "battlegroup stop returned exit code $LASTEXITCODE."
            $force = Read-Host "Continue with VM shutdown anyway? (YES to continue)"
            if ($force -ne "YES") { continue }
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
        # Keep dune-admin's copy of the SSH key in sync with the rotated one
        if ($cfg.DuneAdminExe -and (Test-Path $cfg.DuneAdminExe)) {
            try {
                $freshKey = Resolve-FreshSshKey -ConfiguredPath $sshKey
                if ($freshKey) {
                    Copy-SshKeyToDir -SourceKey $freshKey `
                                     -DestDir (Split-Path $cfg.DuneAdminExe -Parent) | Out-Null
                }
            } catch {
                Write-Warning "Could not refresh dune-admin's SSH key copy: $($_.Exception.Message)"
            }
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

    if ($cmdName -eq "dune-admin") {
        # Verify the configured exe exists. If it doesn't (user uninstalled,
        # moved the folder, or never installed it), auto-install the latest
        # release rather than silently registering a scheduled task pointed
        # at a missing file (which fires-and-forgets and leaves dune-admin's
        # web UI showing no data).
        $needsInstall = (-not $duneAdminExe) -or (-not (Test-Path -LiteralPath $duneAdminExe))
        $didInstallWork = $false
        if ($needsInstall) {
            $didInstallWork = $true
            Write-Host ""
            Write-Host "dune-admin.exe was not found." -ForegroundColor Yellow
            if ($duneAdminExe) {
                Write-Host "  Configured path: $duneAdminExe" -ForegroundColor DarkGray
            }
            Write-Host ""
            Write-Host "  This tool can install the latest dune-admin release for you" -ForegroundColor Gray
            Write-Host "  from https://github.com/Icehunter/dune-admin/releases" -ForegroundColor Gray
            Write-Host ""
            $resp = Read-Host "Install dune-admin now? [Y/n]"
            if ($resp -and $resp -notmatch '^(y|yes)$') {
                Write-Host "Aborted." -ForegroundColor Yellow
                Read-Host "Press Enter to close this window"
                continue
            }
            $installDir = if ($duneAdminExe) { Split-Path $duneAdminExe -Parent } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'dune-admin' }
            try {
                $newExe = Install-DuneAdminLatest -InstallDir $installDir
                if (-not $newExe -or -not (Test-Path -LiteralPath $newExe)) {
                    throw "Install completed but dune-admin.exe was not found in $installDir."
                }
                $duneAdminExe = $newExe
                # Persist the new path so future runs find it without re-installing.
                try {
                    if (Test-Path -LiteralPath $configFile) {
                        $lines = Get-Content -LiteralPath $configFile
                        if ($lines -match '^DuneAdminExe=') {
                            $lines = $lines | ForEach-Object { if ($_ -match '^DuneAdminExe=') { "DuneAdminExe=$duneAdminExe" } else { $_ } }
                        } else {
                            $lines += "DuneAdminExe=$duneAdminExe"
                        }
                        $lines | Set-Content -LiteralPath $configFile -Encoding UTF8
                        Write-Host "  Updated config: $configFile" -ForegroundColor DarkGray
                    }
                } catch {
                    Write-Warning "Installed dune-admin OK but could not update config: $($_.Exception.Message)"
                }
                # Seed the install dir with our SSH key so dune-admin can SSH
                # to the VM the same way this tool does. Mirrors initial-setup.
                try {
                    $adminDir = Split-Path $duneAdminExe -Parent
                    $srcKey   = Resolve-FreshSshKey -ConfiguredPath $sshKey
                    if ($srcKey -and $adminDir) {
                        Copy-SshKeyToDir -SourceKey $srcKey -DestDir $adminDir | Out-Null
                        Write-Host "  Copied SSH key into $adminDir" -ForegroundColor DarkGray
                    }
                } catch {
                    Write-Warning "Could not copy SSH key into dune-admin folder: $($_.Exception.Message)"
                }
            } catch {
                Write-Host ""
                Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "You can download manually from https://github.com/Icehunter/dune-admin/releases" -ForegroundColor Gray
                Read-Host "Press Enter to close this window"
                continue
            }
        }

        Write-Host "Launching dune-admin.exe and web UI as $windowsUser..." -ForegroundColor Cyan
        $duneAdminDir = Split-Path $duneAdminExe -Parent
        # Skip the launch if dune-admin is already running — relaunching would
        # spawn a duplicate console/process. We still open the web UI below.
        $adminProcName = [System.IO.Path]::GetFileNameWithoutExtension($duneAdminExe)
        $adminRunning  = $false
        if ($adminProcName) {
            $adminRunning = [bool](Get-Process -Name $adminProcName -ErrorAction SilentlyContinue)
        }
        if ($adminRunning) {
            Write-Host "dune-admin.exe is already running — reusing the existing instance." -ForegroundColor DarkGray
        } else {
            # dune-admin is priority: if its configured port is squatted by a
            # foreign process (e.g. AMP on 0.0.0.0:8080), move dune-admin to its
            # own free 127.0.0.1 loopback port BEFORE launch so it binds IPv4
            # cleanly and the UI opens on a normal name (no [::1]).
            try { Set-DuneAdminOwnLoopbackPort | Out-Null } catch { Write-Warning "Port pre-flight failed: $($_.Exception.Message)" }
            # Ensure dune-admin binds all interfaces (0.0.0.0) on its port so the
            # remote-portal helper bridge can route the friend's WebView2 to it
            # over Tailscale. Also drop a Windows Firewall rule for the same port
            # (Private+Domain — Tailscale's tun is Private). Both idempotent.
            try { Set-DuneAdminBindAllInterfaces | Out-Null } catch { Write-Warning "Bind-all pre-flight failed: $($_.Exception.Message)" }
            try { Add-DuneAdminFirewallRule } catch { Write-Warning "Firewall pre-flight failed: $($_.Exception.Message)" }
            # Launch as the logged-in user via scheduled task (avoids admin elevation).
            # Hiding the spawned console window is harder than it sounds:
            #   * `-Hidden` on New-ScheduledTaskSettingsSet only hides the TASK
            #     in Task Scheduler's UI — the spawned cmd.exe still shows a
            #     console window.
            #   * `-WindowStyle Hidden` on powershell.exe does work but flashes
            #     a visible console for ~50ms while PS itself starts up.
            # The reliable zero-flash trick on Windows 10/11 is to invoke the
            # process via WScript.Shell.Run with intWindowStyle=0 (SW_HIDE).
            # wscript.exe is a Windows-subsystem host (no console of its own)
            # and CreateProcess inherits SW_HIDE through to cmd's spawn of
            # dune-admin. We drop a tiny .vbs to %LOCALAPPDATA%\DuneServer\,
            # then schedule wscript.exe <vbs> <exe> <log>. cmd's redirection
            # captures both streams into the log file the DuneServer mirror
            # runspace tails into THIS console with an [admin] prefix.
            try {
                $duneAdminLogDir  = Join-Path $env:LOCALAPPDATA 'DuneServer\logs'
                $duneAdminLogPath = Join-Path $duneAdminLogDir 'dune-admin.log'
                $duneAdminVbsPath = Join-Path (Join-Path $env:LOCALAPPDATA 'DuneServer') 'launch-dune-admin.vbs'
                if (-not (Test-Path -LiteralPath $duneAdminLogDir)) {
                    New-Item -ItemType Directory -Path $duneAdminLogDir -Force | Out-Null
                }
                $vbsDir = Split-Path -Parent $duneAdminVbsPath
                if (-not (Test-Path -LiteralPath $vbsDir)) {
                    New-Item -ItemType Directory -Path $vbsDir -Force | Out-Null
                }
                # VBS contents — q is the literal ASCII double-quote, used to
                # build a cmd.exe command line with the magic-quote pattern:
                #   cmd /c ""<exe>" 1>>"<log>" 2>&1"
                # The outer "" pair is consumed by cmd /c's tokenizer per its
                # documented quoting rules. Style 0 = SW_HIDE (no window).
                # True (3rd arg) = wait for completion so cmd's redirection
                # file handles stay alive for dune-admin's whole lifetime.
                $vbsContent = @'
Dim args, q, cmd
Set args = WScript.Arguments
If args.Count < 2 Then WScript.Quit 1
q = Chr(34)
cmd = "cmd.exe /c " & q & q & args(0) & q & " 1>>" & q & args(1) & q & " 2>&1" & q
CreateObject("WScript.Shell").Run cmd, 0, True
'@
                [System.IO.File]::WriteAllText($duneAdminVbsPath, $vbsContent, [System.Text.UTF8Encoding]::new($false))

                $wscriptArgs = '"' + $duneAdminVbsPath + '" "' + $duneAdminExe + '" "' + $duneAdminLogPath + '"'
                $action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $wscriptArgs -WorkingDirectory $duneAdminDir
                $settings  = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                $principal = New-ScheduledTaskPrincipal -UserId $windowsUser -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName "DuneAdminLaunch" -Action $action -Principal $principal -Settings $settings -Force | Out-Null
                Start-ScheduledTask -TaskName "DuneAdminLaunch"
                Start-Sleep -Seconds 1
                Unregister-ScheduledTask -TaskName "DuneAdminLaunch" -Confirm:$false
            } catch {
                Write-Host "Failed to launch dune-admin.exe: $($_.Exception.Message)" -ForegroundColor Red
                Read-Host "Press Enter to close this window"
                continue
            }
        }
        # Open the web UI — but ONLY once dune-admin is actually listening on its
        # configured port. Re-resolve fresh: if the user just ran first-time setup
        # (or AMP picked :18080), config.yaml now holds the real port. Opening
        # blindly on :8080 could land on AMP's panel or a dead port.
        $webState = Get-DuneAdminWebState
        if (-not $webState.Configured) {
            Write-Host ""
            Write-Host "dune-admin needs first-time setup before it can serve the web UI." -ForegroundColor Yellow
            Write-Host "Complete the prompts in the dune-admin window (control plane, ports, etc)." -ForegroundColor Yellow
            Write-Host "When it prints 'Starting server on :<port>', re-run this command to open it." -ForegroundColor Yellow
            Write-Host "Not opening a browser yet (would hit the wrong port before setup finishes)." -ForegroundColor DarkGray
            if ($didInstallWork) { Read-Host "Press Enter to close this window" }
            continue
        }
        # Poll until dune-admin is listening on its real port (up to ~30s) AND
        # verify the process that owns the port is dune-admin itself. This closes
        # the AMP edge case: if something else (CubeCoders AMP) already owns the
        # port, dune-admin's bind fails and AMP would answer the probe — we must
        # NOT open AMP's panel. Bail early with guidance instead.
        $ready = $false
        $conflictOwner = $null
        for ($i = 0; $i -lt 30; $i++) {
            if (Test-DuneAdminListening -Port $webState.Port -TimeoutMs 800) {
                $owners = @(Get-DunePortOwnerNames -Port $webState.Port)
                if ($owners.Count -eq 0) {
                    # Listening but owners unresolved (loopback can hide it) — accept.
                    $ready = $true; break
                } elseif (-not $adminProcName -or ($owners -icontains $adminProcName)) {
                    # dune-admin is among the listeners (even if AMP also holds the
                    # port on another interface) — safe to open.
                    $ready = $true; break
                } else {
                    $conflictOwner = $owners[0]; break
                }
            }
            Start-Sleep -Seconds 1
        }
        if ($ready) {
            # Build the URL with the loopback host that actually routes to
            # dune-admin. If AMP holds IPv4:<port>, dune-admin is IPv6-only and
            # 'localhost' (127.0.0.1-first) would open AMP's panel — use [::1].
            $urlHost = Get-DuneAdminUrlHost -Port $webState.Port -AdminProcName $adminProcName
            $openUrl = "http://${urlHost}:$($webState.Port)/#/players"
            # The DST embed tab is the canonical dune-admin viewer now, so the
            # API command runner sets DST_DUNE_ADMIN_NO_BROWSER=1 to stop us
            # from popping a redundant second browser window over the iframe.
            # CLI users running this command directly have the env var unset
            # and still get the browser open.
            if ($env:DST_DUNE_ADMIN_NO_BROWSER -eq '1') {
                Write-Host "Done. dune-admin is listening on port $($webState.Port) ($openUrl). Browser skipped (DST embed tab is active)." -ForegroundColor Green
            } else {
                # Start-Process <url> uses the registered https:// protocol handler,
                # honoring the user's default browser (avoids Win11 24H2's Edge bug).
                Start-Process $openUrl
                Write-Host "Done. dune-admin is listening on port $($webState.Port); web UI opened in browser ($openUrl)." -ForegroundColor Green
            }
        } elseif ($conflictOwner) {
            Write-Host ""
            Write-Host "Port $($webState.Port) is in use by '$conflictOwner' (not dune-admin)." -ForegroundColor Yellow
            Write-Host "dune-admin can't bind that port, so its web UI isn't available there." -ForegroundColor Yellow
            if ($conflictOwner -match 'amp|cube') {
                Write-Host "Looks like CubeCoders AMP. Re-run dune-admin setup and choose the 'amp'" -ForegroundColor Yellow
                Write-Host "control plane (it moves dune-admin to :18080), or set a different" -ForegroundColor Yellow
                Write-Host "listen_addr in ~/.dune-admin/config.yaml, then re-run this command." -ForegroundColor Yellow
            } else {
                Write-Host "Free port $($webState.Port) or set a different listen_addr in" -ForegroundColor Yellow
                Write-Host "~/.dune-admin/config.yaml, then re-run this command." -ForegroundColor Yellow
            }
            Write-Host "Not opening a browser (would land on '$conflictOwner', not dune-admin)." -ForegroundColor DarkGray
        } else {
            Write-Host ""
            Write-Host "dune-admin did not start listening on port $($webState.Port) within 30s." -ForegroundColor Yellow
            Write-Host "If it is still finishing setup, wait for 'Starting server on :$($webState.Port)' then re-run this command." -ForegroundColor Yellow
            Write-Host "URL when ready: $($webState.Url)" -ForegroundColor DarkGray
        }
        if ($didInstallWork) { Read-Host "Press Enter to close this window" }
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
        Invoke-OnDemandPartitionClear -Ip $ip -DelaySec 45 -Phase "post-$cmdName"
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
