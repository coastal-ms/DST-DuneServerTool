BeforeAll {
    $script:statusHandlers = @{}
    function Register-DuneRoute {
        param($Method, $Path, $Handler)
        $script:statusHandlers["$Method $Path"] = $Handler
    }
    function Get-DuneVmStatus { @{running=$true;ip='192.0.2.20'} }
    function Get-DuneBattlegroupSnapshot { param([switch]$Force,$VmStatus) }
    function Get-DunePortStatus { param([switch]$Force,$BattlegroupState) }
    function Test-DuneHyperVLanSetupPending { $false }
    function Write-DuneJson { param($Response,$Body) $script:statusResult=$Body }
    . (Join-Path $PSScriptRoot '../app/server/routes/Status.ps1')
}

Describe 'Settings Apply remote status checks' {
    BeforeEach {
        Mock Get-DuneBattlegroupSnapshot { @{available=$true;state='stopped';title='LAN server';gameServers=@()} }
        Mock Get-DunePortStatus { throw 'Public observer is unavailable' }
    }

    It 'confirms the remote state without waiting for public port observers' {
        & $script:statusHandlers['POST /api/status/refresh'] $null $null $null @{lifecycleOnly=$true}
        $script:statusResult.bg.state | Should -Be 'stopped'
        $script:statusResult.vm.ip | Should -Be '192.0.2.20'
        $script:statusResult.ports | Should -BeNullOrEmpty
        Should -Invoke Get-DuneBattlegroupSnapshot -Times 1 -Exactly -ParameterFilter { $Force -and $VmStatus.ip -eq '192.0.2.20' }
        Should -Invoke Get-DunePortStatus -Times 0 -Exactly
    }

    It 'still forces public checks for a normal manual Refresh' {
        & $script:statusHandlers['POST /api/status/refresh'] $null $null $null @{}
        Should -Invoke Get-DunePortStatus -Times 1 -Exactly -ParameterFilter { $Force }
    }

    It 'reports remote failures without pretending that shutdown completed' {
        Mock Get-DuneBattlegroupSnapshot { throw 'Remote host did not respond' }
        & $script:statusHandlers['POST /api/status/refresh'] $null $null $null @{lifecycleOnly=$true}
        $script:statusResult.bg.available | Should -BeFalse
        $script:statusResult.bg.reason | Should -Be 'Remote host did not respond'
        $script:statusResult.bg.state | Should -Not -Be 'stopped'
        Should -Invoke Get-DunePortStatus -Times 0 -Exactly
    }
}
