# /api/update — GitHub release auto-update
#
# Polls the public GitHub Releases API for the latest tag, compares against
# the running $script:DuneToolVersion, and (on user click) downloads the
# installer asset and runs it silently. The installer's PrepareToInstall
# hook silently uninstalls the prior version before laying down the new
# files, so the Start Menu shortcut keeps working and %APPDATA%\DuneServer
# is preserved.

# --- Config ------------------------------------------------------------------

$script:DuneUpdateRepo  = 'coastal-ms/Simple-Dune-Server-Management-Tool'
$script:DuneUpdateUA    = 'DuneServerTool-Updater'
$script:DuneUpdateCache = $null    # cached release lookup (1 h TTL)

# --- Helpers -----------------------------------------------------------------

function Compare-DuneSemver {
    param([string]$A, [string]$B)
    $clean = { param($v) ($v -replace '^v','').Split('+')[0].Split('-')[0] }
    $pa = (& $clean $A).Split('.') | ForEach-Object { [int]($_ -as [int]) }
    $pb = (& $clean $B).Split('.') | ForEach-Object { [int]($_ -as [int]) }
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -ne $y) { return ($x - $y) }
    }
    return 0
}

function Get-DuneLatestRelease {
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    if (-not $Force -and $script:DuneUpdateCache -and
        ($now - $script:DuneUpdateCache.fetchedAt).TotalMinutes -lt 60) {
        return $script:DuneUpdateCache
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = $script:DuneUpdateUA; 'Accept' = 'application/vnd.github+json' }
        $uri = "https://api.github.com/repos/$($script:DuneUpdateRepo)/releases/latest"
        $rel = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        $asset = $rel.assets | Where-Object { $_.name -like 'DuneServerSetup*.exe' } | Select-Object -First 1
        if (-not $asset) {
            $asset = $rel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
        }
        $script:DuneUpdateCache = [pscustomobject]@{
            fetchedAt    = $now
            tag          = [string]$rel.tag_name
            name         = [string]$rel.name
            htmlUrl      = [string]$rel.html_url
            publishedAt  = [string]$rel.published_at
            releaseNotes = [string]$rel.body
            assetName    = if ($asset) { [string]$asset.name } else { $null }
            assetUrl     = if ($asset) { [string]$asset.browser_download_url } else { $null }
            assetSize    = if ($asset) { [int64]$asset.size } else { 0 }
        }
        return $script:DuneUpdateCache
    } catch {
        # Return a stub on failure so the UI can render a "couldn't check" state.
        return [pscustomobject]@{
            fetchedAt    = $now
            tag          = $null
            error        = $_.Exception.Message
        }
    }
}

# --- Routes ------------------------------------------------------------------

# GET /api/update/check[?force=1] — compare current vs latest release
Register-DuneRoute -Method GET -Path '/api/update/check' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $force = $false
        if ($req.QueryString['force']) {
            $force = ($req.QueryString['force'] -eq '1' -or $req.QueryString['force'] -eq 'true')
        }
        $rel     = Get-DuneLatestRelease -Force:$force
        $current = [string]$script:DuneToolVersion
        if (-not $rel -or $rel.error) {
            Write-DuneJson -Response $res -Body @{
                available       = $false
                currentVersion  = $current
                checkedAt       = (Get-Date).ToString('o')
                error           = $rel.error
            }
            return
        }
        $diff      = Compare-DuneSemver -A $rel.tag -B $current
        $available = ($diff -gt 0) -and ([string]::IsNullOrEmpty($rel.assetUrl) -eq $false)
        Write-DuneJson -Response $res -Body @{
            available       = $available
            currentVersion  = $current
            latestVersion   = ($rel.tag -replace '^v','')
            tagName         = $rel.tag
            releaseName     = $rel.name
            releaseUrl      = $rel.htmlUrl
            releaseNotes    = $rel.releaseNotes
            publishedAt     = $rel.publishedAt
            assetName       = $rel.assetName
            assetSize       = $rel.assetSize
            checkedAt       = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/update/install — download installer asset and run it silently
Register-DuneRoute -Method POST -Path '/api/update/install' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $rel = Get-DuneLatestRelease
        if (-not $rel -or -not $rel.assetUrl) {
            Write-DuneError -Response $res -Status 503 -Message 'No installer asset available on latest release.'
            return
        }
        $diff = Compare-DuneSemver -A $rel.tag -B ([string]$script:DuneToolVersion)
        if ($diff -le 0) {
            Write-DuneJson -Response $res -Body @{
                launched = $false
                reason   = 'Already up to date.'
                currentVersion = $script:DuneToolVersion
                latestVersion  = ($rel.tag -replace '^v','')
            }
            return
        }

        $tmpDir = Join-Path $env:TEMP 'DuneServerUpdate'
        if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
        $safeTag = ($rel.tag -replace '[^A-Za-z0-9._-]','_')
        $dest    = Join-Path $tmpDir ("DuneServerSetup-$safeTag.exe")

        # Download to disk. Skip re-download if size already matches.
        $need = $true
        if (Test-Path -LiteralPath $dest) {
            $existing = (Get-Item -LiteralPath $dest).Length
            if ($rel.assetSize -gt 0 -and $existing -eq $rel.assetSize) { $need = $false }
        }
        if ($need) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $headers = @{ 'User-Agent' = $script:DuneUpdateUA }
            Invoke-WebRequest -Uri $rel.assetUrl -Headers $headers -OutFile $dest -TimeoutSec 300 -UseBasicParsing
        }

        if (-not (Test-Path -LiteralPath $dest)) {
            Write-DuneError -Response $res -Status 500 -Message "Download failed: $dest not present after fetch."
            return
        }

        # Respond to the client FIRST so the browser sees confirmation
        # before we tear ourselves down. The relauncher below kills this
        # very process within a few seconds.
        Write-DuneJson -Response $res -Body @{
            launched        = $true
            installerPath   = $dest
            fromVersion     = $script:DuneToolVersion
            toVersion       = ($rel.tag -replace '^v','')
            note            = 'Updater launched. The portal will close, the installer wizard will open - click through it normally, then the new DuneServer.exe will start automatically from the installer''s Finish page.'
        }

        # Build a relauncher script that:
        #   1. Sleeps briefly so the HTTP response above finishes flushing.
        #   2. Force-kills DuneServer.exe by its known PID (this process).
        #      We do NOT use `taskkill /T` - that would also kill the
        #      relauncher (which is a child of DuneServer.exe). Killing the
        #      specific PID with Stop-Process leaves the relauncher
        #      orphaned but alive.
        #   3. Launches the installer in NORMAL interactive mode (NOT
        #      /VERYSILENT). The user sees the wizard, clicks through, and
        #      the installer's standard "Launch Dune Server" checkbox on
        #      the Finished page handles the relaunch. No silent-mode race
        #      conditions, no detached relauncher needed for the launch
        #      itself - just the standard postinstall [Run] entry.
        $parentPid     = $PID
        $installArgs   = '/SP- /NORESTART'
        $logPath       = Join-Path $tmpDir ("relaunch-$safeTag.log")
        # NOTE: relauncher window is intentionally VISIBLE (not hidden).
        # A hidden parent powershell has no foreground rights, so the
        # installer wizard it spawns lands BEHIND other windows. With a
        # visible parent we also pre-grant ASFW_ANY via
        # AllowSetForegroundWindow and then explicitly raise the
        # installer's main window once it appears - so the wizard is
        # the first thing the user sees when they click Update.
        $relaunchScript = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$logPath' -Append | Out-Null
try {
    `$Host.UI.RawUI.WindowTitle = 'Dune Server - Installing update...'
    Write-Host ''
    Write-Host '  Dune Server Management Tool' -ForegroundColor Cyan
    Write-Host '  ----------------------------' -ForegroundColor Cyan
    Write-Host '  Update in progress. The installer wizard will appear in a few seconds.'
    Write-Host '  This window will close automatically when the installer is launched.'
    Write-Host ''

    Add-Type -Namespace DuneUpd -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool AllowSetForegroundWindow(int dwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool BringWindowToTop(System.IntPtr hWnd);
'@ -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    Write-Host "[`$(Get-Date -Format o)] Stopping DuneServer.exe (PID $parentPid)"
    Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    # Belt-and-suspenders - if a sibling instance is still alive, take it
    # down too. Each by explicit Id (no Stop-Process -Name to satisfy any
    # tooling that forbids name-based kills).
    Get-Process -Name DuneServer -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1

    # Grant foreground rights to whatever we launch next (ASFW_ANY = -1).
    try { [DuneUpd.Win]::AllowSetForegroundWindow(-1) | Out-Null } catch {}

    Write-Host "[`$(Get-Date -Format o)] Launching installer: $dest"
    `$proc = Start-Process -FilePath '$dest' -ArgumentList '$installArgs' -PassThru

    # Wait for the installer wizard window and force it to the top.
    # The installer goes through UAC consent first, so MainWindowHandle
    # may take a few seconds to populate. Try for up to 30 seconds.
    `$deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt `$deadline) {
        Start-Sleep -Milliseconds 250
        # Re-query: under UAC, the originally spawned proc may exit
        # quickly while the elevated child becomes the real installer.
        `$cand = Get-Process -Name 'DuneServerSetup','DuneServerSetup-*' -ErrorAction SilentlyContinue |
                 Where-Object { `$_.MainWindowHandle -ne 0 } |
                 Sort-Object StartTime -Descending |
                 Select-Object -First 1
        if (-not `$cand -and `$proc) {
            try { `$proc.Refresh() } catch {}
            if (`$proc.MainWindowHandle -ne 0) { `$cand = `$proc }
        }
        if (`$cand) {
            try {
                [DuneUpd.Win]::AllowSetForegroundWindow(`$cand.Id) | Out-Null
                [DuneUpd.Win]::ShowWindowAsync(`$cand.MainWindowHandle, 9) | Out-Null  # SW_RESTORE
                [DuneUpd.Win]::BringWindowToTop(`$cand.MainWindowHandle) | Out-Null
                [DuneUpd.Win]::SetForegroundWindow(`$cand.MainWindowHandle) | Out-Null
                Write-Host "[`$(Get-Date -Format o)] Raised installer window (PID `$(`$cand.Id))."
            } catch {}
            break
        }
    }
} catch {
    Write-Host "[`$(Get-Date -Format o)] Relauncher error: `$(`$_.Exception.Message)"
} finally {
    Stop-Transcript | Out-Null
}
"@
        $scriptPath = Join-Path $tmpDir ("DuneRelaunch-$safeTag.ps1")
        Set-Content -LiteralPath $scriptPath -Value $relaunchScript -Encoding UTF8

        # Spawn the relauncher in a VISIBLE (minimized-ok-but-not-hidden)
        # window. A visible parent gets foreground rights, which it then
        # passes to the installer via AllowSetForegroundWindow. The
        # window briefly shows an "Installing update..." banner so the
        # user has clear feedback that something is happening between
        # the portal closing and the wizard appearing.
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -WindowStyle Normal | Out-Null
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
