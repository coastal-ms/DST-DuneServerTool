BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstRoute 'System.ps1'
}

Describe 'System route host access' {
    It 'accepts IPv4 loopback requests' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::Loopback }
        }

        Test-DuneSystemLoopbackRequest $request | Should -BeTrue
    }

    It 'accepts IPv6 loopback requests' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::IPv6Loopback }
        }

        Test-DuneSystemLoopbackRequest $request | Should -BeTrue
    }

    It 'rejects remote requests' {
        $request = [pscustomobject]@{
            RemoteEndPoint = [pscustomobject]@{ Address = [System.Net.IPAddress]::Parse('192.0.2.10') }
        }

        Test-DuneSystemLoopbackRequest $request | Should -BeFalse
    }
}
