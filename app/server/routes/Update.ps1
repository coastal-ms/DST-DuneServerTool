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

        # IMPORTANT: respond to the client BEFORE we spawn anything. The
        # installer's PrepareToInstall hook runs `taskkill /F /IM
        # DuneServer.exe /T`, which kills this very process within a few
        # seconds of launch. If we wrote the JSON after Start-Process, the
        # response would race the kill and the browser would hang.
        Write-DuneJson -Response $res -Body @{
            launched        = $true
            installerPath   = $dest
            fromVersion     = $script:DuneToolVersion
            toVersion       = ($rel.tag -replace '^v','')
            note            = 'Installer launched silently. The portal will go offline briefly while the upgrade lays down new files, then the new DuneServer.exe will relaunch automatically.'
        }

        # Build a relauncher script that:
        #   1. Sleeps a few seconds so the HTTP response finishes flushing.
        #   2. Runs the installer with /VERYSILENT and waits for it.
        #   3. Launches the freshly-installed DuneServer.exe if (and only
        #      if) it isn't already running. The installer's [Run] entry
        #      should handle the relaunch (v6.1.14+ has a silent-mode
        #      entry), but this is belt-and-suspenders for upgrades from
        #      v6.1.13 where the installer's [Run] is skipifsilent-broken.
        #
        # The relauncher is launched via WMI Win32_Process.Create so its
        # parent in the process tree is WmiPrvSE.exe, NOT DuneServer.exe.
        # That detaches it from taskkill /T's kill list. (Start-Process or
        # Start-Job would keep DuneServer.exe as the parent and the
        # relauncher would die with us.)
        $installArgs   = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS'
        $logPath       = Join-Path $tmpDir ("relaunch-$safeTag.log")
        $appExeGuess1  = Join-Path ${env:ProgramFiles}        'Dune Server\DuneServer.exe'
        $appExeGuess2  = Join-Path ${env:ProgramFiles(x86)}   'Dune Server\DuneServer.exe'
        $relaunchScript = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$logPath' -Append | Out-Null
try {
    Start-Sleep -Seconds 3
    Write-Host "[$(Get-Date -Format o)] Launching installer: $dest"
    `$p = Start-Process -FilePath '$dest' -ArgumentList '$installArgs' -PassThru -Wait
    Write-Host "[`$(Get-Date -Format o)] Installer exited with code `$(`$p.ExitCode)"
    Start-Sleep -Seconds 2
    `$running = Get-Process -Name DuneServer -ErrorAction SilentlyContinue
    if (`$running) {
        Write-Host "[`$(Get-Date -Format o)] DuneServer.exe already running (PID=`$(`$running[0].Id)) - not relaunching."
    } else {
        foreach (`$exe in @('$appExeGuess1','$appExeGuess2')) {
            if (Test-Path -LiteralPath `$exe) {
                Write-Host "[`$(Get-Date -Format o)] Relaunching: `$exe"
                Start-Process -FilePath `$exe -WindowStyle Hidden
                break
            }
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

        try {
            $wmi = [WMICLASS]'\\.\root\cimv2:Win32_Process'
            $cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
            $null = $wmi.Create($cmd)
        } catch {
            # Last-ditch fallback: spawn in-tree. Relauncher will likely die
            # with us, but the installer's own [Run] silent-mode entry
            # (v6.1.14+) will still relaunch DuneServer.exe.
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$scriptPath) `
                -WindowStyle Hidden | Out-Null
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
