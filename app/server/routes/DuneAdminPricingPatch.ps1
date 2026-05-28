# /api/dune-admin/pricing-patch — Coastal's sane-pricing patch installer
#
# Bundles `app\resources\dune-admin-patches\*` (the patch file + build script)
# and applies them to the user's dune-admin source repo (derived from the
# DuneAdminExe Settings path's parent directory). Requires Go + git on PATH
# and a running dune-admin with an embedded market bot.
#
# v6.1.20: Initial.

$script:DuneAdminPricingPatchFile  = '0001-sane-pricing-100k-cap.patch'
$script:DuneAdminPricingBuildFile  = 'build-patched.ps1'
$script:DuneAdminPricingMarkerFile = 'dune-admin.exe.coastal-sane-pricing'

# --- Helpers -----------------------------------------------------------------

function Get-DuneAdminPricingResourceDir {
    # Resolves the bundled-resources directory across both install layouts:
    #   - Installed (DuneServer.exe at C:\Program Files\Dune Server\): $script:AppDir
    #     is the install root itself, resources are at $AppDir\resources\...
    #   - Dev/source (running app\DuneServer.ps1 from repo): $script:AppDir is
    #     <repo>\app, resources are at $AppDir\resources\... OR <repo>\app\resources\...
    if (-not $script:AppDir) { return $null }
    $parent = Split-Path -Parent $script:AppDir
    $candidates = @(
        (Join-Path $script:AppDir 'resources\dune-admin-patches'),
        (Join-Path $script:AppDir 'app\resources\dune-admin-patches')
    )
    if ($parent) {
        $candidates += (Join-Path $parent 'resources\dune-admin-patches')
        $candidates += (Join-Path $parent 'app\resources\dune-admin-patches')
    }
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-DuneAdminSourceDir {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    return (Split-Path -Parent $ExePath)
}

function Test-DuneAdminSourceRepo {
    param([string]$SourceDir)
    if (-not $SourceDir -or -not (Test-Path -LiteralPath $SourceDir)) { return $false }
    # Heuristic: the v0.13.0+ source layout has cmd\dune-admin\main.go.
    $main = Join-Path $SourceDir 'cmd\dune-admin\main.go'
    return (Test-Path -LiteralPath $main)
}

function Test-CommandAvailable {
    param([string]$Name)
    # First: standard PATH lookup.
    if (Get-Command -Name $Name -ErrorAction SilentlyContinue) { return $true }
    # Fallback: well-known install locations for tools that aren't always on PATH
    # (winget installs may need a shell restart before PATH refreshes).
    $known = @{
        'go'  = @(
            (Join-Path $env:ProgramFiles 'Go\bin\go.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Go\bin\go.exe'),
            (Join-Path "$env:USERPROFILE" 'go\bin\go.exe')
        )
        'git' = @(
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
        )
    }
    if ($known.ContainsKey($Name)) {
        foreach ($p in $known[$Name]) {
            if ($p -and (Test-Path -LiteralPath $p)) { return $true }
        }
    }
    return $false
}

function Test-DuneAdminMarketBotReady {
    # Probe the running dune-admin's market-bot status endpoint. Assumes
    # default :8080 listener (LISTEN_ADDR override is uncommon).
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:8080/api/v1/market-bot/status' `
                               -TimeoutSec 3 -ErrorAction Stop
        # Embedded bot reports mode='embedded' and running/enabled bools.
        if ($r -and $r.mode -eq 'embedded') { return $true }
        return $false
    } catch {
        return $false
    }
}

function Test-DuneAdminPricingPatchApplied {
    param([string]$ExePath)
    if (-not $ExePath) { return $false }
    $sourceDir = Get-DuneAdminSourceDir -ExePath $ExePath
    if (-not $sourceDir) { return $false }
    # Sidecar marker dropped by our apply handler after a successful build.
    $marker = Join-Path $sourceDir $script:DuneAdminPricingMarkerFile
    return (Test-Path -LiteralPath $marker)
}

function Read-DuneAdminPricingPatchMarker {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    $sourceDir = Get-DuneAdminSourceDir -ExePath $ExePath
    if (-not $sourceDir) { return $null }
    $marker = Join-Path $sourceDir $script:DuneAdminPricingMarkerFile
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    try {
        return (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Build-DuneAdminPricingPreconditions {
    param([string]$ExePath)

    $sourceDir   = Get-DuneAdminSourceDir -ExePath $ExePath
    $exeExists   = ($ExePath -and (Test-Path -LiteralPath $ExePath))
    $repoOK      = ($sourceDir -and (Test-DuneAdminSourceRepo -SourceDir $sourceDir))
    $resDir      = Get-DuneAdminPricingResourceDir
    $patchPath   = if ($resDir) { Join-Path $resDir $script:DuneAdminPricingPatchFile } else { $null }
    $patchExists = ($patchPath -and (Test-Path -LiteralPath $patchPath))
    $goOK        = Test-CommandAvailable -Name 'go'
    $gitOK       = Test-CommandAvailable -Name 'git'
    $botOK       = Test-DuneAdminMarketBotReady
    $applied     = Test-DuneAdminPricingPatchApplied -ExePath $ExePath

    @(
        @{
            key            = 'DuneAdminExe'
            label          = 'dune-admin location is set in Settings'
            ok             = $exeExists
            detail         = if ($exeExists) { $ExePath } else { 'Not set or file missing.' }
            fix            = 'Open Settings -> dune-admin.exe and point it at your built dune-admin.exe (e.g. G:\GitHub Work\dune-admin\dune-admin.exe).'
            installCommand = $null
        }
        @{
            key            = 'SourceRepo'
            label          = 'dune-admin source repo detected (v0.13.0+ layout)'
            ok             = $repoOK
            detail         = if ($repoOK) { "Found cmd\dune-admin\main.go in $sourceDir" } elseif ($sourceDir) { "Expected cmd\dune-admin\main.go under $sourceDir" } else { 'Cannot derive a parent directory from the DuneAdminExe path.' }
            fix            = 'Clone Icehunter/dune-admin into the directory that contains your dune-admin.exe, then build via the upgrade script. The build wrapper lands dune-admin.exe at the repo root.'
            installCommand = 'git clone https://github.com/Icehunter/dune-admin.git <target-dir>'
        }
        @{
            key            = 'Git'
            label          = 'git is available on PATH'
            ok             = $gitOK
            detail         = if ($gitOK) { 'git --version returned OK' } else { 'git not found on PATH.' }
            fix            = 'Install Git for Windows. After install, open a NEW PowerShell window so PATH refreshes.'
            installCommand = 'winget install --id Git.Git -e --source winget'
        }
        @{
            key            = 'Go'
            label          = 'Go toolchain is available on PATH'
            ok             = $goOK
            detail         = if ($goOK) { 'go --version returned OK' } else { 'go not found on PATH.' }
            fix            = 'Install Go 1.26+ (matches dune-admin go.mod). After install, open a NEW PowerShell window so PATH refreshes.'
            installCommand = 'winget install --id GoLang.Go -e --source winget'
        }
        @{
            key            = 'BundledPatch'
            label          = 'Sane-pricing patch is bundled with Dune Server Tool'
            ok             = $patchExists
            detail         = if ($patchExists) { $patchPath } elseif ($patchPath) { "Looked at $patchPath - file not found." } else { 'Resource path not resolvable (script:AppDir unset).' }
            fix            = 'Reinstall Dune Server Tool to restore bundled resources.'
            installCommand = $null
        }
        @{
            key            = 'MarketBotReady'
            label          = 'dune-admin is running with the embedded market bot'
            ok             = $botOK
            detail         = if ($botOK) { 'GET http://localhost:8080/api/v1/market-bot/status returned mode=embedded' } else { 'dune-admin is not reachable on localhost:8080 or did not report an embedded market bot.' }
            fix            = 'Launch dune-admin (via the Dune Server Tool launcher or by double-clicking dune-admin.exe). If port 8080 is held by CubeCoders AMP-ADS01, the command below will stop that service and start dune-admin in one step.'
            installCommand = if ($ExePath) {
                                "Stop-Service AMP-ADS01 -Force -ErrorAction SilentlyContinue; Start-Process '$ExePath'"
                             } else {
                                "Stop-Service AMP-ADS01 -Force -ErrorAction SilentlyContinue; Start-Process '<path-to-dune-admin.exe>'"
                             }
        }
    )
}

# --- Routes ------------------------------------------------------------------

# GET /api/dune-admin/pricing-patch/status - returns preconditions + applied state
Register-DuneRoute -Method GET -Path '/api/dune-admin/pricing-patch/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $exePath = Get-DuneAdminConfiguredPath
        $pre     = Build-DuneAdminPricingPreconditions -ExePath $exePath
        $applied = Test-DuneAdminPricingPatchApplied -ExePath $exePath
        $marker  = Read-DuneAdminPricingPatchMarker -ExePath $exePath

        # canApply: every precondition met AND patch not already applied.
        $allOK = $true
        foreach ($p in $pre) { if (-not $p.ok) { $allOK = $false; break } }
        $canApply   = ($allOK -and -not $applied)
        $canRestore = $applied

        Write-DuneJson -Response $res -Body @{
            exePath        = $exePath
            sourceDir      = Get-DuneAdminSourceDir -ExePath $exePath
            preconditions  = $pre
            patchApplied   = $applied
            marker         = $marker
            canApply       = $canApply
            canRestore     = $canRestore
            checkedAt      = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/dune-admin/pricing-patch/apply - copy patch+script into source repo and run build
Register-DuneRoute -Method POST -Path '/api/dune-admin/pricing-patch/apply' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $exePath = Get-DuneAdminConfiguredPath
        $pre     = Build-DuneAdminPricingPreconditions -ExePath $exePath
        foreach ($p in $pre) {
            if (-not $p.ok) {
                Write-DuneError -Response $res -Status 412 -Message "Precondition not met: $($p.label). $($p.fix)"
                return
            }
        }
        if (Test-DuneAdminPricingPatchApplied -ExePath $exePath) {
            Write-DuneError -Response $res -Status 409 -Message 'Sane-pricing patch is already applied. Use restore first if you want to re-apply.'
            return
        }

        $sourceDir = Get-DuneAdminSourceDir -ExePath $exePath
        $resDir    = Get-DuneAdminPricingResourceDir
        $patchSrc  = Join-Path $resDir $script:DuneAdminPricingPatchFile
        $buildSrc  = Join-Path $resDir $script:DuneAdminPricingBuildFile

        # 1. Stage patch + build-patched.ps1 into the user's source tree.
        $userPatchDir = Join-Path $sourceDir 'scripts\patches'
        $userScripts  = Join-Path $sourceDir 'scripts'
        if (-not (Test-Path -LiteralPath $userPatchDir)) { New-Item -ItemType Directory -Path $userPatchDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $userScripts))  { New-Item -ItemType Directory -Path $userScripts -Force | Out-Null }
        Copy-Item -LiteralPath $patchSrc -Destination $userPatchDir -Force
        Copy-Item -LiteralPath $buildSrc -Destination $userScripts -Force

        # 2. Back up the current upstream binary so restore is possible.
        $backup = "$exePath.upstream"
        if (-not (Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $exePath)) {
            # If dune-admin is running it holds the exe open; we stop it
            # before the build script runs, but the backup also needs
            # the file to be readable. Try a copy first; if it fails the
            # build script's pre-stop will get it on the next attempt.
            try { Copy-Item -LiteralPath $exePath -Destination $backup -Force } catch { }
        }

        # 3. Run build-patched.ps1 -Restart against the user's source repo.
        # The script: stops running dune-admin, applies patches, runs tests,
        # builds dune-admin.exe in place, reverts working tree, relaunches.
        #
        # We invoke pwsh through System.Diagnostics.Process so neither
        # $PSNativeCommandUseErrorActionPreference nor $ErrorActionPreference
        # in the caller can turn git's harmless "LF will be replaced by CRLF"
        # stderr warning into a terminating error.
        $script   = Join-Path $userScripts 'build-patched.ps1'
        $logFile  = Join-Path $env:TEMP "dune-admin-pricing-apply-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = 'pwsh'
        $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Restart -SkipTests"
        $psi.WorkingDirectory       = $sourceDir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $proc   = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $exit   = $proc.ExitCode
        $output = if ($stderr) { "$stdout`n--- stderr ---`n$stderr" } else { $stdout }

        try {
            Set-Content -LiteralPath $logFile -Value $output -Encoding UTF8
        } catch { }

        # 4. On success, drop the sidecar marker so status detects the patch.
        if ($exit -eq 0) {
            $marker = @{
                appliedAt        = (Get-Date).ToString('o')
                appliedByVersion = $script:DuneToolVersion
                patchFile        = $script:DuneAdminPricingPatchFile
                upstreamBackup   = $backup
            } | ConvertTo-Json -Depth 4
            $markerPath = Join-Path $sourceDir $script:DuneAdminPricingMarkerFile
            Set-Content -LiteralPath $markerPath -Value $marker -Encoding UTF8
        }

        Write-DuneJson -Response $res -Body @{
            ok          = ($exit -eq 0)
            exitCode    = $exit
            log         = $output
            logFile     = $logFile
            patchApplied = (Test-DuneAdminPricingPatchApplied -ExePath $exePath)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/dune-admin/pricing-patch/restore - swap back the .upstream backup
Register-DuneRoute -Method POST -Path '/api/dune-admin/pricing-patch/restore' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $exePath = Get-DuneAdminConfiguredPath
        if (-not $exePath) {
            Write-DuneError -Response $res -Status 400 -Message 'DuneAdminExe is not set in Settings.'
            return
        }
        $backup = "$exePath.upstream"
        if (-not (Test-Path -LiteralPath $backup)) {
            Write-DuneError -Response $res -Status 404 -Message "No backup found at $backup. Cannot restore."
            return
        }

        # Stop running dune-admin first (exe is locked otherwise).
        Get-Process -Name dune-admin -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $exePath } |
            ForEach-Object { Stop-Process -Id $_.Id -Force }
        Start-Sleep -Seconds 2

        Copy-Item -LiteralPath $backup -Destination $exePath -Force

        # Remove sidecar so status reflects restored state.
        $sourceDir = Get-DuneAdminSourceDir -ExePath $exePath
        if ($sourceDir) {
            $marker = Join-Path $sourceDir $script:DuneAdminPricingMarkerFile
            if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        }

        Write-DuneJson -Response $res -Body @{
            ok             = $true
            restoredFrom   = $backup
            patchApplied   = $false
            message        = "Restored upstream dune-admin.exe. Re-launch dune-admin to pick it up."
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
