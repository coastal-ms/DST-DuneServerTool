# Smoke test: every server lib and route file dot-sources cleanly with the
# HTTP shims stubbed out. Catches any regression that breaks server boot.

BeforeDiscovery {
    $repoRoot = $env:DST_REPO_ROOT
    if (-not $repoRoot -or -not (Test-Path $repoRoot)) {
        $repoRoot = Split-Path $PSScriptRoot -Parent
    }
    $script:LibFiles   = @(Get-ChildItem (Join-Path $repoRoot 'app\server\lib')    -Filter '*.ps1' | Sort-Object Name)
    $script:RouteFiles = @(Get-ChildItem (Join-Path $repoRoot 'app\server\routes') -Filter '*.ps1' | Sort-Object Name)
}

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Register-DstStubs
}

Describe 'Server libs load cleanly' -Tag 'Smoke' {
    It '<_.Name> parses + dot-sources without errors' -ForEach $script:LibFiles {
        { . $_.FullName } | Should -Not -Throw
    }
}

Describe 'Server route registrations load cleanly' -Tag 'Smoke' {
    BeforeAll {
        # Routes depend on lib + HttpServer; load both before iterating routes.
        $libDir = Join-Path (Get-DstRepoRoot) 'app\server\lib'
        Get-ChildItem $libDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
        $serverPs1 = Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1'
        if (Test-Path $serverPs1) { . $serverPs1 }
    }
    It '<_.Name> registers without errors' -ForEach $script:RouteFiles {
        { . $_.FullName } | Should -Not -Throw
    }
}
