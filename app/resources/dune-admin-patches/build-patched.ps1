# build-patched.ps1
#
# Local Windows build wrapper for dune-admin.exe.
#
# Applies every *.patch file in scripts/patches/ on top of the working tree,
# runs tests, builds dune-admin.exe **in place at the repo root**, and reverts
# the working tree so it stays clean against upstream main.
#
# The built dune-admin.exe lives at $repoRoot\dune-admin.exe — no copy step.
# Your Dune Server Tool's DuneAdminExe should point at that path.
#
# Usage:
#   .\scripts\build-patched.ps1                # build in place (does not stop a
#                                              # running dune-admin — go build
#                                              # will fail if the exe is locked)
#   .\scripts\build-patched.ps1 -Restart       # stop running dune-admin, build,
#                                              # relaunch (visible console)
#   .\scripts\build-patched.ps1 -SkipTests     # skip `go test`
#   .\scripts\build-patched.ps1 -Keep          # leave patches applied after
#                                              # build (for editing — regen the
#                                              # patch via
#                                              # `git diff > scripts/patches/...`)

[CmdletBinding()]
param(
    [switch] $Restart,
    [switch] $SkipTests,
    [switch] $Keep,
    [int]    $GambleDie    = 12,
    [int]    $GambleTarget = 5
)

$ErrorActionPreference = 'Stop'

# --- Validate gamble die config ----------------------------------------------
# The sane-pricing patch replaces dune-admin's price-threshold buy gate with a
# dice roll: roll a $GambleDie-sided die per candidate listing and buy only on
# $GambleTarget. Defaults reproduce the original d12/need-5 behaviour exactly
# (and, being defaults, leave the patched source byte-for-byte unchanged so the
# build is identical to before this feature existed).
if ($GambleDie -lt 2) {
    throw "GambleDie must be >= 2 (got $GambleDie)."
}
if ($GambleTarget -lt 1 -or $GambleTarget -gt $GambleDie) {
    throw "GambleTarget must be between 1 and GambleDie ($GambleDie); got $GambleTarget."
}
# PowerShell 7.4+ makes native commands (git, go) respect $ErrorActionPreference,
# which causes harmless stderr like git's "LF will be replaced by CRLF" warning
# to throw. We rely on explicit $LASTEXITCODE checks below, so opt out.
$PSNativeCommandUseErrorActionPreference = $false
$scriptRoot = $PSScriptRoot
$repoRoot   = Split-Path -Parent $scriptRoot
$exePath    = Join-Path $repoRoot 'dune-admin.exe'

# --- Resolve build tools (git, go) -------------------------------------------
# When this script runs from the Dune Server Tool's background wrapper (spawned
# by DuneServer.exe, a ps2exe binary), the inherited PATH can be missing entries
# an interactive shell would have — most commonly Git. Find git/go via PATH
# first, then fall back to their standard install locations, and prepend the
# containing dir to PATH so every bare `git`/`go` call below — and Go's own
# internal git invocations (module/VCS stamping) — resolve correctly.
function Resolve-ToolDir {
    param([string]$Name, [string[]]$Candidates)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return (Split-Path -Parent $cmd.Source) }
    foreach ($c in $Candidates) {
        $expanded = [Environment]::ExpandEnvironmentVariables($c)
        if ($expanded -and (Test-Path -LiteralPath $expanded)) { return (Split-Path -Parent $expanded) }
    }
    return $null
}

# Return a path to an LF-normalized copy of the patch. `git apply` matches
# context lines BYTE-FOR-BYTE: if the .patch file has CRLF line endings (which
# happens when it's renormalized in transit — OneDrive sync, a Windows editor,
# git core.autocrlf, etc.) but the upstream Go source is LF, every hunk fails
# with "patch does not apply" — against EVERY upstream version, not just a new
# one. This historically looked like (and was misreported as) a "stale patch /
# baseline drift" problem when it was purely line endings. Normalizing to LF
# here makes apply robust regardless of how the file arrived on disk. The
# normalized copy lives in a temp file; the original on disk is left untouched.
$script:TempPatchFiles = @()
function Get-LfPatchPath {
    param([string]$PatchPath)
    $bytes = [System.IO.File]::ReadAllBytes($PatchPath)
    # Fast path: no CR bytes -> already LF, use as-is.
    if (-not ($bytes -contains [byte]13)) { return $PatchPath }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $text = $text -replace "`r`n", "`n"
    $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("dune-patch-" + [System.Guid]::NewGuid().ToString('N') + '.patch')
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    $script:TempPatchFiles += $tmp
    return $tmp
}

$gitDir = Resolve-ToolDir -Name 'git' -Candidates @(
    "$env:ProgramFiles\Git\cmd\git.exe",
    "$env:ProgramFiles\Git\bin\git.exe",
    "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
    "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\git.exe"
)
$goDir = Resolve-ToolDir -Name 'go' -Candidates @(
    "$env:ProgramFiles\Go\bin\go.exe",
    "$env:LOCALAPPDATA\Programs\Go\bin\go.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\go.exe",
    "C:\Go\bin\go.exe"
)
foreach ($d in @($gitDir, $goDir)) {
    if ($d -and (";$env:PATH;" -notlike "*;$d;*")) { $env:PATH = "$d;$env:PATH" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git was not found on this machine (searched PATH and the standard install locations). Install Git for Windows — e.g. run 'winget install --id Git.Git' — then close and reopen the Dune Server Tool and re-apply the patch."
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw "Go was not found on this machine (searched PATH and the standard install locations). Install Go — e.g. run 'winget install --id GoLang.Go' — then close and reopen the Dune Server Tool and re-apply the patch."
}

# --- Resolve build tools (node, pnpm) ----------------------------------------
# The patched binary embeds the dune-admin web UI (go build -tags embed reads
# cmd/dune-admin/dist). Building that SPA needs Node + pnpm. WITHOUT the embed,
# the binary serves the API + market bot but every web-portal request 404s —
# i.e. "can't access dune-admin / market bot" even though the backend is up.
$nodeDir = Resolve-ToolDir -Name 'node' -Candidates @(
    "$env:ProgramFiles\nodejs\node.exe",
    "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
    "${env:ProgramFiles(x86)}\nodejs\node.exe",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\node.exe"
)
if ($nodeDir -and (";$env:PATH;" -notlike "*;$nodeDir;*")) { $env:PATH = "$nodeDir;$env:PATH" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js was not found on this machine (searched PATH and the standard install locations). The patched build embeds the dune-admin web UI, which requires Node to build — without it dune-admin.exe serves the API and market bot but the web portal returns 404. Install Node — e.g. run 'winget install --id OpenJS.NodeJS.LTS' — then close and reopen the Dune Server Tool and re-apply the patch."
}

# pnpm: prefer a real pnpm on PATH; otherwise bootstrap it via corepack (ships
# with Node >= 16.9, no global install needed). Returns the exe to invoke plus
# any leading args (corepack runs pnpm as `corepack pnpm ...`).
function Resolve-Pnpm {
    $direct = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($direct -and $direct.Source) { return @{ Exe = $direct.Source; Pre = @() } }
    $corepack = Get-Command corepack -ErrorAction SilentlyContinue
    if ($corepack -and $corepack.Source) {
        try { & $corepack.Source enable pnpm 2>$null | Out-Null } catch { }
        $direct2 = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($direct2 -and $direct2.Source) { return @{ Exe = $direct2.Source; Pre = @() } }
        return @{ Exe = $corepack.Source; Pre = @('pnpm') }
    }
    return $null
}
$pnpm = Resolve-Pnpm
if (-not $pnpm) {
    throw "pnpm was not found and could not be bootstrapped via corepack (which ships with Node). Enable it by running 'corepack enable pnpm', or install pnpm with 'npm install -g pnpm', then re-apply the patch. The patched build needs pnpm to build the embedded dune-admin web UI."
}
$pnpmExe = $pnpm.Exe
$pnpmPre = $pnpm.Pre

Push-Location $repoRoot
try {
    function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
    function Info($msg) { Write-Host "    $msg" -ForegroundColor Gray  }

    # If we're going to overwrite dune-admin.exe and it's currently running,
    # stop it now (otherwise go build fails with "Access is denied").
    $running = Get-Process -Name dune-admin -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -eq $exePath }
    if ($running) {
        Step "Stopping running dune-admin (PID $($running.Id)) — exe is locked"
        foreach ($proc in $running) { Stop-Process -Id $proc.Id -Force }
        Start-Sleep -Seconds 2
        $stoppedRunning = $true
    } else {
        $stoppedRunning = $false
    }

    $patchDir = Join-Path $scriptRoot 'patches'
    $patches  = @(Get-ChildItem -Path $patchDir -Filter '*.patch' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    # Snapshot of pre-patch file contents (raw bytes), keyed by repo-relative
    # path. After the build we restore each file's exact pre-patch bytes so
    # the working tree returns to whatever state it was in BEFORE we touched
    # it — independent of the user's git HEAD. This is critical: a plain
    # `git restore` reverts to LOCAL HEAD, which on user machines is often an
    # older release than the one we just patched against, breaking subsequent
    # reinstalls (the next `git apply --check` would find a mismatched
    # baseline and fail).
    $preSnapshots = @{}

    $patchedFiles = @()
    if ($patches.Count -eq 0) {
        Info "No patches in scripts\patches\ — building straight upstream."
    } else {
        Step "Applying $($patches.Count) patch(es) from scripts\patches\"
        foreach ($p in $patches) {
            Info "git apply $($p.Name)"
            # Normalize to LF before applying — CRLF in the .patch breaks
            # git apply against LF Go source (see Get-LfPatchPath).
            $applyPath = Get-LfPatchPath -PatchPath $p.FullName
            # Determine which files this patch touches (works regardless of
            # apply state) — used for revert tracking and for cleanup on
            # conflict.
            $touched = @(& git apply --numstat -- $applyPath 2>$null |
                        ForEach-Object { ($_ -split "`t")[2] } |
                        Where-Object { $_ })

            # Try clean apply.
            & git apply --check -- $applyPath 2>$null
            if ($LASTEXITCODE -eq 0) {
                # Snapshot pre-patch bytes so the cleanup can restore them
                # exactly (independent of git history).
                foreach ($t in $touched) {
                    $tPath = Join-Path $repoRoot $t
                    if ((Test-Path -LiteralPath $tPath) -and -not $preSnapshots.ContainsKey($t)) {
                        $preSnapshots[$t] = [System.IO.File]::ReadAllBytes($tPath)
                    }
                }
                & git apply --whitespace=nowarn -- $applyPath
                if ($LASTEXITCODE -ne 0) { throw "Patch failed (clean apply): $($p.Name)" }
                $patchedFiles += $touched
                continue
            }

            # Maybe it's already applied — reverse-apply check. If so, leave
            # it applied; the build will use it as-is. (Previously we did a
            # `git restore` + re-apply for a "clean state", but `git restore`
            # reverts to LOCAL git HEAD, which in the installer flow may be
            # an old commit — that corrupts the upstream-tarball overlay we
            # just dropped in. Skipping the restore is both safer and
            # produces an identical end state.)
            & git apply --reverse --check -- $applyPath 2>$null
            if ($LASTEXITCODE -eq 0) {
                Info "Patch is already applied to the working tree — using as-is."
                $patchedFiles += $touched
                continue
            }

            # Neither forward nor reverse — the patch genuinely does not match
            # the current source. We deliberately do NOT `git restore` +
            # force-apply: when this script runs from the installer, the working
            # tree was just overlaid from an upstream source tarball, and
            # `git restore` reverts to whatever the user's local git HEAD
            # happens to be (often an older release), which strips the new
            # symbols bot.go/exchange.go reference and breaks the build with
            # confusing "undefined: LoadState" errors. Failing fast tells the
            # user the real problem.
            Info "Patch does not apply cleanly and is not already applied."
            Info "Touched files: $($touched -join ', ')"
            Info "The patch was LF-normalized before applying, so this is NOT a"
            Info "line-ending mismatch — the bundled patch was authored against a"
            Info "different dune-admin baseline than the source on disk. Update the"
            Info "Dune Server Tool (which ships the patch) and reinstall to refresh it."
            throw "Patch does not match current source: $($p.Name). Refusing to corrupt the working tree."
        }
        # De-duplicate file list for the revert step.
        $patchedFiles = @($patchedFiles | Sort-Object -Unique)
    }

    # --- Inject custom gamble die size / target ------------------------------
    # The patch hard-codes a 12-sided die that buys on a roll of 5. When the
    # operator picks different values we rewrite the just-patched exchange.go in
    # place (it's reverted from the pre-patch snapshot after the build, so the
    # working tree still ends up clean). Defaults (12/5) skip this entirely so a
    # default build is byte-identical to the unmodified patch output.
    if ($GambleDie -ne 12 -or $GambleTarget -ne 5) {
        $exchangeGo = Join-Path $repoRoot 'internal\marketbot\exchange.go'
        if (-not (Test-Path -LiteralPath $exchangeGo)) {
            throw "Cannot inject gamble die config: $exchangeGo not found after patch."
        }
        Step "Injecting gamble die config (d$GambleDie, buy on $GambleTarget)"
        $src = Get-Content -LiteralPath $exchangeGo -Raw
        $orig = $src
        # Functional roll: rand.Intn(12) + 1; roll != 5
        $src = $src -replace 'rand\.Intn\(12\) \+ 1', "rand.Intn($GambleDie) + 1"
        $src = $src -replace 'roll != 5\b',            "roll != $GambleTarget"
        # Log strings: "(need 5)" and the d12 labels
        $src = $src -replace '\(need 5\)',  "(need $GambleTarget)"
        $src = $src -replace 'buy: d12 ',   "buy: d$GambleDie "
        if ($src -eq $orig) {
            throw "Gamble die injection matched nothing in exchange.go — patch layout may have changed."
        }
        # Preserve original (LF) line endings — never write CRLF into Go source.
        [System.IO.File]::WriteAllText($exchangeGo, ($src -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Info "exchange.go: die=$GambleDie target=$GambleTarget"
    }

    try {
        if (-not $SkipTests) {
            Step "go test ./internal/marketbot/..."
            & go test ./internal/marketbot/...
            if ($LASTEXITCODE -ne 0) { throw "Tests failed." }
        } else {
            Info "Skipping tests (-SkipTests)."
        }

        Step "go build (windows/amd64) → $exePath"
        # The installer rebuild flow overlays an upstream *source tarball*, which
        # has NO .git directory and may lack a VERSION file. `git apply` doesn't
        # need a repo, but `git rev-parse HEAD` does — so both of these are
        # best-effort. Never let stamping metadata fail the build.
        $version = 'unknown'
        $versionFile = Join-Path $repoRoot 'VERSION'
        if (Test-Path -LiteralPath $versionFile) {
            $vRaw = (Get-Content -LiteralPath $versionFile -Raw)
            if ($vRaw) { $version = $vRaw.Trim() }
        }
        $gitCommit = 'unknown'
        try {
            $rev = (& git rev-parse --short HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $rev) { $gitCommit = ($rev | Out-String).Trim() }
        } catch { }
        $buildTime  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $ldflags    = "-s -w -X main.AppVersion=$version -X main.GitCommit=$gitCommit -X main.BuildTime=$buildTime"

        # --- Build the embedded web UI (mirrors upstream `make web`) ----------
        # cmd/dune-admin/embed_prod.go embeds cmd/dune-admin/dist behind the
        # `embed` build tag; without it embed_dev.go serves no SPA and every
        # web request 404s. Build web/dist with pnpm and stage it for embedding.
        Step "pnpm install + build (web UI for embedding)"
        $webDir = Join-Path $repoRoot 'web'
        if (-not (Test-Path -LiteralPath (Join-Path $webDir 'package.json'))) {
            throw "web\package.json not found at $webDir — cannot build the dune-admin web UI to embed."
        }
        Push-Location $webDir
        try {
            & $pnpmExe @pnpmPre install --frozen-lockfile
            if ($LASTEXITCODE -ne 0) { throw "pnpm install failed (web UI)." }
            & $pnpmExe @pnpmPre build
            if ($LASTEXITCODE -ne 0) { throw "pnpm build failed (web UI)." }
        } finally { Pop-Location }
        $webDist   = Join-Path $webDir 'dist'
        $embedDist = Join-Path $repoRoot 'cmd\dune-admin\dist'
        if (-not (Test-Path -LiteralPath (Join-Path $webDist 'index.html'))) {
            throw "web build produced no dist\index.html — refusing to build a UI-less binary."
        }
        if (Test-Path -LiteralPath $embedDist) { Remove-Item -LiteralPath $embedDist -Recurse -Force }
        Copy-Item -LiteralPath $webDist -Destination $embedDist -Recurse -Force
        Info "staged web UI for embedding → cmd\dune-admin\dist"

        $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
        try {
            & go build -trimpath -tags embed -ldflags $ldflags -o $exePath ./cmd/dune-admin
            if ($LASTEXITCODE -ne 0) { throw "go build failed." }
        } finally {
            Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
        $exe = Get-Item $exePath
        Info "built: $($exe.FullName) ($([math]::Round($exe.Length / 1MB, 2)) MB)"
        Info "version=$version commit=$gitCommit"
    } finally {
        if (-not $Keep -and $patchedFiles.Count -gt 0) {
            Step "Reverting patched files (working tree → exact pre-patch state)"
            foreach ($f in $patchedFiles) {
                if ($preSnapshots.ContainsKey($f)) {
                    $fPath = Join-Path $repoRoot $f
                    try {
                        [System.IO.File]::WriteAllBytes($fPath, $preSnapshots[$f])
                        Info "restored $f from snapshot"
                    } catch {
                        Info "snapshot restore failed for $f, falling back to git restore"
                        & git restore -- $f
                    }
                } else {
                    # No snapshot (e.g. the patch was already-applied path) —
                    # leave the file as-is so we don't accidentally revert
                    # against an older git HEAD.
                    Info "no snapshot for $f — leaving as-is"
                }
            }
        } elseif ($Keep) {
            Info "Leaving patches applied in working tree (-Keep). 'git status' will show diff."
        }
    }

    if ($Restart -or $stoppedRunning) {
        Step "Relaunching dune-admin (visible console)"
        # Use Start-Process (not `cmd /c start`) so the launched dune-admin
        # does NOT inherit any redirected stdout/stderr handles from our
        # parent. cmd's `start` historically leaked inherited handles, which
        # caused our Dune Server Tool's HTTP apply call to hang forever
        # waiting for pipes to close (v6.1.22 fix).
        Start-Process -FilePath $exePath -WorkingDirectory $repoRoot -WindowStyle Normal
        Info "dune-admin started from $exePath"
    } else {
        Info "Build complete. Re-run with -Restart to relaunch, or start dune-admin manually."
    }
}
finally {
    Pop-Location
    if ($script:TempPatchFiles) {
        foreach ($tmp in $script:TempPatchFiles) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
