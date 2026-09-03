BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib 'BuildMetadata.ps1'
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'app\build\BuildHelpers.ps1')

    function New-BuildIdentityTestRepo {
        param(
            [Parameter(Mandatory)][string]$Path,
            [string[]]$Tags = @()
        )

        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        & git -C $Path init --quiet
        & git -C $Path config user.name 'DST Tests'
        & git -C $Path config user.email 'dst-tests@example.invalid'
        Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value 'test'
        & git -C $Path add tracked.txt
        & git -C $Path commit --quiet -m 'test commit'
        foreach ($tag in $Tags) {
            & git -C $Path tag $tag
        }
        return "$(& git -C $Path rev-parse HEAD)".Trim().ToLowerInvariant()
    }
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
        $helpers | Should -Match 'Existing release tag .* resolves to'
        $installer | Should -Match 'Tagged build .* requires a clean checkout'
        $helpers | Should -Match 'refs/tags/\$BuildTag\^\{commit\}'
        $installer | Should -Match '\[string\]\$BuildTag'
        $exe | Should -Match 'DuneServer\.\$buildId\.generated\.ps1'
        $exe | Should -Match 'rev-parse HEAD'
        $exe | Should -Not -Match 'rev-parse --short'
        $exe | Should -Match 'DuneBuildMetadataPresent = \$true'
        $workflow | Should -Match 'prerelease_build'
        $workflow | Should -Match 'inputs\.release_tag.*github\.ref'
        $workflow | Should -Match 'fetch-depth:\s*0'
        $workflow | Should -Not -Match 'github\.ref.*Prerelease'
        $workflow | Should -Match '\$biArgs\s*=\s*@\{'
        $workflow | Should -Match '\$biArgs\.BuildTag\s*='
        $workflow | Should -Match '\$biArgs\.BuildCommit\s*='
        $workflow | Should -Match 'Verify-ReleaseArtifact\.ps1'
        $workflow | Should -Match 'Test-DunePrereleaseTag'
        $workflow | Should -Match 'refs/tags/\$env:BUILD_TAG\^\{commit\}'
        $workflow | Should -Match 'Release assets are immutable; publish a new version instead'
        $workflow | Should -Match "'--draft'"
        $workflow | Should -Match "'release', 'edit'"
        $workflow | Should -Match "'release', 'create'"
        $workflow | Should -Not -Match 'release upload'
        $workflow | Should -Not -Match '--clobber'
        $workflow | Should -Not -Match '\$biArgs\s*=\s*@\('
        $workflow | Should -Not -Match '\$biArgs\s*\+='
    }

    It 'validates release versions and derives numeric resource versions' {
        $candidate = Get-DuneVersionInfo -Version '15.0.0-phase2-test1'

        $candidate.IsPrerelease | Should -BeTrue
        $candidate.CoreVersion | Should -BeExactly '15.0.0'
        $candidate.NumericVersion | Should -BeExactly '15.0.0.0'
        foreach ($invalid in @('01.2.3', '1.02.3', '1.2.03', '1.2.3-', '1.2.3-.test', '1.2.3-test.', '1.2.3-..', '1.2.3-01')) {
            { Get-DuneVersionInfo -Version $invalid } | Should -Throw '*SemVer-compatible release version*'
        }
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

    It 'rejects the original plain installer build on a prerelease-tagged HEAD' {
        $repo = Join-Path $TestDrive 'tagged-omission'
        $null = New-BuildIdentityTestRepo -Path $repo -Tags 'v15.0.0-test9'

        {
            Resolve-DuneBuildIdentity -RepoRoot $repo
        } | Should -Throw "*already has release tag v15.0.0-test9*BuildTag was omitted*Refusing to embed '(manual)' identity*"
    }

    It 'fails closed when an omitted build tag is ambiguous' {
        $repo = Join-Path $TestDrive 'multiple-tags'
        $null = New-BuildIdentityTestRepo -Path $repo -Tags @('v15.0.0-test9', 'v15.0.0-test10')

        {
            Resolve-DuneBuildIdentity -RepoRoot $repo
        } | Should -Throw '*multiple release tags*Refusing an ambiguous manual build*'
    }

    It 'preserves stable manual builds on an untagged HEAD' {
        $repo = Join-Path $TestDrive 'untagged-stable'
        $head = New-BuildIdentityTestRepo -Path $repo

        $identity = Resolve-DuneBuildIdentity -RepoRoot $repo

        $identity.Tag | Should -Be ''
        $identity.Prerelease | Should -BeFalse
        $identity.Commit | Should -BeExactly $head
    }

    It 'preserves prerelease identity for an untagged candidate build' {
        $repo = Join-Path $TestDrive 'untagged-prerelease'
        $head = New-BuildIdentityTestRepo -Path $repo

        $identity = Resolve-DuneBuildIdentity -RepoRoot $repo -Prerelease

        $identity.Tag | Should -Be ''
        $identity.Prerelease | Should -BeTrue
        $identity.Commit | Should -BeExactly $head
    }

    It 'requires prerelease-style tags to use the prerelease flag' {
        {
            Assert-DuneTagPrereleaseConsistency -BuildTag 'v15.0.0-test9'
        } | Should -Throw '*requires -Prerelease*'
    }

    It 'rejects the prerelease flag for stable tags' {
        {
            Assert-DuneTagPrereleaseConsistency -BuildTag 'v15.0.0' -Prerelease
        } | Should -Throw '*must not use -Prerelease*'
    }

    It 'requires an explicit full commit for tagged builds' {
        $repo = Join-Path $TestDrive 'tagged-commit'
        $head = New-BuildIdentityTestRepo -Path $repo -Tags 'v15.0.0-test9'

        {
            Resolve-DuneBuildIdentity -RepoRoot $repo -BuildTag 'v15.0.0-test9' -Prerelease
        } | Should -Throw '*requires an explicit full -BuildCommit*'
        {
            Resolve-DuneBuildIdentity -RepoRoot $repo -BuildTag 'v15.0.0-test9' -BuildCommit $head.Substring(0, 12) -BuildCommitSpecified -Prerelease
        } | Should -Throw '*requires a full 40-character BuildCommit*'
        {
            Resolve-DuneBuildIdentity -RepoRoot $repo -BuildTag 'v15.0.0-test9' -BuildCommit ('a' * 40) -BuildCommitSpecified -Prerelease
        } | Should -Throw '*does not match existing release tag*'
    }

    It 'accepts only the exact tag commit for a tagged build' {
        $repo = Join-Path $TestDrive 'exact-tagged-commit'
        $head = New-BuildIdentityTestRepo -Path $repo -Tags 'v15.0.0-test9'

        $identity = Resolve-DuneBuildIdentity `
            -RepoRoot $repo `
            -BuildTag 'v15.0.0-test9' `
            -BuildCommit $head `
            -BuildCommitSpecified `
            -Prerelease

        $identity.Commit | Should -BeExactly $head
        $identity.Tag | Should -BeExactly 'v15.0.0-test9'
        $identity.Prerelease | Should -BeTrue
    }

    It 'rejects compiled metadata that differs from the target release' {
        $metadata = [pscustomobject]@{
            present = $true
            valid = $true
            tag = 'v15.0.0-test9'
            commit = 'a' * 40
            prerelease = $false
        }

        {
            Assert-DuneBuildMetadataMatches `
               -Metadata $metadata `
               -ExpectedTag 'v15.0.0-test9' `
               -ExpectedCommit ('a' * 40) `
               -ExpectedPrerelease
        } | Should -Throw '*Built DuneServer.exe identity mismatch*'
    }

    It 'accepts matching stable manual compiled metadata' {
        $metadata = [pscustomobject]@{
            present = $true
            valid = $true
            tag = ''
            commit = 'a' * 40
            prerelease = $false
        }

        {
            $null = Assert-DuneBuildMetadataMatches `
                -Metadata $metadata `
                -ExpectedTag '' `
                -ExpectedCommit ('a' * 40)
        } | Should -Not -Throw
    }

    It 'accepts matching prerelease manual compiled metadata' {
        $metadata = [pscustomobject]@{
            present = $true
            valid = $true
            tag = ''
            commit = 'a' * 40
            prerelease = $true
        }

        {
            $null = Assert-DuneBuildMetadataMatches `
                -Metadata $metadata `
                -ExpectedTag '' `
                -ExpectedCommit ('a' * 40) `
                -ExpectedPrerelease
        } | Should -Not -Throw
    }

    It 'preserves abbreviated commit metadata for stable manual builds' {
        $metadata = [pscustomobject]@{
            present = $true
            valid = $true
            tag = ''
            commit = 'abcdef123456'
            prerelease = $false
        }

        {
            $null = Assert-DuneBuildMetadataMatches `
                -Metadata $metadata `
                -ExpectedTag '' `
                -ExpectedCommit 'abcdef123456'
        } | Should -Not -Throw
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
