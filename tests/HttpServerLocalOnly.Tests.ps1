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
