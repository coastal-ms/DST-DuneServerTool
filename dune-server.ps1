#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # When set, skip the interactive menu and dispatch directly to the named
    # command. Used by the web UI (web/Start-DuneWeb.ps1) to invoke commands
    # in a fresh console window per click.
    [string]$Cmd
)

# ============================================================
# Dune Awakening Server Management — Extended Menu
# Wraps the original battlegroup.ps1 menu and adds extra tools
# ============================================================

$script:ToolVersion = "1.2.2"

# Resize console window so the full menu is visible
try {
    $bufWidth  = [Math]::Max($Host.UI.RawUI.BufferSize.Width, 120)
    $winHeight = 50
    $winWidth  = [Math]::Min($bufWidth, 120)
    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($bufWidth, 9999)
    $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($winWidth, $winHeight)
} catch {}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = "$scriptDir\dune-server.config"

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
        $defaultInstallDir = if ($existingAdmin) { Split-Path $existingAdmin -Parent } else { "$env:USERPROFILE\dune-admin" }
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
            "$env:USERPROFILE\dune-admin\dune-admin.exe",
            "$env:USERPROFILE\Desktop\dune-admin-main\dune-admin.exe",
            "$env:USERPROFILE\Desktop\dune-admin\dune-admin.exe",
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
$duneAdminWeb  = 'https://dune-admin.layout.tools/'
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

$logFile = "$scriptDir\.logs\dune-server-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
Start-Transcript -Path $logFile -Append | Out-Null

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

# --- Online-player lookup (for safety check before shutdown commands) ---
# Queries the Postgres DB inside the cluster via `kubectl exec`. Returns
# @{ Names=@(string); Error=$null|string }. On any failure returns Error set
# and Names empty so callers can decide whether to proceed or abort.
function Get-OnlinePlayers {
    if (-not $ip) { return @{ Names = @(); Error = 'VM IP not set' } }

    # Locate the Postgres pod (name typically contains "-db-", "postgres", or "-pg-")
    $pgInfo = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
        "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|-pg-)/ {print `$1`" `"`$2; exit}'"
    $pgInfo = ($pgInfo | Out-String).Trim()
    if (-not $pgInfo) { return @{ Names = @(); Error = 'Postgres pod not found' } }
    $parts = $pgInfo -split '\s+', 2
    if ($parts.Count -lt 2) { return @{ Names = @(); Error = "Could not parse pod info: $pgInfo" } }
    $pgNs  = $parts[0].Trim()
    $pgPod = $parts[1].Trim()

    # Query online players. The cluster's postgres listens on 15432 (not default 5432).
    $sql = "SELECT character_name FROM player_state WHERE online_status = 'Online' AND character_name IS NOT NULL ORDER BY character_name;"
    $cmd = "sudo k3s kubectl exec -n '$pgNs' '$pgPod' -- env PGPASSWORD=dune psql -h 127.0.0.1 -p 15432 -U dune -d dune -t -A -c `"$sql`" 2>&1"
    $raw = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" $cmd
    $rawText = ($raw | Out-String)
    if ($LASTEXITCODE -ne 0 -or $rawText -match 'error|FATAL|ERROR') {
        return @{ Names = @(); Error = "psql failed: $($rawText.Trim())" }
    }
    $names = @($rawText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\(\d+ rows?\)$' })
    return @{ Names = $names; Error = $null }
}

# Helper used by both graceful-reboot and graceful-shutdown handlers.
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
        $line = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$Ip" `
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
#  MENU DEFINITIONS
# ============================================================

$vmCommands = @(
    [pscustomobject]@{ Key = "a"; Name = "initial-setup";      Desc = "Run the initial VM setup" }
    [pscustomobject]@{ Key = "b"; Name = "web";                Desc = "Open the web UI in your browser (button panel for these commands)" }
    [pscustomobject]@{ Key = "c"; Name = "startup";            Desc = "Power on VM -> start battlegroup -> wait for overmap + survival maps" }
    [pscustomobject]@{ Key = "d"; Name = "graceful-reboot";    Desc = "Stop battlegroup -> restart VM -> start battlegroup (clean cycle)" }
    [pscustomobject]@{ Key = "e"; Name = "graceful-shutdown";  Desc = "Stop battlegroup -> power off VM (e.g. shut down for the night)" }
    [pscustomobject]@{ Key = "f"; Name = "rotate-ssh-key";     Desc = "Generate a new SSH key and replace the one authorized on the VM" }
    [pscustomobject]@{ Key = "g"; Name = "change-password";    Desc = "Change the password of the 'dune' user on the VM" }
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
)

$toolCommands = @(
    [pscustomobject]@{ Key = "20"; Name = "ssh";             Desc = "Open an SSH terminal to the VM" }
)
if ($duneAdminExe) {
    $toolCommands += [pscustomobject]@{ Key = "21"; Name = "dune-admin";      Desc = "Launch dune-admin.exe  +  Open dune-admin web UI" }
}
$toolCommands += [pscustomobject]@{ Key = "22"; Name = "setup-guide";    Desc = "Open Funcom Self-Hosted Server Setup Instructions" }

# ============================================================
#  AVAILABILITY CHECKS
# ============================================================

function Get-VmCmdAvailability {
    param($cmdName, $info)
    switch ($cmdName) {
        "initial-setup" { return @{ Available = $true; Reason = $null } }
        "web"           { return @{ Available = $true; Reason = $null } }
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
        "graceful-reboot" {
            if (-not $info.Exists)  { return @{ Available = $false; Reason = "VM '$vmName' does not exist." } }
            if (-not $info.Running) { return @{ Available = $false; Reason = "VM '$vmName' is not running. Use 'c. startup' to cold-start." } }
            return @{ Available = $true; Reason = $null }
        }
        "graceful-shutdown" {
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
        # Non-interactive dispatch (called by web UI). Skip menu render +
        # interactive selection; look up the entry by command name and fall
        # through to the handler block.
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

    $cmd = $entry.Name
    $ip  = $info.Ip

    # ========================================================
    #  VM COMMANDS
    # ========================================================

    if ($cmd -eq "initial-setup") {
        . "$bgSetupPath\initial-setup.ps1"
        if ($Cmd) { break }
        continue
    }

    if ($cmd -eq "web") {
        $webScript = Join-Path $scriptDir 'web\Start-DuneWeb.ps1'
        if (-not (Test-Path $webScript)) {
            Write-Warning "Web UI script not found at $webScript"
            if ($Cmd) { break } else { continue }
        }
        if (-not (Get-Module -ListAvailable Pode)) {
            Write-Warning "Pode PowerShell module is not installed. Install with:"
            Write-Host "    Install-Module Pode -Scope CurrentUser" -ForegroundColor Cyan
            if ($Cmd) { break } else { continue }
        }

        $port = 8765
        $url  = "http://127.0.0.1:$port"

        $alreadyRunning = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
            $alreadyRunning = $iar.AsyncWaitHandle.WaitOne(300) -and $tcp.Connected
            $tcp.Close()
        } catch {}

        if (-not $alreadyRunning) {
            Write-Host "Starting Pode web server on $url (minimized)..." -ForegroundColor Cyan
            Start-Process pwsh `
                -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$webScript`"" `
                -WindowStyle Minimized
            $waited = 0
            while ($waited -lt 8) {
                Start-Sleep -Milliseconds 500; $waited++
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $iar = $tcp.BeginConnect('127.0.0.1', $port, $null, $null)
                    if ($iar.AsyncWaitHandle.WaitOne(200) -and $tcp.Connected) { $tcp.Close(); break }
                    $tcp.Close()
                } catch {}
            }
        } else {
            Write-Host "Web server already running at $url" -ForegroundColor DarkGray
        }

        Write-Host "Opening $url in your default browser..." -ForegroundColor Cyan
        Start-Process $url
        if ($Cmd) { break }
        continue
    }

    if ($cmd -eq "start-vm") {
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

    if ($cmd -eq "stop-vm") {
        Write-Host "Stopping VM '$vmName'..." -ForegroundColor Cyan
        Stop-VM -Name $vmName -Force | Out-Null
        Write-Host "VM stopped." -ForegroundColor Green
        continue
    }

    if ($cmd -eq "startup") {
        Write-Host ""
        Write-Host "=== Startup ===" -ForegroundColor Cyan
        Write-Host "  1. Start VM (skipped if already running)" -ForegroundColor DarkGray
        Write-Host "  2. Wait for SSH + k3s + DB + operator webhook readiness" -ForegroundColor DarkGray
        Write-Host "  3. Start battlegroup" -ForegroundColor DarkGray
        Write-Host "  4. Wait for overmap and survival map pods to be Ready" -ForegroundColor DarkGray
        Write-Host ""
        $confirm = Read-Host "Type YES to continue"
        if ($confirm -ne "YES") { Write-Host "Aborted." -ForegroundColor Cyan; continue }

        $t0 = Get-Date

        # ---- Step 1: VM ----
        Write-Host ""
        if ($info.Running) {
            Write-Host "[1/4] VM '$vmName' already running ($($info.Ip))." -ForegroundColor Green
            $ip = $info.Ip
        } else {
            Write-Host "[1/4] Starting VM '$vmName'..." -ForegroundColor Cyan
            Start-VM -Name $vmName | Out-Null
            do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Running')
            Write-Host "  VM running. Waiting for IP..." -ForegroundColor DarkGray

            $newIp = $null; $timeout = 180; $elapsed = 0; $dots = 0
            while (-not $newIp -and $elapsed -lt $timeout) {
                $dots = ($dots % 3) + 1
                Write-Host -NoNewline ("`r  Waiting for IP$('.' * $dots)   ")
                Start-Sleep -Seconds 1; $elapsed += 1
                $newIp = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                          Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            }
            Write-Host ""
            if (-not $newIp) { Write-Warning "VM did not acquire IP within ${timeout}s. Aborting."; continue }
            $ip = $newIp
            Write-Host "  VM IP: $ip" -ForegroundColor Green
        }

        # ---- Step 2: SSH + cluster readiness ----
        Write-Host ""
        Write-Host "[2/4] Waiting for cluster readiness..." -ForegroundColor Cyan

        # 2a. SSH responsive
        $elapsed = 0; $sshReady = $false
        while ($elapsed -lt 180) {
            $probe = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=3 -i "$sshKey" "$sshUser@$ip" "echo ok" 2>$null
            if ($probe -match 'ok') { $sshReady = $true; break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        if (-not $sshReady) { Write-Warning "SSH not responsive after 180s. Aborting."; continue }
        Write-Host "  SSH responsive (${elapsed}s)." -ForegroundColor Green

        # 2b. k3s API
        Write-Host "  Waiting for k3s API..." -ForegroundColor DarkGray
        $elapsed = 0
        while ($elapsed -lt 180) {
            $apiOk = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get --raw='/readyz' 2>/dev/null"
            if ($apiOk -match 'ok') { break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        Write-Host "  k3s API ready (${elapsed}s)." -ForegroundColor Green

        # 2c. DB pod(s) Ready (auto-discover namespace)
        Write-Host "  Waiting for DB pod(s) Ready..." -ForegroundColor DarkGray
        $dbNs = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ {print `$1}' | sort -u | head -1"
        $dbNs = ($dbNs | Out-String).Trim()
        if ($dbNs) {
            ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl wait --for=condition=Ready pods --all -n '$dbNs' --timeout=180s 2>&1 | tail -n 3"
            Write-Host "  DB pods Ready (namespace: $dbNs)." -ForegroundColor Green
        } else {
            Write-Host "  No dedicated DB namespace detected - skipping." -ForegroundColor DarkGray
        }

        # 2d. operator pods Ready
        Write-Host "  Waiting for operator pods Ready..." -ForegroundColor DarkGray
        ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl wait --for=condition=Ready pods --all -n funcom-operators --timeout=180s 2>&1 | tail -n 5"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Operator pods did not become Ready within 180s. Aborting battlegroup start."
            continue
        }

        # 2e. webhook Service endpoints
        Write-Host "  Waiting for webhook Service endpoints..." -ForegroundColor DarkGray
        $elapsed = 0; $epReady = $false
        while ($elapsed -lt 120) {
            $epOut = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl -n funcom-operators get endpoints battlegroupoperator-webhook-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null"
            if ($epOut -match '\d+\.\d+\.\d+\.\d+') { $epReady = $true; break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        if (-not $epReady) {
            Write-Warning "battlegroupoperator-webhook-svc has no endpoints after 120s. Aborting."
            continue
        }
        Write-Host "  Webhook endpoints populated (${elapsed}s). Settling 10s..." -ForegroundColor Green
        Start-Sleep -Seconds 10

        # ---- Step 3: battlegroup start ----
        Write-Host ""
        Write-Host "[3/4] Starting battlegroup..." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath start"

        # ---- Step 4: wait for map pods ----
        Write-Host ""
        Write-Host "[4/4] Waiting for map pods to be Ready..." -ForegroundColor Cyan
        $mapResults = @{}
        foreach ($map in 'overmap','survival') {
            Write-Host "  Waiting for $map pod (timeout 300s)..." -ForegroundColor DarkGray
            $r = Wait-MapPodReady -Ip $ip -MapName $map -TimeoutSec 300
            $mapResults[$map] = $r
            if ($r.Success) {
                Write-Host "  $map -> $($r.Pod) is Ready ($($r.Ready)) in $($r.Elapsed)s" -ForegroundColor Green
            } else {
                if ($r.Pod) {
                    Write-Warning "  $map ($($r.Pod)) did not become Ready within $($r.Elapsed)s (last seen: $($r.LastStatus))"
                } else {
                    Write-Warning "  $map pod was never found within $($r.Elapsed)s"
                }
            }
        }

        $totalSec = [int]((Get-Date) - $t0).TotalSeconds
        Write-Host ""
        $allOk = ($mapResults.Values | Where-Object { -not $_.Success } | Measure-Object).Count -eq 0
        if ($allOk) {
            Write-Host "=== Startup complete in ${totalSec}s (overmap + survival Ready) ===" -ForegroundColor Green
        } else {
            Write-Host "=== Startup finished in ${totalSec}s with WARNINGS - see above ===" -ForegroundColor Yellow
            Write-Host "Use 'status' (1) or 'shell-pod' (16) to investigate any map that didn't reach Ready." -ForegroundColor DarkGray
        }
        $directorPort = $null
        continue
    }

    if ($cmd -eq "graceful-reboot") {
        Write-Host ""
        Write-Host "=== Graceful Reboot ===" -ForegroundColor Cyan
        Write-Host "  1. Stop battlegroup (waits for game/mq/gateway/director pods to terminate)" -ForegroundColor DarkGray
        Write-Host "  2. Hard-stop and restart the VM" -ForegroundColor DarkGray
        Write-Host "  3. Start battlegroup again" -ForegroundColor DarkGray
        Write-Host ""
        if (-not (Confirm-NoPlayersOnline -ActionLabel "graceful-reboot")) {
            Write-Host "Aborted." -ForegroundColor Cyan; continue
        }

        # ---- Step 1: stop battlegroup ----
        Write-Host ""
        Write-Host "[1/3] Stopping battlegroup..." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath stop"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "battlegroup stop returned exit code $LASTEXITCODE. Aborting graceful-reboot."
            continue
        }

        # Wait for game/infra pods to fully terminate (only db/fb/operator pods should remain).
        # Pattern matches the dynamic Funcom pod families: sg-* (servers), mq-* (rabbitmq),
        # sgw-* (gateway), tr-* (traffic router), bgd-* (battlegroup director).
        Write-Host "  Waiting for pods to terminate..." -ForegroundColor DarkGray
        $waitStart = Get-Date
        $maxWaitSec = 360
        while ($true) {
            $remainRaw = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E '(-sg-|-mq-|-sgw-|-tr-|-bgd-)' | wc -l"
            $remain = ($remainRaw -replace '\D','')
            if (-not $remain) { $remain = '0' }
            $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
            if ($remain -eq '0') {
                Write-Host ("`r  All game/infra pods terminated after {0}s.{1}" -f $elapsed, (' ' * 30)) -ForegroundColor Green
                break
            }
            if ($elapsed -gt $maxWaitSec) {
                Write-Host ""
                Write-Warning "$remain pod(s) still present after ${maxWaitSec}s. Proceeding with VM restart anyway."
                break
            }
            Write-Host -NoNewline ("`r  $remain pod(s) still running... [${elapsed}s]" + (' ' * 10))
            Start-Sleep -Seconds 5
        }

        # ---- Step 2: VM restart ----
        Write-Host ""
        Write-Host "[2/3] Restarting VM '$vmName'..." -ForegroundColor Cyan
        Stop-VM -Name $vmName -Force | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Off')
        Write-Host "  VM stopped." -ForegroundColor Green
        Start-VM -Name $vmName | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Running')
        Write-Host "  VM running. Waiting for IP..." -ForegroundColor DarkGray

        $newIp = $null; $timeout = 180; $elapsed = 0; $dots = 0
        while (-not $newIp -and $elapsed -lt $timeout) {
            $dots = ($dots % 3) + 1
            Write-Host -NoNewline ("`r  Waiting for IP$('.' * $dots)   ")
            Start-Sleep -Seconds 1; $elapsed += 1
            $newIp = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses |
                      Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        }
        Write-Host ""
        if (-not $newIp) { Write-Warning "VM did not acquire IP within ${timeout}s. Aborting."; continue }
        $ip = $newIp
        Write-Host "  VM IP: $ip" -ForegroundColor Green

        # Wait for SSH to be responsive
        $elapsed = 0; $sshReady = $false
        while ($elapsed -lt 180) {
            $probe = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -o ConnectTimeout=3 -i "$sshKey" "$sshUser@$ip" "echo ok" 2>$null
            if ($probe -match 'ok') { $sshReady = $true; break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        if (-not $sshReady) { Write-Warning "SSH not responsive after 180s. Aborting."; continue }
        Write-Host "  SSH responsive after ${elapsed}s." -ForegroundColor Green

        # Wait for k3s API + DB + operator webhook to be FULLY ready.
        # "Pod Running" is not enough: the mutating webhook needs the operator
        # pod's Ready condition true AND its Service endpoints populated, otherwise
        # 'battlegroup start' fails with: 502 Bad Gateway from the API-server proxy.

        # 2a. k3s API responsive
        Write-Host "  Waiting for k3s API..." -ForegroundColor DarkGray
        $elapsed = 0
        while ($elapsed -lt 180) {
            $apiOk = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get --raw='/readyz' 2>/dev/null"
            if ($apiOk -match 'ok') { break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        Write-Host "  k3s API ready (${elapsed}s)." -ForegroundColor Green

        # 2b. DB pod(s) Ready (operator queries DB on startup). Auto-discover the namespace
        # since it varies by install (could be funcom-db, funcom-pg, default, or the bg namespace).
        Write-Host "  Waiting for DB pod(s) Ready..." -ForegroundColor DarkGray
        $dbNs = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | awk '`$2 ~ /(-db-|postgres|^pg-|-pg-)/ {print `$1}' | sort -u | head -1"
        $dbNs = ($dbNs | Out-String).Trim()
        if ($dbNs) {
            ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl wait --for=condition=Ready pods --all -n '$dbNs' --timeout=180s 2>&1 | tail -n 3"
            Write-Host "  DB pods Ready (namespace: $dbNs)." -ForegroundColor Green
        } else {
            Write-Host "  No dedicated DB namespace detected - skipping (operator readiness will catch DB issues)." -ForegroundColor DarkGray
        }

        # 2c. ALL funcom-operators pods Ready (not just Running)
        Write-Host "  Waiting for operator pods Ready..." -ForegroundColor DarkGray
        ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
            "sudo k3s kubectl wait --for=condition=Ready pods --all -n funcom-operators --timeout=180s 2>&1 | tail -n 5"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Operator pods did not become Ready within 180s. Aborting battlegroup start."
            continue
        }

        # 2d. Webhook Service must have endpoints populated, else API-server proxy returns 502
        Write-Host "  Waiting for webhook Service endpoints..." -ForegroundColor DarkGray
        $elapsed = 0; $epReady = $false
        while ($elapsed -lt 120) {
            $epOut = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl -n funcom-operators get endpoints battlegroupoperator-webhook-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null"
            if ($epOut -match '\d+\.\d+\.\d+\.\d+') { $epReady = $true; break }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        if (-not $epReady) {
            Write-Warning "battlegroupoperator-webhook-svc has no endpoints after 120s. Aborting."
            continue
        }
        Write-Host "  Webhook endpoints populated (${elapsed}s). Settling 10s..." -ForegroundColor Green
        Start-Sleep -Seconds 10

        # ---- Step 3: start battlegroup ----
        Write-Host ""
        Write-Host "[3/3] Starting battlegroup..." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath start"

        # Reset cached director port; it'll be resolved on next 'open-director'
        $directorPort = $null

        Write-Host ""
        Write-Host "=== Graceful reboot complete ===" -ForegroundColor Green
        Write-Host "Pods may take another 1-2 min to all reach Healthy. Check with 'status'." -ForegroundColor DarkGray
        continue
    }

    if ($cmd -eq "graceful-shutdown") {
        Write-Host ""
        Write-Host "=== Graceful Shutdown ===" -ForegroundColor Cyan
        Write-Host "  1. Stop battlegroup (waits for game/mq/gateway/director pods to terminate)" -ForegroundColor DarkGray
        Write-Host "  2. Power off the VM" -ForegroundColor DarkGray
        Write-Host "  Use this when shutting down for the night - player data is persisted to DB." -ForegroundColor DarkGray
        Write-Host ""
        if (-not (Confirm-NoPlayersOnline -ActionLabel "graceful-shutdown")) {
            Write-Host "Aborted." -ForegroundColor Cyan; continue
        }

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
        Write-Host "  Waiting for pods to terminate..." -ForegroundColor DarkGray
        $waitStart = Get-Date
        $maxWaitSec = 360
        while ($true) {
            $remainRaw = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo k3s kubectl get pods -A --no-headers 2>/dev/null | grep -E '(-sg-|-mq-|-sgw-|-tr-|-bgd-)' | wc -l"
            $remain = ($remainRaw -replace '\D','')
            if (-not $remain) { $remain = '0' }
            $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
            if ($remain -eq '0') {
                Write-Host ("`r  All game/infra pods terminated after {0}s.{1}" -f $elapsed, (' ' * 30)) -ForegroundColor Green
                break
            }
            if ($elapsed -gt $maxWaitSec) {
                Write-Host ""
                Write-Warning "$remain pod(s) still present after ${maxWaitSec}s. Proceeding with VM shutdown anyway."
                break
            }
            Write-Host -NoNewline ("`r  $remain pod(s) still running... [${elapsed}s]" + (' ' * 10))
            Start-Sleep -Seconds 5
        }

        # ---- Step 2: power off VM ----
        Write-Host ""
        Write-Host "[2/2] Stopping VM '$vmName'..." -ForegroundColor Cyan
        Stop-VM -Name $vmName -Force | Out-Null
        do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne 'Off')
        Write-Host "  VM stopped." -ForegroundColor Green

        # Invalidate cached director port + port-check results (no longer meaningful)
        $directorPort = $null
        $script:portCheckCache = $null

        Write-Host ""
        Write-Host "=== Graceful shutdown complete ===" -ForegroundColor Green
        Write-Host "Use option 'b. start-vm' (and then '2. start') when you're ready to bring it back up." -ForegroundColor DarkGray
        continue
    }

    if ($cmd -eq "rotate-ssh-key") {
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

    if ($cmd -eq "change-password") {
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

    if ($cmd -eq "open-file-browser") {
        Start-Process "http://${ip}:18888/"
        continue
    }

    if ($cmd -eq "open-director") {
        if (-not $directorPort) {
            $directorNodePort = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>&1"
            if ($directorNodePort -match '^\d+$') { $directorPort = $directorNodePort.Trim() }
        }
        if (-not $directorPort) { Write-Warning "Could not determine Director port."; continue }
        Start-Process "http://${ip}:${directorPort}/"
        continue
    }

    if ($cmd -eq "shell-vm") {
        Write-Host "Opening shell in the VM. Type 'exit' to return." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip"
        continue
    }

    if ($cmd -eq "shell-pod") {
        $bgPrefix = "funcom-seabass-"
        $nsList = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "sudo kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | grep '^$bgPrefix'"
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
        $podList = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "sudo kubectl get pods -n '$ns' --no-headers -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.role"
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

    if ($cmd -eq "edit-advanced") {
        Write-Host ""
        Write-Host "WARNING:" -ForegroundColor Red -NoNewline
        Write-Host " You are about to edit the live battlegroup YAML directly in Kubernetes." -ForegroundColor Yellow
        Write-Host "         Mistakes can permanently break the battlegroup." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Type YES to continue"
        if ($confirm -ne "YES") { Write-Host "Aborted." -ForegroundColor Cyan; continue }
    }

    if ($cmd -eq "logs-export") {
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

    if ($cmd -eq "operator-logs-export") {
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

    if ($cmd -eq "ssh") {
        Write-Host "Connecting to VM via SSH... Type 'exit' to return." -ForegroundColor Cyan
        ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip"
        continue
    }

    if ($cmd -eq "dune-admin") {
        Write-Host "Launching dune-admin.exe and web UI as $windowsUser..." -ForegroundColor Cyan
        $duneAdminDir = Split-Path $duneAdminExe -Parent
        $duneAdminName = Split-Path $duneAdminExe -Leaf
        # Launch as the logged-in user via scheduled task (avoids admin elevation)
        $action = New-ScheduledTaskAction -Execute $duneAdminExe -WorkingDirectory $duneAdminDir
        $principal = New-ScheduledTaskPrincipal -UserId $windowsUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName "DuneAdminLaunch" -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName "DuneAdminLaunch"
        Start-Sleep -Seconds 1
        Unregister-ScheduledTask -TaskName "DuneAdminLaunch" -Confirm:$false
        # Open web UI via explorer (always runs as logged-in user)
        Start-Process "$env:SystemRoot\explorer.exe" $duneAdminWeb
        Write-Host "Done. dune-admin.exe is running and web UI opened in browser." -ForegroundColor Green
        continue
    }

    if ($cmd -eq "setup-guide") {
        Start-Process "https://duneawakening.com/self-hosted-servers/"
        continue
    }

    # --- Fallback: delegate to battlegroup CLI on VM ---
    ssh -t -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" "$bgBinPath $cmd"

    # Battlegroup commands (status/start/restart/stop) can change observable
    # port state, so invalidate the cached external port-check results to
    # force a fresh check on the next menu render.
    $script:portCheckCache = $null

    # After start/restart, resolve director port
    if ($cmd -eq "start" -or $cmd -eq "restart") {
        $elapsed = 0; $timeout = 60
        while (-not $directorPort -and $elapsed -lt $timeout) {
            $directorNodePort = ssh -o StrictHostKeyChecking=no -o LogLevel=QUIET -i "$sshKey" "$sshUser@$ip" `
                "sudo kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>&1"
            if ($directorNodePort -match '^\d+$') { $directorPort = $directorNodePort.Trim() }
            else { Start-Sleep -Seconds 5; $elapsed += 5 }
        }
        if (-not $directorPort) { Write-Warning "Could not determine Director port after $timeout seconds." }
    }

    if ($Cmd) { break }
}

Stop-Transcript | Out-Null
