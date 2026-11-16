BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'RetailServerSettings.ps1'
}
Describe 'Bounded read-only Retail settings recovery' {
    It 'retries an incomplete File Browser response once and returns only the complete snapshot' {
        $script:attempt=0
        Mock Get-DuneRetailServerSettingsSnapshotOnce {
            $script:attempt++
            if($script:attempt -eq 1){throw 'Retail Server Settings returned an incomplete runtime-file response.'}
            @{available=$true;raw='complete verified content';revision='verified'}
        }
        $r=Get-DuneRetailServerSettingsSnapshot -Ip test
        $r.raw|Should -Be 'complete verified content'
        Should -Invoke Get-DuneRetailServerSettingsSnapshotOnce -Times 2
    }
    It 'reports an actionable failure after two incomplete reads and never returns partial settings' {
        Mock Get-DuneRetailServerSettingsSnapshotOnce {throw 'Retail Server Settings returned an incomplete runtime-file response.'}
        {Get-DuneRetailServerSettingsSnapshot -Ip test}|Should -Throw '*File Browser pod, then Refresh. No settings were changed*'
        Should -Invoke Get-DuneRetailServerSettingsSnapshotOnce -Times 2
    }
    It 'retries a file changed during read without retrying configuration writes' {
        $script:attempt=0
        Mock Get-DuneRetailServerSettingsSnapshotOnce {
            $script:attempt++;if($script:attempt -eq 1){throw 'Retail Server Settings file changed during read. Refresh and try again.'}
            @{available=$true;raw='latest verified content'}
        }
        (Get-DuneRetailServerSettingsSnapshot -Ip test).raw|Should -Be 'latest verified content'
        Should -Invoke Get-DuneRetailServerSettingsSnapshotOnce -Times 2
    }
    It 'does not retry unrelated validation or configuration failures' {
        Mock Get-DuneRetailServerSettingsSnapshotOnce {throw 'Retail Server Settings received an invalid pod name from Kubernetes.'}
        {Get-DuneRetailServerSettingsSnapshot -Ip test}|Should -Throw '*invalid pod name*'
        Should -Invoke Get-DuneRetailServerSettingsSnapshotOnce -Times 1
    }
}
