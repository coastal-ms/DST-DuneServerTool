BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
}

Describe 'Installer legacy autostart preservation' -Tag 'Pure' {
    It 'exports v12-v14 autostart definitions before their uninstaller removes them' {
        $installer = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\installer\DuneServer.iss') -Raw
        $prepare = $installer.Substring(
            $installer.IndexOf('function PrepareToInstall'),
            $installer.IndexOf('function ShouldInstallBridge') - $installer.IndexOf('function PrepareToInstall')
        )

        $installer | Should -Match 'function ShouldPreserveLegacyAutostart'
        $installer | Should -Match 'Result := \(major >= 12\) and \(major < 15\);'
        $installer | Should -Match 'Export-ScheduledTask'
        $installer | Should -Match 'Register-ScheduledTask'
        $installer | Should -Match 'Check: ShouldRestoreLegacyAutostart'
        $installer | Should -Match '\\Uninstall\\\{B3F8A2C1-7E5D-4F9A-8B2C-1D6E3A4F5C7D\}_is1'
        $installer | Should -Not -Match '\\Uninstall\\\{#MyAppId\}_is1'
        $prepare | Should -Match 'CaptureLegacyAutostartTasks\(\)'
        $prepare | Should -Match 'UninstallPreviousVersion\(\);'
    }

    It 'escapes apostrophes in capture and restore paths and emits valid PowerShell' {
        $installer = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\installer\DuneServer.iss') -Raw
        $path = "C:\Temp\O'Connor\DuneServer-autostart-migration"
        $escapedPath = $path.Replace("'", "''")
        $command = '$backup = ''' + $escapedPath + '''; Get-ChildItem -LiteralPath $backup -Filter ''DuneServer-Autostart-*.xml'' -File | ForEach-Object { Register-ScheduledTask -TaskPath ''\Dune Server\'' -TaskName $_.BaseName -Xml (Get-Content -LiteralPath $_.FullName -Raw) -Force -ErrorAction Stop }'
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $command,
            [ref]$tokens,
            [ref]$errors
        )

        $installer | Should -Match 'function EscapePowerShellSingleQuoted'
        $installer | Should -Match ([regex]::Escape("StringChangeEx(Result, '''', '''''', True);"))
        $installer | Should -Match 'escapedBackupDir := EscapePowerShellSingleQuoted\(LegacyAutostartBackupDir\);'
        $errorPreference = '$ErrorActionPreference = ' + "''Stop''"
        $installer | Should -Match ([regex]::Escape($errorPreference))
        $installer | Should -Match 'Parameters: "\{code:GetLegacyAutostartRestoreParameters\|\}";'
        $command | Should -Match "O''Connor"
        $errors | Should -BeNullOrEmpty
    }

    It 'blocks a v12-v14 upgrade when autostart capture cannot complete' {
        $installer = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\installer\DuneServer.iss') -Raw
        $prepare = $installer.Substring(
            $installer.IndexOf('function PrepareToInstall'),
            $installer.IndexOf('function ShouldInstallBridge') - $installer.IndexOf('function PrepareToInstall')
        )

        $installer | Should -Match 'function CaptureLegacyAutostartTasks\(\): Boolean;'
        $installer | Should -Match 'Result := False;'
        $prepare | Should -Match 'if not CaptureLegacyAutostartTasks\(\) then\s*begin'
        $prepare | Should -Match 'No changes were made\.'
        $prepare | Should -Match 'Exit;\s*end;\s*UninstallPreviousVersion\(\);'
    }

    It 'allows upgrades with no startup tasks while filtering the exact task folder locally' {
        $installer = Get-Content -LiteralPath (Join-Path (Get-DstRepoRoot) 'app\installer\DuneServer.iss') -Raw
        $capture = $installer.Substring(
            $installer.IndexOf('function CaptureLegacyAutostartTasks'),
            $installer.IndexOf('function ShouldRestoreLegacyAutostart') -
                $installer.IndexOf('function CaptureLegacyAutostartTasks')
        )

        $capture | Should -Match 'Get-ScheduledTask -ErrorAction Stop'
        $capture | Should -Not -Match 'Get-ScheduledTask -TaskPath'
        $folderFilter = '$_.TaskPath -eq ' + "''\Dune Server\''"
        $nameFilter = '$_.TaskName -like ' + "''DuneServer-Autostart-*''"
        $capture | Should -Match ([regex]::Escape($folderFilter))
        $capture | Should -Match ([regex]::Escape($nameFilter))
        $capture | Should -Match 'Result := True;\s*LegacyAutostartBackupPresent := False;'
    }
}

Describe 'Installer preserves launched games' {
    It 'stops only the DST backend without terminating its process tree' {
        $installer = Get-Content (Join-Path (Get-DstRepoRoot) 'app/installer/DuneServer.iss') -Raw
        $installer | Should -Match "'/F /IM DuneServer.exe'"
        $installer | Should -Not -Match "'/F /IM DuneServer.exe /T'"
    }
}