BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperV.ps1'
    function global:Get-VM { param($Name,$CimSession,$ComputerName,$Credential) }
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
        Mock Get-VM { throw 'Original transport unavailable' } -ParameterFilter { $ComputerName }
    }
    It 'preserves the original credentialed path without requiring Negotiate' {
        Mock Get-VM { [pscustomobject]@{Name='dune-awakening';State='Running'} } -ParameterFilter { $ComputerName }
        Mock New-CimSession { throw 'Negotiate denied' }
        $result = Test-DuneHyperVLan -HostIp '192.0.2.10' -User 'SERVER\Owner' -Password 'pw'
        $result.ok | Should -BeTrue
        Should -Invoke New-CimSession -Times 0
        $args = ConvertTo-DuneHyperVCimSplat -HyperV @{ComputerName='192.0.2.10';Credential=$script:testCredential}
        $args.ComputerName | Should -Be '192.0.2.10'
        $args.Credential.UserName | Should -Be 'SERVER\Owner'
        $args.ContainsKey('CimSession') | Should -BeFalse
    }
    It 'reports both failures without caching an unusable connection' {
        Mock New-CimSession { throw 'Negotiate denied' }
        { ConvertTo-DuneHyperVCimSplat -HyperV @{ComputerName='192.0.2.10';Credential=$script:testCredential} } | Should -Throw '*Original transport unavailable*Negotiate denied*'
        $script:DuneHyperVCimSessionCache | Should -BeNullOrEmpty
    }
    It 'caches the original path only for the same host and credential' {
        Mock Get-VM {} -ParameterFilter { $ComputerName }
        $hv=@{ComputerName='192.0.2.10';Credential=$script:testCredential}
        ConvertTo-DuneHyperVCimSplat -HyperV $hv | Out-Null
        ConvertTo-DuneHyperVCimSplat -HyperV $hv | Out-Null
        Should -Invoke Get-VM -Times 1 -ParameterFilter { $ComputerName -eq '192.0.2.10' }
        ConvertTo-DuneHyperVCimSplat -HyperV @{ComputerName='192.0.2.11';Credential=$script:testCredential} | Out-Null
        Should -Invoke Get-VM -Times 1 -ParameterFilter { $ComputerName -eq '192.0.2.11' }
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
    It 'retries discovery after a cached original path expires' {
        Mock Get-VM {} -ParameterFilter { $ComputerName }
        $hv=@{ComputerName='192.0.2.10';Credential=$script:testCredential}
        ConvertTo-DuneHyperVCimSplat -HyperV $hv | Out-Null
        $script:DuneHyperVCimSessionCache.Created=[datetime]::UtcNow.AddMinutes(-2)
        Mock Get-VM { throw 'Original transport unavailable' } -ParameterFilter { $ComputerName }
        $result=ConvertTo-DuneHyperVCimSplat -HyperV $hv
        $result.CimSession | Should -Be $script:fakeSession
        Should -Invoke New-CimSession -Times 1
    }
    It 'does not reuse or replace a cached connection during an independent connection test' {
        $hv=@{ComputerName='192.0.2.10';Credential=$script:testCredential}
        ConvertTo-DuneHyperVCimSplat -HyperV $hv | Out-Null
        $cached=$script:DuneHyperVCimSessionCache
        Test-DuneHyperVLan -HostIp '192.0.2.10' -User 'SERVER\Owner' -Password 'pw' | Out-Null
        $script:DuneHyperVCimSessionCache | Should -Be $cached
        Should -Invoke New-CimSession -Times 2
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
