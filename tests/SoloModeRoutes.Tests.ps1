BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    $script:RouteFile = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
}

Describe 'Solo Mode route registration' {
    It 'keeps bulk grants local-only and rejects a changed profile before writing' {
        $result = & {
            function Register-DuneRoute {
                param($Method, $Path, [switch]$LocalOnly, $Handler)
                [pscustomobject]@{ path=$Path; localOnly=[bool]$LocalOnly; handler=$Handler }
            }
            $route = @(. $script:RouteFile) | Where-Object path -eq '/api/solo/grant-unlocks'
            $script:bulkCalled = $false
            $script:bulkError = $null
            function Invoke-WithDuneLock { param($Name, $Script); & $Script }
            function Assert-DuneSoloExpectedProfile { throw 'Solo profile changed in another window.' }
            function Invoke-DuneSoloGrantUnlocks { $script:bulkCalled = $true }
            function Write-DuneJson {}
            function Write-DuneError { param($Response, $Status, $Message); $script:bulkError=$Status }
            & $route.handler $null $null $null @{kind='building-sets';expectedProfileToken='old'}
            [pscustomobject]@{localOnly=$route.localOnly;called=$script:bulkCalled;status=$script:bulkError}
        }
        $result.localOnly | Should -BeTrue
        $result.called | Should -BeFalse
        $result.status | Should -Be 409
    }
    It 'keeps diagnostic export and specialization edits local-only' {
        $routes = @(& {
            function Register-DuneRoute {
                param($Method, $Path, [switch]$LocalOnly, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; localOnly = [bool]$LocalOnly }
            }
            . $script:RouteFile
        })
        $newRoutes = @($routes | Where-Object { $_.path -in @('/api/solo/diagnostics', '/api/solo/progression/specializations', '/api/solo/progression/specializations/reset-rewards') })
        $newRoutes.Count | Should -Be 3
        @($newRoutes | Where-Object { -not $_.localOnly }).Count | Should -Be 0
    }

    It 'rejects an invalid specialization request before writing (<case>)' -TestCases @(
        @{ case = 'fractional level'; level = 37.5; stale = $false; status = 400 }
        @{ case = 'changed profile'; level = 37; stale = $true; status = 409 }
        @{ case = 'changed profile during reward reset'; level = 37; stale = $true; status = 409 }
    ) {
        param($case, $level, $stale, $status)
        $result = & {
            param($level, $stale, $case)
            function Register-DuneRoute {
                param($Method, $Path, [switch]$LocalOnly, $Handler)
                [pscustomobject]@{ method = $Method; path = $Path; handler = $Handler }
            }
            $path = if ($case -eq 'changed profile during reward reset') { '/api/solo/progression/specializations/reset-rewards' } else { '/api/solo/progression/specializations' }
            $route = @(. $script:RouteFile) | Where-Object path -eq $path
            $script:specializationCalled = $false
            $script:specializationError = $null
            function Set-DuneSoloSpecialization { $script:specializationCalled = $true }
            function Reset-DuneSoloSpecializationRewards { $script:specializationCalled = $true }
            function Invoke-WithDuneLock { param($Name, $Script); & $Script }
            function Assert-DuneSoloExpectedProfile {
                if ($stale) { throw 'Solo profile changed in another window.' }
            }
            function Write-DuneJson {}
            function Write-DuneError {
                param($Response, $Status, $Message)
                $script:specializationError = $Status
            }
            & $route.handler $null $null $null @{ track = 'Crafting'; level = $level; expectedProfileToken = 'old'; confirm = 'SET SOLO SPECIALIZATION' }
            [pscustomobject]@{ called = $script:specializationCalled; status = $script:specializationError }
        } $level $stale $case
        $result.called | Should -BeFalse
        $result.status | Should -Be $status
    }

    It 'registers Retail console settings as local-only read and write routes' {
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
