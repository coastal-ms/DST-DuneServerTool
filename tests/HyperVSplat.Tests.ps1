# Routing + "no silent identity fallback" coverage for HyperV.ps1
# (Get-DuneHyperVComputerName / Get-DuneHyperVSplat / Test-DuneHyperVLan).
#
# Regression target: a field tester (workgroup, separate host credentials) hit
# "Could not query Hyper-V" because every ongoing Hyper-V call ran under DST's
# own Windows identity instead of an explicit host credential. These tests lock
# in that Get-DuneHyperVSplat now (a) stays local-only and credential-free when
# LAN mode is off (today's behavior, byte-for-byte), (b) attaches -Credential
# for a LAN host with a matching saved credential, and (c) THROWS an actionable
# error - never silently falls back to ComputerName-only - when LAN mode is on
# but no matching credential is saved.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperVLanCredential.ps1'
    Import-DstLib 'HyperV.ps1'
}

Describe 'Get-DuneHyperVComputerName' {
    It 'is empty when VmHostMode is local' {
        function global:Get-DuneVmHostMode { 'local' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        Get-DuneHyperVComputerName | Should -BeNullOrEmpty
    }

    It 'is empty when lan mode is set but no host IP is configured' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '' }
        Get-DuneHyperVComputerName | Should -BeNullOrEmpty
    }

    It 'returns the host IP when lan mode is fully configured' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        Get-DuneHyperVComputerName | Should -Be '192.168.1.50'
    }
}

Describe 'Get-DuneHyperVSplat' {
    It 'returns an empty splat for local mode (today''s behavior, unchanged)' {
        function global:Get-DuneVmHostMode { 'local' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        $splat = Get-DuneHyperVSplat
        $splat.Keys.Count | Should -Be 0
    }

    It 'attaches ComputerName + Credential for a LAN host with a matching saved credential' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        $fakeCred = [System.Management.Automation.PSCredential]::new(
            'HOST\Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        function global:Get-DuneHyperVLanCredential {
            param($HostIp)
            @{ ok = $true; exists = $true; matchesHost = $true; user = 'HOST\Administrator'; credential = $fakeCred; error = $null }
        }

        $splat = Get-DuneHyperVSplat
        $splat['ComputerName'] | Should -Be '192.168.1.50'
        $splat['Credential'] | Should -Be $fakeCred
    }

    It 'THROWS (never silently omits Credential) when LAN mode is on but no credential is saved' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        function global:Get-DuneHyperVLanCredential {
            param($HostIp)
            @{ ok = $true; exists = $false; matchesHost = $false; user = ''; credential = $null; error = $null }
        }

        { Get-DuneHyperVSplat } | Should -Throw '*no saved host administrator credential*'
    }

    It 'THROWS when the saved credential was for a different (stale) host IP' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        function global:Get-DuneHyperVLanCredential {
            param($HostIp)
            @{ ok = $true; exists = $true; matchesHost = $false; user = 'HOST\Administrator'; credential = $null; error = $null }
        }

        { Get-DuneHyperVSplat } | Should -Throw '*no saved host administrator credential*'
    }

    It 'THROWS with the Credential Manager error when it cannot be read at all' {
        function global:Get-DuneVmHostMode { 'lan' }
        function global:Get-DuneHyperVHostIp { '192.168.1.50' }
        function global:Get-DuneHyperVLanCredential {
            param($HostIp)
            @{ ok = $false; exists = $false; matchesHost = $false; user = ''; credential = $null; error = 'Win32 error 1234.' }
        }

        { Get-DuneHyperVSplat } | Should -Throw '*Win32 error 1234*'
    }
}

Describe 'Test-DuneHyperVLan input validation' {
    It 'rejects an empty host IP before touching credentials or Hyper-V' {
        $r = Test-DuneHyperVLan -HostIp ''
        $r.ok | Should -BeFalse
        $r.reason | Should -Match 'No Hyper-V host IP'
    }

    It 'fails fast with an actionable message when no credential is available (explicit or saved)' {
        function global:Get-DuneHyperVLanCredential {
            param($HostIp)
            @{ ok = $true; exists = $false; matchesHost = $false; user = ''; credential = $null; error = $null }
        }
        $r = Test-DuneHyperVLan -HostIp '203.0.113.5'
        $r.ok | Should -BeFalse
        $r.reason | Should -Match 'No Hyper-V host administrator credential'
    }
}
