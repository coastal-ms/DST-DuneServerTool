BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $repo 'app/build/BuildHelpers.ps1')
    $source = Get-Content -LiteralPath (Join-Path $repo 'app/installer/DuneServer.iss') -Raw
    $versionMacros = [regex]::Match($source, '(?ms)^#define MyAppVersion .*?^#endif').Value
    $versionDirective = [regex]::Match($source, '(?m)^VersionInfoVersion=.*$').Value.Trim()
    $iscc = $null
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $iscc = $command.Source }
    if (-not $iscc) {
        foreach ($root in @($env:LOCALAPPDATA, ${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
            if (-not $root) { continue }
            foreach ($relative in @('Programs/Inno Setup 6/ISCC.exe', 'Inno Setup 6/ISCC.exe')) {
                $candidate = Join-Path $root $relative
                if (Test-Path -LiteralPath $candidate) { $iscc = $candidate; break }
            }
            if ($iscc) { break }
        }
    }
}

Describe 'Compiled Inno installer version resources' {
    It 'compiles <Version> with the build handoff set to <Handoff>' -ForEach @(
        @{ Version = '15.2.4'; Expected = '15.2.4.0'; Handoff = $false }
        @{ Version = '15.2.3.1'; Expected = '15.2.3.1'; Handoff = $false }
        @{ Version = '15.2.4-test1'; Expected = '15.2.4.0'; Handoff = $false }
        @{ Version = '15.2.3.1-test1'; Expected = '15.2.3.1'; Handoff = $false }
        @{ Version = '15.2.4'; Expected = '15.2.4.0'; Handoff = $true }
        @{ Version = '15.2.3.1'; Expected = '15.2.3.1'; Handoff = $true }
        @{ Version = '15.2.4-test1'; Expected = '15.2.4.0'; Handoff = $true }
        @{ Version = '15.2.3.1-test1'; Expected = '15.2.3.1'; Handoff = $true }
    ) {
        if (-not $iscc) { Set-ItResult -Skipped -Because 'Inno Setup compiler is not installed'; return }
        $versionMacros | Should -Not -BeNullOrEmpty
        $versionDirective | Should -Not -BeNullOrEmpty
        $macros = $versionMacros -replace '(?m)^#define MyAppVersion .*$', ('#define MyAppVersion "' + $Version + '"')
        $scriptPath = Join-Path $TestDrive 'version.iss'
        # Compile the production macros/directive into a minimal real installer.
        @"
$macros
[Setup]
AppName=Installer version regression
AppVersion={#MyAppVersion}
$versionDirective
DefaultDirName={tmp}\InstallerVersionTest
CreateAppDir=no
Uninstallable=no
OutputDir=$TestDrive
OutputBaseFilename=version-test
Compression=none
"@ | Set-Content -LiteralPath $scriptPath
        $arguments = @('/Q')
        if ($Handoff) { $arguments += '/DMyAppNumericVersion=' + (Get-DuneVersionInfo -Version $Version).NumericVersion }
        $output = & $iscc @arguments $scriptPath 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
        $installer = Join-Path $TestDrive 'version-test.exe'
        $resource = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($installer)
        $resource.FileVersion.Trim() | Should -BeExactly $Expected
        { Assert-DuneInstallerVersion -InstallerPath $installer -ExpectedNumericVersion $Expected } | Should -Not -Throw
        { Assert-DuneInstallerVersion -InstallerPath $installer -ExpectedNumericVersion '0.0.0.0' } | Should -Throw '*installer version resource mismatch*'
    }
}
