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

    It 'registers Solo blueprint list and export as local-only routes' {
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

        $blueprintRoutes = @($routes | Where-Object {
            $_.path -in @('/api/solo/blueprints', '/api/solo/blueprints/export')
        })
        $blueprintRoutes.Count | Should -Be 2
        @($blueprintRoutes | Where-Object { -not $_.localOnly }).Count | Should -Be 0
    }

    It 'rejects fractional <field> before invoking the setter' -TestCases @(
        @{ field = 'skillPoints'; message = 'Skill points must be a whole number.' }
        @{ field = 'intel'; message = 'Intel points must be a whole number.' }
    ) {
        param($field, $message)
        $result = & {
            param($field)
            function Register-DuneRoute {
                param($Method, $Path, [switch]$LocalOnly, $Handler)
                [pscustomobject]@{
                    method = $Method
                    path = $Path
                    handler = $Handler
                }
            }
            $routes = @(. $script:RouteFile)
            $route = $routes | Where-Object {
                $_.method -eq 'PUT' -and $_.path -eq '/api/solo/progression/points'
            } | Select-Object -First 1

            $script:setProgressionPointsCalled = $false
            $script:soloRouteError = $null
            function Set-DuneSoloProgressionPoints { $script:setProgressionPointsCalled = $true }
            function Invoke-WithDuneLock { param($Name, $Script); & $Script }
            function Assert-DuneSoloExpectedProfile {}
            function Write-DuneJson {}
            function Write-DuneError {
                param($Response, $Status, $Message)
                $script:soloRouteError = [pscustomobject]@{ status = $Status; message = $Message }
            }

            $body = @{
                skillPoints = 1.5
                intel = 2
                confirm = 'SET SOLO PROGRESSION POINTS'
            }
            if ($field -eq 'intel') {
                $body.skillPoints = 1
                $body.intel = 2.5
            }
            & $route.handler $null $null $null $body
            [pscustomobject]@{
                setterCalled = $script:setProgressionPointsCalled
                error = $script:soloRouteError
            }
        } $field

        $result.setterCalled | Should -BeFalse
        $result.error.status | Should -Be 400
        $result.error.message | Should -Be $message
    }
}
