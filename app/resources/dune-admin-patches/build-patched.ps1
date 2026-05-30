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
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.4+ makes native commands (git, go) respect $ErrorActionPreference,
# which causes harmless stderr like git's "LF will be replaced by CRLF" warning
# to throw. We rely on explicit $LASTEXITCODE checks below, so opt out.
$PSNativeCommandUseErrorActionPreference = $false
$scriptRoot = $PSScriptRoot
$repoRoot   = Split-Path -Parent $scriptRoot
$exePath    = Join-Path $repoRoot 'dune-admin.exe'

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

    $patchedFiles = @()
    if ($patches.Count -eq 0) {
        Info "No patches in scripts\patches\ — building straight upstream."
    } else {
        Step "Applying $($patches.Count) patch(es) from scripts\patches\"
        foreach ($p in $patches) {
            Info "git apply $($p.Name)"
            # Determine which files this patch touches (works regardless of
            # apply state) — used for revert tracking and for cleanup on
            # conflict.
            $touched = @(& git apply --numstat -- $p.FullName 2>$null |
                        ForEach-Object { ($_ -split "`t")[2] } |
                        Where-Object { $_ })

            # Try clean apply.
            & git apply --check -- $p.FullName 2>$null
            if ($LASTEXITCODE -eq 0) {
                & git apply --whitespace=nowarn -- $p.FullName
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
            & git apply --reverse --check -- $p.FullName 2>$null
            if ($LASTEXITCODE -eq 0) {
                Info "Patch is already applied to the working tree — using as-is."
                $patchedFiles += $touched
                continue
            }

            # Neither forward nor reverse — the patch is stale relative to
            # the current source. Surface a clear diagnostic and stop. We
            # deliberately do NOT `git restore` + force-apply: when this
            # script runs from the installer, the working tree was just
            # overlaid from an upstream source tarball, and `git restore`
            # reverts to whatever the user's local git HEAD happens to be
            # (often an older release), which strips the new symbols
            # bot.go/exchange.go reference and breaks the build with
            # confusing "undefined: LoadState" errors. Failing fast tells
            # the user the real problem: ship a refreshed patch.
            Info "Patch does not apply cleanly and is not already applied."
            Info "Touched files: $($touched -join ', ')"
            Info "Likely cause: the bundled patch was authored against an"
            Info "older dune-admin baseline. Update the Dune Server Tool"
            Info "(which ships the patch) and reinstall."
            throw "Patch is stale relative to current source: $($p.Name). Refusing to corrupt the working tree."
        }
        # De-duplicate file list for the revert step.
        $patchedFiles = @($patchedFiles | Sort-Object -Unique)
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
        $version    = (Get-Content (Join-Path $repoRoot 'VERSION') -Raw).Trim()
        $gitCommit  = (& git rev-parse --short HEAD).Trim()
        $buildTime  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $ldflags    = "-s -w -X main.AppVersion=$version -X main.GitCommit=$gitCommit -X main.BuildTime=$buildTime"
        $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
        try {
            & go build -trimpath -ldflags $ldflags -o $exePath ./cmd/dune-admin
            if ($LASTEXITCODE -ne 0) { throw "go build failed." }
        } finally {
            Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
        }
        $exe = Get-Item $exePath
        Info "built: $($exe.FullName) ($([math]::Round($exe.Length / 1MB, 2)) MB)"
        Info "version=$version commit=$gitCommit"
    } finally {
        if (-not $Keep -and $patchedFiles.Count -gt 0) {
            Step "Reverting patched files (working tree → clean upstream)"
            foreach ($f in $patchedFiles) {
                Info "git restore $f"
                & git restore -- $f
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
}
