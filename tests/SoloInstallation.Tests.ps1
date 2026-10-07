BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'Config.ps1'
    Import-DstLib 'Status.ps1'
    Import-DstLib 'Ports.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app/lib/Db-Postgres.ps1')
    function global:Get-DuneHyperVSplat { throw 'Unexpected VM discovery' }
}

Describe 'Solo installation configuration and isolation' {
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
}
