BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'BuildMetadata.ps1'
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'app\build\BuildHelpers.ps1')
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
        $helpers = Get-Content -LiteralPath (Join-Path $repo 'app\build\BuildHelpers.ps1') -Raw
        $workflow = Get-Content -LiteralPath (Join-Path $repo '.github\workflows\release-signed.yml') -Raw
        $installer | Should -Match '\[switch\]\$Prerelease'
        $exe | Should -Match '\[switch\]\$Prerelease'
        $installer | Should -Match '-Prerelease:\$Prerelease'
        $installer | Should -Match 'DST-BuildInstaller-'
        $installer | Should -Match 'Another installer build is already running'
        $installer | Should -Match 'Existing release tag .* resolves to'
        $installer | Should -Match 'Tagged build .* requires a clean checkout'
        $helpers | Should -Match 'refs/tags/\$BuildTag\^\{commit\}'
        $installer | Should -Match '\[string\]\$BuildTag'
        $exe | Should -Match 'DuneServer\.\$buildId\.generated\.ps1'
        $exe | Should -Match 'rev-parse HEAD'
        $exe | Should -Not -Match 'rev-parse --short'
        $exe | Should -Match 'DuneBuildMetadataPresent = \$true'
        $workflow | Should -Match 'prerelease_build'
        $workflow | Should -Match 'inputs\.attach_to_release_tag.*github\.ref'
        $workflow | Should -Match 'fetch-depth:\s*0'
        $workflow | Should -Not -Match 'github\.ref.*Prerelease'
        $workflow | Should -Match '\$biArgs\s*=\s*@\{'
        $workflow | Should -Match '\$biArgs\.BuildTag\s*='
        $workflow | Should -Not -Match '\$biArgs\s*=\s*@\('
        $workflow | Should -Not -Match '\$biArgs\s*\+='
    }

    It 'publishes through replacement so an installed hardlink is not overwritten' {
        $installed = Join-Path $TestDrive 'installed.exe'
        $destination = Join-Path $TestDrive 'output.exe'
        $temporary = Join-Path $TestDrive 'compiled.tmp.exe'
        [IO.File]::WriteAllText($installed, 'installed-build')
        New-Item -ItemType HardLink -Path $destination -Target $installed | Out-Null
        [IO.File]::WriteAllText($temporary, 'new-build')

        Publish-DuneBuildArtifact -TemporaryPath $temporary -DestinationPath $destination

        [IO.File]::ReadAllText($installed) | Should -Be 'installed-build'
        [IO.File]::ReadAllText($destination) | Should -Be 'new-build'
        Test-Path -LiteralPath $temporary | Should -BeFalse
    }

    It 'returns an empty string when a new build tag does not exist yet' {
        $repo = Split-Path $PSScriptRoot -Parent
        Get-DuneExistingTagCommit `
            -RepoRoot $repo `
            -BuildTag 'v999.999.999-test-new-tag-regression' | Should -Be ''
    }

    It 'injects immutable build identity into API worker runspaces' {
        $repo = Split-Path $PSScriptRoot -Parent
        $http = Get-Content -LiteralPath (Join-Path $repo 'app\server\HttpServer.ps1') -Raw
        $http | Should -Match 'BuildMetadataPresent\s*=\s*\[bool\]\$script:DuneBuildMetadataPresent'
        $http | Should -Match "@\('DuneBuildMetadataPresent',\s*\`$ctx\.BuildMetadataPresent\)"
        $http | Should -Match "@\('DuneBuildCommit',\s*\`$ctx\.BuildCommit\)"
        $http | Should -Match "@\('DuneBuildPrerelease',\s*\`$ctx\.BuildPrerelease\)"
        $http | Should -Match "@\('DuneBuildTag',\s*\`$ctx\.BuildTag\)"
    }
}
