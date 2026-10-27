BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'HyperV.ps1'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-DstRepoRoot) 'dune-server.ps1'),[ref]$tokens,[ref]$errors)
    $definition=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Stop-VmWithEscalation'},$true)[0]
    Invoke-Expression ('function global:Stop-VmWithEscalation'+$definition.Body.Extent.Text)
    function global:Get-VM { param($Name,$ComputerName,$Credential,$CimSession) }
    function global:Write-WaitCounter { param($Start,$Label,$EstimateText) }
    function global:Complete-WaitCounter { param($Message,$Color) }
    function global:Format-Duration { param($Seconds) "$Seconds seconds" }
    $script:DuneHyperVLibPath=Join-Path (Get-DstRepoRoot) 'app/server/lib/HyperV.ps1'
    $script:DuneHyperVLanCredLibPath=Join-Path $TestDrive 'credentials.ps1'
    @'
function Get-DuneHyperVLanCredential {
    param($HostIp)
    @{ok=$true;exists=$true;matchesHost=((Get-Content "$PSScriptRoot/mode") -ne 'missing');credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))}
}
function Get-VM {
    [CmdletBinding()]param($Name,$ComputerName,$Credential,$CimSession)
    if ($ComputerName -and (Get-Content "$PSScriptRoot/mode") -eq 'negotiate') { throw 'Direct denied' }
    @{State='Running'}
}
function New-CimSession {
    [CmdletBinding()]param($ComputerName,$Credential,$Authentication,$OperationTimeoutSec)
    if ($Authentication -ne 'Negotiate') { throw 'Unexpected transport' }
    'fixture-session'
}
function Stop-VM {
    [CmdletBinding()]param($Name,$ComputerName,$Credential,$CimSession,[switch]$Force,[switch]$TurnOff)
    @{Name=$Name;ComputerName=$ComputerName;User=$Credential.UserName;CimSession=$CimSession;TurnOff=[bool]$TurnOff} | ConvertTo-Json -Compress | Add-Content "$PSScriptRoot/actions"
    if ((Get-Content "$PSScriptRoot/mode") -eq 'fail') { throw 'Connection lost after submission' }
    if ((Get-Content "$PSScriptRoot/mode") -eq 'hang') { return }
    if ((Get-Content "$PSScriptRoot/mode") -eq 'hard' -and -not $TurnOff) { return }
    Set-Content "$PSScriptRoot/off" 'off'
}
'@ | Set-Content -LiteralPath $script:DuneHyperVLanCredLibPath
}
Describe 'Isolated Commands shutdown jobs' {
    BeforeEach {
        $script:DuneHyperVCimSessionCache=$null
        $global:hvComputer='192.0.2.1'
        $global:hvSplat=@{ComputerName=$global:hvComputer;Credential=[pscredential]::new('fixture',(ConvertTo-SecureString 'fixture' -AsPlainText -Force))}
        Remove-Item "$TestDrive/actions","$TestDrive/off" -ErrorAction SilentlyContinue
        Set-Content "$TestDrive/mode" 'direct'
        Mock Get-VM { @{State=$(if (Test-Path "$TestDrive/off") {'Off'}else{'Running'})} }
        Mock Write-WaitCounter {}
        Mock Complete-WaitCounter {}
        Mock Start-Sleep { [Threading.Thread]::Sleep(50) }
    }
    It 'loads the saved credential and shared transport in the real background process' {
        Stop-VmWithEscalation -Name fixture-vm -GracefulOnly -TotalSec 15
        $actions=@(Get-Content "$TestDrive/actions" | ConvertFrom-Json)
        $actions.Count | Should -Be 1
        $actions[0].ComputerName | Should -Be '192.0.2.1'
        $actions[0].User | Should -Be 'fixture'
        $actions[0].TurnOff | Should -BeFalse
    }
    It 'uses Negotiate in the background process when direct discovery is denied' {
        Set-Content "$TestDrive/mode" 'negotiate'
        Stop-VmWithEscalation -Name fixture-vm -GracefulOnly -TotalSec 15
        $actions=@(Get-Content "$TestDrive/actions" | ConvertFrom-Json)
        $actions.Count | Should -Be 1
        $actions[0].CimSession | Should -Be 'fixture-session'
        $actions[0].TurnOff | Should -BeFalse
    }
    It 'reports an ambiguous write failure without retrying or escalating' {
        Set-Content "$TestDrive/mode" 'fail'
        { Stop-VmWithEscalation -Name fixture-vm -GracefulSec 10 -TotalSec 15 } | Should -Throw '*after submission*did not retry*'
        @(Get-Content "$TestDrive/actions").Count | Should -Be 1
    }
    It 'sends no power action when the saved credential no longer matches the host' {
        Set-Content "$TestDrive/mode" 'missing'
        { Stop-VmWithEscalation -Name fixture-vm -GracefulOnly -TotalSec 15 } | Should -Throw '*credential is unavailable*'
        Test-Path "$TestDrive/actions" | Should -BeFalse
    }
    It 'never hard-powers off a graceful-only shutdown that times out' {
        Set-Content "$TestDrive/mode" 'hang'
        { Stop-VmWithEscalation -Name fixture-vm -GracefulOnly -GracefulSec 0 -TotalSec 2 } | Should -Throw '*did not attempt a hard power-off*'
        $actions=@(Get-Content "$TestDrive/actions" | ConvertFrom-Json)
        $actions.Count | Should -Be 1
        $actions[0].TurnOff | Should -BeFalse
    }
    It 'preserves the explicit hard escalation after a successful graceful submission' {
        Set-Content "$TestDrive/mode" 'hard'
        Stop-VmWithEscalation -Name fixture-vm -GracefulSec 1 -TotalSec 15
        $actions=@(Get-Content "$TestDrive/actions" | ConvertFrom-Json)
        $actions.Count | Should -Be 2
        $actions[0].TurnOff | Should -BeFalse
        $actions[1].TurnOff | Should -BeTrue
    }
}
