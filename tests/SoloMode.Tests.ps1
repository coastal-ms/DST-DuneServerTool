BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $script:OriginalAppData = $env:APPDATA
    $script:OriginalLocalAppData = $env:LOCALAPPDATA
    $script:SoloTestRoot = Join-Path ([IO.Path]::GetTempPath()) "dst-solo-tests-$([guid]::NewGuid().ToString('N'))"
    $env:APPDATA = Join-Path $script:SoloTestRoot 'Roaming'
    $env:LOCALAPPDATA = Join-Path $script:SoloTestRoot 'Local'
    New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
    Import-DstLib 'AugmentCatalog.ps1'
    Import-DstLib 'SoloMode.ps1'
    Import-DstLib 'SoloCosmetics.ps1'
    Import-DstLib 'SoloBlueprintSettings.ps1'
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
    param([string]$Channel = 'FLS_retail')
    $root = Join-Path $env:LOCALAPPDATA 'DuneSandbox\Saved'
    $profile = Join-Path $root "Cloud\PlayerClientStorage\$Channel\123456789"
    $config = Join-Path $root 'Config\Windows'
    New-Item -ItemType Directory -Path $profile, $config -Force | Out-Null
    $db = Join-Path $profile 'game.db'
    [IO.File]::WriteAllBytes($db, [byte[]](1, 2, 3))
    return @{ root = $root; db = $db; config = $config }
}

Describe 'Solo blueprint timer restoration' {
    BeforeEach {
        Reset-TestSoloState
        $script:blueprintLayout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $script:blueprintLayout.root -DbPath $script:blueprintLayout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        $script:blueprintIni = Join-Path $script:blueprintLayout.config 'Game.ini'
    }

    It 'restores custom and duplicated prior values while preserving later unrelated edits and UTF-8 BOM' {
        $original = "[Other]`r`nm_DefaultBuildAndFillTimeInSeconds=99`r`n[/Script/DuneSandbox.BuildingSettings]`r`n; Keep this comment`r`n m_DefaultBuildAndFillTimeInSeconds = 2.50`r`nm_BuildableBuildAndFillHoldTimes=((Short, 3),(Long, 5))`r`n[/Script/DuneSandbox.BuildingSettings]`r`nm_DefaultBuildAndFillTimeInSeconds=4`r`nFutureKey=Keep`r`n"
        [IO.File]::WriteAllText($script:blueprintIni, $original, (New-Object Text.UTF8Encoding($true)))
        $enabled = Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS'
        $enabled.settings.enabled | Should -BeTrue
        [IO.File]::ReadAllText($enabled.backupPath) | Should -BeExactly $original
        Add-Content -LiteralPath $script:blueprintIni 'NewKey=Later'
        Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' | Out-Null
        $restored = Set-DuneSoloBlueprintSettings -Enabled $false -Confirm 'APPLY SOLO BLUEPRINT SETTINGS'
        $restored.settings.canRestore | Should -BeFalse
        $lines = @(Get-DuneSoloBlueprintLines -Text ([IO.File]::ReadAllText($script:blueprintIni)))
        $lines.Count | Should -Be 3
        $lines[0] | Should -BeExactly ' m_DefaultBuildAndFillTimeInSeconds = 2.50'
        $lines[1] | Should -BeExactly 'm_BuildableBuildAndFillHoldTimes=((Short, 3),(Long, 5))'
        $lines[2] | Should -BeExactly 'm_DefaultBuildAndFillTimeInSeconds=4'
        $text = [IO.File]::ReadAllText($script:blueprintIni)
        $text | Should -Match 'NewKey=Later'
        $text | Should -Match 'FutureKey=Keep'
        $text | Should -Match 'm_DefaultBuildAndFillTimeInSeconds=99'
        $text | Should -Match '; Keep this comment'
        [IO.File]::ReadAllBytes($script:blueprintIni)[0] | Should -Be 239
    }

    It 'removes introduced keys when no original overrides or file existed' {
        Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' | Out-Null
        Add-Content -LiteralPath $script:blueprintIni 'OtherSetting=Keep'
        Set-DuneSoloBlueprintSettings -Enabled $false -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' | Out-Null
        @(Get-DuneSoloBlueprintLines -Text ([IO.File]::ReadAllText($script:blueprintIni))).Count | Should -Be 0
        Get-Content -LiteralPath $script:blueprintIni -Raw | Should -Match 'OtherSetting=Keep'
    }

    It 'blocks writes while the game runs without creating a restoration record' {
        Mock Get-DuneSoloGameProcesses { @([pscustomobject]@{ ProcessName = 'DuneSandbox'; Id = 42 }) }
        { Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*still running*'
        Test-Path -LiteralPath $script:blueprintIni | Should -BeFalse
    }

    It 'blocks overwriting externally changed timers and retains original restoration evidence' {
        Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' | Out-Null
        $text = [IO.File]::ReadAllText($script:blueprintIni).Replace('m_DefaultBuildAndFillTimeInSeconds=0.000000','m_DefaultBuildAndFillTimeInSeconds=7')
        [IO.File]::WriteAllText($script:blueprintIni, $text)
        { Set-DuneSoloBlueprintSettings -Enabled $false -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*changed outside DST*'
        [IO.File]::ReadAllText($script:blueprintIni) | Should -BeExactly $text
        (Read-DuneSoloBlueprintSettings).canRestore | Should -BeTrue
    }

    It 'preserves the file when atomic replacement fails and clears the unused snapshot' {
        [IO.File]::WriteAllText($script:blueprintIni, '[Unrelated]')
        Mock Invoke-DuneSoloFileReplace { throw 'Test replacement failure' }
        { Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*replacement failure*'
        [IO.File]::ReadAllText($script:blueprintIni) | Should -BeExactly '[Unrelated]'
        (Read-DuneSoloBlueprintSettings).canRestore | Should -BeFalse
    }

    It 'rejects legacy profiles before writing configuration' {
        $legacy = New-TestSoloLayout -Channel 'FLS_beta'
        Save-DuneSoloState -DataRoot $legacy.root -DbPath $legacy.db | Out-Null
        { Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*verified Retail*'
        Test-Path -LiteralPath $script:blueprintIni | Should -BeFalse
    }
}

Describe 'Solo blueprint write recovery' {
    BeforeEach {
        Reset-TestSoloState
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        $script:recoveryIni = Join-Path $layout.config 'Game.ini'
    }
    It 'rolls back a verification failure and keeps exact original bytes' {
        $original = "[Other]`nKeep=Yes"
        [IO.File]::WriteAllText($script:recoveryIni, $original)
        Mock Invoke-DuneSoloFileReplace {
            param($Source, $Destination, $Backup)
            [IO.File]::Replace($Source, $Destination, $Backup)
            if ($Source.EndsWith('.tmp')) { [IO.File]::WriteAllText($Destination, 'Test corruption') }
        }
        { Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*verification failed*'
        [IO.File]::ReadAllText($script:recoveryIni) | Should -BeExactly $original
        (Read-DuneSoloBlueprintSettings).canRestore | Should -BeFalse
    }
    It 'rejects UTF-16 without modifying it or creating restoration state' {
        [IO.File]::WriteAllText($script:recoveryIni, '[Other]', [Text.Encoding]::Unicode)
        $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:recoveryIni))
        { Set-DuneSoloBlueprintSettings -Enabled $true -Confirm 'APPLY SOLO BLUEPRINT SETTINGS' } | Should -Throw '*UTF-8*'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:recoveryIni)) | Should -BeExactly $before
        (Read-DuneSoloBlueprintSettings).canRestore | Should -BeFalse
    }
}

Describe 'Solo Mode profile discovery and persistence' {
    BeforeEach { Reset-TestSoloState }

    It 'finds the released Retail profile beneath the Saved root' {
        $layout = New-TestSoloLayout
        $profiles = @(Find-DuneSoloProfiles -DataRoot $layout.root)
        $profiles.Count | Should -Be 1
        $profiles[0].id | Should -Be '123456789'
        $profiles[0].channel | Should -Be 'FLS_retail'
        $profiles[0].dbPath | Should -Be $layout.db
        $profiles[0].adapter | Should -Be 'retail-wrapper-v1-2026-09'
        $profiles[0].legacy | Should -BeFalse
    }

    It 'identifies the legacy wrapper-v1 profile separately from Retail' {
        $layout = New-TestSoloLayout -Channel 'FLS_beta'
        $profiles = @(Find-DuneSoloProfiles -DataRoot $layout.root)

        $profiles.Count | Should -Be 1
        $profiles[0].channel | Should -Be 'FLS_beta'
        $profiles[0].adapter | Should -Be 'legacy-wrapper-v1-2026-08'
        $profiles[0].legacy | Should -BeTrue

        $manifest = Get-Content -LiteralPath (Get-DuneSoloDataFilePath -Name 'solo-retail-v1.json') -Raw |
            ConvertFrom-Json
        $manifest.wrapper_version | Should -Be 1
        $manifest.schema_fingerprint | Should -Be '421d15955599ea223b3a72d1b418eb94befe333b7be9c20babd40ddf60274130'
    }

    It 'prefers the single Retail profile when Retail and legacy profiles both exist' {
        $legacy = New-TestSoloLayout -Channel 'FLS_beta'
        $retail = New-TestSoloLayout -Channel 'FLS_retail'

        $discovery = Get-DuneSoloDiscovery -SelectedPath $retail.root

        @($discovery.profiles).Count | Should -Be 2
        $discovery.profiles[0].channel | Should -Be 'FLS_retail'
        $discovery.suggestedDbPath | Should -Be $retail.db
        (Get-DuneSoloProfile).dbPath | Should -Be $retail.db
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

    It 'connects Retail with its exact manifest and persists its versioned adapter identity' {
        $layout = New-TestSoloLayout -Channel 'FLS_retail'
        Mock Invoke-DuneSoloHelper {
            [pscustomobject]@{
                ok = $true
                wrapperVersion = 1
                schemaFingerprint = '421d15955599ea223b3a72d1b418eb94befe333b7be9c20babd40ddf60274130'
                integrity = 'ok'
                foreignKeyViolations = 0
                characterCount = 1
            }
        }

        $status = Connect-DuneSoloProfile -SelectedPath (Split-Path -Parent $layout.db)

        $status.adapter | Should -Be 'retail-wrapper-v1-2026-09'
        (Read-DuneSoloState).adapter | Should -Be 'retail-wrapper-v1-2026-09'
        Assert-MockCalled Invoke-DuneSoloHelper -Times 2 -Exactly -ParameterFilter {
            $Command -eq 'inspect' -and $Arguments.adapter -like '*solo-retail-v1.json'
        }
    }

    It 'runs established write capabilities on the released Retail adapter' {
        $layout = New-TestSoloLayout -Channel 'FLS_retail'
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper { @{ ok = $true } }

        { Set-DuneSoloCurrencies -Solari 1 -Scrip 2 -Confirm 'SET SOLO CURRENCIES' } |
            Should -Not -Throw
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -Exactly -ParameterFilter {
            $Command -eq 'set-currencies'
        }
    }

    It 'allows the established Solo capabilities on Retail' {
        $layout = New-TestSoloLayout -Channel 'FLS_retail'
        $profile = @{ dbPath = $layout.db }

        { Assert-DuneSoloAdapterCapability -Profile $profile -Capability 'inspect' | Out-Null } |
            Should -Not -Throw
        { Assert-DuneSoloAdapterCapability -Profile $profile -Capability 'backup' | Out-Null } |
            Should -Not -Throw
        foreach ($capability in @('restore','currencies','item-grant','item-delete','blueprint-import','progression')) {
            { Assert-DuneSoloAdapterCapability -Profile $profile -Capability $capability | Out-Null } |
                Should -Not -Throw
        }
    }

    It 'keeps the incompatible legacy blueprint import blocked' {
        $layout = New-TestSoloLayout -Channel 'FLS_beta'
        $profile = @{ dbPath = $layout.db }

        { Assert-DuneSoloAdapterCapability -Profile $profile -Capability 'blueprint-read' | Out-Null } |
            Should -Not -Throw
        { Assert-DuneSoloAdapterCapability -Profile $profile -Capability 'blueprint-import' | Out-Null } |
            Should -Throw '*has not proven*blueprint-import*'
    }

    It 'persists and reloads an active profile atomically' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $state = Read-DuneSoloState
        $state.dataRoot | Should -Be $layout.root
        $state.dbPath | Should -Be $layout.db
        $state.adapter | Should -Be 'retail-wrapper-v1-2026-09'
        (Test-Path -LiteralPath (Get-DuneSoloStatePath)) | Should -BeTrue
    }

    It 'switches between two account folders without reusing the previous save' {
        $layout = New-TestSoloLayout
        $secondFolder = Join-Path (Split-Path -Parent (Split-Path -Parent $layout.db)) '987654321'
        New-Item -ItemType Directory -Path $secondFolder -Force | Out-Null
        $secondDb = Join-Path $secondFolder 'game.db'
        [IO.File]::WriteAllBytes($secondDb, [byte[]](4, 5, 6))
        Mock Invoke-DuneSoloHelper {
            [pscustomobject]@{
                ok = $true; wrapperVersion = 1; integrity = 'ok'
                foreignKeyViolations = 0; characterCount = 1
            }
        }

        (Get-DuneSoloDiscovery -SelectedPath $layout.root).suggestedDbPath | Should -BeNullOrEmpty
        Connect-DuneSoloProfile -SelectedPath (Split-Path -Parent $layout.db) | Out-Null
        $firstToken = Get-DuneSoloProfileToken -DbPath $layout.db
        $connected = Connect-DuneSoloProfile -SelectedPath $secondFolder

        $connected.dbPath | Should -Be $secondDb
        (Read-DuneSoloState).dbPath | Should -Be $secondDb
        (Read-DuneSoloState).dataRoot | Should -Be $layout.root
        { Assert-DuneSoloExpectedProfile -ExpectedProfileToken $firstToken } |
            Should -Throw '*changed in another window*'
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

    It 'validates integer, boolean, select, and game-controlled settings' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        { Set-DuneSoloSettings -Settings @{ FiefdomLimit = '1.5' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*must be a whole number*'
        { Set-DuneSoloSettings -Settings @{ bAllowSandstorms = 'yes' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*must be True or False*'
        { Set-DuneSoloSettings -Settings @{ PlayerDeathLootRule = 'EveryoneMaybe' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*unsupported option*'
        { Set-DuneSoloSettings -Settings @{ DifficultyLevel = 'Custom' } -Confirm 'APPLY SOLO SETTINGS' } |
            Should -Throw '*controlled by the game*'
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

    It 'reads and atomically writes the allowlisted Retail Engine.ini settings' {
        $layout = New-TestSoloLayout
        $engine = Join-Path $layout.config 'Engine.ini'
        $clientConfig = Join-Path $layout.root 'Config\WindowsClient'
        New-Item -ItemType Directory -Path $clientConfig -Force | Out-Null
        $clientEngine = Join-Path $clientConfig 'Engine.ini'
        @(
            '[Other.Section]'
            'KeepMe=Yes'
            '[ConsoleVariables]'
            'Hydration.SunExposureEnabled=1'
            'Hydration.SunExposureEnabled=1'
            'Unknown.FutureKey=KeepMe'
        ) | Set-Content -LiteralPath $engine -Encoding utf8
        @(
            '[ConsoleVariables]'
            'Dune.DisableShieldOnShooting=1'
            'Dune.DisableShieldOnShooting=1'
            'Client.FutureKey=KeepMe'
        ) | Set-Content -LiteralPath $clientEngine -Encoding utf8
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        $before = Read-DuneSoloConsoleSettings
        $before.supported | Should -BeTrue
        ($before.entries | Where-Object key -eq 'Hydration.SunExposureEnabled').value |
            Should -Be '1'

        $result = Set-DuneSoloConsoleSettings -Settings @{
            'Hydration.SunExposureEnabled' = '0'
            'Vehicle.MaxVehiclesPerPlayer' = '20'
            'Dune.DisableShieldOnShooting' = '0'
            'Vehicle.RecoveryTimeLimit' = '1'
            'dw.VehicleDurabilityDamageMultiplier' = '0.01'
            'Vehicle.RelocationEnabled' = '1'
            'Vehicle.RecoveryChassisDurabilityReductionFraction' = '0.001'
            'Vehicle.RecoveryCurrencyBaseCost' = '100'
        } -Confirm 'APPLY SOLO CONSOLE SETTINGS'

        $result.ok | Should -BeTrue
        (Test-Path -LiteralPath $result.backupPath) | Should -BeTrue
        @($result.backupPaths).Count | Should -Be 1
        (Get-Content -LiteralPath ($result.backupPaths | Where-Object { $_ -like '*Engine-Windows-*' }) -Raw) |
            Should -Match 'Unknown\.FutureKey=KeepMe'
        $written = Get-Content -LiteralPath $engine -Raw
        $clientWritten = Get-Content -LiteralPath $clientEngine -Raw
        $written | Should -Match '(?m)^KeepMe=Yes\r?$'
        $written | Should -Match '(?m)^Unknown\.FutureKey=KeepMe\r?$'
        @([regex]::Matches($written, '(?m)^Hydration\.SunExposureEnabled=0\r?$')).Count |
            Should -Be 1
        $written | Should -Match '(?m)^Vehicle\.MaxVehiclesPerPlayer=20\r?$'
        $written | Should -Match '(?m)^Dune\.DisableShieldOnShooting=0\r?$'
        $written | Should -Match '(?m)^Vehicle\.RecoveryTimeLimit=1\r?$'
        $written | Should -Match '(?m)^dw\.VehicleDurabilityDamageMultiplier=0\.01\r?$'
        $written | Should -Match '(?m)^Vehicle\.RelocationEnabled=1\r?$'
        $written | Should -Match '(?m)^Vehicle\.RecoveryChassisDurabilityReductionFraction=0\.001\r?$'
        $written | Should -Match '(?m)^Vehicle\.RecoveryCurrencyBaseCost=100\r?$'
        $clientWritten | Should -Match '(?m)^Client\.FutureKey=KeepMe\r?$'
        $clientWritten.Trim() | Should -Be ((@(
            '[ConsoleVariables]'
            'Dune.DisableShieldOnShooting=1'
            'Dune.DisableShieldOnShooting=1'
            'Client.FutureKey=KeepMe'
        ) -join [Environment]::NewLine).Trim())
    }

    It 'rejects invalid vehicle values before changing Engine.ini' -TestCases @(
        @{ Key = 'dw.VehicleDurabilityDamageMultiplier'; Value = 'NaN' }
        @{ Key = 'dw.VehicleDurabilityDamageMultiplier'; Value = 'Infinity' }
        @{ Key = 'dw.VehicleDurabilityDamageMultiplier'; Value = '0,01' }
        @{ Key = 'Vehicle.RecoveryTimeLimit'; Value = '-1' }
        @{ Key = 'Vehicle.RecoveryChassisDurabilityReductionFraction'; Value = '1.01' }
        @{ Key = 'Vehicle.RecoveryCurrencyBaseCost'; Value = '100.5' }
        @{ Key = 'Vehicle.RelocationEnabled'; Value = '2' }
    ) {
        param($Key, $Value)
        $layout = New-TestSoloLayout
        $engine = Join-Path $layout.config 'Engine.ini'
        $original = "[ConsoleVariables]`nUnknown.FutureKey=KeepMe"
        [IO.File]::WriteAllText($engine, $original)
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        { Set-DuneSoloConsoleSettings -Settings @{ $Key = $Value } -Confirm 'APPLY SOLO CONSOLE SETTINGS' } |
            Should -Throw
        [IO.File]::ReadAllText($engine) | Should -BeExactly $original
    }

    It 'blocks Retail Engine.ini writes while the game is running' {
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

    It 'does not write the stale WindowsClient Engine.ini file' {
        $layout = New-TestSoloLayout
        $engine = Join-Path $layout.config 'Engine.ini'
        $clientConfig = Join-Path $layout.root 'Config\WindowsClient'
        New-Item -ItemType Directory -Path $clientConfig -Force | Out-Null
        $clientEngine = Join-Path $clientConfig 'Engine.ini'
        $hostOriginal = "[ConsoleVariables]`nHydration.SunExposureEnabled=1"
        $clientOriginal = "[ConsoleVariables]`nHydration.SunExposureEnabled=1"
        [IO.File]::WriteAllText($engine, $hostOriginal)
        [IO.File]::WriteAllText($clientEngine, $clientOriginal)
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Set-DuneSoloConsoleSettings -Settings @{
            'Hydration.SunExposureEnabled' = '0'
        } -Confirm 'APPLY SOLO CONSOLE SETTINGS' | Out-Null
        (Get-Content -LiteralPath $engine -Raw) | Should -Match 'Hydration\.SunExposureEnabled=0'
        (Get-Content -LiteralPath $clientEngine -Raw).Trim() | Should -Be $clientOriginal.Trim()
    }

    It 'rejects unsupported or out-of-range Retail console settings' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        {
            Set-DuneSoloConsoleSettings -Settings @{ 'Unknown.Key' = '1' } `
                -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*Unsupported Solo console setting*'
        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Vehicle.MaxVehiclesPerPlayer' = '1001'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*between 0 and 1000*'
    }

    It 'does not guess an unsupported Engine.ini folder' {
        $layout = New-TestSoloLayout -Channel 'FLS_live'
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }

        (Read-DuneSoloConsoleSettings).supported | Should -BeFalse
        {
            Set-DuneSoloConsoleSettings -Settings @{
                'Hydration.SunExposureEnabled' = '0'
            } -Confirm 'APPLY SOLO CONSOLE SETTINGS'
        } | Should -Throw '*supported Retail adapter*'
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

    It 'builds a backup-safe exact Solo item deletion while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Get-DuneSoloGameplayCatalogPath { Join-Path $script:SoloTestRoot 'catalog.json' }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                itemId = 107
                removed = 4
                remaining = 6
                safetyBackup = 'test'
            }
        }

        $result = Remove-DuneSoloInventoryItem -ItemId 107 `
            -ExpectedStackSize 10 -Quantity 4 -Confirm 'DELETE SOLO ITEM'

        $result.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'delete-item' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['item-id'] -eq 107 -and
            $Arguments['expected-stack-size'] -eq 10 -and
            $Arguments.quantity -eq 4 -and
            $Arguments['safety-backup'] -like '*pre-item-delete*'
        }
    }

    It 'rejects invalid or unconfirmed Solo item deletion input before invoking the helper' {
        Mock Get-DuneSoloGameProcesses { @() }
        {
            Remove-DuneSoloInventoryItem -ItemId 107 `
                -ExpectedStackSize 10 -Quantity 11 -Confirm 'DELETE SOLO ITEM'
        } | Should -Throw '*between 1 and the current stack size*'
        {
            Remove-DuneSoloInventoryItem -ItemId 107 `
                -ExpectedStackSize 10 -Quantity 4 -Confirm 'yes'
        } | Should -Throw '*Confirm the offline Solo item deletion*'
    }

    It 'requires the exact blueprint-import confirmation phrase' {
        {
            Import-DuneSoloBlueprint -Blueprint @{
                name = 'Test'
                instances = @(@{ building_type = 'Wall'; x = 0; y = 0; z = 0; rotation = 0 })
                placeables = @()
                pentashields = @()
            } -Confirm 'yes'
        } | Should -Throw '*Confirm the offline blueprint import*'
    }

    It 'builds a backup-safe Retail blueprint import while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper { @{ ok = $true; safetyBackup = 'test' } }

        {
            Import-DuneSoloBlueprint -Blueprint @{
                name = 'Test'
                instances = @()
                placeables = @()
                pentashields = @()
            } -Confirm 'IMPORT SOLO BLUEPRINT'
        } | Should -Not -Throw

        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'import-blueprint' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['safety-backup'] -like '*pre-blueprint*'
        }
    }

    It 'lists and exports Solo blueprints from a connected save without opening import' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Invoke-DuneSoloHelper {
            if ($Command -eq 'list-blueprints') {
                return @{
                    ok = $true
                    blueprints = @(
                        @{ id = 7; itemId = 11; name = 'Wick Solido'; instances = 4; placeables = 1; pentashields = 0 }
                    )
                }
            }
            if ($Command -eq 'export-blueprint') {
                return @{
                    ok = $true
                    filename = 'Wick Solido.json'
                    blueprint = @{
                        name = 'Wick Solido'
                        instances = @()
                        placeables = @()
                        pentashields = @()
                    }
                }
            }
            throw "Unexpected helper command $Command"
        }

        $listed = Get-DuneSoloBlueprints
        $listed.blueprints[0].id | Should -Be 7
        $exported = Export-DuneSoloBlueprint -Id 7
        $exported.filename | Should -Be 'Wick Solido.json'

        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'list-blueprints' -and $Arguments.input -eq $layout.db
        }
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'export-blueprint' -and $Arguments.input -eq $layout.db -and $Arguments.id -eq 7
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

    It 'builds a backup-safe ranged weapon ammo update while the game is closed' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Get-DuneSoloGameplayCatalogPath { Join-Path $script:SoloTestRoot 'catalog.json' }
        Mock Invoke-DuneSoloHelper {
            @{
                ok = $true
                itemId = 106
                currentAmmo = 250
                safetyBackup = 'test'
            }

        }
        $result = Set-DuneSoloWeaponAmmo -ItemId 106 -Ammo 250 `
            -Confirm 'SET SOLO WEAPON AMMO'

        $result.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'set-weapon-ammo' -and
            $Arguments.input -eq $layout.db -and
            $Arguments['item-id'] -eq 106 -and
            $Arguments.ammo -eq 250 -and
            $Arguments['safety-backup'] -like '*pre-ammo*'
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

    It 'builds a main quest unlock with the selected save and retained backup' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Invoke-DuneSoloHelper { @{ ok = $true } }
        (Unlock-DuneSoloMainQuest -Quest 'DA_MQ_AssassinsHandbook' -Confirm 'UNLOCK SOLO MAIN QUEST').ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'unlock-main-quest' -and $Arguments.input -eq $layout.db -and
            $Arguments.quest -eq 'DA_MQ_AssassinsHandbook' -and
            $Arguments.tags -like '*dune-tags.json' -and
            $Arguments['safety-backup'] -like '*pre-progression*'
        }
    }

    It 'rejects a main quest unlock while the game is running' {
        Mock Get-DuneSoloGameProcesses { @(@{name='DuneSandbox';pid=42}) }
        Mock Invoke-DuneSoloHelper { throw 'Must not run' }
        { Unlock-DuneSoloMainQuest -Quest 'DA_MQ_ANewBeginning' -Confirm 'UNLOCK SOLO MAIN QUEST' } | Should -Throw '*still running*'
        Assert-MockCalled Invoke-DuneSoloHelper -Times 0
    }

    It 'builds each Retail progression command with a retained backup' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        Mock Get-DuneSoloGameProcesses { @() }
        Mock Get-DuneSoloDataFilePath {
            if ($Name -eq 'solo-retail-v1.json') {
                return Join-Path (Get-DstRepoRoot) 'app\data\solo-retail-v1.json'
            }
            Join-Path $script:SoloTestRoot $Name
        }
        Mock Invoke-DuneSoloHelper { @{ ok = $true; action = $Command } }

        $spec = Invoke-DuneSoloProgressionAction -Action 'max-specializations' `
            -Confirm 'MAX SOLO SPECIALIZATIONS' -ExpectedConfirm 'MAX SOLO SPECIALIZATIONS'
        $fremen = Invoke-DuneSoloProgressionAction -Action 'complete-fremen' `
            -Confirm 'COMPLETE FIND THE FREMEN' -ExpectedConfirm 'COMPLETE FIND THE FREMEN'
        $npe = Invoke-DuneSoloProgressionAction -Action 'complete-npe' `
            -Confirm 'COMPLETE SOLO NPE' -ExpectedConfirm 'COMPLETE SOLO NPE'
        $skills = Invoke-DuneSoloProgressionAction -Action 'enable-skills' `
            -Confirm 'ENABLE SOLO SKILLS' -ExpectedConfirm 'ENABLE SOLO SKILLS'
        $points = Set-DuneSoloProgressionPoints -SkillPoints 321 -Intel 654 `
            -Confirm 'SET SOLO PROGRESSION POINTS'

        $spec.ok | Should -BeTrue
        $fremen.ok | Should -BeTrue
        $npe.ok | Should -BeTrue
        $skills.ok | Should -BeTrue
        $points.ok | Should -BeTrue
        Assert-MockCalled Invoke-DuneSoloHelper -Times 5 -ParameterFilter {
            $Arguments.input -eq $layout.db -and
            $Arguments['safety-backup'] -like '*pre-progression*' -and
            $Arguments.adapter -like '*solo-retail-v1.json'
        }
        Assert-MockCalled Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'set-progression-points' -and
            $Arguments['skill-points'] -eq 321 -and
            $Arguments.intel -eq 654
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
            '/api/solo/blueprints',
            '/api/solo/blueprints/export',
            '/api/solo/blueprints/import',
            '/api/solo/items/augments/max',
            '/api/solo/currencies',
            '/api/solo/fillables/water',
            '/api/solo/items/weapon-ammo',
            '/api/solo/progression/specializations/max',
            '/api/solo/progression/find-the-fremen',
            '/api/solo/progression/npe/complete',
            '/api/solo/progression/skills/enable-all',
            '/api/solo/progression/points'
        )) {
            $script:CapturedSoloRoutes | Should -Contain $expected
        }
    }

    It 'rejects a stale blueprint export before invoking the export helper' {
        Register-DstStubs
        $script:CapturedSoloRouteHandlers = @{}
        function global:Write-DuneError {
            param($Response, $Status, $Message)
            $Response.Status = $Status
            $Response.Message = $Message
        }
        function global:Invoke-WithDuneLock {
            param($Name, $Script)
            & $Script
        }
        Mock Register-DuneRoute {
            param($Method, $Path, $Handler, [switch]$Inline, [switch]$LocalOnly)
            $script:CapturedSoloRouteHandlers[$Path] = $Handler
        }
        Mock Invoke-WithDuneLock {
            param($Name, $Script)
            & $Script
        }
        Mock Assert-DuneSoloExpectedProfile {
            throw 'The selected Solo profile changed in another window. Refresh and try again.'
        }
        Mock Export-DuneSoloBlueprint {}
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1')

        $query = [Collections.Specialized.NameValueCollection]::new()
        $query.Add('id', '7')
        $query.Add('expectedProfileToken', 'stale-profile-token')
        $request = [pscustomobject]@{ QueryString = $query }
        $response = [pscustomobject]@{ Status = 0; Message = '' }
        & $script:CapturedSoloRouteHandlers['/api/solo/blueprints/export'] $request $response $null $null

        $response.Status | Should -Be 409
        $response.Message | Should -Match 'changed in another window'
        Assert-MockCalled Export-DuneSoloBlueprint -Times 0 -Exactly
    }

    It 'returns blueprint rows with the connected profile token' {
        Register-DstStubs
        $script:CapturedSoloRouteHandlers = @{}
        function global:Write-DuneJson {
            param($Response, $Body)
            $Response.Body = $Body
        }
        function global:Invoke-WithDuneLock {
            param($Name, $Script)
            & $Script
        }
        Mock Register-DuneRoute {
            param($Method, $Path, $Handler, [switch]$Inline, [switch]$LocalOnly)
            $script:CapturedSoloRouteHandlers[$Path] = $Handler
        }
        Mock Assert-DuneSoloExpectedProfile {}
        Mock Get-DuneSoloProfile { @{ dbPath = 'C:\Solo\profile\game.db' } }
        Mock Get-DuneSoloBlueprints {
            [pscustomobject]@{ ok = $true; blueprints = @([pscustomobject]@{ id = 7 }) }
        }
        Mock Get-DuneSoloProfileToken { 'active-profile-token' }
        . (Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1')

        $query = [Collections.Specialized.NameValueCollection]::new()
        $query.Add('expectedProfileToken', 'active-profile-token')
        $request = [pscustomobject]@{ QueryString = $query }
        $response = [pscustomobject]@{ Body = $null }
        & $script:CapturedSoloRouteHandlers['/api/solo/blueprints'] $request $response $null $null

        $response.Body.profileToken | Should -Be 'active-profile-token'
        $response.Body.blueprints[0].id | Should -Be 7
        Assert-MockCalled Get-DuneSoloProfileToken -Times 1 -Exactly -ParameterFilter {
            $DbPath -eq 'C:\Solo\profile\game.db'
        }
    }
}

Describe 'Solo Mode Retail progression catalogs' {
    It 'keeps the 140-node Retail NPE catalog separate from the 136-node shared catalog' {
        $root = Get-DstRepoRoot
        $shared = Get-Content (Join-Path $root 'app\data\dune-npe-completion-nodes.json') -Raw | ConvertFrom-Json
        $retail = Get-Content (Join-Path $root 'app\data\solo-retail-v1.json') -Raw | ConvertFrom-Json
        $retailNodes = @($retail.complete_npe.nodes)
        $sharedNodes = @($shared.nodes)
        $extras = @($retailNodes | Where-Object { $_ -notin $sharedNodes })

        $sharedNodes.Count | Should -Be 136
        $retail.complete_npe.node_count | Should -Be 140
        $retailNodes.Count | Should -Be 140
        @($retailNodes | Sort-Object -Unique).Count | Should -Be 140
        $retail.schema_fingerprint | Should -Be '421d15955599ea223b3a72d1b418eb94befe333b7be9c20babd40ddf60274130'
        $extras | Should -Be @(
            'DA_MQ_ANewBeginning.Dangerous Mission No 2.BaseBackupTool'
            'DA_MQ_ANewBeginning.Dangerous Mission No 2.BaseBackupTool.CraftBaseBackupTool'
            'DA_MQ_ANewBeginning.Dangerous Mission No 2.BaseBackupTool.ResearchBaseBackupTool'
            'DA_MQ_ANewBeginning.Dangerous Mission No 2.Build a Sandbike.BackupBase'
        )
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
        $legacy = Join-Path $root 'FLS_beta\123\game.db'
        $retail = Join-Path $root 'FLS\123\game.db'
        (Get-DuneSoloProfileBackupRoot -DbPath $legacy) |
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

    It 'keeps blueprint list and export behind the same stale-profile guard' {
        $route = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\server\routes\SoloMode.ps1') -Raw
        $listRoute = $route.Substring(
            $route.IndexOf("Register-DuneRoute -Method GET -Path '/api/solo/blueprints'"),
            $route.IndexOf("Register-DuneRoute -Method GET -Path '/api/solo/blueprints/export'") -
                $route.IndexOf("Register-DuneRoute -Method GET -Path '/api/solo/blueprints'")
        )
        $exportRoute = $route.Substring(
            $route.IndexOf("Register-DuneRoute -Method GET -Path '/api/solo/blueprints/export'"),
            $route.IndexOf("Register-DuneRoute -Method POST -Path '/api/solo/blueprints/import'") -
                $route.IndexOf("Register-DuneRoute -Method GET -Path '/api/solo/blueprints/export'")
        )

        $listRoute | Should -Match "QueryString\['expectedProfileToken'\]"
        $listRoute | Should -Match 'Invoke-WithDuneLock'
        $listRoute | Should -Match 'Assert-DuneSoloExpectedProfile'
        $listRoute | Should -Match 'profileToken'
        $exportRoute | Should -Match "QueryString\['expectedProfileToken'\]"
        $exportRoute | Should -Match 'Invoke-WithDuneLock'
        $exportRoute | Should -Match 'Assert-DuneSoloExpectedProfile'
        $exportRoute | Should -Match 'Export-DuneSoloBlueprint -Id \$id'
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

    It 'deletes multiple selected backups after validating the complete set' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        foreach ($name in @('first.db', 'second.db', 'keep.db')) {
            [IO.File]::WriteAllBytes((Join-Path $activeRoot $name), [byte[]](1))
        }

        $result = Remove-DuneSoloBackups -RelativePaths @('first.db', 'second.db') `
            -Confirm 'DELETE SOLO BACKUPS'

        $result.deletedCount | Should -Be 2
        @($result.deleted | Sort-Object) | Should -Be @('first.db', 'second.db')
        (Test-Path -LiteralPath (Join-Path $activeRoot 'first.db')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $activeRoot 'second.db')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $activeRoot 'keep.db')) | Should -BeTrue
    }

    It 'validates every selected backup before deleting any' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        $valid = Join-Path $activeRoot 'valid.db'
        [IO.File]::WriteAllBytes($valid, [byte[]](1))

        {
            Remove-DuneSoloBackups -RelativePaths @('valid.db', '..\foreign.db') `
                -Confirm 'DELETE SOLO BACKUPS'
        } | Should -Throw '*outside the connected Solo profile backup directory*'
        (Test-Path -LiteralPath $valid) | Should -BeTrue
    }

    It 'rolls staged backups back when a later staging move fails' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        $first = Join-Path $activeRoot 'first.db'
        $second = Join-Path $activeRoot 'second.db'
        [IO.File]::WriteAllBytes($first, [byte[]](1))
        [IO.File]::WriteAllBytes($second, [byte[]](2))
        $script:moveCount = 0
        Mock Move-Item {
            param($LiteralPath, $Destination, $ErrorAction)
            $script:moveCount++
            if ($script:moveCount -eq 2) { throw 'simulated staging failure' }
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath `
                -Destination $Destination -ErrorAction $ErrorAction
        }

        {
            Remove-DuneSoloBackups -RelativePaths @('first.db', 'second.db') `
                -Confirm 'DELETE SOLO BACKUPS'
        } | Should -Throw '*simulated staging failure*'
        (Test-Path -LiteralPath $first) | Should -BeTrue
        (Test-Path -LiteralPath $second) | Should -BeTrue
    }

    It 'rejects a reparse point on the deletion staging directory' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        $stageParent = Join-Path $activeRoot '.delete-staging'
        $junctionTarget = Join-Path $script:SoloTestRoot 'staging-junction-target'
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $stageParent -Target $junctionTarget | Out-Null
        $target = Join-Path $activeRoot 'keep.db'
        [IO.File]::WriteAllBytes($target, [byte[]](1))

        {
            Remove-DuneSoloBackups -RelativePaths @('keep.db') `
                -Confirm 'DELETE SOLO BACKUPS'
        } | Should -Throw '*reparse point*'
        (Test-Path -LiteralPath $target) | Should -BeTrue
    }

    It 'reports exact deleted and retained files when final cleanup is partial' {
        $layout = New-TestSoloLayout
        Save-DuneSoloState -DataRoot $layout.root -DbPath $layout.db | Out-Null
        $activeRoot = Get-DuneSoloProfileBackupRoot -DbPath $layout.db
        New-Item -ItemType Directory -Path $activeRoot -Force | Out-Null
        $first = Join-Path $activeRoot 'first.db'
        $second = Join-Path $activeRoot 'second.db'
        [IO.File]::WriteAllBytes($first, [byte[]](1))
        [IO.File]::WriteAllBytes($second, [byte[]](2))
        Mock Remove-DuneSoloBackupFile {
            param($Path)
            if ($Path -like '*001-second.db') {
                throw 'simulated final delete failure'
            }
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }

        {
            Remove-DuneSoloBackups -RelativePaths @('first.db', 'second.db') `
                -Confirm 'DELETE SOLO BACKUPS'
        } | Should -Throw '*Permanently deleted: first.db*Retained for recovery: second.db*'
        (Test-Path -LiteralPath $first) | Should -BeFalse
        (Test-Path -LiteralPath $second) | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $activeRoot '.delete-staging') `
            -Filter '*second.db' -File -Recurse).Count | Should -Be 1
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

Describe 'Solo diagnostic export and specialization edits' {
    BeforeEach {
        Reset-TestSoloState
        $script:DiagnosticLayout = New-TestSoloLayout
        Mock Assert-DuneSoloSupportedPlatform {}
        Mock Assert-DuneSoloGameClosed {}
        Mock Get-DuneSoloProfile { @{ dbPath = $script:DiagnosticLayout.db; channel = 'FLS_retail' } }
        Mock Assert-DuneSoloProgressionAdapter {}
        Mock Get-DuneSoloAdapterDescriptor { @{ manifestPath = 'retail-adapter.json' } }
        Mock Invoke-DuneSoloHelper { [pscustomobject]@{ ok = $true; report = [pscustomobject]@{ format = 'dst-solo-diagnostics-v1' } } }
    }
    It 'exports through a read-only command and excludes the source path from the returned report' {
        $result = Export-DuneSoloDiagnostics
        $result.ok | Should -BeTrue
        $result.report.channel | Should -Be 'FLS_retail'
        ($result.report | ConvertTo-Json) | Should -Not -Match 'dbPath'
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -ParameterFilter { $Command -eq 'diagnostics' -and $Arguments.input -eq $script:DiagnosticLayout.db }
    }
    It 'refuses diagnostics while the game is running' {
        Mock Assert-DuneSoloGameClosed { throw 'Game is still running' }
        { Export-DuneSoloDiagnostics } | Should -Throw '*still running*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
    It 'edits a single track with an explicit target and retained pre-progression backup' {
        Set-DuneSoloSpecialization -Track Crafting -Level 37 -Confirm 'SET SOLO SPECIALIZATION'
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'set-specialization' -and $Arguments.level -eq 37 -and $Arguments.track -eq 'Crafting' -and $Arguments['safety-backup'] -like '*pre-progression*game-before-set-specialization*'
        }
    }
    It 'rejects out-of-range levels without invoking the helper' {
        { Set-DuneSoloSpecialization -Track Crafting -Level 101 -Confirm 'SET SOLO SPECIALIZATION' } | Should -Throw '*0 to 100*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
    It 'requires the exact edit confirmation' {
        { Set-DuneSoloSpecialization -Track Crafting -Level 37 -Confirm '' } | Should -Throw '*Confirm*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
    It 'resets reward claims using the verified catalog and retained backup' {
        Reset-DuneSoloSpecializationRewards -Track Crafting -Confirm 'RESET SOLO SPECIALIZATION REWARDS'
        Should -Invoke Invoke-DuneSoloHelper -Times 1 -ParameterFilter {
            $Command -eq 'reset-specialization-rewards' -and $Arguments.track -eq 'Crafting' -and $Arguments.keystones -like '*dune-keystones.json' -and $Arguments['safety-backup'] -like '*pre-progression*game-before-reset-specialization-rewards*'
        }
    }
    It 'requires explicit confirmation before resetting rewards' {
        { Reset-DuneSoloSpecializationRewards -Track Crafting -Confirm '' } | Should -Throw '*Confirm*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
    It 'refuses reward resets while the game is running' {
        Mock Assert-DuneSoloGameClosed { throw 'Game is still running' }
        { Reset-DuneSoloSpecializationRewards -Track Crafting -Confirm 'RESET SOLO SPECIALIZATION REWARDS' } | Should -Throw '*still running*'
        Should -Invoke Invoke-DuneSoloHelper -Times 0
    }
}
