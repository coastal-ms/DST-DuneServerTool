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

# Copies the configured SSH key (private + .pub if present) into the
# dune-admin install folder. dune-admin will not function without this
# key sitting next to dune-admin.exe — its SSH/kubectl-over-SSH layer
# looks for `./sshKey` first. We pick the freshest of:
#   1) the path stored in dune-server.config (SshKey)
#   2) %LOCALAPPDATA%\DuneAwakeningServer\sshKey (where rotate-ssh-key
#      writes new keys)
# and copy it to $TargetDir. We never throw — a copy failure is logged
# and bubbled up as a non-fatal warning in the install response so a
# bad ACL or missing key doesn't break the binary install itself.
function Copy-DuneAdminSshKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetDir
    )

    $result = [pscustomobject]@{
        ok      = $false
        skipped = $false
        source  = $null
        dest    = $null
        message = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $TargetDir)) {
            $result.message = "Target dir does not exist: $TargetDir"
            return $result
        }

        $cfg = Read-DuneConfig
        $configured = $null
        if ($cfg -and $cfg.Contains('SshKey')) { $configured = [string]$cfg['SshKey'] }
        $appDataKey = Join-Path $env:LOCALAPPDATA 'DuneAwakeningServer\sshKey'

        $candidates = @()
        if ($configured -and (Test-Path -LiteralPath $configured)) {
            $candidates += Get-Item -LiteralPath $configured
        }
        if (Test-Path -LiteralPath $appDataKey) {
            $resolved = (Resolve-Path -LiteralPath $appDataKey).Path
            if (-not ($candidates | Where-Object { $_.FullName -eq $resolved })) {
                $candidates += Get-Item -LiteralPath $appDataKey
            }
        }
        if (-not $candidates -or $candidates.Count -eq 0) {
            $result.message = 'No SSH key found (neither SshKey in config nor %LOCALAPPDATA%\DuneAwakeningServer\sshKey exists). dune-admin will not work until a key is placed next to dune-admin.exe.'
            return $result
        }

        $src = ($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        $srcDir = (Resolve-Path -LiteralPath (Split-Path $src -Parent)).Path
        $dstDir = (Resolve-Path -LiteralPath $TargetDir).Path
        if ($srcDir -eq $dstDir) {
            $result.ok = $true
            $result.skipped = $true
            $result.source = $src
            $result.dest = $src
            $result.message = 'Source already in target dir; no copy needed.'
            return $result
        }

        # Always land as `sshKey` (the name dune-admin's SSH layer
        # expects) regardless of the source filename.
        $destKey = Join-Path $TargetDir 'sshKey'
        Copy-Item -LiteralPath $src -Destination $destKey -Force

        $pubSrc = "$src.pub"
        if (Test-Path -LiteralPath $pubSrc) {
            Copy-Item -LiteralPath $pubSrc -Destination (Join-Path $TargetDir 'sshKey.pub') -Force
        }

        $result.ok = $true
        $result.source = $src
        $result.dest = $destKey
        $result.message = "Copied $src -> $destKey"
        return $result
    } catch {
        $result.message = "SSH key copy failed: $($_.Exception.Message)"
        return $result
    }
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

function Get-DuneAdminConfigYamlPath {
    # dune-admin -setup writes ~/.dune-admin/config.yaml. On Windows that
    # resolves to %USERPROFILE%\.dune-admin\config.yaml.
    return Join-Path $env:USERPROFILE '.dune-admin\config.yaml'
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

# v6.1.25: status file directory + helpers for the detached pricing-patch
# rebuild. The install route launches the patched build as a fully detached
# background process and writes a JSON status file here; the UI polls
# GET /api/dune-admin/pricing-patch-status until status is terminal. This
# prevents the multi-minute Go build from blocking the HTTP listener thread
# (which previously froze the entire server, since PowerShell HttpListener
# processes one request at a time on the main thread).

function Get-DuneAdminPricingStateDir {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer\dune-admin-pricing'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}

function Get-DuneAdminPricingStatusPath {
    return (Join-Path (Get-DuneAdminPricingStateDir) 'rebuild-status.json')
}

function Write-DuneAdminPricingStatus {
    param([hashtable]$Data)
    $path = Get-DuneAdminPricingStatusPath
    try {
        $json = $Data | ConvertTo-Json -Depth 6 -Compress
        Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    } catch { }
}

function Read-DuneAdminPricingStatus {
    $path = Get-DuneAdminPricingStatusPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Start-DuneAdminPricingRebuild {
    param(
        [string]$ResDir,       # bundled resources dir containing patch + build-patched.ps1
        [string]$TargetDir,    # user's dune-admin source dir
        [string]$TargetTag,    # e.g. 'v0.14.2' for status display
        [int]$GambleDie = 12,  # gamble-buy die size (patch default 12)
        [int]$GambleTarget = 5 # winning roll that buys (patch default 5)
    )
    $stateDir = Get-DuneAdminPricingStateDir
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile  = Join-Path $stateDir "rebuild-$stamp.log"
    $wrapper  = Join-Path $stateDir "rebuild-$stamp.ps1"
    $statusPath = Get-DuneAdminPricingStatusPath

    # v6.1.26: if a previous wrapper is still running, kill it so this click
    # gets a clean slate. The user explicitly said "I should be able to
    # reinstall this as many times as I want" — repeated clicks must not
    # silently orphan background work.
    $prev = Read-DuneAdminPricingStatus
    if ($prev -and $prev.PSObject.Properties.Name -contains 'status' -and $prev.status -eq 'running' -and
        $prev.PSObject.Properties.Name -contains 'pid' -and $prev.pid) {
        try {
            $prevProc = Get-Process -Id ([int]$prev.pid) -ErrorAction SilentlyContinue
            if ($prevProc) {
                # Kill descendants first (go.exe, link.exe, git.exe), then the
                # wrapper itself, so a long-running compile doesn't keep
                # writing to the new run's log.
                try {
                    $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($prev.pid)" -ErrorAction SilentlyContinue
                    foreach ($k in $kids) {
                        try { Stop-Process -Id ([int]$k.ProcessId) -Force -ErrorAction SilentlyContinue } catch { }
                    }
                } catch { }
                try { Stop-Process -Id ([int]$prev.pid) -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }
    }

    # Stage the bundled patch + build wrapper into the user's source dir.
    $userPatchDir = Join-Path $TargetDir 'scripts\patches'
    $userScripts  = Join-Path $TargetDir 'scripts'
    if (-not (Test-Path -LiteralPath $userPatchDir)) { New-Item -ItemType Directory -Path $userPatchDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $userScripts))  { New-Item -ItemType Directory -Path $userScripts -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $ResDir '0001-sane-pricing-100k-cap.patch') -Destination $userPatchDir -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $ResDir 'build-patched.ps1') -Destination $userScripts -Force -ErrorAction SilentlyContinue
    $buildScript = Join-Path $userScripts 'build-patched.ps1'

    # The wrapper script runs build-patched.ps1 piping ALL output to file, then
    # atomically rewrites the status file with the final state. Failure modes
    # (stale patch, missing tools, build error) are surfaced via exitCode + the
    # log tail in the UI.
    $wrapperBody = @"
`$ErrorActionPreference = 'Continue'
`$statusPath    = '$statusPath'
`$logFile       = '$logFile'

function Write-Status {
    param([hashtable]`$Data)
    try {
        `$json = `$Data | ConvertTo-Json -Depth 6 -Compress
        Set-Content -LiteralPath `$statusPath -Value `$json -Encoding UTF8
    } catch { }
}

`$startedAt = (Get-Date).ToString('o')
Write-Status @{
    status     = 'running'
    targetTag  = '$TargetTag'
    targetDir  = '$TargetDir'
    logFile    = `$logFile
    startedAt  = `$startedAt
    pid        = `$PID
}

Set-Location -LiteralPath '$TargetDir'

try {
    & '$buildScript' -SkipTests -GambleDie $GambleDie -GambleTarget $GambleTarget *> `$logFile
    `$buildCode = `$LASTEXITCODE
    if (`$null -eq `$buildCode) { `$buildCode = 0 }
} catch {
    `$buildCode = 1
    try { Add-Content -LiteralPath `$logFile -Value "``r``n[wrapper] build-patched.ps1 threw: `$(`$_.Exception.Message)``r``n" } catch { }
}

`$finished = (Get-Date).ToString('o')
if (`$buildCode -eq 0) {
    Write-Status @{
        status     = 'success'
        targetTag  = '$TargetTag'
        targetDir  = '$TargetDir'
        logFile    = `$logFile
        startedAt  = `$startedAt
        finishedAt = `$finished
        exitCode   = `$buildCode
        pid        = `$PID
    }
    exit 0
} else {
    Write-Status @{
        status     = 'failed'
        targetTag  = '$TargetTag'
        targetDir  = '$TargetDir'
        logFile    = `$logFile
        startedAt  = `$startedAt
        finishedAt = `$finished
        exitCode   = `$buildCode
        error      = "build-patched.ps1 exited with code `$buildCode (see log)."
        pid        = `$PID
    }
    exit `$buildCode
}
"@
    Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8

    # Seed the status file BEFORE launching so the polling UI gets 'running'
    # even if the background process is still warming up.
    Write-DuneAdminPricingStatus @{
        status     = 'running'
        targetTag  = $TargetTag
        targetDir  = $TargetDir
        logFile    = $logFile
        startedAt  = (Get-Date).ToString('o')
    }

    # Launch fully detached. Start-Process -WindowStyle Hidden returns a
    # Process object whose handle we close immediately so DuneServer holds no
    # reference. The child runs under pwsh.exe and supervises itself.
    try {
        $shell = $null
        foreach ($candidate in @('pwsh', 'powershell')) {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) { $shell = $cmd.Source; break }
        }
        if (-not $shell) { throw 'Neither pwsh nor powershell found on PATH' }

        $proc = Start-Process -FilePath $shell `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',"`"$wrapper`"") `
            -WorkingDirectory $TargetDir `
            -WindowStyle Hidden `
            -PassThru
        $bgPid = if ($proc) { $proc.Id } else { 0 }
        if ($proc) {
            try { $proc.Dispose() } catch { }
        }
        return [pscustomobject]@{
            ok        = $true
            status    = 'running'
            logFile   = $logFile
            statusFile= $statusPath
            pid       = $bgPid
            startedAt = (Get-Date).ToString('o')
        }
    } catch {
        $err = $_.Exception.Message
        Write-DuneAdminPricingStatus @{
            status     = 'failed'
            targetTag  = $TargetTag
            targetDir  = $TargetDir
            logFile    = $logFile
            startedAt  = (Get-Date).ToString('o')
            finishedAt = (Get-Date).ToString('o')
            error      = "Failed to launch rebuild: $err"
        }
        return [pscustomobject]@{
            ok        = $false
            status    = 'failed'
            error     = "Failed to launch rebuild: $err"
            logFile   = $logFile
            statusFile= $statusPath
        }
    }
}

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
                configYamlPath   = Get-DuneAdminConfigYamlPath
                configYamlExists = (Test-Path -LiteralPath (Get-DuneAdminConfigYamlPath))
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
            configYamlPath = Get-DuneAdminConfigYamlPath
            configYamlExists = (Test-Path -LiteralPath (Get-DuneAdminConfigYamlPath))
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

        # Copy the user's SSH key into the dune-admin folder so dune-admin's
        # SSH/kubectl-over-SSH layer (which looks for ./sshKey first) just
        # works. Non-fatal on failure — the binary install itself already
        # succeeded; we surface the result so the UI can warn the user.
        $sshKeyCopy = Copy-DuneAdminSshKey -TargetDir $targetDir

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
            $gambleDie = 12
            $gambleTarget = 5
            try {
                $cfg = Read-DuneConfig
                if ($cfg -and $cfg.Contains('AutoApplyPricingPatch')) {
                    $val = "$($cfg['AutoApplyPricingPatch'])".Trim().ToLower()
                    $autoApply = ($val -eq 'true' -or $val -eq '1' -or $val -eq 'yes' -or $val -eq 'on')
                }
                # Gamble die config (optional). Defaults reproduce the patch's
                # original d12 / buy-on-5 behaviour. Validate defensively so a
                # bad config value can never break the rebuild.
                if ($cfg -and $cfg.Contains('GambleDieSize')) {
                    $d = 0
                    if ([int]::TryParse("$($cfg['GambleDieSize'])".Trim(), [ref]$d) -and $d -ge 2) { $gambleDie = $d }
                }
                if ($cfg -and $cfg.Contains('GambleTarget')) {
                    $t = 0
                    if ([int]::TryParse("$($cfg['GambleTarget'])".Trim(), [ref]$t) -and $t -ge 1) { $gambleTarget = $t }
                }
                if ($gambleTarget -gt $gambleDie) { $gambleTarget = $gambleDie }
            } catch { }
            if ($sourceSync -and $sourceSync.ok -and $autoApply) {
                # v6.1.25: launch the patched-build wrapper as a fully detached
                # background process. The HTTP request returns immediately with
                # the status file path; the UI polls /api/dune-admin/pricing-
                # patch-status until status is terminal. This stops the
                # PowerShell HttpListener thread from blocking for the entire
                # multi-minute Go build, which previously froze the whole
                # server (no /healthz, /ports, etc.) and made the install
                # button appear hung.
                try {
                    $resDir = $null
                    foreach ($p in @(
                        (Join-Path $script:AppDir 'resources\dune-admin-patches'),
                        (Join-Path $script:AppDir 'app\resources\dune-admin-patches'),
                        (Join-Path (Split-Path -Parent $script:AppDir) 'resources\dune-admin-patches'),
                        (Join-Path (Split-Path -Parent $script:AppDir) 'app\resources\dune-admin-patches')
                    )) { if (Test-Path -LiteralPath $p) { $resDir = $p; break } }
                    if ($resDir) {
                        $autoRebuild = Start-DuneAdminPricingRebuild -ResDir $resDir -TargetDir $targetDir -TargetTag $rel.tag -GambleDie $gambleDie -GambleTarget $gambleTarget
                    } else {
                        $autoRebuild = [pscustomobject]@{ ok = $false; status = 'failed'; error = 'Bundled patch resources not found' }
                    }
                } catch {
                    $autoRebuild = [pscustomobject]@{ ok = $false; status = 'failed'; error = $_.Exception.Message }
                }
            }
        }

        Write-DuneJson -Response $res -Body @{
            ok             = $true
            fromVersion    = (Get-DuneAdminInstalledVersion -ExePath $exePath).version
            toVersion      = ($rel.tag -replace '^v','')
            tagName         = $rel.tag
            assetName      = $rel.assetName
            assetSize      = $rel.assetSize
            targetDir      = $targetDir
            copied         = $copied
            sshKeyCopy     = $sshKeyCopy
            sourceSync     = $sourceSync
            autoRebuild    = $autoRebuild
            pricingPatch   = $autoRebuild
            note           = 'dune-admin.exe replaced. Restart any open instance.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# GET /api/dune-admin/pricing-patch-status - poll the detached pricing-patch
# rebuild started by /install. The UI shows a separate "Patching..." chip
# and polls this every couple of seconds while status === 'running'.
# Response shape mirrors the status JSON written by the wrapper script with
# an extra `logTail` (last ~40 lines of the build log) so the user can see
# progress / failure detail in the UI without opening a file explorer.
Register-DuneRoute -Method GET -Path '/api/dune-admin/pricing-patch-status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $statusPath = Get-DuneAdminPricingStatusPath
        $status = Read-DuneAdminPricingStatus
        if (-not $status) {
            Write-DuneJson -Response $res -Body @{
                ok         = $true
                status     = 'idle'
                statusFile = $statusPath
            }
            return
        }

        # status is a PSCustomObject from ConvertFrom-Json; copy fields onto a
        # hashtable so we can add logTail safely.
        $out = @{
            ok         = $true
            status     = ([string]$status.status)
            statusFile = $statusPath
        }
        foreach ($prop in $status.PSObject.Properties) {
            if (-not $out.ContainsKey($prop.Name)) { $out[$prop.Name] = $prop.Value }
        }

        # Tail the log (best-effort, capped at 40 lines / 8 KB).
        if ($status.PSObject.Properties.Name -contains 'logFile' -and $status.logFile -and (Test-Path -LiteralPath $status.logFile)) {
            try {
                $tail = Get-Content -LiteralPath $status.logFile -Tail 40 -ErrorAction SilentlyContinue
                if ($tail) {
                    $joined = ($tail -join "`n")
                    if ($joined.Length -gt 8000) { $joined = $joined.Substring($joined.Length - 8000) }
                    $out['logTail'] = $joined
                }
            } catch { }
        }

        # If status says 'running' but the wrapper PID is no longer alive,
        # the background process died without writing a terminal status.
        # Promote to 'failed' so the UI stops spinning forever.
        if ($out['status'] -eq 'running' -and $out.ContainsKey('pid') -and $out['pid']) {
            $alive = $false
            try {
                $p = Get-Process -Id ([int]$out['pid']) -ErrorAction SilentlyContinue
                if ($p) { $alive = $true }
            } catch { $alive = $false }
            if (-not $alive) {
                $out['status'] = 'failed'
                $out['error']  = 'Rebuild process exited without writing a terminal status (likely crashed). See log for details.'
                # Persist so subsequent polls are consistent.
                try {
                    $persist = @{}
                    foreach ($k in $out.Keys) { if ($k -ne 'ok' -and $k -ne 'logTail' -and $k -ne 'statusFile') { $persist[$k] = $out[$k] } }
                    Write-DuneAdminPricingStatus $persist
                } catch { }
            }
        }

        Write-DuneJson -Response $res -Body $out
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/dune-admin/setup - one-button first-run setup wizard launcher
#
# What it does, in order:
#   1. If DuneAdminExe path is not configured -> 400 (user must set the path
#      in Settings first so we know where to put dune-admin.exe).
#   2. If dune-admin.exe does not exist at that path -> download + extract
#      the latest Windows release into the parent dir (same as /install does,
#      minus the source-tarball sync + auto-rebuild).
#   3. Spawn a VISIBLE cmd.exe console window in the dune-admin folder that
#      runs `dune-admin.exe -setup` interactively. The user answers the
#      wizard's prompts (control plane / SSH / DB / broker / paths) — every
#      user's deployment is different, so we never pre-fill anything.
#   4. When the wizard exits with success (errorlevel 0) AND a config.yaml
#      now exists at %USERPROFILE%\.dune-admin\config.yaml, the wrapper
#      auto-launches dune-admin.exe in a separate visible window so the
#      server starts listening on :8080 immediately.
#   5. The setup window stays open after exit ("Press any key to close")
#      so the user can see any wizard errors before the window closes.
#
# Returns 200 immediately as soon as the console is spawned — the wizard
# itself runs asynchronously and the user interacts with it directly.
Register-DuneRoute -Method POST -Path '/api/dune-admin/setup' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $exePath = Get-DuneAdminConfiguredPath
        if (-not $exePath) {
            Write-DuneError -Response $res -Status 400 -Message 'DuneAdminExe path is not set in Settings. Pick a location for dune-admin.exe first (e.g. C:\Tools\dune-admin\dune-admin.exe), Save, then click Run setup wizard again.'
            return
        }
        $targetDir = Split-Path -Parent $exePath
        if (-not $targetDir) {
            Write-DuneError -Response $res -Status 400 -Message "Cannot derive a parent directory from '$exePath'."
            return
        }
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        # --- Step 1: install the binary if it isn't there yet -----------------
        $didInstall = $false
        if (-not (Test-Path -LiteralPath $exePath)) {
            $rel = Get-DuneAdminLatestRelease
            if (-not $rel -or -not $rel.assetUrl) {
                Write-DuneError -Response $res -Status 503 -Message 'No Windows zip asset available on the latest dune-admin release.'
                return
            }
            $tmpRoot = Join-Path $env:TEMP 'DuneAdminUpdate'
            if (-not (Test-Path -LiteralPath $tmpRoot)) { New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null }
            $safeTag = ($rel.tag -replace '[^A-Za-z0-9._-]','_')
            $zipPath = Join-Path $tmpRoot ("dune-admin-$safeTag.zip")
            $extract = Join-Path $tmpRoot ("dune-admin-$safeTag")

            $need = $true
            if (Test-Path -LiteralPath $zipPath) {
                $existing = (Get-Item -LiteralPath $zipPath).Length
                if ($rel.assetSize -gt 0 -and $existing -eq $rel.assetSize) { $need = $false }
            }
            if ($need) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $rel.assetUrl -Headers @{ 'User-Agent' = $script:DuneAdminUA } -OutFile $zipPath -TimeoutSec 300 -UseBasicParsing
            }
            if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extract -Force

            $srcExe = Get-ChildItem -Path $extract -Recurse -Filter 'dune-admin.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $srcExe) {
                Write-DuneError -Response $res -Status 500 -Message "Extracted archive does not contain dune-admin.exe (looked under $extract)."
                return
            }
            $srcDir = $srcExe.Directory.FullName
            Get-ChildItem -Path $srcDir -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $targetDir $_.Name) -Force
            }
            Save-DuneAdminVersionSidecar -ExePath $exePath -Tag $rel.tag
            $didInstall = $true
        }

        # dune-admin needs the SSH key sitting next to dune-admin.exe to
        # talk to the VM (its own SSH/kubectl-over-SSH layer looks for
        # ./sshKey first). Copy it from the configured SshKey path (or
        # %LOCALAPPDATA%\DuneAwakeningServer\sshKey if newer) every
        # time the wizard runs, not just when we just installed — covers
        # cases where the user rotated keys between sessions.
        $sshKeyCopy = Copy-DuneAdminSshKey -TargetDir $targetDir

        # --- Step 2: spawn a visible console for the interactive wizard ------
        # cmd.exe wrapper lets us chain (a) run setup, (b) auto-launch
        # dune-admin if config.yaml was created, (c) pause so the user
        # can read any errors before the window closes.
        $configYaml = Get-DuneAdminConfigYamlPath
        $cmdBody = @"
@echo off
title dune-admin setup wizard
echo ============================================================
echo   dune-admin first-time setup wizard
echo ============================================================
echo.
echo Every user's deployment is different — you'll be asked for:
echo   * Control plane: amp / kubectl / docker / local
echo   * SSH host, user, key path (for kubectl over SSH)
echo   * DB host, port, user, password, name, schema
echo   * Broker addresses (mq-game / mq-admin)
echo   * Backup directory
echo.
echo Config will be written to:
echo   $configYaml
echo.
echo ------------------------------------------------------------
echo.
"$exePath" -setup
set RC=%ERRORLEVEL%
echo.
echo ------------------------------------------------------------
if "%RC%"=="0" (
    if exist "$configYaml" (
        echo Setup complete. Launching dune-admin in a new window...
        start "dune-admin" "$exePath"
        timeout /t 3 >nul
        echo dune-admin is now running on http://localhost:8080
        echo You can close this window.
    ) else (
        echo Setup wizard exited cleanly but no config.yaml was written.
        echo Expected location: $configYaml
    )
) else (
    echo Setup wizard exited with error code %RC%.
    echo Review the messages above for what went wrong.
)
echo.
pause
"@
        $cmdFile = Join-Path $env:TEMP ('dune-admin-setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bat')
        Set-Content -LiteralPath $cmdFile -Value $cmdBody -Encoding ASCII

        # Launch the wrapper in a visible console window. We do NOT redirect
        # stdio so the user can interact with the wizard directly.
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$cmdFile`"" -WorkingDirectory $targetDir | Out-Null

        Write-DuneJson -Response $res -Body @{
            ok               = $true
            exePath          = $exePath
            targetDir        = $targetDir
            didInstall       = $didInstall
            sshKeyCopy       = $sshKeyCopy
            configYamlPath   = $configYaml
            configYamlExists = (Test-Path -LiteralPath $configYaml)
            wizardScript     = $cmdFile
            note             = 'A console window opened with the dune-admin setup wizard. Answer the prompts there; dune-admin will auto-launch when the wizard finishes.'
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
