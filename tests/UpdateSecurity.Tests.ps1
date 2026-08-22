BeforeAll {
    . "$PSScriptRoot\_TestHelpers.ps1"
    Import-DstLib 'Config.ps1'
    . (Join-Path (Get-DstRepoRoot) 'app\server\HttpServer.ps1')
    Import-DstRoute 'Update.ps1'
    $script:UpdateInstallHandler = @($script:DuneRoutes | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/api/update/install' })[0].Handler
    $script:UpdateCheckHandler = @($script:DuneRoutes | Where-Object { $_.Method -eq 'GET' -and $_.Path -eq '/api/update/check' })[0].Handler

    function global:Get-TestSha256Digest {
        param([byte[]]$Bytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { 'sha256:' + (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
        finally { $sha.Dispose() }
    }
    function global:New-UpdateSecurityResponse {
        [pscustomobject]@{
            StatusCode=0; ContentType=''; ContentLength64=0L; Headers=@{}
            OutputStream=[IO.MemoryStream]::new()
        }
        function global:Read-UpdateSecurityResponse {
            param($Response)
            [Text.Encoding]::UTF8.GetString($Response.OutputStream.ToArray()) | ConvertFrom-Json
        }
    }
}

Describe 'Protected updater download seam' {
    BeforeEach {
        Get-ChildItem -LiteralPath $TestDrive -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $script:Payload = [Text.Encoding]::UTF8.GetBytes('verified installer payload')
        $script:DownloadCalls = 0
        Mock Invoke-WebRequest {
            $script:DownloadCalls++
            [IO.File]::WriteAllBytes($OutFile, $script:Payload)
        }
    }

    It 'always downloads to a fresh random path and ignores a same-size predictable preseed' {
        $preseed = Join-Path $TestDrive 'DuneServerSetup-v14.0.0-test6.exe'
        [IO.File]::WriteAllBytes($preseed, [byte[]](1..$script:Payload.Length))
        $release = [pscustomobject]@{
            tag='v14.0.0-test6'; assetUrl='https://example.test/installer'
            assetDigest=(Get-TestSha256Digest $script:Payload)
        }

        $first = Save-DuneVerifiedUpdateAsset -Release $release -Directory $TestDrive
        $second = Save-DuneVerifiedUpdateAsset -Release $release -Directory $TestDrive
        $first | Should -Not -Be $second
        (Split-Path $first -Leaf) | Should -Match '^DuneServerSetup-v14\.0\.0-test6-[0-9a-f]{32}\.exe$'
        $script:DownloadCalls | Should -Be 2
        [IO.File]::ReadAllBytes($preseed)[0] | Should -Be 1
    }

    It 'captures GitHub asset digest from the production release response' {
        $script:ExpectedDigest = 'sha256:' + ('a' * 64)
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name='v14.0.0-test7'; name='test7'; html_url='u'; published_at='2026-08-21'
                target_commitish='abcdef1234567890'
                body=''; assets=@([pscustomobject]@{
                    name='DuneServerSetup.exe'; browser_download_url='https://example.test/installer'
                    size=10; digest=$script:ExpectedDigest
                })
            }
        }
        $script:DuneUpdateCache = $null
        $release = Get-DuneLatestRelease -Force
        $release.assetDigest | Should -Be $script:ExpectedDigest
        $release.targetCommit | Should -Be 'abcdef1234567890'
    }

    It 'accepts only an exact SHA-256 digest match' {
        $release = [pscustomobject]@{
            tag='v14.0.0-test6'; assetUrl='https://example.test/installer'
            assetDigest=(Get-TestSha256Digest $script:Payload)
        }
        Test-Path (Save-DuneVerifiedUpdateAsset -Release $release -Directory $TestDrive) | Should -BeTrue
    }

    It 'deletes and rejects a digest mismatch' {
        $release = [pscustomobject]@{
            tag='v14.0.0-test6'; assetUrl='https://example.test/installer'
            assetDigest=('sha256:' + ('0' * 64))
        }
        { Save-DuneVerifiedUpdateAsset -Release $release -Directory $TestDrive } | Should -Throw '*does not match*'
        @(Get-ChildItem $TestDrive -Filter '*.exe').Count | Should -Be 0
    }

    It 'fails closed before download when the digest is missing or malformed' {
        foreach ($digest in @('', 'sha256:nope', ('md5:' + ('0' * 32)))) {
            $release = [pscustomobject]@{ tag='v14.0.0-test6'; assetUrl='https://example.test/installer'; assetDigest=$digest }
            { Save-DuneVerifiedUpdateAsset -Release $release -Directory $TestDrive } | Should -Throw '*valid GitHub SHA-256*'
        }
        $script:DownloadCalls | Should -Be 0
    }

    It 'resolves lightweight and annotated release tags to immutable commits' {
        $commitSha = 'a' * 40
        Mock Invoke-RestMethod {
            if ($Uri -match '/git/ref/tags/') {
                return [pscustomobject]@{
                    object = [pscustomobject]@{ type='tag'; sha=('b' * 40) }
                }
            }
            return [pscustomobject]@{
                object = [pscustomobject]@{ type='commit'; sha=$commitSha }
            }
        }
        Get-DuneReleaseCommitSha -Tag 'v14.0.0-test10' | Should -Be $commitSha
        Assert-MockCalled Invoke-RestMethod -Times 2
    }

    It 'prunes bounded installer, relaunch, Inno, and result evidence' {
        foreach ($prefix in 'DuneServerSetup','DuneRelaunch','relaunch','inno','update-result') {
            $extension = switch ($prefix) {
                'DuneServerSetup' { 'exe' }
                'DuneRelaunch' { 'ps1' }
                'update-result' { 'json' }
                default { 'log' }
            }
            1..3 | ForEach-Object {
                $path = Join-Path $TestDrive "$prefix-v14.0.0-test10-$('{0:x32}' -f $_).$extension"
                [IO.File]::WriteAllText($path, 'evidence')
            }
        }
        Remove-DuneOldUpdateFiles -Directory $TestDrive -Retain 2
        @(Get-ChildItem $TestDrive -File).Count | Should -Be 2
    }

    It 'does not launch when production-route verification fails' {
        Mock Get-DuneLock { [Threading.SemaphoreSlim]::new(1, 1) }
        Mock Get-DuneDecoupleNotice { @{ Needed=$false } }
        Mock Get-DuneSelectedRelease {
            [pscustomobject]@{
                tag='v14.0.1'; assetUrl='https://example.test/installer'; assetSize=10
                assetDigest=''; isPrerelease=$false
            }
        }
        Mock Get-DuneUpdateChannel { 'stable' }
        Mock Get-DuneUpdateRunningBuildInfo { @{ runningIsPrerelease=$false; installedTag=''; buildCommit='' } }
        Mock Get-DuneProtectedUpdateDirectory { $TestDrive }
        Mock Get-DuneReleaseCommitSha { 'abcdef1234567890abcdef1234567890abcdef12' }
        Mock Start-Process {}
        $script:DuneToolVersion = '14.0.0'
        $request = [pscustomobject]@{ QueryString=@{} }
        $response = New-UpdateSecurityResponse
        & $script:UpdateInstallHandler $request $response @{} @{ mode='interactive'; source='settings' }
        $response.StatusCode | Should -Be 502
        Assert-MockCalled Start-Process -Times 0 -Exactly
    }

    It 'uses an Administrators and SYSTEM-only protected production directory' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Update.ps1') -Raw
        $source | Should -Match "ProgramData.*DuneServer\\Updates"
        $source | Should -Match "SetAccessRuleProtection\(\`$true, \`$false\)"
        $source | Should -Match 'S-1-5-32-544'
        $source | Should -Match 'S-1-5-18'
        $source | Should -Match 'ReparsePoint'
    }

    It 'logs Inno setup and verifies installed tag and commit after exit zero' {
        $source = Get-Content (Join-Path (Get-DstRepoRoot) 'app\server\routes\Update.ps1') -Raw
        $source | Should -Match '/LOG='
        $source | Should -Match 'Get-DuneInstalledBuildIdentity'
        $source | Should -Match 'DuneServer\(\?:\\\.\[0-9a-f\]\{32\}\)\?\\\.generated\\\.ps1'
        $source | Should -Match 'Installed identity mismatch'
        $source | Should -Match 'update-result-\$safeTag-\$launchId\.json'
        $source | Should -Match 'targetCommit'
        $source | Should -Match 'Resolve-DuneInstalledExecutablePath'
        $source | Should -Match '\{B3F8A2C1-7E5D-4F9A-8B2C-1D6E3A4F5C7D\}_is1'
        $source | Should -Match 'Get-DuneReleaseCommitSha'
    }

    It 'parses literal embedded build metadata without interpolating script variables' {
        $text = @'
$script:DuneBuildMetadataPresent = $true
$script:DuneBuildCommit = '1BA87F64F62BD4F405C89E9289A0057018CB5A28'
$script:DuneBuildPrerelease = $true
$script:DuneBuildTag = 'v14.0.0-test10'
'@
        $identity = Get-DuneEmbeddedBuildIdentityFromText -Text $text
        $identity.present | Should -BeTrue
        $identity.tag | Should -Be 'v14.0.0-test10'
        $identity.commit | Should -Be '1ba87f64f62bd4f405c89e9289a0057018cb5a28'
    }

    It 'generates a PowerShell 5.1-parseable relaunch verifier' {
        Mock Get-DuneLock { [Threading.SemaphoreSlim]::new(1, 1) }
        Mock Get-DuneDecoupleNotice { @{ Needed=$false } }
        Mock Get-DuneSelectedRelease {
            [pscustomobject]@{
                tag='v14.0.0-test7'; assetUrl='https://example.test/installer'
                assetSize=10; assetDigest=('sha256:' + ('a' * 64))
                isPrerelease=$true
                targetCommit='abcdef1234567890abcdef1234567890abcdef12'
            }
        }
        Mock Get-DuneUpdateChannel { 'test' }
        Mock Get-DuneUpdateRunningBuildInfo {
            @{ runningIsPrerelease=$true; installedTag='v14.0.0-test6'; buildCommit='abcdef6' }
        }
        Mock Get-DuneProtectedUpdateDirectory { $TestDrive }
        Mock Get-DuneReleaseCommitSha { 'abcdef1234567890abcdef1234567890abcdef12' }
        Mock Save-DuneVerifiedUpdateAsset {
            $path = Join-Path $TestDrive 'verified-installer.exe'
            [IO.File]::WriteAllText($path, 'installer')
            return $path
        }
        Mock Start-Process {}
        $script:DuneToolVersion = '14.0.0'
        $script:AppDir = 'C:\Program Files\Dune Server'
        $request = [pscustomobject]@{ QueryString=@{} }
        $response = New-UpdateSecurityResponse

        & $script:UpdateInstallHandler $request $response @{} @{
            mode='silent'
            source='banner'
        }

        $response.StatusCode | Should -Be 200
        $scriptPath = @(Get-ChildItem $TestDrive -Filter 'DuneRelaunch-*.ps1') |
            Select-Object -ExpandProperty FullName -First 1
        $scriptPath | Should -Not -BeNullOrEmpty
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        $errors | Should -BeNullOrEmpty
        $generated = Get-Content -LiteralPath $scriptPath -Raw
        $generated | Should -Match 'abcdef1234567890abcdef1234567890abcdef12'
        $generated | Should -Match 'Resolve-DuneInstalledExecutablePath'
        $generated | Should -Match 'Get-DuneEmbeddedBuildIdentityFromText'
        $generated | Should -Not -Match '\[regex\]::Match\(\$text, "\(\?m\)\^\\\$script'
    }
}

Describe 'Exact installed test tag comparison' {
    It 'accepts full and short forms of the same commit only' {
        Test-DuneUpdateCommitIdentity `
            -Expected 'abcdef1234567890abcdef1234567890abcdef12' `
            -Actual 'abcdef123456' | Should -BeTrue
        Test-DuneUpdateCommitIdentity `
            -Expected 'abcdef123456' `
            -Actual 'abcdef1234567890abcdef1234567890abcdef12' | Should -BeTrue
        Test-DuneUpdateCommitIdentity `
            -Expected 'abcdef1234567890abcdef1234567890abcdef12' `
            -Actual '1234567890ab' | Should -BeFalse
        Test-DuneUpdateCommitIdentity -Expected '' -Actual '' | Should -BeTrue
    }

    It 'treats test6 as current, test7 as newer, and test5 as an intentional rollback' {
        $build = @{ runningIsPrerelease=$true; installedTag='v14.0.0-test6' }
        $running = Get-DuneRunningUpdateComparisonVersion -Channel test -CoreVersion '14.0.0' -BuildInfo $build
        $running | Should -Be 'v14.0.0-test6'

        $same = Compare-DuneSemver -A 'v14.0.0-test6' -B $running
        $newer = Compare-DuneSemver -A 'v14.0.0-test7' -B $running
        $rollback = Compare-DuneSemver -A 'v14.0.0-test5' -B $running
        (Get-DuneInstallDecision -Diff $same -Channel test -HasAsset $true -RunningIsPrerelease $true).blocked | Should -BeTrue
        (Get-DuneInstallDecision -Diff $newer -Channel test -HasAsset $true -RunningIsPrerelease $true).available | Should -BeTrue
        (Get-DuneInstallDecision -Diff $rollback -Channel test -HasAsset $true -RunningIsPrerelease $true).installable | Should -BeTrue
    }

    It 'leaves stable comparison on the core version' {
        $build = @{ runningIsPrerelease=$true; installedTag='v14.0.0-test6' }
        Get-DuneRunningUpdateComparisonVersion -Channel stable -CoreVersion '14.0.0' -BuildInfo $build |
            Should -Be '14.0.0'
    }

    It 'marks untagged and same-tag mismatched dev builds for published install' {
        $release = [pscustomobject]@{
            tag='v14.0.0-test10'
            targetCommit='abcdef1234567890abcdef1234567890abcdef12'
        }
        $untagged = Get-DuneSelectedReleaseIdentity -Release $release -BuildInfo @{
            runningIsPrerelease=$true
            installedTag=''
            buildCommit='abcdef1234567890abcdef1234567890abcdef12'
        }
        $untagged.checked | Should -BeTrue
        $untagged.mismatch | Should -BeTrue

        $mismatched = Get-DuneSelectedReleaseIdentity -Release $release -BuildInfo @{
            runningIsPrerelease=$true
            installedTag='v14.0.0-test10'
            buildCommit='1111111111111111111111111111111111111111'
        }
        $mismatched.checked | Should -BeTrue
        $mismatched.mismatch | Should -BeTrue

        $published = Get-DuneSelectedReleaseIdentity -Release $release -BuildInfo @{
            runningIsPrerelease=$true
            installedTag='v14.0.0-test10'
            buildCommit='abcdef1234567890abcdef1234567890abcdef12'
        }
        $published.checked | Should -BeTrue
        $published.mismatch | Should -BeFalse
    }

    It 'drives the production check route and global banner from test6 to newest test7' {
        Mock Get-DuneUpdateChannel { 'test' }
        Mock Get-DuneUpdateRunningBuildInfo {
            @{ runningIsPrerelease=$true; installedTag='v14.0.0-test6'; buildCommit='abcdef123456' }
        }
        Mock Get-DuneSelectedRelease {
            [pscustomobject]@{
                tag='v14.0.0-test7'; name='test7'; htmlUrl='u'; releaseNotes=''
                assetName='DuneServerSetup.exe'; assetUrl='https://example.test/installer'
                assetSize=10; assetDigest=('sha256:' + ('a' * 64)); isPrerelease=$true
            }
        }
        $script:DuneToolVersion = '14.0.0'
        $response = New-UpdateSecurityResponse
        & $script:UpdateCheckHandler ([pscustomobject]@{ QueryString=@{} }) $response @{} $null
        $body = Read-UpdateSecurityResponse $response
        $body.available | Should -BeTrue
        $body.installable | Should -BeTrue
    }

    It 'reports the exact installed test6 tag as up to date' {
        Mock Get-DuneUpdateChannel { 'test' }
        Mock Get-DuneUpdateRunningBuildInfo {
            @{ runningIsPrerelease=$true; installedTag='v14.0.0-test6'; buildCommit='abcdef123456' }
        }
        Mock Get-DuneSelectedRelease {
            [pscustomobject]@{
                tag='v14.0.0-test6'; name='test6'; htmlUrl='u'; releaseNotes=''
                assetName='DuneServerSetup.exe'; assetUrl='https://example.test/installer'
                assetSize=10; assetDigest=('sha256:' + ('a' * 64)); isPrerelease=$true
                targetCommit='abcdef1234567890abcdef1234567890abcdef12'
            }
        }
        $script:DuneToolVersion = '14.0.0'
        $response = New-UpdateSecurityResponse
        & $script:UpdateCheckHandler ([pscustomobject]@{ QueryString=@{} }) $response @{} $null
        $body = Read-UpdateSecurityResponse $response
        $body.available | Should -BeFalse
        $body.installable | Should -BeFalse
        $body.identityMismatch | Should -BeFalse
    }

    It 'reports a same-tag different-commit dev build as updateable' {
        Mock Get-DuneUpdateChannel { 'test' }
        Mock Get-DuneUpdateRunningBuildInfo {
            @{
                runningIsPrerelease=$true
                installedTag='v14.0.0-test10'
                buildCommit='1111111111111111111111111111111111111111'
            }
        }
        Mock Get-DuneSelectedRelease {
            [pscustomobject]@{
                tag='v14.0.0-test10'; name='test10'; htmlUrl='u'; releaseNotes=''
                assetName='DuneServerSetup.exe'; assetUrl='https://example.test/installer'
                assetSize=10; assetDigest=('sha256:' + ('a' * 64)); isPrerelease=$true
                targetCommit='abcdef1234567890abcdef1234567890abcdef12'
            }
        }
        $script:DuneToolVersion = '14.0.0'
        $response = New-UpdateSecurityResponse
        & $script:UpdateCheckHandler ([pscustomobject]@{ QueryString=@{} }) $response @{} $null
        $body = Read-UpdateSecurityResponse $response
        $body.available | Should -BeTrue
        $body.installable | Should -BeTrue
        $body.identityMismatch | Should -BeTrue
        $body.releaseCommit | Should -Be 'abcdef1234567890abcdef1234567890abcdef12'
    }
}
