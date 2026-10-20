BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'dune-server.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Launcher failed to parse.' }
    foreach($name in @('Get-DuneCliLanVmSnapshot','Get-VmInfo','Resolve-DuneCliVmIp')) {
        $definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object Name -eq $name
        Invoke-Expression ('function global:'+$name+$definition.Body.Extent.Text)
    }
    function global:Get-VM { param($Name,$CimSession) }
    function global:Get-VMNetworkAdapter { param($VMName,$CimSession) }
    function global:New-PSSessionOption { param($OpenTimeout,$OperationTimeout) }
    function global:New-CimSessionOption { param($Protocol) }
    function global:New-CimSession { param($ComputerName,$Credential,$SessionOption,$OperationTimeoutSec) }
    function global:Remove-CimSession { param($CimSession) }
}
Describe 'Console LAN VM discovery' {
    BeforeEach {
        $script:credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))
        $global:hvSplat=@{ComputerName='192.0.2.1';Credential=$script:credential}
        $global:vmName='dune-awakening'
        Mock New-PSSessionOption { [System.Management.Automation.Remoting.PSSessionOption]::new() }
        Mock Invoke-Command { @{Exists=$true;State='Running';IPAddresses=@('192.0.2.2','fe80::1')} }
        Mock New-CimSessionOption { @{protocol='Dcom'} }
        Mock New-CimSession { 'isolated-session' }
        Mock Remove-CimSession {}
        Mock Get-VM { @{State='Running'} }
        Mock Get-VMNetworkAdapter { @{IPAddresses=@('192.0.2.2')} }
    }
    It 'gets state and address in one host-side request without a second remote adapter query' {
        $result=Get-VmInfo -HyperV $global:hvSplat -Name $global:vmName
        $result.Running | Should -BeTrue
        $result.Ip | Should -BeExactly '192.0.2.2'
        Should -Invoke Invoke-Command -Times 1 -ParameterFilter { $ComputerName -eq '192.0.2.1' -and $ArgumentList[0] -eq 'dune-awakening' }
        Should -Invoke Get-VM -Times 0
        Should -Invoke Get-VMNetworkAdapter -Times 0
        Should -Invoke New-PSSessionOption -Times 1 -ParameterFilter { $OpenTimeout -eq 8000 -and $OperationTimeout -eq 8000 }
    }
    It 'preserves CIM-only hosts with a timed session and releases it' {
        Mock Invoke-Command { throw 'Remoting unavailable' }
        (Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat).State | Should -Be 'Running'
        Should -Invoke New-CimSession -Times 1 -ParameterFilter { $OperationTimeoutSec -eq 8 -and $ComputerName -eq '192.0.2.1' }
        Should -Invoke Get-VM -Times 1 -ParameterFilter { $CimSession -eq 'isolated-session' }
        Should -Invoke Remove-CimSession -Times 1
    }
    It 'reports both connection failures and still releases a created session' {
        Mock Invoke-Command { throw 'Remoting unavailable' }
        Mock Get-VM { throw 'CIM unavailable' }
        { Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat } | Should -Throw '*The command was not sent*'
        Should -Invoke Remove-CimSession -Times 1
    }
    It 'never prompts for missing saved credentials' {
        { Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV @{ComputerName='192.0.2.1'} } | Should -Throw '*saved Hyper-V host credential*'
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke New-CimSession -Times 0
    }
    It 'does not reinterpret an absent VM as a running server or use a stale IP' {
        Mock Invoke-Command { @{Exists=$false;State='Missing';IPAddresses=@()} }
        $result=Get-VmInfo -HyperV $global:hvSplat -Name $global:vmName
        $result.Exists | Should -BeFalse
        $result.Running | Should -BeFalse
        $result.Ip | Should -BeNullOrEmpty
        Should -Invoke Get-VMNetworkAdapter -Times 0
    }
    It 'retains local Hyper-V discovery without using remoting' {
        $global:hvSplat=@{}
        $result=Get-VmInfo -HyperV $global:hvSplat -Name $global:vmName
        $result.Running | Should -BeTrue
        $result.Ip | Should -Be '192.0.2.2'
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke Get-VM -Times 1
        Should -Invoke Get-VMNetworkAdapter -Times 1
    }
}
