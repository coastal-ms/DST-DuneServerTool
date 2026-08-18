BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:SoloTestRoot = Join-Path ([IO.Path]::GetTempPath()) "dst-solo-tests-$([guid]::NewGuid().ToString('N'))"
    $env:APPDATA = Join-Path $script:SoloTestRoot 'Roaming'
    $env:LOCALAPPDATA = Join-Path $script:SoloTestRoot 'Local'
    New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
    Import-DstLib 'SoloMode.ps1'
}

AfterAll {
    $env:APPDATA = $script:OriginalAppData
    $env:LOCALAPPDATA = $script:OriginalLocalAppData
    Remove-Item -LiteralPath $script:SoloTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function global:Reset-TestSoloState {
    Remove-Item -LiteralPath (Join-Path $env:APPDATA 'DuneServer') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'DuneServer') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'DuneSandbox') -Recurse -Force -ErrorAction SilentlyContinue
}

function global:New-TestSoloLayout {
    param([string]$Channel = 'FLS_beta')
    $root = Join-Path $env:LOCALAPPDATA 'DuneSandbox\Saved'
    $profile = Join-Path $root "Cloud\PlayerClientStorage\$Channel\123456789"
    $config = Join-Path $root 'Config\Windows'
    New-Item -ItemType Directory -Path $profile, $config -Force | Out-Null
    $db = Join-Path $profile 'game.db'
    [IO.File]::WriteAllBytes($db, [byte[]](1, 2, 3))
    return @{ root = $root; db = $db; config = $config }
}

Describe 'Solo Mode profile discovery and persistence' {
    BeforeEach { Reset-TestSoloState }

    It 'finds the one PTC profile beneath the Saved root' {
        $layout = New-TestSoloLayout
        $profiles = @(Find-DuneSoloProfiles -DataRoot $layout.root)
        $profiles.Count | Should -Be 1
        $profiles[0].id | Should -Be '123456789'
        $profiles[0].channel | Should -Be 'FLS_beta'
        $profiles[0].dbPath | Should -Be $layout.db
    }

    It 'resolves a nested profile selection back to the Saved root' {
        $layout = New-TestSoloLayout
        Resolve-DuneSoloDataRoot -SelectedPath (Split-Path -Parent $layout.db) |
            Should -Be $layout.root
    }

    It 'uses game.db directly when the selected folder is an exact profile' {
        $layout = New-TestSoloLayout
        Mock Invoke-DuneSoloHelper {
            [pscustomobject]@{
                ok = $true
                wrapperVersion = 1
                integrity = 'ok'
                foreignKeyViolations = 0
                characterCount = 1
            }
        }
        $status = Connect-DuneSoloProfile -SelectedPath (Split-Path -Parent $layout.db)
        $status.dbPath | Should -Be $layout.db
    }

    It 'persists and reloads an active profile atomically' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $state = Read-DuneSoloState
        $state.dataRoot | Should -Be $layout.root
        $state.dbPath | Should -Be $layout.db
        (Test-Path -LiteralPath (Get-DuneSoloStatePath)) | Should -BeTrue
    }

    It 'rejects a saved database path outside its configured root' {
        $layout = New-TestSoloLayout
        $outside = Join-Path $script:SoloTestRoot 'outside\game.db'
        New-Item -ItemType Directory -Path (Split-Path -Parent $outside) -Force | Out-Null
        [IO.File]::WriteAllBytes($outside, [byte[]](1))
        Save-DuneSoloState -DataRoot $layout.root -DbPath $outside | Out-Null
        { Get-DuneSoloProfile } | Should -Throw '*outside the configured data root*'
    }
}

Describe 'Solo Mode write gates and settings backups' {
    BeforeEach { Reset-TestSoloState }

    It 'reports all 48 native settings even when the INI is absent' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $settings = Read-DuneSoloSettings
        $settings.entries.Count | Should -Be 48
        @($settings.entries | Where-Object present).Count | Should -Be 0
    }

    It 'requires the exact settings confirmation phrase' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        { Set-DuneSoloSettings -Settings @{ GatheringAmount = '2.0' } -Confirm 'yes' } |
            Should -Throw '*APPLY SOLO SETTINGS*'
    }

    It 'blocks settings writes while a Dune process is running' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @([pscustomobject]@{ name = 'DuneSandbox'; pid = 42 }) }
        { Set-DuneSoloSettings -Settings @{ GatheringAmount = '2.0' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*still running*'
    }

    It 'backs up, writes, preserves unknown keys, and verifies the intended value' {
        $layout = New-TestSoloLayout
        $ini = Join-Path $layout.config 'ServerCustomSettings.ini'
        @(
            '[/Script/DuneSandbox.UserServerCustomSettings]'
            'GatheringAmount=1.000000'
            'FutureRetailSetting=KeepMe'
        ) | Set-Content -LiteralPath $ini -Encoding utf8
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        $result = Set-DuneSoloSettings -Settings @{ GatheringAmount = '2.500000' } -Confirm 'APPLY SOLO SETTINGS'

        $result.ok | Should -BeTrue
        (Get-Content -LiteralPath $ini -Raw) | Should -Match 'GatheringAmount=2\.500000'
        (Get-Content -LiteralPath $ini -Raw) | Should -Match 'FutureRetailSetting=KeepMe'
        (Test-Path -LiteralPath $result.backupPath) | Should -BeTrue
    }

    It 'rejects unsupported setting injection' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        { Set-DuneSoloSettings -Settings @{ ExecCmds = 'bad' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*Unsupported Solo setting*'
    }

    It 'restores the prior INI when post-write verification fails' {
        $layout = New-TestSoloLayout
        $ini = Join-Path $layout.config 'ServerCustomSettings.ini'
        $original = @(
            '[/Script/DuneSandbox.UserServerCustomSettings]'
            'GatheringAmount=1.000000'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($ini, $original)
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Read-DuneSoloSettings {
            @{
                entries = @([pscustomobject]@{
                    key = 'GatheringAmount'
                    value = 'verification-failed'
                })
            }
        }

        { Set-DuneSoloSettings -Settings @{ GatheringAmount = '2.500000' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*verification failed*'
        (Get-Content -LiteralPath $ini -Raw).Trim() | Should -Be $original.Trim()
    }

    It 'reads and atomically writes allowlisted PTC Engine.ini settings' {
        $layout = New-TestSoloLayout
        $engine = Join-Path $layout.config 'Engine.ini'
        @(
            '[Other.Section]'
            'KeepMe=Yes'
            '[ConsoleVariables]'
            'Hydration.SunExposureEnabled=1'
            'Hydration.SunExposureEnabled=1'
            'Unknown.FutureKey=KeepMe'
        ) | Set-Content -LiteralPath $engine -Encoding utf8
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        $before = Read-DuneSoloConsoleSettings
        $before.supported | Should -BeTrue
        ($before.entries | Where-Object key -eq 'Hydration.SunExposureEnabled').value |
            Should -Be '1'

        $result = Set-DuneSoloConsoleSettings -Settings @{
            'Hydration.SunExposureEnabled' = '0'
            'Vehicle.MaxVehiclesPerPlayer' = '20'
        } -Confirm 'APPLY SOLO CONSOLE SETTINGS'

        $result.ok | Should -BeTrue
        (Test-Path -LiteralPath $result.backupPath) | Should -BeTrue
        $written = Get-Content -LiteralPath $engine -Raw
        $written | Should -Match '(?m)^KeepMe=Yes\r?$'
        $written | Should -Match '(?m)^Unknown\.FutureKey=KeepMe\r?$'
        @([regex]::Matches($written, '(?m)^Hydration\.SunExposureEnabled=0\r?$')).Count |
            Should -Be 1
        $written | Should -Match '(?m)^Vehicle\.MaxVehiclesPerPlayer=20\r?$'
    }

    It 'blocks PTC Engine.ini writes while the game is running' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @([pscustomobject]@{ name = 'DuneSandbox'; pid = 42 }) }

        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Hydration.SunExposureEnabled' = '0'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*still running*'
    }

    It 'restores Engine.ini when verification reports a missing default-valued key' {
        $layout = New-TestSoloLayout
        $engine = Join-Path $layout.config 'Engine.ini'
        $original = @(
            '[ConsoleVariables]'
            'Unknown.FutureKey=KeepMe'
        ) -join [Environment]::NewLine
        [IO.File]::WriteAllText($engine, $original)
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Read-DuneSoloConsoleSettings {
            @{
                entries = @([pscustomobject]@{
                    key = 'Hydration.SunExposureEnabled'
                    value = '1'
                    present = $false
                })
            }
        }

        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Hydration.SunExposureEnabled' = '1'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*verification failed*'
        (Get-Content -LiteralPath $engine -Raw).Trim() | Should -Be $original.Trim()
    }

    It 'rejects unsupported or out-of-range PTC console settings' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        {
            Set-DuneSoloConsoleSettings -Settings @{ 'Unknown.Key' = '1' } `
                -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*Unsupported PTC Solo console setting*'
        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Vehicle.MaxVehiclesPerPlayer' = '1001'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*between 0 and 1000*'
    }

    It 'does not guess a retail Engine.ini folder' {
        $layout = New-TestSoloLayout -Channel 'FLS_live'
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        (Read-DuneSoloConsoleSettings).supported | Should -BeFalse
        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Hydration.SunExposureEnabled' = '0'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*verified PTC FLS_beta adapter*'
    }

    It 'requires the exact item-grant confirmation phrase' {
        {
            Invoke-DuneSoloGiveItems -Destination 'inventory:1' `
                -Items @(@{ templateId = 'CopperBar'; quantity = 10; quality = 0 }) `
                -Confirm 'yes'
        } | Should -Throw '*Confirm the offline item grant*'
    }

    It 'builds a backup-safe item grant plan while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Get-DuneSoloGameplayCatalogPath { Join-Path $script:SoloTestRoot 'catalog.json' }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                safetyBackup = 'test'
                granted = @()
            }
        }
        $result = Invoke-DuneSoloGiveItems -Destination 'inventory:1' `
            -Items @(@{ templateId = 'CopperBar'; quantity = 10; quality = 0 }) `
            -Confirm 'GIVE SOLO ITEMS'

        $result.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'grant-items' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['safety-backup'] -like '*pre-grant*'
        }
    }

    It 'builds a backup-safe currency write while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                solari = 1000000
                scrip = 250000
                safetyBackup = 'test'
            }
        }
        $result = Set-DuneSoloCurrencies -Solari 1000000 -Scrip 250000 `
            -Confirm 'SET SOLO CURRENCIES'

        $result.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'set-currencies' -and
            $Arguments.input -eq $layout.db -and
            $Arguments.solari -eq 1000000 -and
            $Arguments.scrip -eq 250000 -and
            $Arguments['safety-backup'] -like '*pre-currency*'
        }
    }

    It 'builds a backup-safe water-container fill while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                itemId = 100
                amount = 3000
                safetyBackup = 'test'
            }
        }
        $result = Fill-DuneSoloWaterContainer -ItemId 100 -Confirm 'FILL SOLO WATER'

        $result.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'fill-water' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['item-id'] -eq 100 -and
            $Arguments['safety-backup'] -like '*pre-fill*'
        }
    }

    It 'builds a backup-safe augment update while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                updated = 2
                safetyBackup = 'test'
            }
        }
        $result = Invoke-DuneSoloMaxAugmentAttributes -Confirm 'MAX SOLO AUGMENT ATTRIBUTES'

        $result.ok | Should -BeTrue
        $result.updated | Should -Be 2
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'max-augment-attributes' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['safety-backup'] -like '*pre-augment*'
        }
    }

    It 'builds each PTC progression command with a retained backup' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Get-DuneSoloDataFilePath { Join-Path $script:SoloTestRoot $Name }
        Mock Invoke-DuneSoloHelper { @{ ok = $true; action = $Command } }

        $spec = Invoke-DuneSoloProgressionAction -Action 'max-specializations' `
            -Confirm 'MAX SOLO SPECIALIZATIONS' -ExpectedConfirm 'MAX SOLO SPECIALIZATIONS'
        $fremen = Invoke-DuneSoloProgressionAction -Action 'complete-fremen' `
            -Confirm 'COMPLETE FIND THE FREMEN' -ExpectedConfirm 'COMPLETE FIND THE FREMEN'
        $skills = Invoke-DuneSoloProgressionAction -Action 'enable-skills' `
            -Confirm 'ENABLE SOLO SKILLS' -ExpectedConfirm 'ENABLE SOLO SKILLS'

        $spec.ok | Should -BeTrue
        $fremen.ok | Should -BeTrue
        $skills.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 3 -ParameterFilter {
            $Arguments.input -eq $layout.db -and
            $Arguments['safety-backup'] -like '*pre-progression*' -and
            $Arguments.adapter -like '*solo-ptc-v1.json'
        }
    }
}

Describe 'Solo Mode route security metadata' {
    It 'marks every Solo API route local-only' {
        $path = Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1'
        $registrations = @(Select-String -Path $path -Pattern 'Register-DuneRoute')
        $registrations.Count | Should -BeGreaterThan 0
        foreach ($registration in $registrations) {
            $registration.Line | Should -Match '-LocalOnly'
        }
    }

    It 'registers every Solo action route at file load' {
        Register-DstStubs
        $script:CapturedSoloRoutes = @()
        Mock Register-DuneRoute {
            $script:CapturedSoloRoutes += [string]$Path
        }
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1')

        foreach ($expected in @(
            '/api/solo/items/grant',
            '/api/solo/items/augments/max',
            '/api/solo/currencies',
            '/api/solo/fillables/water',
            '/api/solo/progression/specializations/max',
            '/api/solo/progression/find-the-fremen',
            '/api/solo/progression/skills/enable-all'
        )) {
            $script:CapturedSoloRoutes | Should -Contain $expected
        }
    }
}

Describe 'Solo Mode runtime shape' {
    It 'keeps a single running game process as an array and locks writes' {
        Mock Get-DuneSoloGameProcesses {
            [pscustomobject]@{ name = 'DuneSandbox'; pid = 42 }
        }
        $runtime = Get-DuneSoloRuntime
        $runtime.gameRunning | Should -BeTrue
        @($runtime.processes).Count | Should -Be 1
        $runtime.processes[0].name | Should -Be 'DuneSandbox'
    }
}

Describe 'Solo Mode backup profile isolation' {
    BeforeEach { Reset-TestSoloState }

    It 'uses distinct backup roots for the same account in different channels' {
        $root = Join-Path $env:LOCALAPPDATA 'DuneSandbox\Saved\Cloud\PlayerClientStorage'
        $ptc = Join-Path $root 'FLS_beta\123\game.db'
        $retail = Join-Path $root 'FLS\123\game.db'
        (Get-DuneSoloProfileBackupRoot -DbPath $ptc) |
            Should -Not -Be (Get-DuneSoloProfileBackupRoot -DbPath $retail)
    }

    It 'rejects a stale-tab profile token before mutation' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $token = Get-DuneSoloProfileToken -DbPath $layout.db
        { Assert-DuneSoloExpectedProfile -ExpectedProfileToken $token } | Should -Not -Throw
        { Assert-DuneSoloExpectedProfile -ExpectedProfileToken ('0' * 64) } |
            Should -Throw '*changed in another window*'
    }

    It 'lists only backups belonging to the connected profile' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        $foreignRoot = Join-Path (Get-DuneSoloBackupRoot) 'foreign-profile'
        New-Item -ItemType Directory -Path $activeRoot, $foreignRoot -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $activeRoot 'active.db'), [byte[]](1))
        [IO.File]::WriteAllBytes((Join-Path $foreignRoot 'foreign.db'), [byte[]](2))

        $backups = @(Get-DuneSoloBackups)
        $backups.Count | Should -Be 1
        $backups[0].name | Should -Be 'active.db'
    }

    It 'rejects traversal into another profile backup directory' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        {
            Restore-DuneSoloBackup -RelativePath '..\foreign-profile\foreign.db' -Confirm 'RESTORE SOLO SAVE'
        } | Should -Throw '*outside the connected Solo profile backup directory*'
    }

    It 'deletes exactly one listed backup without requiring the game closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        $first = Join-Path $activeRoot 'first.db'
        $second = Join-Path $activeRoot 'second.db'
        [IO.File]::WriteAllBytes($first, [byte[]](1))
        [IO.File]::WriteAllBytes($second, [byte[]](2))
        Mock Get-DuneSoloGameProcesses {
            throw 'backup deletion must not inspect game processes'
        }

        $result = Remove-DuneSoloBackup -RelativePath 'first.db' -Confirm 'DELETE SOLO BACKUP'

        $result.ok | Should -BeTrue
        (Test-Path -LiteralPath $first) | Should -BeFalse
        (Test-Path -LiteralPath $second) | Should -BeTrue
        Assert-MockCalled Get-DuneSoloGameProcesses -Times 0
    }

    It 'rejects backup deletion traversal and non-db files' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        { Remove-DuneSoloBackup -RelativePath '..\foreign.db' -Confirm 'DELETE SOLO BACKUP' } |
            Should -Throw '*outside the connected Solo profile backup directory*'
        { Remove-DuneSoloBackup -RelativePath 'notes.txt' -Confirm 'DELETE SOLO BACKUP' } |
            Should -Throw '*Only Solo .db*'
    }

    It 'rejects a reparse point anywhere in the backup path' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        $target = Join-Path $activeRoot 'linked.db'
        [IO.File]::WriteAllBytes($target, [byte[]](1))
        Mock Get-Item {
            [pscustomobject]@{
                FullName = $LiteralPath
                Attributes = [IO.FileAttributes]::ReparsePoint
            }
        }
        { Assert-DuneSoloNoReparsePath -Path $target } |
            Should -Throw '*reparse point*'
    }
}
