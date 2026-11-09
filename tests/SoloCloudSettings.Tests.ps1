BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'SoloMode.ps1'
    $script:cloudPriorLocalAppData = $env:LOCALAPPDATA
}
AfterAll { $env:LOCALAPPDATA = $script:cloudPriorLocalAppData }
Describe 'Cloud-backed native Solo settings' {
    BeforeEach {
        $script:cloudRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = $script:cloudRoot
        $script:profileDir = Join-Path $script:cloudRoot 'Cloud\PlayerClientStorage\FLS_retail\123'
        $script:localDir = Join-Path $script:cloudRoot 'Config\Windows'
        $script:cloudIni = Join-Path $script:profileDir 'SOLO\ServerCustomSettings.ini'
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:cloudIni), $script:localDir -Force | Out-Null
        $script:localIni = Join-Path $script:localDir 'ServerCustomSettings.ini'
        [IO.File]::WriteAllText($script:localIni, "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=0.6`n")
        $script:cloudProfile = @{channel='FLS_retail';dbPath=(Join-Path $script:profileDir 'game.db');settingsPath=$script:localIni;dataRoot=$script:cloudRoot}
        [IO.File]::WriteAllText($script:cloudProfile.dbPath, 'untouched save')
        Mock Get-DuneSoloProfile { $script:cloudProfile }
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Assert-DuneSoloGameClosed {}
        Mock Assert-DuneSoloAdapterCapability { @{channel='FLS_retail'} }
        Mock Get-DuneSoloAdapterDescriptor { @{channel='FLS_retail'} }
        Mock Get-DuneSoloBackupRoot { Join-Path $script:cloudRoot 'DuneServer\backups' }
    }
    It 'keeps the local migration source until a cloud settings file exists' {
        (Read-DuneSoloSettings).path | Should -Be $script:localIni
        (Get-DuneSoloNativeSettingsPath -Profile $script:cloudProfile) | Should -Be $script:localIni
        Test-Path -LiteralPath $script:cloudIni | Should -BeFalse
    }
    It 'reads the cloud copy while retaining device-local Game.ini overrides' {
        [IO.File]::WriteAllText($script:cloudIni, "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=2.5`n")
        [IO.File]::WriteAllText((Join-Path $script:localDir 'Game.ini'), "[/Script/DuneSandbox.InventorySystemSettings]`nPlayerInventoryStartingSize=135`n")
        $result = Read-DuneSoloSettings
        $result.path | Should -Be $script:cloudIni
        ($result.entries | Where-Object key -eq 'GatheringAmount').value | Should -Be '2.5'
        ($result.entries | Where-Object key -eq 'PlayerInventoryStartingSize').value | Should -Be '135'
    }
    It 'backs up and writes the authoritative cloud file without touching local overrides or the save' {
        $original = "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=2.5`nFutureValue=Keep`n"
        [IO.File]::WriteAllText($script:cloudIni, $original)
        $localBefore = [IO.File]::ReadAllText($script:localIni)
        $result = Set-DuneSoloSettings -Settings @{GatheringAmount='3.5'} -Confirm 'APPLY SOLO SETTINGS'
        $result.settings.path | Should -Be $script:cloudIni
        [IO.File]::ReadAllText($result.backupPath) | Should -BeExactly $original
        [IO.File]::ReadAllText($script:cloudIni) | Should -Match 'GatheringAmount=3.5'
        [IO.File]::ReadAllText($script:cloudIni) | Should -Match 'FutureValue=Keep'
        [IO.File]::ReadAllText($script:localIni) | Should -BeExactly $localBefore
        [IO.File]::ReadAllText($script:cloudProfile.dbPath) | Should -BeExactly 'untouched save'
    }
    It 'does not assume the Steam storage layout for Xbox profiles' {
        [IO.File]::WriteAllText($script:cloudIni, 'not Xbox settings')
        $script:cloudProfile.channel = 'Xbox'
        (Get-DuneSoloNativeSettingsPath -Profile $script:cloudProfile) | Should -Be $script:localIni
    }
    It 'preserves newer cloud settings when they change during write preparation' {
        [IO.File]::WriteAllText($script:cloudIni, "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=2.5`n")
        $script:cloudHashCalls = 0
        Mock Get-FileHash {
            $script:cloudHashCalls++
            if ($script:cloudHashCalls -eq 2) { [IO.File]::WriteAllText($script:cloudIni, 'newer cloud contents') }
            @{Hash=[string]$script:cloudHashCalls}
        }
        { Set-DuneSoloSettings -Settings @{GatheringAmount='3.5'} -Confirm 'APPLY SOLO SETTINGS' } | Should -Throw '*changed during this request*'
        [IO.File]::ReadAllText($script:cloudIni) | Should -BeExactly 'newer cloud contents'
    }
    It 'keeps local and cloud backup histories distinct after migration' {
        Mock Get-DuneSoloBackupPolicy { @{managed=$true;archiveRoot=(Join-Path $script:cloudRoot 'archive')} }
        $local = Complete-DuneSoloSettingsBackup -Result (Set-DuneSoloSettings -Settings @{GatheringAmount='1.5'} -Confirm 'APPLY SOLO SETTINGS')
        [IO.File]::WriteAllText($script:cloudIni, "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=2.5`n")
        $cloud = Complete-DuneSoloSettingsBackup -Result (Set-DuneSoloSettings -Settings @{GatheringAmount='3.5'} -Confirm 'APPLY SOLO SETTINGS')
        $local.backupPath | Should -Not -Be $cloud.backupPath
        [IO.File]::ReadAllText($local.backupPath) | Should -Match 'GatheringAmount=0.6'
        [IO.File]::ReadAllText($cloud.backupPath) | Should -Match 'GatheringAmount=2.5'
    }
    It 'preserves a newer cloud edit instead of rolling it back after verification fails' {
        [IO.File]::WriteAllText($script:cloudIni, "[/Script/DuneSandbox.UserServerCustomSettings]`nGatheringAmount=2.5`n")
        Mock Read-DuneSoloSettings {
            [IO.File]::WriteAllText($script:cloudIni, 'newer cloud value after the DST write')
            throw 'simulated verification failure'
        }
        { Set-DuneSoloSettings -Settings @{GatheringAmount='3.5'} -Confirm 'APPLY SOLO SETTINGS' } | Should -Throw '*Newer settings were preserved*'
        [IO.File]::ReadAllText($script:cloudIni) | Should -BeExactly 'newer cloud value after the DST write'
        @(Get-ChildItem (Join-Path $script:cloudRoot 'DuneServer\backups\settings') -Filter '*.ini').Count | Should -Be 1
    }
}
