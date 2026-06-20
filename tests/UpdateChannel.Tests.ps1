BeforeAll {
    . (Join-Path $PSScriptRoot '_TestHelpers.ps1')
    Import-DstLib   'Config.ps1'
    Import-DstRoute 'Update.ps1'

    # A representative GitHub /releases payload (newest-first), already mapped to
    # the shape Get-DuneReleases emits. Mix of: newest stable final, two test
    # pre-releases (newest first), one asset-less pre-release (must be filtered),
    # one draft pre-release (must be filtered), and an older final.
    function global:New-DstReleaseFixture {
        @(
            [pscustomobject]@{ tag='v12.9.5';        name='v12.9.5';        isPrerelease=$false; isDraft=$false; assetUrl='https://x/final.exe';  assetName='DuneServerSetup.exe'; assetSize=100; htmlUrl='u'; publishedAt='2026-06-21'; releaseNotes='' }
            [pscustomobject]@{ tag='v12.9.6-test2';  name='Spec fix test2'; isPrerelease=$true;  isDraft=$false; assetUrl='https://x/t2.exe';     assetName='DuneServerSetup.exe'; assetSize=100; htmlUrl='u'; publishedAt='2026-06-20'; releaseNotes='' }
            [pscustomobject]@{ tag='v12.9.6-test1';  name='Spec fix test1'; isPrerelease=$true;  isDraft=$false; assetUrl='https://x/t1.exe';     assetName='DuneServerSetup.exe'; assetSize=100; htmlUrl='u'; publishedAt='2026-06-19'; releaseNotes='' }
            [pscustomobject]@{ tag='v12.9.6-test0';  name='no asset';       isPrerelease=$true;  isDraft=$false; assetUrl=$null;                  assetName=$null;                 assetSize=0;   htmlUrl='u'; publishedAt='2026-06-18'; releaseNotes='' }
            [pscustomobject]@{ tag='v12.9.7-draft';  name='draft';          isPrerelease=$true;  isDraft=$true;  assetUrl='https://x/d.exe';      assetName='DuneServerSetup.exe'; assetSize=100; htmlUrl='u'; publishedAt='2026-06-22'; releaseNotes='' }
            [pscustomobject]@{ tag='v12.9.4';        name='v12.9.4';        isPrerelease=$false; isDraft=$false; assetUrl='https://x/old.exe';    assetName='DuneServerSetup.exe'; assetSize=100; htmlUrl='u'; publishedAt='2026-06-10'; releaseNotes='' }
        )
    }

    function global:New-DstStableLatest {
        [pscustomobject]@{
            fetchedAt=[DateTime]::UtcNow; tag='v12.9.5'; name='v12.9.5'; htmlUrl='u'
            publishedAt='2026-06-21'; releaseNotes=''; assetName='DuneServerSetup.exe'
            assetUrl='https://x/final.exe'; assetSize=100
        }
    }
}

Describe 'Compare-DuneSemver (prerelease-aware)' {
    It 'ranks a higher patch above a lower one' {
        Compare-DuneSemver -A '12.9.5' -B '12.9.4' | Should -BeGreaterThan 0
        Compare-DuneSemver -A '12.9.4' -B '12.9.5' | Should -BeLessThan 0
    }
    It 'treats identical versions as equal' {
        Compare-DuneSemver -A '12.9.5' -B '12.9.5' | Should -Be 0
        Compare-DuneSemver -A 'v12.9.5-test1' -B '12.9.5-test1' | Should -Be 0
    }
    It 'ranks a final release above its prerelease of the same core' {
        Compare-DuneSemver -A '12.9.5' -B '12.9.5-test1' | Should -BeGreaterThan 0
        Compare-DuneSemver -A '12.9.5-test1' -B '12.9.5' | Should -BeLessThan 0
    }
    It 'orders dotted numeric prerelease identifiers numerically' {
        Compare-DuneSemver -A '12.9.5-rc.2' -B '12.9.5-rc.1' | Should -BeGreaterThan 0
    }
    It 'distinguishes distinct -testN tags (never equal)' {
        Compare-DuneSemver -A '12.9.6-test2' -B '12.9.6-test1' | Should -Not -Be 0
    }
    It 'rolls a tester onto the final release when core matches' {
        # current = a -testN build of 12.9.6; final 12.9.6 must read as newer.
        Compare-DuneSemver -A '12.9.6' -B '12.9.6-test1' | Should -BeGreaterThan 0
    }
}

Describe 'Get-DunePreReleaseList filtering' {
    BeforeEach {
        function global:Get-DuneReleases { param([switch]$Force) New-DstReleaseFixture }
    }
    It 'keeps only published pre-releases carrying the installer asset, newest-first' {
        $list = Get-DunePreReleaseList
        @($list).Count | Should -Be 2
        $list[0].tag | Should -Be 'v12.9.6-test2'
        $list[1].tag | Should -Be 'v12.9.6-test1'
    }
    It 'excludes finals, drafts and asset-less pre-releases' {
        $tags = (Get-DunePreReleaseList).tag
        $tags | Should -Not -Contain 'v12.9.5'
        $tags | Should -Not -Contain 'v12.9.6-test0'
        $tags | Should -Not -Contain 'v12.9.7-draft'
    }
}

Describe 'Get-DuneSelectedRelease channel resolution' {
    BeforeEach {
        function global:Get-DuneReleases     { param([switch]$Force) New-DstReleaseFixture }
        function global:Get-DuneLatestRelease { param([switch]$Force) New-DstStableLatest }
        function global:Get-DuneUpdatePreReleaseTag { '' }
    }

    It 'stable channel returns the stable latest, not a prerelease' {
        function global:Get-DuneUpdateChannel { 'stable' }
        $r = Get-DuneSelectedRelease
        $r.tag | Should -Be 'v12.9.5'
        $r.channel | Should -Be 'stable'
        $r.isPrerelease | Should -BeFalse
    }

    It 'test channel with no pin selects the newest prerelease' {
        function global:Get-DuneUpdateChannel { 'test' }
        $r = Get-DuneSelectedRelease
        $r.tag | Should -Be 'v12.9.6-test2'
        $r.channel | Should -Be 'test'
        $r.isPrerelease | Should -BeTrue
    }

    It 'test channel honors a valid pinned tag' {
        function global:Get-DuneUpdateChannel { 'test' }
        function global:Get-DuneUpdatePreReleaseTag { 'v12.9.6-test1' }
        (Get-DuneSelectedRelease).tag | Should -Be 'v12.9.6-test1'
    }

    It 'test channel falls back to newest when the pinned tag is gone' {
        function global:Get-DuneUpdateChannel { 'test' }
        function global:Get-DuneUpdatePreReleaseTag { 'v12.9.6-test99' }
        (Get-DuneSelectedRelease).tag | Should -Be 'v12.9.6-test2'
    }

    It 'test channel falls back to stable when no prereleases exist' {
        function global:Get-DuneUpdateChannel { 'test' }
        function global:Get-DuneReleases { param([switch]$Force) @() }
        $r = Get-DuneSelectedRelease
        $r.tag | Should -Be 'v12.9.5'
        $r.channel | Should -Be 'test'
        $r.isPrerelease | Should -BeFalse
    }
}

Describe 'Get-DuneUpdateInstalledPrerelease (running-build marker)' {
    It 'is false when the marker key is absent (normal stable install)' {
        function global:Read-DuneConfigRaw { @{ UpdateChannel = 'stable' } }
        Get-DuneUpdateInstalledPrerelease | Should -BeFalse
    }
    It 'is true only after a pre-release build was installed' {
        function global:Read-DuneConfigRaw { @{ UpdateInstalledPrerelease = 'true' } }
        Get-DuneUpdateInstalledPrerelease | Should -BeTrue
    }
    It 'is false when a later stable install wrote false' {
        function global:Read-DuneConfigRaw { @{ UpdateInstalledPrerelease = 'false' } }
        Get-DuneUpdateInstalledPrerelease | Should -BeFalse
    }
    It 'does not key off the channel preference (toggling Test alone stays false)' {
        # User toggled to Test (preference set) but never installed a pre-release.
        function global:Read-DuneConfigRaw { @{ UpdateChannel = 'test' } }
        Get-DuneUpdateInstalledPrerelease | Should -BeFalse
    }
}
