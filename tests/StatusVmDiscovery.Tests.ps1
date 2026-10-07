# LAN status uses one credentialed host request for VM and adapter discovery.

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'HyperVGuestRecovery.ps1'
    Import-DstLib 'Status.ps1'
}

Describe 'Get-DuneVmStatus batched LAN discovery' {
    BeforeEach {
        $script:fakeCred = [System.Management.Automation.PSCredential]::new(
            'HOST\Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        function global:Get-DuneHyperVSplat { @{ ComputerName = '192.168.1.50'; Credential = $script:fakeCred } }

        Mock Invoke-Command { @{ State='Running'; UptimeSeconds=300; IPAddresses=@('10.10.10.42') } }
        Mock Get-VM { throw 'Repeated CIM call' }
        Mock Get-VMNetworkAdapter { throw 'Repeated CIM call' }
        Mock -CommandName Set-DuneLastKnownVmIp -MockWith { $true }
        Mock -CommandName Get-DuneLastKnownVmIp -MockWith { '' }
        Mock -CommandName Test-DuneKnownVmIp -MockWith { $true }
        Mock -CommandName Invoke-DuneHyperVGuestRecovery -MockWith { @{ ok = $true } }
    }

    It 'uses one host request carrying the saved credential' {
        Get-DuneVmStatus | Out-Null
        Should -Invoke Invoke-Command -Times 1 -ParameterFilter {
            $ComputerName -eq '192.168.1.50' -and $Credential -eq $script:fakeCred
        }
        Should -Invoke Get-VM -Times 0
        Should -Invoke Get-VMNetworkAdapter -Times 0
    }

    It 'reports an unavailable host instead of a stale running snapshot' {
        Mock Invoke-Command { throw 'Host unavailable' }
        $r = Get-DuneVmStatus
        $r.running | Should -BeFalse
        $r.error | Should -Match 'Host unavailable'
    }

    It 'resolves the discovered guest IPv4 into the status result' {
        $r = Get-DuneVmStatus
        $r.exists | Should -BeTrue
        $r.running | Should -BeTrue
        $r.ip | Should -Be '10.10.10.42'
        $r.ipSource | Should -Be 'hyperv'
        Should -Invoke Set-DuneLastKnownVmIp -ParameterFilter { $Ip -eq '10.10.10.42' }
        Should -Invoke Test-DuneKnownVmIp -ParameterFilter { $Ip -eq '10.10.10.42' }
        Should -Invoke Invoke-DuneHyperVGuestRecovery -ParameterFilter { $Ip -eq '10.10.10.42' }
    }

    It 'uses a reachable last-known guest IP when Hyper-V KVP is blank' {
        Mock Invoke-Command { @{ State='Running'; UptimeSeconds=300; IPAddresses=@() } }
        Mock Get-DuneLastKnownVmIp { '10.10.10.42' }
        Mock Test-DuneKnownVmIp { $true }

        $r = Get-DuneVmStatus

        $r.ip | Should -Be '10.10.10.42'
        $r.ipSource | Should -Be 'last-known'
        Should -Invoke Invoke-DuneHyperVGuestRecovery -ParameterFilter {
            $Ip -eq '10.10.10.42' -and $ForceKvp
        }
    }

    It 'rejects an unreachable last-known guest IP' {
        Mock Invoke-Command { @{ State='Running'; UptimeSeconds=300; IPAddresses=@() } }
        Mock Get-DuneLastKnownVmIp { '10.10.10.99' }
        Mock Test-DuneKnownVmIp { $false }

        $r = Get-DuneVmStatus

        $r.ip | Should -Be ''
        $r.ipSource | Should -Be 'none'
        Should -Invoke Invoke-DuneHyperVGuestRecovery -Times 0
    }
}

Describe 'Get-DuneVmStatus local mode (unchanged, credential-free)' {
    BeforeEach {
        function global:Get-DuneHyperVSplat { @{} }
        Mock -CommandName Get-VM -MockWith {
            [pscustomobject]@{ Name = 'dune-awakening'; State = 'Running'; Uptime = [timespan]::FromMinutes(5) }
        }
        Mock -CommandName Get-VMNetworkAdapter -MockWith {
            [pscustomobject]@{ IPAddresses = @('192.168.100.7') }
        }
        Mock -CommandName Set-DuneLastKnownVmIp -MockWith { $true }
        Mock -CommandName Get-DuneLastKnownVmIp -MockWith { '' }
        Mock -CommandName Test-DuneKnownVmIp -MockWith { $false }
        Mock -CommandName Invoke-DuneHyperVGuestRecovery -MockWith { @{ ok = $true } }
    }

    It 'calls Get-VM and Get-VMNetworkAdapter with no ComputerName/Credential' {
        Get-DuneVmStatus | Out-Null
        Should -Invoke Get-VM -ParameterFilter { -not $ComputerName -and -not $Credential }
        Should -Invoke Get-VMNetworkAdapter -ParameterFilter { -not $ComputerName -and -not $Credential -and $VMName -eq 'dune-awakening' }
    }
}

Describe 'Get-DuneBattlegroupSnapshotFresh VM reuse' {
    It 'uses a supplied VM snapshot instead of repeating Hyper-V discovery' {
        Mock -CommandName Get-DuneVmStatus -MockWith { throw 'duplicate VM discovery' }

        $r = Get-DuneBattlegroupSnapshotFresh -VmStatus @{
            exists = $false
            name = 'dune-awakening'
            state = 'NotFound'
            running = $false
            ip = ''
        }

        $r.available | Should -BeFalse
        $r.reason | Should -Match 'does not exist'
        $r.observedAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
        Should -Invoke Get-DuneVmStatus -Times 0
    }

    It 'preserves the original observation timestamp while serving the cached snapshot' {
        $script:DuneApiLockTable = $null
        $script:DuneBattlegroupSnapshotCache = $null
        $script:DuneBattlegroupSnapshotFetched = [datetime]::MinValue
        $snapshot = @{ available = $true; observedAt = '2026-09-09T04:00:00.0000000Z' }

        Set-DuneBattlegroupSnapshotCacheEntry -Snapshot $snapshot
        $cached = Get-DuneBattlegroupSnapshotCached

        $cached.observedAt | Should -Be $snapshot.observedAt
    }
}
