BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    $installer = Get-Content (Join-Path (Get-DstRepoRoot) 'app/installer/DuneServer.iss') -Raw
    $expression = [regex]::Match($installer, '(?s)probe := (.*?);\s*probeArgs').Groups[1].Value
    $expression = [regex]::Replace($expression,
        "EscapePowerShellSingleQuoted\(ExpandConstant\('(.*?)'\)\)", {
            param($match)
            # Exercise a user profile containing an apostrophe.
            $path = if ($match.Groups[1].Value -eq '{localappdata}') { "C:\Users\user-with-apostrophe'\AppData\Local" } else { 'C:\Program Files' }
            "'" + $path.Replace("'", "''''") + "'"
        })
    $probe = ([regex]::Matches($expression, "'(?:''|[^'])*'") | ForEach-Object {
        $_.Value.Substring(1, $_.Value.Length - 2).Replace("''", "'")
    }) -join ''
    function Invoke-PrerequisiteProbe([string]$Mocks) {
        $file = Join-Path $TestDrive 'probe.ps1'
        Set-Content -LiteralPath $file -Value ($Mocks + "`n" + $probe)
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $file
        return $LASTEXITCODE
    }
}

Describe 'Installer PowerShell prerequisite before upgrade changes' {
    It 'blocks when PowerShell 7 is absent' {
        Invoke-PrerequisiteProbe 'function Get-Command { return $null }; function Test-Path { return $false }' | Should -Be 1
    }
    It 'accepts PowerShell discovered on PATH' {
        Invoke-PrerequisiteProbe 'function Get-Command { return @{Source="C:\PowerShell\pwsh.exe"} }; function Test-Path { throw "Unexpected fallback" }' | Should -Be 0
    }
    It 'accepts the user-local fallback with an apostrophe in the profile path' {
        Invoke-PrerequisiteProbe 'function Get-Command { return $null }; function Test-Path { param($LiteralPath) return $LiteralPath -eq "C:\Users\user-with-apostrophe''\AppData\Local\Microsoft\PowerShell\7\pwsh.exe" }' | Should -Be 0
    }
    It 'checks before stopping the app or uninstalling, for both install modes' {
        $prepare = $installer.Substring($installer.IndexOf('function PrepareToInstall'),
            $installer.IndexOf('function ShouldInstallBridge') - $installer.IndexOf('function PrepareToInstall'))
        $prepare.IndexOf('if probeExitCode <> 0') | Should -BeLessThan $prepare.IndexOf('StopRunningDuneServer();')
        $prepare.IndexOf('if probeExitCode <> 0') | Should -BeLessThan $prepare.IndexOf('UninstallPreviousVersion();')
        $prepare | Should -Not -Match 'InstallationModePage'
    }
}
