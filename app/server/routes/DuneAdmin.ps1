# /api/dune-admin - dune-admin.exe updater (third-party companion tool)
#
# Checks GitHub releases for Icehunter/dune-admin, compares against the
# installed dune-admin.exe (path from DuneAdminExe in dune-server.config),
# downloads the windows_amd64 zip asset and replaces the EXE + sibling
# files in place. Writes a sidecar "<exe>.version" file alongside the
# binary so we have a reliable current-version readout next time (Go
# binaries built with goreleaser do not populate Win32 FileVersionInfo).

# --- Config ------------------------------------------------------------------

$script:DuneAdminRepo  = 'Icehunter/dune-admin'
$script:DuneAdminUA    = 'DuneServerTool-DuneAdmin-Updater'
$script:DuneAdminCache = $null    # cached release lookup (1 h TTL)

# --- Semver compare (mirrors Compare-DuneSemver in Update.ps1) ---------------

function Compare-DuneAdminSemver {
    param([string]$A, [string]$B)
    $clean = { param($v) ($v -replace '^v','').Split('+')[0].Split('-')[0] }
    $sa = (& $clean $A); $sb = (& $clean $B)
    if (-not $sa) { $sa = '0' }
    if (-not $sb) { $sb = '0' }
    $pa = $sa.Split('.') | ForEach-Object { [int]($_ -as [int]) }
    $pb = $sb.Split('.') | ForEach-Object { [int]($_ -as [int]) }
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -ne $y) { return ($x - $y) }
    }
    return 0
}

# --- Helpers -----------------------------------------------------------------

function Get-DuneAdminConfiguredPath {
    $cfg = Read-DuneConfig
    if ($cfg.Contains('DuneAdminExe')) { return [string]$cfg['DuneAdminExe'] }
    return ''
}

function Get-DuneAdminSidecarPath {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    return "$ExePath.version"
}

function Get-DuneAdminInstalledVersion {
    param([string]$ExePath)
    $info = [pscustomobject]@{
        path           = $ExePath
        exists         = $false
        version        = $null
        versionSource  = $null   # 'sidecar' | 'fileinfo' | 'unknown'
        fileSize       = 0
        lastWriteTime  = $null
    }
    if (-not $ExePath) { return $info }
    if (-not (Test-Path -LiteralPath $ExePath)) { return $info }
    $info.exists = $true
    try {
        $f = Get-Item -LiteralPath $ExePath
        $info.fileSize       = [int64]$f.Length
        $info.lastWriteTime  = $f.LastWriteTimeUtc.ToString('o')
    } catch { }

    # Preferred: sidecar file written by our updater.
    $side = Get-DuneAdminSidecarPath -ExePath $ExePath
    if ($side -and (Test-Path -LiteralPath $side)) {
        try {
            $raw = (Get-Content -LiteralPath $side -Raw -ErrorAction Stop).Trim()
            if ($raw) {
                $info.version       = $raw
                $info.versionSource = 'sidecar'
                return $info
            }
        } catch { }
    }

    # Fallback: Win32 FileVersionInfo. Usually empty for Go binaries but
    # if a future build embeds it we will pick it up automatically.
    try {
        $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
        $candidates = @($fvi.ProductVersion, $fvi.FileVersion) | Where-Object {
            $_ -and ($_ -match '\d')
        }
        if ($candidates.Count -gt 0) {
            $info.version       = ($candidates | Select-Object -First 1).Trim()
            $info.versionSource = 'fileinfo'
            return $info
        }
    } catch { }

    $info.versionSource = 'unknown'
    return $info
}

function Save-DuneAdminVersionSidecar {
    param([string]$ExePath, [string]$Tag)
    $side = Get-DuneAdminSidecarPath -ExePath $ExePath
    if (-not $side) { return }
    try {
        Set-Content -LiteralPath $side -Value $Tag -Encoding UTF8 -Force
    } catch { }
}

function Get-DuneAdminLatestRelease {
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    if (-not $Force -and $script:DuneAdminCache -and
        ($now - $script:DuneAdminCache.fetchedAt).TotalMinutes -lt 60) {
        return $script:DuneAdminCache
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = $script:DuneAdminUA; 'Accept' = 'application/vnd.github+json' }
        $uri = "https://api.github.com/repos/$($script:DuneAdminRepo)/releases/latest"
        $rel = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop

        # Prefer the windows amd64 zip. Fall back to anything matching
        # *windows*.zip in case the asset naming changes.
        $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows.*amd64.*\.zip$' } | Select-Object -First 1
        if (-not $asset) {
            $asset = $rel.assets | Where-Object { $_.name -match '(?i)windows.*\.zip$' } | Select-Object -First 1
        }

        # GoReleaser also publishes a "<repo>_<version>_source.tar.gz" asset
        # containing the Go source tree. We use this to keep the user's source
        # repo in sync with the running binary so the sane-pricing patch can
        # be rebuilt on top after each upgrade.
        $srcAsset = $rel.assets | Where-Object { $_.name -match '(?i)_source\.tar\.gz$' } | Select-Object -First 1

        $script:DuneAdminCache = [pscustomobject]@{
            fetchedAt     = $now
            tag           = [string]$rel.tag_name
            name          = [string]$rel.name
            htmlUrl       = [string]$rel.html_url
            publishedAt   = [string]$rel.published_at
            releaseNotes  = [string]$rel.body
            assetName     = if ($asset) { [string]$asset.name } else { $null }
            assetUrl      = if ($asset) { [string]$asset.browser_download_url } else { $null }
            assetSize     = if ($asset) { [int64]$asset.size } else { 0 }
            sourceName    = if ($srcAsset) { [string]$srcAsset.name } else { $null }
            sourceUrl     = if ($srcAsset) { [string]$srcAsset.browser_download_url } else { $null }
            sourceSize    = if ($srcAsset) { [int64]$srcAsset.size } else { 0 }
        }
        return $script:DuneAdminCache
    } catch {
        return [pscustomobject]@{
            fetchedAt = $now
            tag       = $null
            error     = $_.Exception.Message
        }
    }
}

function Test-DuneAdminFileLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

# Sync the source tarball into the user's dune-admin source dir. GoReleaser
# tarballs contain a single top-level directory (e.g. "dune-admin-0.14.0/").
# We extract via the Windows-bundled `tar` (10+), locate the inner directory
# by hunting for go.mod, then overlay all files onto $TargetDir without
# touching .git/, dune-admin.exe, .upstream/.old backups, the sane-pricing
# marker, or anything under scripts/patches/ (where our staged patch lives).
function Sync-DuneAdminSourceTarball {
    param(
        [string]$ZipPath,    # actually a .tar.gz despite the param name
        [string]$ExtractDir, # fresh temp dir for the extract
        [string]$TargetDir   # the user's dune-admin source repo dir
    )
    $result = [pscustomobject]@{
        ok          = $false
        copiedCount = 0
        sourceRoot  = $null
        skipped     = @()
        error       = $null
    }
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        $result.error = "Source tarball missing: $ZipPath"
        return $result
    }
    try {
        if (Test-Path -LiteralPath $ExtractDir) {
            Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

        # Windows 10+ ships tar.exe. Use it directly.
        $tarExe = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
        if (-not $tarExe) {
            $result.error = 'tar.exe not found on PATH (Windows 10+ ships it). Cannot extract source tarball.'
            return $result
        }
        $p = Start-Process -FilePath $tarExe -ArgumentList @('-xzf', $ZipPath, '-C', $ExtractDir) -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) {
            $result.error = "tar -xzf exited with code $($p.ExitCode)"
            return $result
        }

        # Find the source root by locating go.mod.
        $goMod = Get-ChildItem -Path $ExtractDir -Recurse -Filter 'go.mod' -File -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if (-not $goMod) {
            $result.error = "go.mod not found in extracted tarball under $ExtractDir"
            return $result
        }
        $srcRoot = $goMod.Directory.FullName
        $result.sourceRoot = $srcRoot

        # Skip-list: never overlay these.
        $skip = @('.git', 'dune-admin.exe', 'dune-admin.exe.old', 'dune-admin.exe.upstream',
                  'dune-admin.exe.version', 'dune-admin.exe.coastal-sane-pricing',
                  'market bot cache')

        # Use robocopy for the overlay — it handles long paths, copies only
        # changed files, preserves attributes. /XD excludes whole directories
        # (.git/, market bot cache/), /XF excludes files by name.
        $robocopyArgs = @($srcRoot, $TargetDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
        foreach ($name in $skip) {
            if ($name -match '\.') {
                $robocopyArgs += @('/XF', $name)
            } else {
                $robocopyArgs += @('/XD', (Join-Path $TargetDir $name))
            }
        }
        & robocopy @robocopyArgs | Out-Null
        # robocopy exit codes 0-7 indicate success; >=8 indicates failure.
        if ($LASTEXITCODE -ge 8) {
            $result.error = "robocopy exited with code $LASTEXITCODE"
            return $result
        }

        # Best-effort: count copied files.
        $result.copiedCount = (Get-ChildItem -Path $srcRoot -Recurse -File -ErrorAction SilentlyContinue).Count
        $result.skipped     = $skip
        $result.ok          = $true
    } catch {
        $result.error = $_.Exception.Message
    }
    return $result
}

# --- Routes ------------------------------------------------------------------

# GET /api/dune-admin/check[?force=1] - return installed vs latest
Register-DuneRoute -Method GET -Path '/api/dune-admin/check' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $force = $false
        if ($req.QueryString['force']) {
            $force = ($req.QueryString['force'] -eq '1' -or $req.QueryString['force'] -eq 'true')
        }
        $exePath  = Get-DuneAdminConfiguredPath
        $current  = Get-DuneAdminInstalledVersion -ExePath $exePath
        $rel      = Get-DuneAdminLatestRelease -Force:$force

        if (-not $rel -or $rel.error) {
            Write-DuneJson -Response $res -Body @{
                configured       = [bool]$exePath
                exePath          = $exePath
                installed        = $current
                available        = $false
                checkedAt        = (Get-Date).ToString('o')
                error            = $rel.error
            }
            return
        }

        $available = $false
        if ($rel.assetUrl) {
            if (-not $current.version -or $current.version -eq 'dev') {
                # Unknown installed version -> offer install/repair.
                $available = $true
            } else {
                $diff = Compare-DuneAdminSemver -A $rel.tag -B $current.version
                $available = ($diff -gt 0)
            }
        }

        Write-DuneJson -Response $res -Body @{
            configured     = [bool]$exePath
            exePath        = $exePath
            installed      = $current
            available      = $available
            latestVersion  = ($rel.tag -replace '^v','')
            tagName        = $rel.tag
            releaseName    = $rel.name
            releaseUrl     = $rel.htmlUrl
            releaseNotes   = $rel.releaseNotes
            publishedAt    = $rel.publishedAt
            assetName      = $rel.assetName
            assetSize      = $rel.assetSize
            checkedAt      = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/dune-admin/install - download + extract + overwrite
Register-DuneRoute -Method POST -Path '/api/dune-admin/install' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $exePath = Get-DuneAdminConfiguredPath
        if (-not $exePath) {
            Write-DuneError -Response $res -Status 400 -Message 'DuneAdminExe path is not set in Settings. Save a target path first, then re-try.'
            return
        }
        $targetDir = Split-Path -Parent $exePath
        if (-not $targetDir) {
            Write-DuneError -Response $res -Status 400 -Message "Cannot derive a parent directory from '$exePath'."
            return
        }

        $rel = Get-DuneAdminLatestRelease
        if (-not $rel -or -not $rel.assetUrl) {
            Write-DuneError -Response $res -Status 503 -Message 'No Windows zip asset available on the latest dune-admin release.'
            return
        }

        # Bail if the running EXE has the file locked.
        if (Test-DuneAdminFileLocked -Path $exePath) {
            Write-DuneError -Response $res -Status 423 -Message "dune-admin.exe is currently running and the file is locked. Close it and try again. Path: $exePath"
            return
        }

        # Make sure the target directory exists.
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        $tmpRoot = Join-Path $env:TEMP 'DuneAdminUpdate'
        if (-not (Test-Path -LiteralPath $tmpRoot)) { New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null }
        $safeTag = ($rel.tag -replace '[^A-Za-z0-9._-]','_')
        $zipPath = Join-Path $tmpRoot ("dune-admin-$safeTag.zip")
        $extract = Join-Path $tmpRoot ("dune-admin-$safeTag")

        # Download (skip if cached + size matches).
        $need = $true
        if (Test-Path -LiteralPath $zipPath) {
            $existing = (Get-Item -LiteralPath $zipPath).Length
            if ($rel.assetSize -gt 0 -and $existing -eq $rel.assetSize) { $need = $false }
        }
        if ($need) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $headers = @{ 'User-Agent' = $script:DuneAdminUA }
            Invoke-WebRequest -Uri $rel.assetUrl -Headers $headers -OutFile $zipPath -TimeoutSec 300 -UseBasicParsing
        }
        if (-not (Test-Path -LiteralPath $zipPath)) {
            Write-DuneError -Response $res -Status 500 -Message "Download failed: $zipPath not present after fetch."
            return
        }

        # Fresh extract dir.
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

        # Locate dune-admin.exe inside the extracted tree.
        $srcExe = Get-ChildItem -Path $extract -Recurse -Filter 'dune-admin.exe' -File -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if (-not $srcExe) {
            Write-DuneError -Response $res -Status 500 -Message "Extracted archive does not contain dune-admin.exe (looked under $extract)."
            return
        }
        $srcDir = $srcExe.Directory.FullName

        # Re-check the lock immediately before copying.
        if (Test-DuneAdminFileLocked -Path $exePath) {
            Write-DuneError -Response $res -Status 423 -Message "dune-admin.exe became locked between check and copy. Close it and retry."
            return
        }

        # Copy all sibling files from the extract over the target dir.
        # Use Copy-Item -Force; sidecar SBOM/version files alongside the
        # release are also copied for completeness.
        $copied = @()
        Get-ChildItem -Path $srcDir -File | ForEach-Object {
            $dest = Join-Path $targetDir $_.Name
            # Rename the running EXE out of the way as a fallback for the
            # rare case the lock test passed but the actual copy fails.
            if ($_.Name -ieq 'dune-admin.exe' -and (Test-Path -LiteralPath $dest)) {
                try {
                    $bak = "$dest.old"
                    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
                    Move-Item -LiteralPath $dest -Destination $bak -Force -ErrorAction SilentlyContinue
                } catch { }
            }
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            $copied += $_.Name
        }

        # Write sidecar so next /check returns the real version.
        Save-DuneAdminVersionSidecar -ExePath $exePath -Tag $rel.tag

        # --- Sync source tarball + auto-rebuild patched binary (v6.1.22) ---
        # GoReleaser publishes a source tarball alongside the windows zip. We
        # extract it over the user's dune-admin source dir so the next time
        # they apply the sane-pricing patch (or other future patches), the
        # source matches the running binary version. If the patch was already
        # applied (marker file present), we automatically re-run the patched
        # build so the upgrade stays patched without a second click.
        $sourceSync     = $null
        $autoRebuild    = $null
        if ($rel.sourceUrl) {
            $srcZip = Join-Path $tmpRoot ("dune-admin-$safeTag-src.tar.gz")
            $srcExtract = Join-Path $tmpRoot ("dune-admin-$safeTag-src")
            $needSrc = $true
            if (Test-Path -LiteralPath $srcZip) {
                $existingSrc = (Get-Item -LiteralPath $srcZip).Length
                if ($rel.sourceSize -gt 0 -and $existingSrc -eq $rel.sourceSize) { $needSrc = $false }
            }
            if ($needSrc) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $rel.sourceUrl -Headers @{ 'User-Agent' = $script:DuneAdminUA } -OutFile $srcZip -TimeoutSec 300 -UseBasicParsing
                } catch {
                    $sourceSync = [pscustomobject]@{ ok = $false; error = "Source download failed: $($_.Exception.Message)" }
                }
            }
            if (-not $sourceSync -and (Test-Path -LiteralPath $srcZip)) {
                $sourceSync = Sync-DuneAdminSourceTarball -ZipPath $srcZip -ExtractDir $srcExtract -TargetDir $targetDir
            }

            # If AutoApplyPricingPatch is enabled in settings, automatically
            # re-run build-patched.ps1 against the freshly-synced source so the
            # rebuilt binary keeps Coastal's pricing patch on top after every
            # upgrade. No marker files — the setting is the source of truth.
            $autoApply = $false
            try {
                $cfg = Read-DuneConfig
                if ($cfg -and $cfg.Contains('AutoApplyPricingPatch')) {
                    $val = "$($cfg['AutoApplyPricingPatch'])".Trim().ToLower()
                    $autoApply = ($val -eq 'true' -or $val -eq '1' -or $val -eq 'yes' -or $val -eq 'on')
                }
            } catch { }
            if ($sourceSync -and $sourceSync.ok -and $autoApply) {
                try {
                    # Stage the patch + build script the same way the apply
                    # route does, then invoke build-patched.ps1 via a wrapper
                    # script that pipes its own output (avoids the pipe-
                    # deadlock fixed in v6.1.22).
                    $resDir   = $null
                    foreach ($p in @(
                        (Join-Path $script:AppDir 'resources\dune-admin-patches'),
                        (Join-Path $script:AppDir 'app\resources\dune-admin-patches'),
                        (Join-Path (Split-Path -Parent $script:AppDir) 'resources\dune-admin-patches'),
                        (Join-Path (Split-Path -Parent $script:AppDir) 'app\resources\dune-admin-patches')
                    )) { if (Test-Path -LiteralPath $p) { $resDir = $p; break } }
                    if ($resDir) {
                        $userPatchDir = Join-Path $targetDir 'scripts\patches'
                        $userScripts  = Join-Path $targetDir 'scripts'
                        if (-not (Test-Path -LiteralPath $userPatchDir)) { New-Item -ItemType Directory -Path $userPatchDir -Force | Out-Null }
                        if (-not (Test-Path -LiteralPath $userScripts))  { New-Item -ItemType Directory -Path $userScripts -Force | Out-Null }
                        Copy-Item -LiteralPath (Join-Path $resDir '0001-sane-pricing-100k-cap.patch') -Destination $userPatchDir -Force -ErrorAction SilentlyContinue
                        Copy-Item -LiteralPath (Join-Path $resDir 'build-patched.ps1') -Destination $userScripts -Force -ErrorAction SilentlyContinue

                        $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
                        $logFile = Join-Path $env:TEMP "dune-admin-pricing-rebuild-$stamp.log"
                        $wrapper = Join-Path $env:TEMP "dune-admin-pricing-rebuild-wrap-$stamp.ps1"
                        $buildScript = Join-Path $userScripts 'build-patched.ps1'
                        $wrapperBody = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$targetDir'
& '$buildScript' -SkipTests *> '$logFile'
exit `$LASTEXITCODE
"@
                        Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8

                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName               = 'pwsh'
                        $psi.Arguments              = "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
                        $psi.WorkingDirectory       = $targetDir
                        $psi.UseShellExecute        = $false
                        $psi.CreateNoWindow         = $true
                        $bp = [System.Diagnostics.Process]::Start($psi)
                        if ($bp.WaitForExit(15 * 60 * 1000)) {
                            $rebuildOut = if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Raw } else { '' }
                            $autoRebuild = [pscustomobject]@{ ok = ($bp.ExitCode -eq 0); exitCode = $bp.ExitCode; logFile = $logFile; output = $rebuildOut }
                        } else {
                            try { $bp.Kill($true) } catch { }
                            $autoRebuild = [pscustomobject]@{ ok = $false; error = 'Rebuild timed out after 15 minutes'; logFile = $logFile }
                        }
                        try { Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue } catch { }
                    } else {
                        $autoRebuild = [pscustomobject]@{ ok = $false; error = 'Bundled patch resources not found' }
                    }
                } catch {
                    $autoRebuild = [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
                }
            }
        }

        Write-DuneJson -Response $res -Body @{
            ok             = $true
            fromVersion    = (Get-DuneAdminInstalledVersion -ExePath $exePath).version
            toVersion      = ($rel.tag -replace '^v','')
            tagName        = $rel.tag
            assetName      = $rel.assetName
            assetSize      = $rel.assetSize
            targetDir      = $targetDir
            copied         = $copied
            sourceSync     = $sourceSync
            autoRebuild    = $autoRebuild
            note           = 'dune-admin.exe replaced. Restart any open instance.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
