BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
}

Describe 'Solo Mode route registration' {
    It 'registers PTC console settings as local-only read and write routes' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, [switch]$LocalOnly, $Handler)
                [pscustomobject]@{
                    method = $Method
                    path = $Path
                    localOnly = [bool]$LocalOnly
                }
            }
            . $script:RouteFile
        })

        $consoleRoutes = @($routes |
            Where-Object path -eq '/api/solo/console-settings' |
            Sort-Object method)
        $consoleRoutes.Count | Should -Be 2
        $consoleRoutes.method | Should -Be @('GET', 'PUT')
        @($consoleRoutes | Where-Object { -not $_.localOnly }).Count | Should -Be 0
    }
}
