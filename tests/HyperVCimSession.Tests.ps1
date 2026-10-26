BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperV.ps1'
    function global:Get-VM { param($CimSession) }
    # Other suite files leave a minimal global CIM stub behind. Declare the
    # complete signature here so Pester can inspect authentication arguments.
    function global:New-CimSession { param($ComputerName,$Credential,$Authentication,$OperationTimeoutSec) }
    $script:testCredential = [pscredential]::new('SERVER\Owner',(ConvertTo-SecureString 'pw' -AsPlainText -Force))
}
Describe 'Explicit LAN Hyper-V session' {
    BeforeEach {
        $script:DuneHyperVCimSessionCache = $null
        $script:fakeSession = [Microsoft.Management.Infrastructure.CimSession]::Create('localhost')
        Mock New-CimSession { $script:fakeSession }
        Mock Remove-CimSession {}
        Mock Get-VM { [pscustomobject]@{ Name='dune-awakening'; State='Running' } }
    }
    It 'uses Negotiate with the supplied credential and releases a test session' {
        $result = Test-DuneHyperVLan -HostIp '192.0.2.10' -User 'SERVER\Owner' -Password 'pw'
        $result.ok | Should -BeTrue
        $result.vmFound | Should -BeTrue
        Should -Invoke New-CimSession -Times 1 -ParameterFilter {
            $ComputerName -eq '192.0.2.10' -and $Authentication -eq 'Negotiate' -and
            $Credential.UserName -eq 'SERVER\Owner' -and $OperationTimeoutSec -eq 20
        }
        Should -Invoke Remove-CimSession -Times 1
    }
    It 'releases the session when VM discovery fails' {
        Mock Get-VM { throw 'Discovery failed' }
        (Test-DuneHyperVLan -HostIp '192.0.2.10' -User 'SERVER\Owner' -Password 'pw').ok | Should -BeFalse
        Should -Invoke Remove-CimSession -Times 1
    }
    It 'does not open a remote session for local mode' {
        (ConvertTo-DuneHyperVCimSplat -HyperV @{}).Count | Should -Be 0
        Should -Invoke New-CimSession -Times 0
    }
    It 'reuses only the current host and credential and replaces changed credentials' {
        $first = ConvertTo-DuneHyperVCimSplat -HyperV @{ ComputerName='192.0.2.10'; Credential=$script:testCredential }
        $second = ConvertTo-DuneHyperVCimSplat -HyperV @{ ComputerName='192.0.2.10'; Credential=$script:testCredential }
        $first.CimSession | Should -Be $script:fakeSession
        $second.CimSession | Should -Be $script:fakeSession
        Should -Invoke New-CimSession -Times 1
        $changed = [pscredential]::new('SERVER\Owner',(ConvertTo-SecureString 'changed' -AsPlainText -Force))
        ConvertTo-DuneHyperVCimSplat -HyperV @{ ComputerName='192.0.2.10'; Credential=$changed } | Out-Null
        Should -Invoke New-CimSession -Times 2
        Should -Invoke Remove-CimSession -Times 1
    }
}
