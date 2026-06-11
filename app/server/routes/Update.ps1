# /api/update — GitHub release auto-update
#
# Polls the public GitHub Releases API for the latest tag, compares against
# the running $script:DuneToolVersion, and (on user click) downloads the
# installer asset and runs it silently. The installer's PrepareToInstall
# hook silently uninstalls the prior version before laying down the new
# files, so the Start Menu shortcut keeps working and %APPDATA%\DuneServer
# is preserved.

# --- Config ------------------------------------------------------------------

$script:DuneUpdateRepo  = 'coastal-ms/DST-DuneServerTool'
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
        # Strict: the release rule requires `DuneServerSetup.exe` as the sole
        # asset. Match it exactly. Do NOT fall back to "any *.exe" - that
        # masked malformed releases historically and conflicts with the
        # one-asset rule. If a release ships a differently-named installer
        # by mistake, the UI will correctly show "available, no installer
        # attached" with a release-page link, instead of silently treating
        # the wrong file as the installer.
        $asset = $rel.assets | Where-Object { $_.name -eq 'DuneServerSetup.exe' } | Select-Object -First 1
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
        # `available` means a newer release exists (independent of whether an
        # installer asset is attached). `installable` is the stricter flag:
        # newer release AND the installer .exe is uploaded so the in-app
        # auto-updater can actually run it.
        #
        # Background: every DST release MUST upload `DuneServerSetup.exe` as
        # its only asset (hard project rule). If a release is ever published
        # without one, we still want the UI to alert the user that an update
        # exists - just with a "no installer attached" notice and a link to
        # the release page instead of an "Update now" button. We do NOT want
        # the UI to silently report "up to date" while a newer tag is live;
        # that's what happened with v10.1.12 (shipped asset-less) and is the
        # bug this split fixes.
        $available    = ($diff -gt 0)
        $hasAsset     = -not [string]::IsNullOrEmpty($rel.assetUrl)
        $installable  = $available -and $hasAsset
        Write-DuneJson -Response $res -Body @{
            available       = $available
            installable     = $installable
            assetMissing    = ($available -and -not $hasAsset)
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
    # Serialize installs: never let two update flows download + relaunch at once.
    $updLock = Get-DuneLock -Name 'update-install'
    if (-not $updLock.Wait(0)) {
        Write-DuneError -Response $res -Status 409 -Message 'An update is already in progress.'
        return
    }
    try {
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
        # very process about 3 seconds later.
        Write-DuneJson -Response $res -Body @{
            launched        = $true
            installerPath   = $dest
            fromVersion     = $script:DuneToolVersion
            toVersion       = ($rel.tag -replace '^v','')
            note            = 'Updater launched. The Dune Server app and console will close in 3 seconds, then a silent update runs in the background. The app relaunches automatically when it finishes (usually under a minute).'
        }

        # Build a relauncher script that:
        #   1. Sleeps 3 seconds so the user sees the "Updater launched" toast
        #      and the HTTP response finishes flushing before the app vanishes.
        #   2. Force-kills DuneServer.exe by its known PID (this process),
        #      any sibling DuneServer instances, and DuneShell.exe (the app
        #      window). We do NOT use `taskkill /T` - that would also kill
        #      the relauncher (a child of DuneServer.exe). Killing the
        #      specific PID with Stop-Process leaves the relauncher orphaned
        #      but alive.
        #   3. Launches the installer SILENTLY (/VERYSILENT). The installer's
        #      [Run] WizardSilent entry (DuneServer.iss) then relaunches
        #      DuneServer.exe with `runminimized`, which in turn brings up
        #      DuneShell.exe. The whole update is invisible apart from the
        #      3-second portal-close pause.
        #   4. WaitForExit on the installer PID, then on non-zero exit /
        #      timeout shows a topmost WinForms MessageBox so the user has
        #      a real signal when something fails (the hidden powershell
        #      host has no other UI to surface errors).
        $parentPid       = $PID
        $installArgs     = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL'
        $logPath         = Join-Path $tmpDir ("relaunch-$safeTag.log")
        # Defensive escapes: %TEMP% / install path can contain an apostrophe
        # (e.g. C:\Users\O'Brien\AppData\...) which would break the single-
        # quoted literals embedded in the relauncher heredoc below.
        # PowerShell escapes ' as '' inside single-quoted strings.
        $destEsc         = $dest         -replace "'", "''"
        $installArgsEsc  = $installArgs  -replace "'", "''"
        $logPathEsc      = $logPath      -replace "'", "''"
        $relaunchScript = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$logPathEsc' -Append | Out-Null

function Show-DuneUpdateFailure {
    param([string]`$Title, [string]`$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        # Off-screen, transparent, topmost owner so the MessageBox actually
        # comes foreground even though the PowerShell host is hidden.
        `$owner = New-Object System.Windows.Forms.Form
        `$owner.FormBorderStyle = 'FixedToolWindow'
        `$owner.StartPosition   = 'Manual'
        `$owner.Location        = [System.Drawing.Point]::new(-32000, -32000)
        `$owner.Size            = [System.Drawing.Size]::new(1, 1)
        `$owner.ShowInTaskbar   = `$false
        `$owner.TopMost         = `$true
        `$owner.Opacity         = 0
        `$owner.Show()
        `$owner.Activate()
        [System.Windows.Forms.MessageBox]::Show(`$owner, `$Message, `$Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        try { `$owner.Close(); `$owner.Dispose() } catch {}
    } catch {}
}

try {
    Add-Type -Namespace DuneUpd -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool AllowSetForegroundWindow(int dwProcessId);
'@ -ErrorAction SilentlyContinue

    # 1-second grace between user clicking Update and the silent install
    # kicking off. Lets the HTTP response finish flushing so the "Updater
    # launched" toast renders in the portal before the app closes.
    # (v11.4.4: cut from 3s to 1s; v11.4.3 and earlier wasted ~2s here.)
    Start-Sleep -Seconds 1

    Write-Host "[`$(Get-Date -Format o)] Stopping DuneServer.exe (PID $parentPid)"
    Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
    # Sibling DuneServer instances + the standalone app window
    # (DuneShell.exe). Kill by .Id (no Stop-Process -Name).
    Get-Process -Name DuneServer -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name DuneShell -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
    }
    # Brief settle so WebView2 children and file handles in
    # C:\Program Files\Dune Server are released before Inno tries to
    # overwrite them under /VERYSILENT (no in-use retry prompt in silent
    # mode -- file-in-use just fails the install).
    # (v11.4.4: cut from 1s to 250ms. Stop-Process -Force is synchronous
    # on the kill signal; the remaining wait is for WebView2 helper
    # processes to drop their MPK handles, which is sub-100ms in
    # practice.)
    Start-Sleep -Milliseconds 250

    # Grant foreground rights to whatever we launch next (ASFW_ANY = -1)
    # so the post-install DuneServer.exe -> DuneShell.exe chain can take
    # focus when the new app window comes up.
    try { [DuneUpd.Win]::AllowSetForegroundWindow(-1) | Out-Null } catch {}

    Write-Host "[`$(Get-Date -Format o)] Launching installer silently: $destEsc"
    `$proc = Start-Process -FilePath '$destEsc' -ArgumentList '$installArgsEsc' -PassThru

    # Wait up to 5 minutes for the silent install to finish. Under
    # /VERYSILENT Inno runs the entire install + the [Run] WizardSilent
    # entry (which launches the new DuneServer.exe runminimized) and
    # then exits. We were spawned from an already-elevated DuneServer.exe,
    # so Inno runs in-place rather than re-elevating -- WaitForExit on
    # the spawned PID is meaningful end-to-end.
    if (-not `$proc.WaitForExit(300000)) {
        Write-Host "[`$(Get-Date -Format o)] Installer timed out after 5 minutes"
        try { Stop-Process -Id `$proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Show-DuneUpdateFailure -Title 'Dune Server Update Timed Out' -Message (
            "The silent installer did not finish within 5 minutes. The Dune Server app has been closed.``r``n``r``n" +
            "Log file:``r``n  $logPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } elseif (`$proc.ExitCode -ne 0) {
        `$code = `$proc.ExitCode
        Write-Host "[`$(Get-Date -Format o)] Installer exited with code `$code"
        Show-DuneUpdateFailure -Title 'Dune Server Update Failed' -Message (
            "The silent installer exited with code `$code. The Dune Server app has been closed.``r``n``r``n" +
            "Log file:``r``n  $logPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } else {
        Write-Host "[`$(Get-Date -Format o)] Silent install completed successfully (exit 0)"
    }
} catch {
    `$errMsg = `$_.Exception.Message
    Write-Host "[`$(Get-Date -Format o)] Relauncher error: `$errMsg"
    try {
        Show-DuneUpdateFailure -Title 'Dune Server Update Error' -Message (
            "The updater hit an unexpected error:``r``n  `$errMsg``r``n``r``n" +
            "Log file:``r``n  $logPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } catch {}
} finally {
    Stop-Transcript | Out-Null
}
"@
        $scriptPath = Join-Path $tmpDir ("DuneRelaunch-$safeTag.ps1")
        Set-Content -LiteralPath $scriptPath -Value $relaunchScript -Encoding UTF8

        # Spawn the relauncher in a HIDDEN window. No visible UI during the
        # silent update: the 3-second sleep, kill chain, /VERYSILENT install,
        # and post-install DuneServer.exe relaunch all happen in the
        # background. The only visible artifacts are the toast in the portal
        # before it closes and (on failure) the topmost MessageBox.
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -WindowStyle Hidden | Out-Null
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
      }
    } finally {
        [void]$updLock.Release()
    }
}
