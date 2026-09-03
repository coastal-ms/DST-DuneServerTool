Describe 'Mobile bridge startup' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\app\server\lib\MobileBridge.ps1')
    }

    It 'takes the health-only fast path when the bridge is already responding' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Mock Get-DuneBridgeStatus { throw 'full status should not run' }
        Mock Invoke-DuneBridgeRepair { throw 'repair should not run' }

        { Initialize-DuneMobileBridge } | Should -Not -Throw

        Should -Invoke Invoke-RestMethod -Times 1
        Should -Invoke Get-DuneBridgeStatus -Times 0
        Should -Invoke Invoke-DuneBridgeRepair -Times 0
    }
}
