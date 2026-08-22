BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
}

Describe 'HTTP local-only request enforcement' {
    It 'accepts IPv4 loopback without proxy headers' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::Loopback }
            Headers = @{}
        }
        Test-DuneLocalOnlyRequest -Request $request | Should -BeTrue
    }

    It 'accepts IPv6 loopback without proxy headers' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::IPv6Loopback }
            Headers = @{}
        }
        Test-DuneLocalOnlyRequest -Request $request | Should -BeTrue
    }

    It 'rejects non-loopback clients' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::Parse('192.0.2.10') }
            Headers = @{}
        }
        Test-DuneLocalOnlyRequest -Request $request | Should -BeFalse
    }

    It 'rejects tunneled requests whose proxy connects from loopback' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::Loopback }
            Headers = @{ 'Cf-Connecting-Ip' = '198.51.100.12' }
        }
        Test-DuneLocalOnlyRequest -Request $request | Should -BeFalse
    }

    It 'records LocalOnly metadata on registered routes' {
        $before = $script:DuneRoutes.Count
        Register-DuneRoute -Method GET -Path '/api/test-local-only' -LocalOnly -Handler {}
        $route = $script:DuneRoutes[$before]
        $route.LocalOnly | Should -BeTrue
    }

    It 'keeps ad-hoc database SQL host-local' {
        $routes = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Database.ps1') -Raw
        $routes | Should -Match "Register-DuneRoute -Method POST -Path '/api/db/query' -LocalOnly"
    }

    It 'classifies host configuration and filesystem APIs as Owner-only' {
        foreach ($path in @(
            '/api/gameconfig',
            '/api/gameconfig/experimental/categories',
            '/api/db/info',
            '/api/sietches/config',
            '/api/config/rotate-ssh-key',
            '/api/system/install-location',
            '/api/diagnostics/bundle',
            '/api/gameplay/players/fresh-start/snapshots-path',
            '/api/commands/layout',
            '/api/commands/layout/reset',
            '/api/dune-admin-cache',
            '/api/update/migration-notice',
            '/api/update/install'
        )) {
            Test-DunePortalOwnerOnlyPath -Path $path | Should -BeTrue
        }
        Test-DunePortalOwnerOnlyPath -Path '/api/gameplay/players' | Should -BeFalse
        Test-DunePortalOwnerOnlyPath -Path '/api/status' | Should -BeFalse
        Test-DunePortalOwnerOnlyPath -Path '/api/gameconfig/spicefields' -Method GET | Should -BeFalse
        Test-DunePortalOwnerOnlyPath -Path '/api/gameconfig/spicefields/42' -Method PUT | Should -BeFalse
        Test-DunePortalOwnerOnlyPath -Path '/api/gameconfig/spicefields/42/spawning' -Method PUT | Should -BeFalse
        Test-DunePortalOwnerOnlyPath -Path '/api/gameconfig/schema' -Method GET | Should -BeTrue
    }

    It 'allows remote Owners but rejects remote Admins and launch-token-only access' {
        $owner = @{ ok = $true; account = @{ role = 'owner' } }
        $admin = @{ ok = $true; account = @{ role = 'admin' } }
        Test-DunePortalOwnerAccess -AccountMode $true -IsLocalRequest $false -PortalSessionAuth $owner | Should -BeTrue
        Test-DunePortalOwnerAccess -AccountMode $true -IsLocalRequest $false -PortalSessionAuth $admin | Should -BeFalse
        Test-DunePortalOwnerAccess -AccountMode $true -IsLocalRequest $false -PortalSessionAuth $null | Should -BeFalse
        Test-DunePortalOwnerAccess -AccountMode $true -IsLocalRequest $true -PortalSessionAuth $admin | Should -BeTrue
        Test-DunePortalOwnerAccess -AccountMode $false -IsLocalRequest $false -PortalSessionAuth $null | Should -BeTrue
    }

    It 'keeps every Setup API host-only' {
        $routes = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Setup.ps1') -Raw
        $registrations = [regex]::Matches($routes, "Register-DuneRoute[^\r\n]+-Path '/api/setup[^']*'[^\r\n]+-Handler")
        $registrations.Count | Should -BeGreaterThan 0
        foreach ($registration in $registrations) {
            $registration.Value | Should -Match ' -LocalOnly '
        }
    }

    It 'keeps Autostart controls host-only' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Autostart.ps1') -Raw
        ([regex]::Matches($source, "Register-DuneRoute[^\r\n]+-Path '/api/autostart' -LocalOnly -Handler")).Count | Should -Be 2
    }

    It 'keeps Service Mode controls host-only' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\ServiceMode.ps1') -Raw
        ([regex]::Matches($source, "Register-DuneRoute[^\r\n]+-Path '/api/service-mode' -LocalOnly -Handler")).Count | Should -Be 2
    }

    It 'keeps backend Console controls host-only' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Console.ps1') -Raw
        ([regex]::Matches($source, "Register-DuneRoute[^\r\n]+-Path '/api/console' -LocalOnly -Handler")).Count | Should -Be 2
    }

    It 'uses the full local-only detector for the remote command allow-list' {
        $routes = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Commands.ps1') -Raw
        $routes | Should -Match '\$isRemote = -not \(Test-DuneLocalOnlyRequest -Request \$req\)'
        $routes | Should -Not -Match '\$isTunneled'
        $routes | Should -Match "\`$portalRole -eq 'owner' -and \`$name -eq 'update'"
        $server = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $server | Should -Match "\`$routeParams\['portalAccountRole'\]"
    }

    It 'disables the legacy remote surface while account mode is enabled' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw
        $source | Should -Match '\$legacyRemoteDisabled = \[bool\]\(Test-DunePortalAccountModeEnabled\)'
        $source | Should -Match 'if \(\$legacyRemoteDisabled\)[\s\S]+?Status 404'
    }

    It 'keeps the launch-token browser handoff host-only' {
        $routes = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Portal.ps1') -Raw
        $routes | Should -Match "Register-DuneRoute -Method POST -Path '/api/portal/open-in-browser' -Inline -LocalOnly -Handler"
        $routes | Should -Match "Register-DuneRoute -Method POST -Path '/api/portal/checkin' -Inline -LocalOnly -Handler"
        $routes | Should -Match "Register-DuneRoute -Method GET -Path '/api/portal/checkin-status' -Inline -LocalOnly -Handler"
        $routes | Should -Match "Register-DuneRoute -Method POST -Path '/api/portal/reattach' -Inline -LocalOnly -Handler"

        $shutdown = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Shutdown.ps1') -Raw
        $shutdown | Should -Match "Register-DuneRoute -Method POST -Path '/api/shutdown' -Inline -LocalOnly -Handler"
    }

    It 'blocks inline and pooled API writes during World Restart maintenance' {
        function global:Test-DuneWorldRestartMaintenanceActive { $true }
        try {
            Test-DuneWorldRestartWriteBlocked -Method POST -Path '/api/shutdown' | Should -BeTrue
            Test-DuneWorldRestartWriteBlocked -Method POST -Path '/api/commands/run/restart' | Should -BeTrue
            Test-DuneWorldRestartWriteBlocked -Method POST -Path '/api/db/world-restart/rollback' | Should -BeFalse
            Test-DuneWorldRestartWriteBlocked -Method POST -Path '/api/db/world-restart/research-rollback' | Should -BeFalse
            Test-DuneWorldRestartWriteBlocked -Method GET -Path '/api/status' | Should -BeFalse
        } finally {
            Remove-Item function:global:Test-DuneWorldRestartMaintenanceActive -ErrorAction SilentlyContinue
        }
    }

    It 'admits a normal mutating handler exactly once without recursive lock calls' {
        function global:Test-DuneWorldRestartMaintenanceActive { $false }
        $script:admissionCalls = 0
        try {
            $result = Invoke-DuneWorldRestartAdmission -Method POST -Path '/api/test-write' -Action {
                $script:admissionCalls++
                return 'completed'
            }

            $script:admissionCalls | Should -Be 1
            $result.blocked | Should -BeFalse
            $result.value | Should -Be 'completed'
        } finally {
            Remove-Item function:global:Test-DuneWorldRestartMaintenanceActive -ErrorAction SilentlyContinue
        }
    }

    It 'lets research recovery own the World Restart admission lock' {
        function global:Test-DuneWorldRestartMaintenanceActive { $true }
        try {
            $result = Invoke-DuneWorldRestartAdmission -Method POST -Path '/api/db/world-restart/research-recover' -Action {
                return 'handler-owned-lock'
            }

            $result | Should -Be 'handler-owned-lock'
        } finally {
            Remove-Item function:global:Test-DuneWorldRestartMaintenanceActive -ErrorAction SilentlyContinue
        }
    }

    It 'lets research rollback own the World Restart admission lock' {
        function global:Test-DuneWorldRestartMaintenanceActive { $true }
        try {
            $result = Invoke-DuneWorldRestartAdmission -Method POST -Path '/api/db/world-restart/research-rollback' -Action {
                return 'research-rollback-handler-owned-lock'
            }

            $result | Should -Be 'research-rollback-handler-owned-lock'
        } finally {
            Remove-Item function:global:Test-DuneWorldRestartMaintenanceActive -ErrorAction SilentlyContinue
        }
    }

    It 'keeps research rollback reachable through pooled API workers' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1') -Raw

        $source | Should -Match ([regex]::Escape(
            "`$path -notin @('/api/db/world-restart/rollback', '/api/db/world-restart/research-rollback')"
        ))
    }
}
