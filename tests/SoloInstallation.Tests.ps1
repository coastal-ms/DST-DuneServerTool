BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'Status.ps1'
    Import-DstLib 'Ports.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app/lib/Db-Postgres.ps1')
    function global:Get-DuneHyperVSplat { throw 'Unexpected VM discovery' }
}

Describe 'Solo installation configuration and isolation' {
    BeforeEach { $script:DuneConfigFile = Join-Path $TestDrive 'installation.config' }
    AfterEach { $script:DuneConfigFile = $null }
    It 'retains full mode in an uninitialized runtime without a Windows profile' {
        $previousAppData = $env:APPDATA
        $previousConfig = $script:DuneConfigFile
        try {
            $env:APPDATA = $null
            $script:DuneConfigFile = $null
            Mock Read-DuneConfigRaw { throw 'No config context exists' }
            Get-DuneInstallationMode | Should -Be 'full'
            Assert-MockCalled Read-DuneConfigRaw -Times 0 -Exactly
        } finally {
            $env:APPDATA = $previousAppData
            $script:DuneConfigFile = $previousConfig
        }
    }
    It 'keeps existing installations in full mode' {
        Mock Read-DuneConfigRaw { [ordered]@{ SteamPath='existing' } }
        Get-DuneInstallationMode | Should -Be 'full'
    }
    It 'treats an unknown mode as full rather than hiding existing tools' {
        Mock Read-DuneConfigRaw { [ordered]@{ InstallationMode='unknown' } }
        Get-DuneInstallationMode | Should -Be 'full'
    }
    It 'allows a Solo-only setup without server files or an SSH key' {
        Test-DuneConfigComplete -Config @{InstallationMode='solo'} | Should -BeTrue
        Test-DuneConfigComplete -Config @{InstallationMode='full'} | Should -BeFalse
    }
    It 'avoids VM discovery and public port checks in Solo mode' {
        Mock Read-DuneConfigRaw { [ordered]@{InstallationMode='solo'} }
        Mock Get-DuneHyperVSplat { throw 'Must not discover a host' }
        (Get-DuneVmStatus).running | Should -BeFalse
        Get-DunePortStatus | Should -BeNullOrEmpty
        Assert-MockCalled Get-DuneHyperVSplat -Times 0 -Exactly
    }
    It 'retains the installation mode and existing settings when another config value changes' {
        $script:DuneConfigFile = Join-Path $TestDrive 'dune-server.config'
        Set-Content $script:DuneConfigFile "InstallationMode=solo`nSteamPath=existing-server`nUpdateChannel=test"
        $saved = Save-DuneConfig -Config @{OpenInAppWindow='true'}
        $saved.InstallationMode | Should -Be 'solo'
        $saved.SteamPath | Should -Be 'existing-server'
        $saved.UpdateChannel | Should -Be 'test'
        $script:DuneConfigFile = $null
    }
    It 'rejects dedicated-server access before reading credentials or starting SSH' {
        Mock Test-DuneSoloInstallation { $true }
        Mock Get-V6SshKeyPath { throw 'Must not read dedicated-server credentials' }
        { Invoke-V6Ssh -Ip '192.0.2.1' -Cmd 'echo unexpected' } | Should -Throw '*Solo-only*'
        Assert-MockCalled Get-V6SshKeyPath -Times 0 -Exactly
    }
    It 'permits Solo writes and shared catalogs while rejecting server and future APIs' {
        Test-DuneSoloServerApiPath -Path '/api/solo/items/grant' -Method POST | Should -BeFalse
        Test-DuneSoloServerApiPath -Path '/api/catalog/items' | Should -BeFalse
        Test-DuneSoloServerApiPath -Path '/api/gameplay/augments/catalog' | Should -BeFalse
        Test-DuneSoloServerApiPath -Path '/api/config' -Method PUT | Should -BeFalse
        Test-DuneSoloServerApiPath -Path '/api/gameplay/players/give-item' -Method POST | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/api/config/open-battlegroup-bat' -Method POST | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/api/catalog/items' -Method POST | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/api/future-server-feature' | Should -BeTrue
        Test-DuneSoloServerApiPath -Path '/ws/terminal' | Should -BeTrue
    }
}
