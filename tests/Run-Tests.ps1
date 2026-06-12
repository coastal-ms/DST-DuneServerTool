# Run-Tests.ps1
# Entrypoint for the DST PowerShell test suite (Pester 5).
#
# Usage:
#   pwsh -NoProfile -File tests\Run-Tests.ps1                # run all
#   pwsh -NoProfile -File tests\Run-Tests.ps1 -Path .\Rmq.Tests.ps1
#   pwsh -NoProfile -File tests\Run-Tests.ps1 -Tag Schema    # filter by tag
[CmdletBinding()]
param(
    [string[]] $Path,
    [string[]] $Tag,
    [switch]   $CI
)

$ErrorActionPreference = 'Stop'

$module = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $module) {
    Write-Host "Pester 5+ not installed. Install with:" -ForegroundColor Yellow
    Write-Host "  Install-Module -Name Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force"
    exit 2
}

Import-Module $module.Path -Force

$testRoot = $PSScriptRoot
$repoRoot = Split-Path $testRoot -Parent
$env:DST_REPO_ROOT = $repoRoot

$config = New-PesterConfiguration
$config.Run.Path = if ($Path) {
    $Path | ForEach-Object {
        if ([IO.Path]::IsPathRooted($_)) { $_ }
        elseif (Test-Path $_)             { (Resolve-Path $_).Path }
        else                              { Join-Path $testRoot (Split-Path -Leaf $_) }
    }
} else { $testRoot }
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $CI.IsPresent
if ($CI) {
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $testRoot 'TestResults.xml'
}
if ($Tag) { $config.Filter.Tag = $Tag }

$result = Invoke-Pester -Configuration $config

if ($result.FailedCount -gt 0) {
    Write-Host ""
    Write-Host "$($result.FailedCount) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "All $($result.PassedCount) tests passed." -ForegroundColor Green
exit 0
