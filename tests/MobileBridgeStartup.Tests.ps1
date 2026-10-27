Describe 'Mobile bridge startup' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\app\server\lib\MobileBridge.ps1')
    }

    It 'takes the health-only fast path when the bridge is already responding' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true; bridgeVersion = '2.0.1'; protocolVersion = '2' } }
        Mock Get-DuneBridgeStatus { throw 'full status should not run' }
        Mock Invoke-DuneBridgeRepair { throw 'repair should not run' }

        { Initialize-DuneMobileBridge } | Should -Not -Throw

        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter { $TimeoutSec -eq 1 }
        Should -Invoke Get-DuneBridgeStatus -Times 0
        Should -Invoke Invoke-DuneBridgeRepair -Times 0
    }

    It 'repairs a responding legacy or incompatible bridge rather than accepting its open port' -TestCases @(
        @{ Health = @{ ok = $true } }
        @{ Health = @{ ok = $true; bridgeVersion = '1.0.0'; protocolVersion = '1' } }
        @{ Health = @{ ok = $true; bridgeVersion = '2.0.0'; protocolVersion = '2' } }
        @{ Health = @{ ok = $true; bridgeVersion = '2.0.1'; protocolVersion = '3' } }
        @{ Health = @{ ok = $false; bridgeVersion = '2.0.1'; protocolVersion = '2' } }
        @{ Health = @{ ok = $true; bridgeVersion = 'invalid'; protocolVersion = '2' } }
    ) {
        param($Health)
        Mock Invoke-RestMethod { $Health }.GetNewClosure()
        Mock Get-DuneBridgeStatus { @{ task=$true; listening=$true } }
        Mock Invoke-DuneBridgeRepair { @{ ok=$true; started=$true } }

        Initialize-DuneMobileBridge

        Should -Invoke Invoke-DuneBridgeRepair -Times 1 -Exactly -ParameterFilter { $NoWait }
        Should -Invoke Get-DuneBridgeStatus -Times 0
    }

    It 'repairs an unreachable bridge without blocking startup on full task inspection' {
        Mock Invoke-RestMethod { throw 'Connection refused' }
        Mock Get-DuneBridgeStatus { throw 'Full status should not run' }
        Mock Invoke-DuneBridgeRepair { @{ ok=$true; started=$true } }

        { Initialize-DuneMobileBridge } | Should -Not -Throw
        Should -Invoke Invoke-DuneBridgeRepair -Times 1 -Exactly -ParameterFilter { $NoWait }
    }
}

Describe 'Bridge status through the remote proxy' {
    BeforeAll {
        $script:bridgeTestAppData = $env:APPDATA
        $env:APPDATA = Join-Path $TestDrive 'bridge-status'
        . (Join-Path $PSScriptRoot '..\app\server\lib\PortalAuth.ps1')
        . (Join-Path $PSScriptRoot '..\app\server\lib\MobileBridge.ps1')
        function New-BridgeStatusRequest {
            param([string]$Proof = (Get-DunePortalBridgeOriginSecret), [string]$Address = '127.0.0.1')
            [pscustomobject]@{
                RemoteEndPoint = [pscustomobject]@{ Address = [Net.IPAddress]::Parse($Address) }
                Headers = @{
                    Host = '127.0.0.1:18000'
                    'X-Dune-Bridge-Protocol' = '2'
                    'X-Dune-Original-Authority' = 'portal.example.ts.net'
                    'X-Dune-Bridge-Proof' = $Proof
                }
            }
        }
    }
    AfterAll { $env:APPDATA = $script:bridgeTestAppData }
    BeforeEach {
        Mock Test-DuneBridgeElevated { $false }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Running' } }
        Mock Get-NetTCPConnection { [pscustomobject]@{ LocalPort = 47900 } }
        Mock Test-DuneBridgeHealth { $false }
    }
    It 'uses the authenticated in-flight request without calling back into its waiting proxy' {
        $status = Get-DuneBridgeStatus -Request (New-BridgeStatusRequest)
        $status.ready | Should -BeTrue
        $status.healthOk | Should -BeTrue
        $status.issues.Count | Should -Be 0
        Should -Invoke Test-DuneBridgeHealth -Times 0
    }
    It 'still probes the bridge for a direct local status check' {
        $status = Get-DuneBridgeStatus
        $status.ready | Should -BeFalse
        Should -Invoke Test-DuneBridgeHealth -Times 1
    }
    It 'does not trust a spoofed protocol marker or off-host proof' -TestCases @(
        @{ Proof = 'spoof'; Address = '127.0.0.1' }
        @{ Proof = 'spoof'; Address = '192.0.2.1' }
    ) {
        param($Proof, $Address)
        $status = Get-DuneBridgeStatus -Request (New-BridgeStatusRequest -Proof $Proof -Address $Address)
        $status.ready | Should -BeFalse
        Should -Invoke Test-DuneBridgeHealth -Times 1
    }
}
