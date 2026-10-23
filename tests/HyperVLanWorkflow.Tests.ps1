BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'HyperVLanCredential.ps1'
    Import-DstLib 'HyperVLanImage.ps1'
    Import-DstLib 'HyperVLanGuest.ps1'
    Import-DstLib 'HyperVLanInstall.ps1'
    function global:Invoke-Command { param($Session,$ArgumentList,$ScriptBlock,$ComputerName,$Credential,$ErrorAction) }
    $script:token = 'e30.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"HostId":"fixture"}')).TrimEnd('=') + '.signature'
}
Describe 'Partial-attempt removal guards' {
    BeforeEach {
        Mock Get-DuneHyperVLanInstallStatus { [pscustomobject]@{running=$false;phase='error';hostIp='192.0.2.58';vmId='';stageRoot='C:\Users';installRoot='D:\DuneAwakeningServer'} }
        Mock Resolve-DuneHyperVLanCredential { @{ok=$true;credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))} }
        Mock New-PSSession { $null }
        Mock Remove-PSSession {}
        Mock Invoke-Command { & $ScriptBlock @ArgumentList }
    }
    It 'requires explicit confirmation before opening the host session' {
        { Remove-DuneHyperVLanAttempt -HostIp '192.0.2.58' -Confirmed $false } | Should -Throw '*Confirm*'
        Should -Invoke New-PSSession -Times 0
    }
    It 'rejects a staging path outside the recorded generated directory' {
        { Remove-DuneHyperVLanAttempt -HostIp '192.0.2.58' -Confirmed $true } | Should -Throw '*Unexpected staging path*'
    }
    It 'refuses to remove an attempt on a different host' {
        { Remove-DuneHyperVLanAttempt -HostIp '192.0.2.59' -Confirmed $true } | Should -Throw '*this host*'
        Should -Invoke New-PSSession -Times 0
    }
}
AfterAll { Remove-Item function:global:Invoke-Command -ErrorAction SilentlyContinue }
Describe 'LAN installation phase flow' {
    BeforeEach {
        Mock Assert-DuneHyperVLanInstallContinuing {}
        Mock Read-DuneConfig { @{LastKnownVmIp='192.0.2.219';LastAppliedPublicIp=''} }
        Mock Save-DuneConfig {}
        Mock Resolve-DuneHyperVLanCredential { @{ok=$true;credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))} }
        Mock New-PSSession { $null }
        Mock Wait-DuneLanLocalImage { 'fixture-image' }
        Mock Copy-DuneLanImage { @{imageRoot='D:\DuneServerStage\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'} }
        Mock Remove-DuneLanImageStage {}
        Mock Get-DuneHyperVLanResumeTarget { @{ip='192.0.2.92';vmId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'} }
        Mock Invoke-Command { @{ok=$true;ip='192.0.2.92';vmId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'} }
        Mock Initialize-DuneLanGuest { @{ok=$true;ip='192.0.2.219'} }
        Mock Update-DuneLanClientRoute {}
        Mock Save-DuneHyperVLanInstallState { $script:lastState = $State }
        $script:arguments = @{HostIp='192.0.2.58';DestDrive='D:';MemoryGB=20;SwitchName='LAN';WorldName='New World';Region=3;ServerToken=$token;ServerDir=(Join-Path (Get-DstRepoRoot) 'app/server');Network=@{mode='static';address='192.0.2.219';prefix='24';gateway='192.0.2.1';dns='1.1.1.1'}}
    }
    It 'uses the selected address after guest setup and records the created VM identity' {
        Invoke-DuneHyperVLanInstall @arguments
        $lastState.phase | Should -Be 'done' -Because $lastState.error
        $lastState.ip | Should -Be '192.0.2.219'
        $lastState.vmId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Because $lastState.error
        Should -Invoke Initialize-DuneLanGuest -Times 1 -ParameterFilter { $Network.address -eq '192.0.2.219' -and $WorldName -eq 'New World' }
        Should -Invoke Save-DuneConfig -Times 1 -ParameterFilter { $Config.LastKnownVmIp -eq '192.0.2.219' }
    }
    It 'records the actual partial result when bootstrap fails after a successful import' {
        Mock Initialize-DuneLanGuest { @{ok=$false;error='Authentication failed'} }
        Invoke-DuneHyperVLanInstall @arguments
        $lastState.phase | Should -Be 'error'
        $lastState.vmId | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $lastState.guestIp | Should -Be '192.0.2.92'
        $lastState.hostIp | Should -Be '192.0.2.58'
        Should -Invoke Save-DuneConfig -Times 0
    }
    It 'resumes only the recorded VM without transferring or importing another image' {
        Invoke-DuneHyperVLanInstall @arguments -Resume $true -ResumeVmId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $lastState.phase | Should -Be 'done' -Because $lastState.error
        Should -Invoke Get-DuneHyperVLanResumeTarget -Times 1 -ParameterFilter { $VmId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        Should -Invoke Copy-DuneLanImage -Times 0
        Should -Invoke Invoke-Command -Times 0
    }
    It 'cancels between transfer and import without creating a VM' {
        Mock Copy-DuneLanImage { throw [OperationCanceledException]::new('Installation cancelled') }
        Invoke-DuneHyperVLanInstall @arguments
        $lastState.phase | Should -Be 'cancelled' -Because $lastState.error
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke Initialize-DuneLanGuest -Times 0
    }
}
