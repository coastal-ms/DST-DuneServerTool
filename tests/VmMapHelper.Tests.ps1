BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'PortalAuth.ps1'
    Import-DstLib 'Atlas.ps1'
    Import-DstLib 'VmMapHelper.ps1'
    function Get-DuneBackupContext { throw 'Unexpected VM access' }
}
Describe 'VM map existing authentication and opt-in' {
    It 'returns real in-flight collection state to Settings without starting collection' {
        Set-Content "$TestDrive\configuration.json" '{}'
        Mock Get-DuneVmMapDirectory { $TestDrive }
        Mock Get-DuneVmMapState { @{enabled=$true;phase='ready'} }
        Mock ConvertTo-DunePortalHashtable { @{} }
        Mock Invoke-DuneVmMapTool { @{live=$false;refreshSeconds=3;refreshing=$true;stopping=$false;activity=@('native');refreshError=$null} }
        Mock Save-DuneVmMapState {}
        $result=Set-DuneVmMapCollection -Action status
        $result.refreshing | Should -BeTrue
        $result.live | Should -BeFalse
        $result.activity | Should -Contain 'native'
        Should -Invoke Invoke-DuneVmMapTool -Times 1 -ParameterFilter { $Action -eq 'control' -and $Configuration.control.action -eq 'status' }
    }
    It 'redeploys changed map assets while leaving unchanged bundles alone' {
        $previousAppDir=$script:AppDir
        try {
            $script:AppDir=$TestDrive
            New-Item -ItemType Directory -Path "$TestDrive\tools\VmMapHelper","$TestDrive\tools\DuneAtlas" -Force | Out-Null
            Set-Content "$TestDrive\tools\VmMapHelper\manifest.json" 'helper-v1'
            Set-Content "$TestDrive\tools\DuneAtlas\manifest.json" 'map-v1'
            $original=Get-DuneVmMapPackageHash
            Mock Get-DuneVmMapState { @{enabled=$true;phase='ready';packageHash=$original} }
            Mock Start-DuneVmMapSetup { @{} }
            Resume-DuneVmMapSetup
            Should -Invoke Start-DuneVmMapSetup -Times 0
            Set-Content "$TestDrive\tools\DuneAtlas\manifest.json" 'map-v2'
            Get-DuneVmMapPackageHash | Should -Not -Be $original
            Resume-DuneVmMapSetup
            Should -Invoke Start-DuneVmMapSetup -Times 1
        } finally { $script:AppDir=$previousAppDir }
    }
    It 'uses only the VM collector when enabled' {
        Mock Get-DuneVmMapState { @{enabled=$true;phase='ready'} }
        Mock Get-DuneVmMapRelaySession { @{available=$true;url='private'} }
        Mock Start-DuneAtlasSession { throw 'Duplicate PC collector' }
        (Get-DuneAtlasSession).url | Should -Be 'private'
        Should -Invoke Start-DuneAtlasSession -Times 0
    }
    It 'does not start a desktop collector when Live Maps is disabled' {
        Mock Get-DuneVmMapState { @{enabled=$false} }
        Mock Start-DuneAtlasSession { throw 'Unexpected collection' }
        (Get-DuneAtlasSession).reasonCode | Should -Be 'helper-not-enabled'
        Should -Invoke Start-DuneAtlasSession -Times 0
    }
    It 'does not require another account setup to configure the helper' {
        Mock Get-DuneBackupContext { @{ok=$false;message='Reached VM configuration'} }
        Mock Get-DunePortalAccountStore { throw 'Second authentication setup' }
        { Get-DuneVmMapConfiguration } | Should -Throw '*Reached VM configuration*'
        Should -Invoke Get-DunePortalAccountStore -Times 0
    }
}
