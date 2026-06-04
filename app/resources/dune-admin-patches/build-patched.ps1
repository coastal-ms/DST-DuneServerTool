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

# --- Non-interactive guards --------------------------------------------------
# This script is normally launched DETACHED (no console, no stdin) by the Dune
# Server Tool's pricing-patch wrapper. Any tool that tries to prompt on stdin
# would block FOREVER — the build produces no output, leaving an idle node/
# corepack process, a 0-byte log, and the patch stuck on "running". The most
# common offender is corepack's first-run "About to download pnpm@X — continue?
# [Y/n]" confirmation (hit when the standalone pnpm shim is stale and we fall
# back to corepack). Force every step non-interactive so it can never hang.
$env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'   # corepack: auto-yes the download
$env:CI                               = '1'  # most JS tools: assume non-TTY/CI
$env:npm_config_yes                   = 'true'
$env:DO_NOT_TRACK                     = '1'
$scriptRoot = $PSScriptRoot
$repoRoot   = Split-Path -Parent $scriptRoot
$exePath    = Join-Path $repoRoot 'dune-admin.exe'

# --- pnpm content-addressable store (warm-store reuse) -----------------------
# pnpm hardlinks packages from a global content-addressable store into
# node_modules, but hardlinks CANNOT span volumes. dune-admin source commonly
# lives on a non-system drive (e.g. E:\DuneAdminMain) while pnpm's default store
# sits on C: under %LOCALAPPDATA% — so a fresh install re-downloads the whole
# ~480-package tree every time ("reused 0") instead of linking from the store.
# Pin the store to a stable dir on the BUILD's own volume so installs hardlink
# from a warm store and become near-instant on repeat builds. Passed explicitly
# via --store-dir on every install (works for both real pnpm and corepack pnpm).
$pnpmStoreDir = $null
try {
    $qualifier = Split-Path -Qualifier $repoRoot   # e.g. 'E:' (empty for UNC)
    if ($qualifier) {
        $pnpmStoreDir = Join-Path "$qualifier\" '.dst-pnpm-store'
        if (-not (Test-Path -LiteralPath $pnpmStoreDir)) {
            New-Item -ItemType Directory -Path $pnpmStoreDir -Force -ErrorAction Stop | Out-Null
        }
    }
} catch { $pnpmStoreDir = $null }

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

# --- Resolve GNU patch.exe (compatibility-mode fallback) ---------------------
# Git for Windows ships a full GNU patch under usr\bin\. We use it as a
# fuzz-tolerant fallback when `git apply` (which requires byte-exact context)
# refuses a patch whose context lines have drifted slightly because upstream
# made a small unrelated change inside our context window — typically a new
# function parameter on a signature line we depend on, or a reworded comment
# next to a hunk. `git apply` already tolerates line-offset drift (it'll
# locate the hunk a few lines up or down), so the fuzz fallback ONLY fires
# for context-byte mismatches.
#
# Strategy: try fuzz=2 first (conservative — at most 2 of 6 context lines
# may mismatch). If that rejects, escalate ONCE to fuzz=3 (effectively
# matches on the removed/added lines alone). Both paths run the SAME post-
# apply invariants check, which is the real safety net: it verifies the
# patch left behind the expected semantic markers (math/rand import,
# 100k-cap constant, d12 roll, removed BuyThreshold gate, …), and reverts
# the working tree if any check fails. So even the permissive fuzz=3 tier
# can't silently land a hunk in the wrong function — it'd fail the check
# and bail.
$patchExe = Resolve-ToolDir -Name 'patch' -Candidates @(
    "$env:ProgramFiles\Git\usr\bin\patch.exe",
    "${env:ProgramFiles(x86)}\Git\usr\bin\patch.exe",
    "$env:LOCALAPPDATA\Programs\Git\usr\bin\patch.exe"
)
if ($patchExe) {
    $patchExePath = Join-Path $patchExe 'patch.exe'
    if (-not (Test-Path -LiteralPath $patchExePath)) { $patchExePath = $null }
} else { $patchExePath = $null }

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
#
# IMPORTANT: never trust `Get-Command pnpm` blindly. The standalone pnpm
# installer drops a `pnpm.ps1`/`pnpm.cmd` shim on PATH that points at a
# *versioned* global exe (…\pnpm\global\v11\<hash>\…\pnpm.exe). When pnpm
# self-updates (or that global dir is cleaned), the shim survives but the exe it
# targets is gone — so `& pnpm install` dies with "pnpm.exe is not recognized"
# even though `pnpm` is on PATH. We therefore PROBE each candidate by actually
# running `--version` and only accept one that works; otherwise we fall back to
# corepack's pnpm, which is independent of the standalone shim.
function Test-PnpmCandidate {
    param([string]$Exe, [string[]]$Pre = @())
    if (-not $Exe) { return $false }
    try {
        $probeArgs = @() + $Pre + @('--version')
        $out = & $Exe @probeArgs 2>&1
        $text = ($out | Out-String)
        return [bool](($LASTEXITCODE -eq 0) -or ($text -match '\d+\.\d+\.\d+'))
    } catch { return $false }
}
function Resolve-Pnpm {
    # 1) pnpm on PATH — but only if it actually runs (guards the stale shim).
    $direct = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($direct -and $direct.Source -and (Test-PnpmCandidate -Exe $direct.Source)) {
        return @{ Exe = $direct.Source; Pre = @() }
    }
    # 2) corepack: enable, then re-probe a (possibly freshly shimmed) pnpm.
    $corepack = Get-Command corepack -ErrorAction SilentlyContinue
    if ($corepack -and $corepack.Source) {
        try { & $corepack.Source enable pnpm 2>$null | Out-Null } catch { }
        $direct2 = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($direct2 -and $direct2.Source -and (Test-PnpmCandidate -Exe $direct2.Source)) {
            return @{ Exe = $direct2.Source; Pre = @() }
        }
        # 3) run pnpm THROUGH corepack (independent of the standalone shim).
        if (Test-PnpmCandidate -Exe $corepack.Source -Pre @('pnpm')) {
            return @{ Exe = $corepack.Source; Pre = @('pnpm') }
        }
    }
    return $null
}
$pnpm = Resolve-Pnpm
if (-not $pnpm) {
    throw "pnpm was not found, or the pnpm on PATH is broken (its shim points at a pnpm.exe that no longer exists, e.g. after a pnpm self-update), and it could not be bootstrapped via corepack (which ships with Node). Fix it by running 'corepack enable pnpm', or reinstall pnpm with 'npm install -g pnpm', then re-apply the patch. The patched build needs pnpm to build the embedded dune-admin web UI."
}
$pnpmExe = $pnpm.Exe
$pnpmPre = $pnpm.Pre

# --- Stale flat-file shadow cleanup (web/src/) -------------------------------
# Sync-DuneAdminSourceTarball in DuneAdmin.ps1 overlays the upstream tarball
# with `robocopy /E`, which is additive — it never deletes files that were
# removed upstream. When the upstream `web/src/` tree refactors a flat
# component file (Foo.tsx) into a directory (Foo/index.tsx), the deleted
# flat file lingers on disk as an orphan from the prior install. TypeScript
# / Vite module resolution prefers a bare `.tsx` over a sibling `dir/index.tsx`,
# so the stale flat file SHADOWS the new directory and the build picks it up
# instead — with predictable disasters: named imports of a default-exported
# symbol fail (TS2614), type literals miss new required fields (TS2741), etc.
#
# Concrete instance that motivated this code: upstream Icehunter/dune-admin
# v0.24.0 refactored web/src/tabs/WelcomePackageTab.tsx into
# web/src/tabs/WelcomePackageTab/index.tsx (plus views/, types.ts). Users
# upgrading from v0.23.x kept the old flat file, App.tsx's
# `import { WelcomePackageTab } from './tabs/WelcomePackageTab'` resolved to
# the stale flat file (which exported the symbol as default and lacked the
# new active_versions field), and `pnpm build` failed every reinstall with:
#   src/App.tsx(20,10): error TS2614 ...
#   src/tabs/WelcomePackageTab.tsx(138,13): error TS2741 ...
#
# The fix is purely local: scan web/src/ for any `Foo.tsx` / `Foo.ts` that
# has a sibling `Foo/` directory containing `index.tsx` / `index.ts`, and
# delete the flat file (the directory wins on disk if the flat sibling is
# gone). This is safe by construction — you never legitimately ship a flat
# `Foo.tsx` next to a sibling `Foo/index.tsx`; the pattern only arises as a
# refactor leftover. We also nuke the .dst-web-build-stamp on any removal so
# the prior dist (which may have been built FROM the stale file) gets
# rebuilt, not reused.
function Remove-StaleFlatFileShadows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $removed = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $removed }
    $candidates = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Extension -eq '.tsx' -or $_.Extension -eq '.ts') -and
            $_.Name -ne 'index.tsx' -and $_.Name -ne 'index.ts' -and
            $_.Name -notlike '*.d.ts'
        }
    foreach ($f in $candidates) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $siblingDir = Join-Path $f.Directory.FullName $base
        if (-not (Test-Path -LiteralPath $siblingDir -PathType Container)) { continue }
        $hasIndex = (Test-Path -LiteralPath (Join-Path $siblingDir 'index.tsx')) -or
                    (Test-Path -LiteralPath (Join-Path $siblingDir 'index.ts'))
        if (-not $hasIndex) { continue }
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $removed.Add($f.FullName) | Out-Null
        } catch {
            # Best-effort: if we can't delete (locked, AV, perms), the build
            # will fail with the original TS error below — which is no worse
            # than the pre-fix behavior. Log and continue.
            Write-Host "    WARN: could not remove stale shadow $($f.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return $removed
}

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

            # Neither forward nor reverse — git apply rejects the patch.
            # Before giving up, try GNU `patch.exe` in compatibility mode
            # (fuzz=1): `git apply` requires byte-exact context, which means
            # even a single unrelated upstream tweak inside our context
            # window (e.g. a new function parameter, a renamed local var, a
            # reworded comment) makes it refuse to apply — even when our
            # actual edit lines are still perfectly placeable. GNU patch
            # tolerates this drift; we then verify the resulting file
            # contains the expected semantic markers ("invariants") to
            # guarantee we didn't quietly land a hunk in the wrong place.
            #
            # We deliberately do NOT `git restore` + force-apply: when this
            # script runs from the installer, the working tree was just
            # overlaid from an upstream source tarball, and `git restore`
            # reverts to whatever the user's local git HEAD happens to be
            # (often an older release), which strips the new symbols
            # bot.go/exchange.go reference and breaks the build with
            # confusing "undefined: LoadState" errors.
            $fuzzApplied = $false
            if ($patchExePath) {
                Info "git apply refused (likely upstream context drift) — trying GNU patch.exe (compatibility mode)."

                # Snapshot pre-patch bytes BEFORE patch.exe touches anything,
                # so the revert/invariant-failure path can restore exactly.
                foreach ($t in $touched) {
                    $tPath = Join-Path $repoRoot $t
                    if ((Test-Path -LiteralPath $tPath) -and -not $preSnapshots.ContainsKey($t)) {
                        $preSnapshots[$t] = [System.IO.File]::ReadAllBytes($tPath)
                    }
                }

                # Try fuzz tiers in ascending order. fuzz=2 is conservative
                # (≥4 of 6 context lines must match); fuzz=3 effectively
                # matches on the removed/added lines alone (needed when the
                # drift is on a context line in the middle of the hunk
                # window, e.g. a function-signature change). Either tier
                # goes through the SAME invariants check below.
                $chosenFuzz = $null
                foreach ($fuzz in 2, 3) {
                    # --batch suppresses ALL prompts so a renamed/missing
                    # file can never hang on stdin; --forward refuses to
                    # silently reverse-apply; --no-backup-if-mismatch
                    # prevents .orig file litter; --dry-run is non-mutating
                    # so we can probe both fuzz tiers safely.
                    $dryArgs = @('-p1', '--batch', '--forward', '--no-backup-if-mismatch', "-F$fuzz", '--dry-run', '-i', $applyPath)
                    $dryOut  = & $patchExePath @dryArgs 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        $chosenFuzz = $fuzz
                        break
                    } else {
                        Info "patch.exe dry-run rejected fuzz=$fuzz (exit $LASTEXITCODE)."
                    }
                }

                if ($null -ne $chosenFuzz) {
                    $applyArgs = @('-p1', '--batch', '--forward', '--no-backup-if-mismatch', "-F$chosenFuzz", '-i', $applyPath)
                    $applyOut  = & $patchExePath @applyArgs 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Info "patch.exe applied with fuzz=$chosenFuzz — COMPATIBILITY MODE active (verifying invariants below)."
                        foreach ($line in @($applyOut)) {
                            $s = "$line"
                            if ($s -match 'Hunk #|with fuzz|with offset|succeeded') { Info "  $s" }
                        }

                        # Invariants: each known patched marker MUST be
                        # present after a successful apply. These guard
                        # against a fuzz=3 application landing a hunk in
                        # the wrong function (e.g. if upstream renamed the
                        # patched function and a similar `if X { return }`
                        # block exists elsewhere — vanishingly unlikely
                        # given the specific removed text, but enforced
                        # here regardless). On any violation we restore
                        # the pre-patch snapshot byte-for-byte and bail.
                        $invariantViolations = @()
                        $invariants = @(
                            @{ File = 'internal\marketbot\exchange.go'; Needle = '"math/rand"';            Why = 'math/rand import' },
                            @{ File = 'internal\marketbot\exchange.go'; Needle = 'd12 gamble-buy';         Why = 'd12 gamble-buy comment' },
                            @{ File = 'internal\marketbot\exchange.go'; Needle = 'rand.Intn(';             Why = 'rand.Intn() roll' },
                            @{ File = 'internal\marketbot\pricing.go';  Needle = 'maxAnyPrice';            Why = '100k cap constant' },
                            @{ File = 'internal\marketbot\pricing.go';  Needle = 'tierBasePrice';          Why = 'tier-based pricing function' },
                            @{ File = 'internal\marketbot\pricing.go';  Needle = 'func capPrice(';         Why = 'capPrice helper' },
                            @{ File = 'internal\marketbot\config.go';   Needle = 'saneDefaultsRevision';   Why = 'defaults-revision migration constant' }
                        )
                        foreach ($inv in $invariants) {
                            $invFile = Join-Path $repoRoot $inv.File
                            if (-not (Test-Path -LiteralPath $invFile)) {
                                $invariantViolations += "$($inv.File): file missing"
                                continue
                            }
                            $bytes = [System.IO.File]::ReadAllBytes($invFile)
                            $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
                            if ($text -notlike "*$($inv.Needle)*") {
                                $invariantViolations += "$($inv.File): missing $($inv.Why) (`"$($inv.Needle)`")"
                            }
                        }
                        # Also: the BuyThreshold short-circuit MUST be gone
                        # from buyPlayerListings (otherwise the gamble-buy
                        # path is unreachable when threshold<=0). The
                        # `snap.BuyThreshold` reference still exists in
                        # other functions, so we scope the check to a
                        # window after the function signature.
                        $exGo = Join-Path $repoRoot 'internal\marketbot\exchange.go'
                        if (Test-Path -LiteralPath $exGo) {
                            $exText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($exGo))
                            if ($exText -match 'buyPlayerListings[\s\S]{0,300}snap\.BuyThreshold\s*<=\s*0') {
                                $invariantViolations += "internal\marketbot\exchange.go: BuyThreshold short-circuit was not removed from buyPlayerListings (patch landed wrong hunk)"
                            }
                        }

                        if ($invariantViolations.Count -gt 0) {
                            Info "Post-apply invariants failed (compatibility-mode result is unsafe):"
                            foreach ($v in $invariantViolations) { Info "  - $v" }
                            foreach ($t in $touched) {
                                $tPath = Join-Path $repoRoot $t
                                if ($preSnapshots.ContainsKey($t)) {
                                    try { [System.IO.File]::WriteAllBytes($tPath, $preSnapshots[$t]) } catch { }
                                }
                                foreach ($ext in @('.rej', '.orig')) {
                                    $litter = "$tPath$ext"
                                    if (Test-Path -LiteralPath $litter) { Remove-Item -LiteralPath $litter -Force -ErrorAction SilentlyContinue }
                                }
                            }
                            throw "Compatibility-mode apply landed in a semantically-wrong location: $($p.Name). Update the Dune Server Tool (which ships the patch) and reinstall to refresh it."
                        }

                        # Clean up any benign .rej / .orig that patch may
                        # have left even on a successful apply (rare with
                        # --no-backup-if-mismatch, but be defensive).
                        foreach ($t in $touched) {
                            $tPath = Join-Path $repoRoot $t
                            foreach ($ext in @('.rej', '.orig')) {
                                $litter = "$tPath$ext"
                                if (Test-Path -LiteralPath $litter) { Remove-Item -LiteralPath $litter -Force -ErrorAction SilentlyContinue }
                            }
                        }
                        $patchedFiles += $touched
                        $fuzzApplied = $true
                    } else {
                        Info "patch.exe failed despite passing dry-run at fuzz=$chosenFuzz (exit $LASTEXITCODE):"
                        foreach ($line in @($applyOut)) { Info "  $line" }
                        foreach ($t in $touched) {
                            $tPath = Join-Path $repoRoot $t
                            if ($preSnapshots.ContainsKey($t)) {
                                try { [System.IO.File]::WriteAllBytes($tPath, $preSnapshots[$t]) } catch { }
                            }
                            foreach ($ext in @('.rej', '.orig')) {
                                $litter = "$tPath$ext"
                                if (Test-Path -LiteralPath $litter) { Remove-Item -LiteralPath $litter -Force -ErrorAction SilentlyContinue }
                            }
                        }
                    }
                } else {
                    # Dry-run didn't modify anything, but the snapshot
                    # bookkeeping shouldn't leak into the revert step.
                    foreach ($t in $touched) {
                        if ($preSnapshots.ContainsKey($t)) { $preSnapshots.Remove($t) | Out-Null }
                    }
                }
            } else {
                Info "GNU patch.exe was not found at the standard Git-for-Windows location — cannot try compatibility mode."
            }
            if ($fuzzApplied) { continue }

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
        # The web UI is identical across pricing-patch rebuilds (the sane-pricing
        # patch only touches Go), so re-running `pnpm install` (which re-resolves
        # and re-downloads the full ~480-package dependency tree) + `pnpm build`
        # on every reinstall is pure waste. Skip it when the prerequisites are
        # already in place: node_modules present, a prior web\dist\index.html
        # exists, and the build inputs (upstream VERSION + pnpm-lock.yaml) match
        # the last successful web build. ANY version or lockfile change
        # invalidates the stamp and forces a fresh install+build, so correctness
        # is preserved — we only skip when the inputs are provably unchanged.
        $webDir = Join-Path $repoRoot 'web'
        if (-not (Test-Path -LiteralPath (Join-Path $webDir 'package.json'))) {
            throw "web\package.json not found at $webDir — cannot build the dune-admin web UI to embed."
        }
        $webDist     = Join-Path $webDir 'dist'
        $nodeModules = Join-Path $webDir 'node_modules'
        $lockFile    = Join-Path $webDir 'pnpm-lock.yaml'
        $webStamp    = Join-Path $webDir '.dst-web-build-stamp'

        # Purge stale flat-file shadows left over by the additive tarball
        # overlay (see Remove-StaleFlatFileShadows docs above). Must run
        # BEFORE the prereqs check — any removal forces a rebuild because the
        # prior dist may have embedded code from the stale file.
        $webSrc = Join-Path $webDir 'src'
        $shadowsRemoved = Remove-StaleFlatFileShadows -Root $webSrc
        if ($shadowsRemoved.Count -gt 0) {
            Step "Removed $($shadowsRemoved.Count) stale flat-file shadow(s) under web\src\ (upstream refactor leftovers)"
            foreach ($r in $shadowsRemoved) {
                $rel = $r
                if ($r.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $r.Substring($repoRoot.Length).TrimStart('\','/')
                }
                Info "removed $rel (shadowed by sibling directory with index.ts[x])"
            }
            # Invalidate the build stamp so the cached dist (potentially built
            # FROM the stale file) gets rebuilt.
            if (Test-Path -LiteralPath $webStamp) {
                try { Remove-Item -LiteralPath $webStamp -Force -ErrorAction Stop } catch { }
            }
        }
        $lockHash = ''
        if (Test-Path -LiteralPath $lockFile) {
            try { $lockHash = (Get-FileHash -LiteralPath $lockFile -Algorithm SHA256).Hash } catch { }
        }
        $wantStamp = "$version|$lockHash"
        $haveStamp = ''
        if (Test-Path -LiteralPath $webStamp) {
            try { $haveStamp = (Get-Content -LiteralPath $webStamp -Raw).Trim() } catch { }
        }
        $webPrereqsReady = (Test-Path -LiteralPath $nodeModules) -and `
                           (Test-Path -LiteralPath (Join-Path $webDist 'index.html')) -and `
                           $lockHash -and ($haveStamp -eq $wantStamp)
        if ($webPrereqsReady) {
            Step "Web UI already built (v$version, deps installed) - skipping pnpm install + build"
            Info "Reusing existing web\dist (build stamp matches). Delete $webStamp to force a rebuild."
        } else {
            Step "pnpm install + build (web UI for embedding)"
            if (-not (Test-Path -LiteralPath $nodeModules)) {
                Info "node_modules missing - installing dependencies."
            } elseif ($haveStamp -ne $wantStamp) {
                Info "Build inputs changed (VERSION/pnpm-lock) - rebuilding web UI."
            }
            Push-Location $webDir
            try {
                # --prefer-offline reuses the pnpm content-addressable store so a
                # forced rebuild doesn't re-download packages it already has.
                # --store-dir pins that store to the build's own volume so the
                # reuse is via hardlink (instant) rather than a cross-drive miss.
                $installArgs = @('install', '--frozen-lockfile', '--prefer-offline')
                if ($pnpmStoreDir) {
                    $installArgs += @('--store-dir', $pnpmStoreDir)
                    Info "pnpm store: $pnpmStoreDir (same-volume warm store)"
                }
                & $pnpmExe @pnpmPre @installArgs
                if ($LASTEXITCODE -ne 0) { throw "pnpm install failed (web UI)." }
                & $pnpmExe @pnpmPre build
                if ($LASTEXITCODE -ne 0) { throw "pnpm build failed (web UI)." }
            } finally { Pop-Location }
            if (-not (Test-Path -LiteralPath (Join-Path $webDist 'index.html'))) {
                throw "web build produced no dist\index.html — refusing to build a UI-less binary."
            }
            # Stamp the successful build so the next reinstall can skip it.
            try { Set-Content -LiteralPath $webStamp -Value $wantStamp -Encoding ascii -ErrorAction Stop } catch { }
        }
        $embedDist = Join-Path $repoRoot 'cmd\dune-admin\dist'
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
        # Stamp the patched binary so the Dune Server Tool can skip a redundant
        # download + rebuild on the next reinstall of the SAME upstream version
        # and gamble-die config (the result would be byte-identical). Best-effort:
        # a stamp failure must never fail an otherwise-successful build.
        try {
            Set-Content -LiteralPath "$exePath.coastal-sane-pricing" `
                        -Value "$version|$GambleDie|$GambleTarget" -Encoding ascii -ErrorAction Stop
            Info "patched stamp: $version|$GambleDie|$GambleTarget"
        } catch { }
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
