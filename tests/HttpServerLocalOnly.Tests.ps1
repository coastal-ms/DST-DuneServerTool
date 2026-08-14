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
}
