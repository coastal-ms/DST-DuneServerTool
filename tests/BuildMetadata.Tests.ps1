BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'BuildMetadata.ps1'
}

Describe 'Build artifact metadata' {
    BeforeEach {
        $script:DuneServerDir = $TestDrive
        Remove-Item -LiteralPath (Join-Path $TestDrive 'build-metadata.json') -Force -ErrorAction SilentlyContinue
    }

    It 'reads a valid explicit prerelease artifact identity' {
        '{"commit":"ABCDEF123456","prerelease":true}' |
            Set-Content -LiteralPath (Join-Path $TestDrive 'build-metadata.json') -Encoding UTF8
        $metadata = Get-DuneBuildMetadata
        $metadata.present | Should -BeTrue
        $metadata.prerelease | Should -BeTrue
        $metadata.commit | Should -Be 'abcdef123456'
    }

    It 'fails safely when metadata is missing or malformed' {
        (Get-DuneBuildMetadata).present | Should -BeFalse
        '{broken' | Set-Content -LiteralPath (Join-Path $TestDrive 'build-metadata.json') -Encoding UTF8
        $metadata = Get-DuneBuildMetadata
        $metadata.present | Should -BeFalse
        $metadata.prerelease | Should -BeFalse
        $metadata.commit | Should -Be ''
    }

    It 'keeps build flavor explicit and stable by default across the pipeline' {
        $repo = Split-Path $PSScriptRoot -Parent
        $installer = Get-Content -LiteralPath (Join-Path $repo 'app\installer\Build-Installer.ps1') -Raw
        $exe = Get-Content -LiteralPath (Join-Path $repo 'app\build\Build-Exe.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $repo '.github\workflows\release-signed.yml') -Raw
        $installer | Should -Match '\[switch\]\$Prerelease'
        $exe | Should -Match '\[switch\]\$Prerelease'
        $installer | Should -Match '-Prerelease:\$Prerelease'
        $workflow | Should -Match 'prerelease_build'
        $workflow | Should -Not -Match 'github\.ref.*Prerelease'
    }
}
