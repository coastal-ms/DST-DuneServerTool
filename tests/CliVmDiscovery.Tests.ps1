BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperV.ps1'
    $root = Split-Path $PSScriptRoot -Parent
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'dune-server.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Launcher failed to parse.' }
    foreach($name in @('Get-DuneCliLanVmSnapshot','Get-VmInfo','Resolve-DuneCliVmIp','Get-VmCmdAvailability','Get-BgCmdAvailability','Get-ToolCmdAvailability','Stop-VmWithEscalation')) {
        $definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object Name -eq $name
        Invoke-Expression ('function global:'+$name+$definition.Body.Extent.Text)
    }
    function global:Get-VM { param($Name,$CimSession,$ComputerName,$Credential) }
    function global:Get-VMNetworkAdapter { param($VMName,$CimSession,$ComputerName,$Credential) }
    function global:New-PSSessionOption { param($OpenTimeout,$OperationTimeout) }
    function global:New-CimSessionOption { param($Protocol) }
    function global:New-CimSession { param($ComputerName,$Credential,$SessionOption,$Authentication,$OperationTimeoutSec) }
    function global:Remove-CimSession { param($CimSession) }
    function global:Start-VM { param($Name,$ComputerName,$Credential,$CimSession) }
    function global:Stop-VM { param($Name,$ComputerName,$Credential,$CimSession,[switch]$Force,[switch]$TurnOff) }
    function global:ssh { }
    function global:Sync-DuneBattlegroupPhaseReader { param($Ip) }
    function global:Invoke-DunePauseBeforeClose { throw 'Command unavailable' }
    function global:Format-PhaseEstimate { param($Phase) }
    function global:Save-PhaseTiming { param($Phase,$Seconds) }
    function global:Complete-WaitCounter { param($Message,$Color) }
    function global:Format-Duration { param($Seconds) }
    function global:Write-WaitCounter { param($Start,$Label,$EstimateText) }
    $commandTables = $ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.VariablePath.UserPath -in @('vmCommands','bgCommands','toolCommands')
    }
    $loop = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.WhileStatementAst] } | Select-Object -Last 1
    $fixture = 'param($Cmd); $cmdHasRun=$false; $bgBinPath="/home/dune/.dune/bin/battlegroup"; $sshKey="fixture-key"; $sshUser="dune";' +
        (($commandTables | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + $loop.Extent.Text
    Set-Item function:global:Invoke-DuneCliCommandFixture ([scriptblock]::Create($fixture))
}

Describe 'Commands dispatch with LAN Hyper-V credentials' {
    BeforeEach {
        $script:DuneHyperVCimSessionCache=$null
        $global:hvComputer='192.0.2.1'
        $global:vmName='dune-awakening'
        $global:hvSplat=@{ComputerName=$global:hvComputer;Credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))}
        Mock Get-VM { @{State='Running'} }
        Mock Get-VMNetworkAdapter { @{IPAddresses=@('192.0.2.2')} }
        Mock New-CimSession { 'fixture-session' }
        Mock Remove-CimSession {}
        Mock Invoke-Command { throw 'Access denied' }
        Mock ssh { $global:LASTEXITCODE=0 }
        Mock Sync-DuneBattlegroupPhaseReader {}
        Mock Start-Sleep {}
        Mock Start-VM {}
        Mock Save-PhaseTiming {}
        Mock Complete-WaitCounter {}
        Mock Format-PhaseEstimate {}
    }
    It 'runs the actual stop command once when saved credentials work and remoting is denied' {
        Invoke-DuneCliCommandFixture -Cmd stop
        Should -Invoke ssh -Times 1 -Exactly -ParameterFilter { $args[-1] -eq '/home/dune/.dune/bin/battlegroup stop' -and $args -contains 'dune@192.0.2.2' }
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke New-CimSession -Times 0
        Should -Invoke Start-VM -Times 0
    }
    It 'runs stop through the explicit Negotiate transport when direct discovery is denied' {
        Mock Get-VM { throw 'Direct denied' } -ParameterFilter { $ComputerName }
        Invoke-DuneCliCommandFixture -Cmd stop
        Should -Invoke ssh -Times 1 -Exactly -ParameterFilter { $args[-1] -eq '/home/dune/.dune/bin/battlegroup stop' }
        Should -Invoke New-CimSession -Times 1 -ParameterFilter { $Authentication -eq 'Negotiate' }
    }
    It 'retains the local Commands stop workflow' {
        $global:hvComputer=$null
        $global:hvSplat=@{}
        Invoke-DuneCliCommandFixture -Cmd stop
        Should -Invoke ssh -Times 1 -Exactly -ParameterFilter { $args[-1] -eq '/home/dune/.dune/bin/battlegroup stop' }
        Should -Invoke New-CimSession -Times 0
        Should -Invoke Invoke-Command -Times 0
    }
    It 'retains Commands stop for hosts using the older remoting discovery path' {
        Mock Get-VM { throw 'Direct denied' }
        Mock New-CimSession { throw 'Negotiate denied' }
        Mock Invoke-Command { @{Exists=$true;State='Running';IPAddresses=@('192.0.2.2')} }
        Invoke-DuneCliCommandFixture -Cmd stop
        Should -Invoke ssh -Times 1 -Exactly -ParameterFilter { $args[-1] -eq '/home/dune/.dune/bin/battlegroup stop' }
        Should -Invoke Invoke-Command -Times 1
    }
    It 'sends no SSH or VM power action when every discovery transport is denied' {
        Mock Get-VM { throw 'Denied' }
        Mock New-CimSession { throw 'Denied' }
        { Invoke-DuneCliCommandFixture -Cmd stop } | Should -Throw '*command was not sent*'
        Should -Invoke ssh -Times 0
        Should -Invoke Start-VM -Times 0
    }
    It 'starts a VM once through the selected Negotiate transport' {
        Mock Get-VM { throw 'Direct denied' } -ParameterFilter { $ComputerName }
        Mock Get-VM { @{State='Off'} } -ParameterFilter { $Name }
        Mock Start-VM { Mock Get-VM { @{State='Running'} } -ParameterFilter { $Name } }
        Invoke-DuneCliCommandFixture -Cmd start-vm
        Should -Invoke Start-VM -Times 1 -Exactly -ParameterFilter { $CimSession -eq 'fixture-session' }
        Should -Invoke ssh -Times 0
    }
    It 'never retries a start action after an ambiguous failure' {
        Mock Get-VM { @{State='Off'} }
        Mock Start-VM { throw 'Connection lost after submission' }
        { Invoke-DuneCliCommandFixture -Cmd start-vm } | Should -Throw '*after submission*'
        Should -Invoke Start-VM -Times 1 -Exactly
        Should -Invoke New-CimSession -Times 0
    }
}
Describe 'Console LAN VM discovery' {
    BeforeEach {
        $script:DuneHyperVCimSessionCache = $null
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
    It 'preserves saved-credential discovery when PowerShell remoting and explicit DCOM are denied' {
        Mock Invoke-Command { throw 'Access is denied' }
        Mock New-CimSession { throw 'Access is denied' }
        Mock Get-VM { @{State='Running'} } -ParameterFilter { $ComputerName -eq '192.0.2.1' -and $Credential -eq $script:credential }
        $result = Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat
        $result.Exists | Should -BeTrue
        $result.State | Should -Be 'Running'
        $result.IPAddresses | Should -Contain '192.0.2.2'
        Should -Invoke New-CimSession -Times 0
        Should -Invoke Invoke-Command -Times 0
    }
    It 'gets state and address through the same saved-credential transport as Settings' {
        $result=Get-VmInfo -HyperV $global:hvSplat -Name $global:vmName
        $result.Running | Should -BeTrue
        $result.Ip | Should -BeExactly '192.0.2.2'
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke Get-VM -Times 2 -ParameterFilter { $ComputerName -eq '192.0.2.1' -and $Credential -eq $script:credential }
        Should -Invoke Get-VMNetworkAdapter -Times 1 -ParameterFilter { $ComputerName -eq '192.0.2.1' -and $Credential -eq $script:credential }
        Should -Invoke New-PSSessionOption -Times 0
    }
    It 'uses explicit Negotiate when the original saved-credential transport is denied' {
        Mock Get-VM { throw 'Original transport unavailable' } -ParameterFilter { $ComputerName }
        (Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat).State | Should -Be 'Running'
        Should -Invoke New-CimSession -Times 1 -ParameterFilter { $Authentication -eq 'Negotiate' -and $OperationTimeoutSec -eq 20 }
        Should -Invoke Get-VMNetworkAdapter -Times 1 -ParameterFilter { $CimSession -eq 'isolated-session' }
        Should -Invoke Invoke-Command -Times 0
    }
    It 'preserves CIM-only hosts with a timed session and releases it' {
        Mock Invoke-Command { throw 'Remoting unavailable' }
        Mock Get-VM { throw 'Original transport unavailable' } -ParameterFilter { $ComputerName }
        Mock New-CimSession { throw 'Negotiate unavailable' } -ParameterFilter { $Authentication -eq 'Negotiate' }
        (Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat).State | Should -Be 'Running'
        Should -Invoke New-CimSession -Times 1 -ParameterFilter { $OperationTimeoutSec -eq 8 -and $ComputerName -eq '192.0.2.1' }
        Should -Invoke Get-VM -Times 1 -ParameterFilter { $CimSession -eq 'isolated-session' }
        Should -Invoke Remove-CimSession -Times 1
    }
    It 'reports both connection failures and still releases a created session' {
        Mock Invoke-Command { throw 'Remoting unavailable' }
        Mock Get-VM { throw 'CIM unavailable' }
        { Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV $global:hvSplat } | Should -Throw '*The command was not sent*'
        Should -Invoke Remove-CimSession -Times 2
    }
    It 'never prompts for missing saved credentials' {
        { Get-DuneCliLanVmSnapshot -Name $global:vmName -HyperV @{ComputerName='192.0.2.1'} } | Should -Throw '*saved Hyper-V host credential*'
        Should -Invoke Invoke-Command -Times 0
        Should -Invoke New-CimSession -Times 0
    }
    It 'does not reinterpret an absent VM as a running server or use a stale IP' {
        Mock Get-VM { $null }
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
