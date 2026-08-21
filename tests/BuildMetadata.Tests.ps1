BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'BuildMetadata.ps1'
}

Describe 'Build artifact metadata' {
    BeforeEach {
        $script:DuneBuildMetadataPresent = $false
        $script:DuneBuildCommit = ''
        $script:DuneBuildPrerelease = $false
        $script:DuneBuildTag = ''
    }

    It 'reads a valid explicit prerelease artifact identity' {
        $script:DuneBuildMetadataPresent = $true
        $script:DuneBuildCommit = 'ABCDEF123456'
        $script:DuneBuildPrerelease = $true
        $script:DuneBuildTag = 'v14.0.0-test6'
        $metadata = Get-DuneBuildMetadata
        $metadata.present | Should -BeTrue
        $metadata.prerelease | Should -BeTrue
        $metadata.commit | Should -Be 'abcdef123456'
        $metadata.tag | Should -Be 'v14.0.0-test6'
    }

    It 'fails safely when metadata is absent and sanitizes malformed fields' {
        (Get-DuneBuildMetadata).present | Should -BeFalse
        $script:DuneBuildMetadataPresent = $true
        $script:DuneBuildCommit = 'not-a-commit'
        $script:DuneBuildTag = 'not a tag'
        $metadata = Get-DuneBuildMetadata
        $metadata.present | Should -BeTrue
        $metadata.prerelease | Should -BeFalse
        $metadata.commit | Should -Be ''
        $metadata.tag | Should -Be ''
    }

    It 'keeps build flavor explicit and stable by default across the pipeline' {
        $repo = Split-Path $PSScriptRoot -Parent
        $installer = Get-Content -LiteralPath (Join-Path $repo 'app\installer\Build-Installer.ps1') -Raw
        $exe = Get-Content -LiteralPath (Join-Path $repo 'app\build\Build-Exe.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $repo '.github\workflows\release-signed.yml') -Raw
        $installer | Should -Match '\[switch\]\$Prerelease'
        $exe | Should -Match '\[switch\]\$Prerelease'
        $installer | Should -Match '-Prerelease:\$Prerelease'
        $installer | Should -Match '\[string\]\$BuildTag'
        $exe | Should -Match 'DuneServer\.generated\.ps1'
        $exe | Should -Match 'DuneBuildMetadataPresent = \$true'
        $workflow | Should -Match 'prerelease_build'
        $workflow | Should -Not -Match 'github\.ref.*Prerelease'
    }
}
