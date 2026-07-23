# Regression lock for the LAN VM-status/guest-IP discovery credential bug:
# Get-DuneVmStatus (Status.ps1) must call Get-VMNetworkAdapter with the SAME
# -ComputerName/-Credential splat used for Get-VM, via the "-VMName <string>"
# parameter set - NOT by piping the $vm object into Get-VMNetworkAdapter.
#
# Field-confirmed bug: Get-Command shows Get-VMNetworkAdapter's piped
# "-VM <VirtualMachine[]>" parameter set carries NO ComputerName/Credential/
# CimSession parameters at all (unlike its "-VMName <string[]>" set), so
# piping a remotely-fetched $vm silently drops the LAN host's credential -
# guest IP discovery came back empty even though the VM was running and its
# IP was visible in Hyper-V Manager, leaving ServerHealth stuck on "Unknown".

BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Status.ps1'
}

Describe 'Get-DuneVmStatus LAN credential propagation to guest-IP discovery' {
    BeforeEach {
        $script:fakeCred = [System.Management.Automation.PSCredential]::new(
            'HOST\Administrator', (ConvertTo-SecureString 'x' -AsPlainText -Force))
        function global:Get-DuneHyperVSplat { @{ ComputerName = '192.168.1.50'; Credential = $script:fakeCred } }

        Mock -CommandName Get-VM -MockWith {
            [pscustomobject]@{ Name = 'dune-awakening'; State = 'Running'; Uptime = [timespan]::FromMinutes(5) }
        }
        Mock -CommandName Get-VMNetworkAdapter -MockWith {
            [pscustomobject]@{ IPAddresses = @('10.10.10.42') }
        }
    }

    It 'passes ComputerName + Credential to Get-VM' {
        Get-DuneVmStatus | Out-Null
        Should -Invoke Get-VM -ParameterFilter {
            $ComputerName -eq '192.168.1.50' -and $Credential -eq $script:fakeCred
        }
    }

    It 'passes the SAME ComputerName + Credential to Get-VMNetworkAdapter via -VMName (never piping the bare VM object)' {
        Get-DuneVmStatus | Out-Null
        Should -Invoke Get-VMNetworkAdapter -ParameterFilter {
            $VMName -eq 'dune-awakening' -and $ComputerName -eq '192.168.1.50' -and $Credential -eq $script:fakeCred
        }
    }

    It 'resolves the discovered guest IPv4 into the status result' {
        $r = Get-DuneVmStatus
        $r.exists | Should -BeTrue
        $r.running | Should -BeTrue
        $r.ip | Should -Be '10.10.10.42'
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
    }

    It 'calls Get-VM and Get-VMNetworkAdapter with no ComputerName/Credential' {
        Get-DuneVmStatus | Out-Null
        Should -Invoke Get-VM -ParameterFilter { -not $ComputerName -and -not $Credential }
        Should -Invoke Get-VMNetworkAdapter -ParameterFilter { -not $ComputerName -and -not $Credential -and $VMName -eq 'dune-awakening' }
    }
}
