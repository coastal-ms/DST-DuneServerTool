BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Config.ps1'
    Import-DstRoute 'Update.ps1'
}
Describe 'Updater request budget' {
    BeforeEach {
        $script:DuneUpdateRetryAt = [DateTime]::MinValue
        $script:DuneUpdateRetryMessage = ''
        $script:DuneUpdateCache = $null
        $script:DuneReleasesCache = $null
        $script:DuneUpdateCommitCache = @{}
        Mock Invoke-RestMethod {
            [pscustomobject]@{ tag_name='v15.2.8'; name='stable'; body=''; published_at='2026-10-07'; target_commitish=('a'*40); assets=@() }
        }
    }
    It 'coalesces repeated forced stable checks and permits refresh after the minimum interval' {
        Get-DuneLatestRelease -Force | Out-Null
        Get-DuneLatestRelease -Force | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
        $script:DuneUpdateCache.fetchedAt = [DateTime]::UtcNow.AddSeconds(-301)
        Get-DuneLatestRelease -Force | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly
    }
    It 'coalesces repeated forced release-list checks' {
        Get-DuneReleases -Force | Out-Null
        Get-DuneReleases -Force | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
    }
    It 'does not retry a failed network request through another updater endpoint' {
        Mock Invoke-RestMethod { throw 'network unavailable' }
        (Get-DuneLatestRelease -Force).error | Should -Match 'network unavailable'
        { Get-DuneReleases -Force } | Should -Throw '*network unavailable*'
        Get-DuneLatestRelease -Force | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
    }
    It 'honors the rate-limit reset across endpoints and reports a useful error' {
        $reset = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()
        $script:RateLimitResponse = [pscustomobject]@{ Headers=@{'X-RateLimit-Remaining'='0';'X-RateLimit-Reset'=[string]$reset} }
        Mock Invoke-RestMethod {
            $exception = [Exception]::new('403 Forbidden')
            Add-Member -InputObject $exception -NotePropertyName Response -NotePropertyValue $script:RateLimitResponse
            throw $exception
        }
        (Get-DuneLatestRelease -Force).error | Should -Match 'limit reached.*local time'
        $script:DuneUpdateRetryAt | Should -BeGreaterThan ([DateTime]::UtcNow.AddMinutes(29))
        { Get-DuneReleases -Force } | Should -Throw '*limit reached*'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
    }
    It 'keeps repeated Test refreshes to one list request and one stable request' {
        Mock Invoke-RestMethod {
            $release = [pscustomobject]@{tag_name='v15.2.8';name='stable';body='';published_at='2026-10-07';target_commitish=('a'*40);assets=@([pscustomobject]@{name='DuneServerSetup.exe';browser_download_url='https://example.test/setup';size=1})}
            if ($Uri -match '/releases\?') {
                return [pscustomobject]@{tag_name='v15.2.8-test1';name='Stable mirror';body='';published_at='2026-10-07';target_commitish=('a'*40);prerelease=$true;draft=$false;assets=$release.assets}
            }
            return $release
        }
        1..20 | ForEach-Object {
            $list = @(Get-DunePreReleaseList -Force)
            $list.Count | Should -Be 1
            $list[0].isStableMirror | Should -BeTrue
        }
        Assert-MockCalled Invoke-RestMethod -Times 2 -Exactly
    }
    It 'permits a network retry when the cooldown has expired' {
        $script:DuneUpdateRetryAt = [DateTime]::UtcNow.AddSeconds(-1)
        Get-DuneLatestRelease -Force | Out-Null
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
    }
    It 'reuses immutable tag commit lookups' {
        Mock Invoke-RestMethod { [pscustomobject]@{object=[pscustomobject]@{type='commit';sha=('a'*40)}} }
        Get-DuneReleaseCommitSha -Tag 'v15.2.8' | Should -Be ('a'*40)
        Get-DuneReleaseCommitSha -Tag 'v15.2.8' | Should -Be ('a'*40)
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly
    }
}
