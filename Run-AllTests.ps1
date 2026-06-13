# Run-AllTests.ps1
# Top-level convenience runner: executes the PowerShell (Pester 5) suite for
# the server + the Vitest suite for the webui. Use this from CI or to do a
# pre-commit smoke. Exit code is non-zero if either side fails.
#
# Usage:
#   pwsh -NoProfile -File Run-AllTests.ps1
#   pwsh -NoProfile -File Run-AllTests.ps1 -SkipWebUI    # backend only
#   pwsh -NoProfile -File Run-AllTests.ps1 -SkipServer   # webui only
[CmdletBinding()]
param(
    [switch] $SkipServer,
    [switch] $SkipWebUI,
    [switch] $CI
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$failures = @()

if (-not $SkipServer) {
    Write-Host ""
    Write-Host "=== Running PowerShell (Pester) tests ===" -ForegroundColor Cyan
    $pesterArgs = @()
    if ($CI) { $pesterArgs += '-CI' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot 'tests\Run-Tests.ps1') @pesterArgs
    if ($LASTEXITCODE -ne 0) { $failures += "Pester (exit $LASTEXITCODE)" }
}

if (-not $SkipWebUI) {
    Write-Host ""
    Write-Host "=== Running Vitest (webui) ===" -ForegroundColor Cyan
    Push-Location (Join-Path $repoRoot 'webui')
    try {
        # Use cmd.exe to invoke npm.cmd directly; the bare `npm` shim on
        # PowerShell 7 mangles arg-passing through the call operator.
        $npm = (Get-Command npm -ErrorAction Stop).Source
        if ($npm -like '*.ps1') { $npm = 'npm.cmd' }
        & cmd.exe /c "$npm test"
        if ($LASTEXITCODE -ne 0) { $failures += "Vitest (exit $LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "FAILED: $($failures -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "All test suites passed." -ForegroundColor Green
exit 0
