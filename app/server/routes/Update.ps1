# /api/update — GitHub release auto-update
#
# Polls the public GitHub Releases API for the latest tag, compares against
# the running $script:DuneToolVersion, and (on user click) downloads the
# installer asset and runs it silently for Update Banner requests or
# interactively for Settings requests. The installer's PrepareToInstall
# hook silently uninstalls the prior version before laying down the new
# files, so the Start Menu shortcut keeps working and %APPDATA%\DuneServer
# is preserved.

# --- Config ------------------------------------------------------------------

$script:DuneUpdateRepo  = 'coastal-ms/DST-DuneServerTool'
$script:DuneUpdateUA    = 'DuneServerTool-Updater'
$script:DuneUpdateCache = $null    # cached release lookup (1 h TTL)

# --- Helpers -----------------------------------------------------------------

function Compare-DuneSemver {
    # Prerelease-aware semver compare. Returns <0 if A<B, 0 if equal, >0 if A>B.
    # Numeric core (major.minor.patch) compares first. On a tie, semver
    # precedence applies: a build with NO prerelease tag outranks the same core
    # WITH one (12.9.5 > 12.9.5-test1), and among prereleases the dot-separated
    # identifiers compare left-to-right (12.9.5-test1 < 12.9.5-test2,
    # rc.1 < rc.2). This is what lets a tester on a -testN build roll onto the
    # final release when they switch back to the Stable channel.
    param([string]$A, [string]$B)
    $parse = {
        param($v)
        $s = ($v -replace '^v','').Split('+')[0]   # strip leading v + build metadata
        $dash = $s.IndexOf('-')
        if ($dash -ge 0) { $core = $s.Substring(0, $dash); $pre = $s.Substring($dash + 1) }
        else             { $core = $s;                      $pre = '' }
        [pscustomobject]@{
            Core = @($core.Split('.') | ForEach-Object { [int]($_ -as [int]) })
            Pre  = if ($pre) { @($pre.Split('.')) } else { @() }
        }
    }
    $pa = & $parse $A
    $pb = & $parse $B
    $maxc = [Math]::Max($pa.Core.Count, $pb.Core.Count)
    for ($i = 0; $i -lt $maxc; $i++) {
        $x = if ($i -lt $pa.Core.Count) { $pa.Core[$i] } else { 0 }
        $y = if ($i -lt $pb.Core.Count) { $pb.Core[$i] } else { 0 }
        if ($x -ne $y) { return ($x - $y) }
    }
    # Normalize to arrays: a single-identifier prerelease (e.g. 'test1') is
    # stored as a scalar string on the parse object, so re-wrap with @() before
    # indexing or `$x[0]` would index the string's first character.
    $preA = @($pa.Pre); $preB = @($pb.Pre)
    $aHasPre = $preA.Count -gt 0
    $bHasPre = $preB.Count -gt 0
    if (-not $aHasPre -and -not $bHasPre) { return 0 }
    if (-not $aHasPre) { return 1 }   # A final, B prerelease -> A wins
    if (-not $bHasPre) { return -1 }  # A prerelease, B final -> B wins
    $maxp = [Math]::Max($preA.Count, $preB.Count)
    for ($i = 0; $i -lt $maxp; $i++) {
        if ($i -ge $preA.Count) { return -1 }   # shorter prerelease set ranks lower
        if ($i -ge $preB.Count) { return 1 }
        $ai = [string]$preA[$i]; $bi = [string]$preB[$i]
        $an = 0; $bn = 0
        $aNum = [int]::TryParse($ai, [ref]$an)
        $bNum = [int]::TryParse($bi, [ref]$bn)
        if ($aNum -and $bNum) { if ($an -ne $bn) { return ($an - $bn) } }
        elseif ($aNum)        { return -1 }   # numeric identifier ranks below alphanumeric
        elseif ($bNum)        { return 1 }
        else {
            $aTest = [regex]::Match($ai, '^(?i:test)(\d+)$')
            $bTest = [regex]::Match($bi, '^(?i:test)(\d+)$')
            if ($aTest.Success -and $bTest.Success) {
                $aTestNumber = 0L
                $bTestNumber = 0L
                if ([long]::TryParse($aTest.Groups[1].Value, [ref]$aTestNumber) -and
                    [long]::TryParse($bTest.Groups[1].Value, [ref]$bTestNumber) -and
                    $aTestNumber -ne $bTestNumber) {
                    return [Math]::Sign($aTestNumber - $bTestNumber)
                }
            }
            $cmp = [string]::CompareOrdinal($ai, $bi)
            if ($cmp -ne 0) { return $cmp }
        }
    }
    return 0
}

function Get-DuneLatestRelease {
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    if (-not $Force -and $script:DuneUpdateCache -and
        ($now - $script:DuneUpdateCache.fetchedAt).TotalMinutes -lt 60) {
        return $script:DuneUpdateCache
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = $script:DuneUpdateUA; 'Accept' = 'application/vnd.github+json' }
        $uri = "https://api.github.com/repos/$($script:DuneUpdateRepo)/releases/latest"
        $rel = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        # Strict: the release rule requires `DuneServerSetup.exe` as the sole
        # asset. Match it exactly. Do NOT fall back to "any *.exe" - that
        # masked malformed releases historically and conflicts with the
        # one-asset rule. If a release ships a differently-named installer
        # by mistake, the UI will correctly show "available, no installer
        # attached" with a release-page link, instead of silently treating
        # the wrong file as the installer.
        $asset = $rel.assets | Where-Object { $_.name -eq 'DuneServerSetup.exe' } | Select-Object -First 1
        $script:DuneUpdateCache = [pscustomobject]@{
            fetchedAt    = $now
            tag          = [string]$rel.tag_name
            name         = [string]$rel.name
            htmlUrl      = [string]$rel.html_url
            publishedAt  = [string]$rel.published_at
            targetCommit = [string]$rel.target_commitish
            releaseNotes = [string]$rel.body
            assetName    = if ($asset) { [string]$asset.name } else { $null }
            assetUrl     = if ($asset) { [string]$asset.browser_download_url } else { $null }
            assetSize    = if ($asset) { [int64]$asset.size } else { 0 }
            assetDigest  = if ($asset) { [string]$asset.digest } else { $null }
        }
        return $script:DuneUpdateCache
    } catch {
        # Return a stub on failure so the UI can render a "couldn't check" state.
        return [pscustomobject]@{
            fetchedAt    = $now
            tag          = $null
            error        = $_.Exception.Message
        }
    }
}

$script:DuneReleasesCache = $null   # cached /releases list (1 h TTL)

# Fetch the repo's recent releases (newest-first), each normalized to the same
# shape Get-DuneLatestRelease emits plus isPrerelease/isDraft. Throws on
# network failure so callers can decide how to degrade.
function Get-DuneReleases {
    param([switch]$Force)
    $now = [DateTime]::UtcNow
    if (-not $Force -and $script:DuneReleasesCache -and
        ($now - $script:DuneReleasesCache.fetchedAt).TotalMinutes -lt 60) {
        return $script:DuneReleasesCache.releases
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = $script:DuneUpdateUA; 'Accept' = 'application/vnd.github+json' }
    $uri = "https://api.github.com/repos/$($script:DuneUpdateRepo)/releases?per_page=30"
    $rels = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    $mapped = foreach ($rel in $rels) {
        $asset = $rel.assets | Where-Object { $_.name -eq 'DuneServerSetup.exe' } | Select-Object -First 1
        [pscustomobject]@{
            tag          = [string]$rel.tag_name
            name         = [string]$rel.name
            htmlUrl      = [string]$rel.html_url
            publishedAt  = [string]$rel.published_at
            targetCommit = [string]$rel.target_commitish
            releaseNotes = [string]$rel.body
            isPrerelease = [bool]$rel.prerelease
            isDraft      = [bool]$rel.draft
            assetName    = if ($asset) { [string]$asset.name } else { $null }
            assetUrl     = if ($asset) { [string]$asset.browser_download_url } else { $null }
            assetSize    = if ($asset) { [int64]$asset.size } else { 0 }
            assetDigest  = if ($asset) { [string]$asset.digest } else { $null }
        }
    }
    # GitHub's /releases endpoint does not reliably return newest-first (a
    # recently-edited older release can resurface at the top), so sort
    # explicitly by published date, newest-first. Null/unparseable dates sink.
    $sorted = @($mapped | Sort-Object -Property @{ Expression = {
        $dt = [datetime]::MinValue
        if ($_.publishedAt -and [datetime]::TryParse($_.publishedAt, [ref]$dt)) { $dt.ToUniversalTime() } else { [datetime]::MinValue }
    } } -Descending)
    $script:DuneReleasesCache = [pscustomobject]@{ fetchedAt = $now; releases = $sorted }
    return $script:DuneReleasesCache.releases
}

function Test-DuneStableMirrorRelease {
    param($Release)
    $text = "$($Release.name)`n$($Release.releaseNotes)"
    return ($text -match '(?i)\b(?:test|stable)(?:[-\s]+channel)?[-\s]+mirror\b')
}

# Test-channel candidates: the newest two published pre-releases that carry the
# installer asset. A newest stable mirror stands alone so old test-cycle builds
# do not remain selectable after the stable release ships.
function Get-DunePreReleaseList {
    param([switch]$Force)
    $candidates = @(Get-DuneReleases -Force:$Force |
        Where-Object { $_.isPrerelease -and -not $_.isDraft -and $_.assetUrl })
    if ($candidates.Count -gt 0 -and (Test-DuneStableMirrorRelease -Release $candidates[0])) {
        return @($candidates[0])
    }
    return @($candidates |
        Where-Object { -not (Test-DuneStableMirrorRelease -Release $_) } |
        Select-Object -First 2)
}

# Resolve which release the in-app updater should act on for THIS install,
# honoring the configured channel + pinned pre-release tag. Returns the same
# object shape as Get-DuneLatestRelease, annotated with `channel` and
# `isPrerelease`. On the test channel: pin an explicit tag if set and still
# available, else default to the newest pre-release. Falls back to the stable
# release if the test channel has no usable pre-release so a tester is never
# stranded.
function Get-DuneSelectedRelease {
    param([switch]$Force)
    $channel = Get-DuneUpdateChannel
    if ($channel -ne 'test') {
        $rel = Get-DuneLatestRelease -Force:$Force
        if ($rel) {
            Add-Member -InputObject $rel -NotePropertyName channel      -NotePropertyValue 'stable' -Force
            Add-Member -InputObject $rel -NotePropertyName isPrerelease -NotePropertyValue $false   -Force
        }
        return $rel
    }
    try {
        $list = Get-DunePreReleaseList -Force:$Force
    } catch {
        return [pscustomobject]@{ fetchedAt = [DateTime]::UtcNow; tag = $null; channel = 'test'; error = $_.Exception.Message }
    }
    if (-not $list -or $list.Count -eq 0) {
        $rel = Get-DuneLatestRelease -Force:$Force
        if ($rel) {
            Add-Member -InputObject $rel -NotePropertyName channel      -NotePropertyValue 'test' -Force
            Add-Member -InputObject $rel -NotePropertyName isPrerelease -NotePropertyValue $false -Force
        }
        return $rel
    }
    $pin = Get-DuneUpdatePreReleaseTag
    $chosen = $null
    if ($pin) { $chosen = $list | Where-Object { $_.tag -eq $pin } | Select-Object -First 1 }
    if (-not $chosen) { $chosen = $list[0] }   # newest available pre-release
    return [pscustomobject]@{
        fetchedAt    = [DateTime]::UtcNow
        tag          = $chosen.tag
        name         = $chosen.name
        htmlUrl      = $chosen.htmlUrl
        publishedAt  = $chosen.publishedAt
        targetCommit = $chosen.targetCommit
        releaseNotes = $chosen.releaseNotes
        assetName    = $chosen.assetName
        assetUrl     = $chosen.assetUrl
        assetSize    = $chosen.assetSize
        assetDigest  = $chosen.assetDigest
        channel      = 'test'
        isPrerelease = $true
    }
}

# Pure decision for "can the in-app updater install the selected release?" Shared
# by GET /api/update/check (the `installable` flag) and POST /api/update/install
# (the `blocked` gate) so the two never drift.
#
#   Diff                = Compare-DuneSemver(selectedTag, runningVersion)
#   Channel             = 'stable' | 'test'
#   HasAsset            = selected release carries DuneServerSetup.exe
#   RunningIsPrerelease = the build currently running was installed from a pre-release
#   IdentityMismatch    = selected tag matches, but the running artifact is not
#                         the exact published commit (or is an untagged dev build)
#
# Test channel: install whenever the selected pre-release differs from the
# running build (forward, sideways, or rollback between -testN candidates).
# Stable channel: classic "strictly newer" rule, RELAXED when the running build
# is a pre-release so a tester can always return to the live release even though
# it is not newer (downgrade to the last Stable or a same-version reinstall that
# clears the TEST BUILD indicator).
function Get-DuneInstallDecision {
    param(
        [int]$Diff = 0,
        [string]$Channel = 'stable',
        [bool]$HasAsset = $false,
        [bool]$RunningIsPrerelease = $false,
        [bool]$IdentityMismatch = $false
    )
    $available = ($Diff -gt 0) -or $IdentityMismatch
    if ($Channel -eq 'test') {
        $installable = $HasAsset -and (($Diff -ne 0) -or $IdentityMismatch)
        $blocked     = ($Diff -eq 0) -and (-not $IdentityMismatch)
    } else {
        $installable = $HasAsset -and ($available -or $RunningIsPrerelease)
        $blocked     = (-not $available) -and (-not $RunningIsPrerelease)
    }

    [pscustomobject]@{
        available   = $available
        installable = $installable
        blocked     = $blocked
    }
}

function Get-DuneRunningUpdateComparisonVersion {
    param([string]$Channel, [string]$CoreVersion, $BuildInfo)
    if ($Channel -eq 'test' -and [bool]$BuildInfo.runningIsPrerelease -and [string]$BuildInfo.installedTag) {
        return [string]$BuildInfo.installedTag
    }
    return $CoreVersion
}

function Test-DuneUpdateCommitIdentity {
    param([string]$Expected, [string]$Actual)
    $expectedValue = $Expected.Trim().ToLowerInvariant()
    $actualValue = $Actual.Trim().ToLowerInvariant()
    if (-not $expectedValue) { return $true }
    if ($expectedValue -notmatch '^[0-9a-f]{7,40}$' -or
        $actualValue -notmatch '^[0-9a-f]{7,40}$') {
        return $false
    }
    return $expectedValue.StartsWith($actualValue, [StringComparison]::Ordinal) -or
        $actualValue.StartsWith($expectedValue, [StringComparison]::Ordinal)
}

function Get-DuneEmbeddedBuildIdentityFromText {
    param([Parameter(Mandatory)][string]$Text)

    $present = [regex]::IsMatch(
        $Text,
        '(?m)^\$script:DuneBuildMetadataPresent\s*=\s*\$true\s*$'
    )
    $tagMatch = [regex]::Match(
        $Text,
        '(?m)^\$script:DuneBuildTag\s*=\s*''([^'']*)''\s*$'
    )
    $commitMatch = [regex]::Match(
        $Text,
        '(?m)^\$script:DuneBuildCommit\s*=\s*''([^'']*)''\s*$'
    )
    return [pscustomobject]@{
        present = $present
        tag = if ($tagMatch.Success) { $tagMatch.Groups[1].Value } else { '' }
        commit = if ($commitMatch.Success) {
            $commitMatch.Groups[1].Value.ToLowerInvariant()
        } else { '' }
    }
}

function Get-DuneReleaseCommitSha {
    param([Parameter(Mandatory)][string]$Tag)
    $tagValue = $Tag.Trim()
    if ($tagValue -notmatch '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'Release tag is invalid.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'User-Agent' = $script:DuneUpdateUA
        'Accept' = 'application/vnd.github+json'
    }
    $encoded = [uri]::EscapeDataString($tagValue)
    $refUri = "https://api.github.com/repos/$($script:DuneUpdateRepo)/git/ref/tags/$encoded"
    $ref = Invoke-RestMethod -Uri $refUri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
    $type = [string]$ref.object.type
    $sha = ([string]$ref.object.sha).Trim().ToLowerInvariant()
    for ($depth = 0; $depth -lt 5 -and $type -eq 'tag'; $depth++) {
        if ($sha -notmatch '^[0-9a-f]{40}$') {
            throw 'Annotated release tag returned an invalid object id.'
        }
        $tagObjectUri = "https://api.github.com/repos/$($script:DuneUpdateRepo)/git/tags/$sha"
        $tagObject = Invoke-RestMethod -Uri $tagObjectUri -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        $type = [string]$tagObject.object.type
        $sha = ([string]$tagObject.object.sha).Trim().ToLowerInvariant()
    }
    if ($type -ne 'commit' -or $sha -notmatch '^[0-9a-f]{40}$') {
        throw 'Release tag does not resolve to an immutable Git commit.'
    }
    return $sha
}

function Get-DuneReleaseExpectedCommit {
    param([Parameter(Mandatory)]$Release)
    $target = ([string]$Release.targetCommit).Trim().ToLowerInvariant()
    if ($target -match '^[0-9a-f]{40}$') { return $target }
    return Get-DuneReleaseCommitSha -Tag ([string]$Release.tag)
}

function Get-DuneSelectedReleaseIdentity {
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)]$BuildInfo
    )
    $runningIsPrerelease = [bool]$BuildInfo.runningIsPrerelease
    $installedTag = ([string]$BuildInfo.installedTag).Trim()
    $selectedTag = ([string]$Release.tag).Trim()
    if (-not $runningIsPrerelease) {
        return [pscustomobject]@{
            checked = $false
            mismatch = $false
            expectedCommit = ''
            actualCommit = [string]$BuildInfo.buildCommit
        }
    }
    if ($installedTag -and $installedTag -ne $selectedTag) {
        return [pscustomobject]@{
            checked = $false
            mismatch = $false
            expectedCommit = ''
            actualCommit = [string]$BuildInfo.buildCommit
        }
    }

    $expectedCommit = Get-DuneReleaseExpectedCommit -Release $Release
    $actualCommit = ([string]$BuildInfo.buildCommit).Trim().ToLowerInvariant()
    $mismatch = (-not $installedTag) -or
        (-not (Test-DuneUpdateCommitIdentity -Expected $expectedCommit -Actual $actualCommit))
    return [pscustomobject]@{
        checked = $true
        mismatch = $mismatch
        expectedCommit = $expectedCommit
        actualCommit = $actualCommit
    }
}

function Get-DuneUpdateExpectedSha256 {
    param([string]$Digest)
    if ($Digest -notmatch '^(?i:sha256):([0-9a-fA-F]{64})$') {
        throw 'The release installer is missing a valid GitHub SHA-256 digest.'
    }
    return $Matches[1].ToUpperInvariant()
}

function Get-DuneProtectedUpdateDirectory {
    $root = Join-Path $env:ProgramData 'DuneServer\Updates'
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', $inherit, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', $inherit, $propagation, $allow))

    if (Test-Path -LiteralPath $root) {
        $item = Get-Item -LiteralPath $root -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The protected update directory cannot be a reparse point.'
        }
    } else {
        [void][IO.Directory]::CreateDirectory($root, $acl)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    $unexpected = @(Get-Acl -LiteralPath $root).Access | Where-Object {
        $_.AccessControlType -eq $allow -and
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @($admins.Value, $system.Value)
    }
    if ($unexpected) { throw 'The update directory ACL contains an unexpected write principal.' }
    return $root
}

function Remove-DuneOldUpdateFiles {
    param([Parameter(Mandatory)][string]$Directory, [string]$Keep = '', [int]$Retain = 12)
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^(?:DuneServerSetup|DuneRelaunch|relaunch|inno|update-result)-[A-Za-z0-9._-]+-[0-9a-f]{32}\.(?:exe|ps1|log|json)$'
        } |
        Sort-Object LastWriteTimeUtc -Descending)
    $retained = 0
    foreach ($file in $files) {
        if ($Keep -and $file.FullName -eq $Keep) { continue }
        $retained++
        if ($retained -gt $Retain) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-DuneVerifiedUpdateAsset {
    param(
        [Parameter(Mandatory)]$Release,
        [string]$Directory = ''
    )
    $expected = Get-DuneUpdateExpectedSha256 ([string]$Release.assetDigest)
    if (-not $Directory) { $Directory = Get-DuneProtectedUpdateDirectory }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Update directory is unavailable.' }
    $safeTag = ([string]$Release.tag -replace '[^A-Za-z0-9._-]','_')
    $dest = Join-Path $Directory ("DuneServerSetup-{0}-{1}.exe" -f $safeTag, [guid]::NewGuid().ToString('N'))
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $headers = @{ 'User-Agent' = $script:DuneUpdateUA }
        Invoke-WebRequest -Uri $Release.assetUrl -Headers $headers -OutFile $dest -TimeoutSec 300 -UseBasicParsing
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw 'Downloaded installer was not created.' }
        $actual = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) { throw 'Downloaded installer SHA-256 does not match the GitHub release digest.' }
        Remove-DuneOldUpdateFiles -Directory $Directory -Keep $dest
        return $dest
    } catch {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw
    }
}

# --- Routes ------------------------------------------------------------------

# GET /api/update/check[?force=1] — compare current vs latest release
Register-DuneRoute -Method GET -Path '/api/update/check' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $force = $false
        if ($req.QueryString['force']) {
            $force = ($req.QueryString['force'] -eq '1' -or $req.QueryString['force'] -eq 'true')
        }
        $rel     = Get-DuneSelectedRelease -Force:$force
        $current = [string]$script:DuneToolVersion
        $channel = Get-DuneUpdateChannel
        $buildInfo = Get-DuneUpdateRunningBuildInfo
        $runningIsPrerelease = [bool]$buildInfo.runningIsPrerelease
        if (-not $rel -or $rel.error) {
            Write-DuneJson -Response $res -Body @{
                available           = $false
                channel             = $channel
                runningIsPrerelease = $runningIsPrerelease
                installedTag        = [string]$buildInfo.installedTag
                buildCommit         = [string]$buildInfo.buildCommit
                currentVersion      = $current
                checkedAt           = (Get-Date).ToString('o')
                error               = $rel.error
            }
            return
        }
        $comparisonVersion = Get-DuneRunningUpdateComparisonVersion -Channel $channel -CoreVersion $current -BuildInfo $buildInfo
        $diff      = Compare-DuneSemver -A $rel.tag -B $comparisonVersion
        $identity = Get-DuneSelectedReleaseIdentity -Release $rel -BuildInfo $buildInfo
        # `available` means a newer release exists (independent of whether an
        # installer asset is attached). `installable` is the stricter flag:
        # the in-app auto-updater can actually run it.
        #
        # Background: every DST release MUST upload `DuneServerSetup.exe` as
        # its only asset (hard project rule). If a release is ever published
        # without one, we still want the UI to alert the user that an update
        # exists - just with a "no installer attached" notice and a link to
        # the release page instead of an "Update now" button. We do NOT want
        # the UI to silently report "up to date" while a newer tag is live;
        # that's what happened with v10.1.12 (shipped asset-less) and is the
        # bug this split fixes.
        #
        # Channel nuance: on the Test channel the user has deliberately pinned
        # a specific pre-release, so installing it is allowed whenever it
        # differs from the running build (sideways re-install or rollback to an
        # earlier -testN build are both intentional). On Stable the classic
        # "strictly newer" rule applies - EXCEPT when the running build is a
        # pre-release (Test build). In that case Stable must stay installable
        # even when not strictly newer so a tester can always return to the live
        # release (a downgrade to the last Stable, or a same-version reinstall
        # to clear the TEST BUILD indicator). Without this a Test build is a
        # dead-end: the live release is never "newer", so the button stays off.
        $hasAsset     = -not [string]::IsNullOrEmpty($rel.assetUrl)
        $decision     = Get-DuneInstallDecision -Diff $diff -Channel $channel -HasAsset $hasAsset -RunningIsPrerelease $runningIsPrerelease -IdentityMismatch ([bool]$identity.mismatch)
        $available    = $decision.available
        $installable  = $decision.installable
        Write-DuneJson -Response $res -Body @{
            available       = $available
            installable     = $installable
            assetMissing    = ($available -and -not $hasAsset)
            channel         = $channel
            runningIsPrerelease = $runningIsPrerelease
            installedTag    = [string]$buildInfo.installedTag
            buildCommit     = [string]$buildInfo.buildCommit
            identityChecked = [bool]$identity.checked
            identityMismatch = [bool]$identity.mismatch
            releaseCommit   = [string]$identity.expectedCommit
            isPrerelease    = [bool]$rel.isPrerelease
            selectedTag     = $rel.tag
            currentVersion  = $current
            latestVersion   = ($rel.tag -replace '^v','')
            tagName         = $rel.tag
            releaseName     = $rel.name
            releaseUrl      = $rel.htmlUrl
            releaseNotes    = $rel.releaseNotes
            publishedAt     = $rel.publishedAt
            assetName       = $rel.assetName
            assetSize       = $rel.assetSize
            checkedAt       = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# GET /api/update/prereleases[?force=1] — list test-channel candidate builds
# (newest two published pre-releases that carry the installer asset) for the
# Settings picker. Stable is always the primary channel; an empty pin means
# "latest" (the first test item).
Register-DuneRoute -Method GET -Path '/api/update/prereleases' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $force = $false
        if ($req.QueryString['force']) {
            $force = ($req.QueryString['force'] -eq '1' -or $req.QueryString['force'] -eq 'true')
        }
        $list  = Get-DunePreReleaseList -Force:$force
        $items = foreach ($r in $list) {
            @{
                tag         = $r.tag
                name        = $r.name
                version     = ($r.tag -replace '^v','')
                publishedAt = $r.publishedAt
                releaseUrl  = $r.htmlUrl
                assetSize   = $r.assetSize
                hasAsset    = $true
            }
        }
        Write-DuneJson -Response $res -Body @{
            channel     = Get-DuneUpdateChannel
            selectedTag = Get-DuneUpdatePreReleaseTag
            count       = @($items).Count
            releases    = @($items)
            checkedAt   = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# GET /api/update/migration-notice — one-time "DST is now decoupled from
# the reference implementation" notice. `needed` is true only for installs upgraded from a
# pre-decouple build (see Get-DuneDecoupleNotice).
#
# Loopback-only: the notice exposes the host's local the reference implementation folder path and
# is a host-machine concern (the host runs the reference implementation, not a remote Tailscale /
# LAN viewer). Remote callers must never see the path or be blocked by it.
function Test-DuneUpdateLoopbackRequest {
    param($req)
    try {
        $remote = $req.RemoteEndPoint.Address
        if ($remote) { return [System.Net.IPAddress]::IsLoopback($remote) }
    } catch {}
    return $false
}

Register-DuneRoute -Method GET -Path '/api/update/migration-notice' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneUpdateLoopbackRequest $req)) {
            # Remote viewers are never shown the host migration notice. Report a
            # benign "nothing to do" state instead of the host's folder path.
            Write-DuneJson -Response $res -Body @{
                needed       = $false
                acknowledged = $true
                fromLegacy   = $false
                portalUrl    = 'https://dune-admin.layout.tools'
                remote       = $true
            }
            return
        }
        $n = Get-DuneDecoupleNotice
        Write-DuneJson -Response $res -Body @{
            needed          = [bool]$n.Needed
            acknowledged    = [bool]$n.Acknowledged
            fromLegacy      = [bool]$n.FromLegacy
            duneAdminExe    = [string]$n.DuneAdminExe
            duneAdminFolder = [string]$n.DuneAdminFolder
            portalUrl       = 'https://dune-admin.layout.tools'
            currentVersion  = [string]$script:DuneToolVersion
            checkedAt       = (Get-Date).ToString('o')
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/update/migration-notice/ack — record that the user has read the
# decoupling notice. Loopback-only: only the host can acknowledge a host
# migration (a remote viewer must not be able to clear it for the host).
Register-DuneRoute -Method POST -Path '/api/update/migration-notice/ack' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneUpdateLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'The decoupling notice can only be acknowledged from the host machine.'
            return
        }
        $ver = [string]$script:DuneToolVersion
        Invoke-WithDuneLock -Name 'config' -Script { Set-DuneDecoupleAck -Version $ver } | Out-Null
        Write-DuneJson -Response $res -Body @{
            ok           = $true
            acknowledged = $true
            ackVersion   = $ver
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

function Resolve-DuneUpdateInstallRequest {
    param($Request, $Body)

    $queryMode = ''
    $querySource = ''
    try {
        $queryMode = ([string]$Request.QueryString['mode']).Trim().ToLowerInvariant()
        $querySource = ([string]$Request.QueryString['source']).Trim().ToLowerInvariant()
    } catch {}
    $bodyMode = ''
    $bodySource = ''
    if ($Body -is [hashtable]) {
        if ($Body.ContainsKey('mode')) { $bodyMode = ([string]$Body.mode).Trim().ToLowerInvariant() }
        if ($Body.ContainsKey('source')) { $bodySource = ([string]$Body.source).Trim().ToLowerInvariant() }
    } elseif ($Body) {
        if ($Body.PSObject.Properties.Name -contains 'mode') { $bodyMode = ([string]$Body.mode).Trim().ToLowerInvariant() }
        if ($Body.PSObject.Properties.Name -contains 'source') { $bodySource = ([string]$Body.source).Trim().ToLowerInvariant() }
    }

    if ($queryMode -and $bodyMode -and $queryMode -ne $bodyMode) { throw 'Conflicting update install mode values.' }
    if ($querySource -and $bodySource -and $querySource -ne $bodySource) { throw 'Conflicting update install source values.' }
    $mode = if ($queryMode) { $queryMode } elseif ($bodyMode) { $bodyMode } else { 'interactive' }
    $source = if ($querySource) { $querySource } elseif ($bodySource) { $bodySource } else { 'legacy' }
    if ($mode -notin @('interactive', 'silent')) { throw 'Invalid update install mode.' }
    if ($source -notin @('legacy', 'banner', 'settings')) { throw 'Invalid update install source.' }
    if ($mode -eq 'silent' -and $source -ne 'banner') { throw 'Silent update installs are allowed only from the update banner.' }
    return @{ mode = $mode; source = $source }
}

# POST /api/update/install - download the selected installer and launch it in
# the explicitly requested mode. Older clients omit mode and remain interactive.
Register-DuneRoute -Method POST -Path '/api/update/install' -Handler {
    param($req, $res, $routeParams, $body)
    # Serialize installs: never let two update flows download + relaunch at once.
    $updLock = Get-DuneLock -Name 'update-install'
    if (-not $updLock.Wait(0)) {
        Write-DuneError -Response $res -Status 409 -Message 'An update is already in progress.'
        return
    }
    try {
      try {
        try {
            $installRequest = Resolve-DuneUpdateInstallRequest -Request $req -Body $body
        } catch {
            Write-DuneError -Response $res -Status 400 -Message $_.Exception.Message
            return
        }
        $installMode = [string]$installRequest.mode
        $installSource = [string]$installRequest.source
        # Gate: a user upgrading across the companion-tool decoupling must read and
        # acknowledge the one-time notice before any further update can run.
        $notice = Get-DuneDecoupleNotice
        if ($notice.Needed) {
            Write-DuneJson -Response $res -Body @{
                launched               = $false
                reason                 = 'Please review and acknowledge the Dune-Admin decoupling notice before updating.'
                decoupleNoticeRequired = $true
            }
            return
        }
        # Mirror releases are replaced atomically during stable publication.
        # Never install from the one-hour release-list cache: it may still point
        # at the deleted prior mirror even after a forced check sees the new tag.
        $rel = Get-DuneSelectedRelease -Force
        if (-not $rel -or -not $rel.assetUrl) {
            Write-DuneError -Response $res -Status 503 -Message 'No installer asset available on the selected release.'
            return
        }
        # Channel-aware gate. Stable blocks anything not strictly newer, UNLESS
        # the running build is a pre-release (Test build) - then a stable install
        # is always allowed so the tester can return to the live release even
        # though it is not "newer" (downgrade to last Stable, or same-version
        # reinstall to clear the TEST BUILD indicator). Test only blocks
        # re-installing the exact same build (diff == 0); a deliberate sideways
        # install or rollback to an earlier -testN build is allowed so a tester
        # can move between candidate builds at will.
        $channel = Get-DuneUpdateChannel
        $buildInfo = Get-DuneUpdateRunningBuildInfo
        $runningIsPrerelease = [bool]$buildInfo.runningIsPrerelease
        $comparisonVersion = Get-DuneRunningUpdateComparisonVersion -Channel $channel -CoreVersion ([string]$script:DuneToolVersion) -BuildInfo $buildInfo
        $diff = Compare-DuneSemver -A $rel.tag -B $comparisonVersion
        $identity = Get-DuneSelectedReleaseIdentity -Release $rel -BuildInfo $buildInfo
        $hasAsset = -not [string]::IsNullOrEmpty($rel.assetUrl)
        # Explicit reinstall: the user asked to re-download and re-run the
        # current version's installer (Settings "Reinstall" button) even though
        # it isn't newer. Skip the up-to-date gate; an asset is still required.
        $reinstall = $false
        if ($req.QueryString['reinstall']) {
            $reinstall = ($req.QueryString['reinstall'] -eq '1' -or $req.QueryString['reinstall'] -eq 'true')
        }
        $blocked = (Get-DuneInstallDecision -Diff $diff -Channel $channel -HasAsset $hasAsset -RunningIsPrerelease $runningIsPrerelease -IdentityMismatch ([bool]$identity.mismatch)).blocked
        if ($reinstall -and -not $hasAsset) {
            Write-DuneError -Response $res -Status 503 -Message 'No installer asset available to reinstall.'
            return
        }
        if ($blocked -and -not $reinstall) {
            Write-DuneJson -Response $res -Body @{
                launched = $false
                reason   = 'Already up to date.'
                currentVersion = $script:DuneToolVersion
                latestVersion  = ($rel.tag -replace '^v','')
            }
            return
        }

        $safeTag = ($rel.tag -replace '[^A-Za-z0-9._-]','_')
        try {
            $updateDir = Get-DuneProtectedUpdateDirectory
            $dest = Save-DuneVerifiedUpdateAsset -Release $rel -Directory $updateDir
            $resolvedReleaseCommit = if ([string]$identity.expectedCommit) {
                [string]$identity.expectedCommit
            } else {
                Get-DuneReleaseExpectedCommit -Release $rel
            }
        } catch {
            Write-DuneError -Response $res -Status 502 -Message $_.Exception.Message
            return
        }

        # Respond to the client FIRST so the browser sees confirmation
        # before we tear ourselves down. The relauncher below kills this
        # very process about 3 seconds later.
        $installNote = if ($installMode -eq 'silent') {
            'Automatic update started. DST will close, install silently, and relaunch automatically.'
        } else {
            'Installer wizard launched. Complete the visible setup steps; DST relaunches when installation finishes.'
        }
        Write-DuneJson -Response $res -Body @{
            launched        = $true
            installerPath   = $dest
            fromVersion     = $script:DuneToolVersion
            toVersion       = ($rel.tag -replace '^v','')
            mode            = $installMode
            source          = $installSource
            note            = $installNote
        }

        # Build a relauncher script that:
        #   1. Sleeps 3 seconds so the user sees the "Updater launched" toast
        #      and the HTTP response finishes flushing before the app vanishes.
        #   2. Force-kills DuneServer.exe by its known PID (this process),
        #      any sibling DuneServer instances, and DuneShell.exe (the app
        #      window). We do NOT use `taskkill /T` - that would also kill
        #      the relauncher (a child of DuneServer.exe). Killing the
        #      specific PID with Stop-Process leaves the relauncher orphaned
        #      but alive.
        #   3. Launches Inno in the explicitly requested mode. Silent banner
        #      installs use the installer's silent-only [Run] entry to relaunch
        #      DST; Settings installs show the wizard and its finish-page action.
        #   4. WaitForExit on the installer PID, then on non-zero exit /
        #      timeout shows a topmost WinForms MessageBox so the user has
        #      a real signal when something fails (the hidden powershell
        #      host has no other UI to surface errors).
        $parentPid = $PID
        $launchId = [guid]::NewGuid().ToString('N')
        $logPath = Join-Path $updateDir ("relaunch-$safeTag-$launchId.log")
        $innoLogPath = Join-Path $updateDir ("inno-$safeTag-$launchId.log")
        $resultPath = Join-Path $updateDir ("update-result-$safeTag-$launchId.json")
        $installedExe = Join-Path $script:AppDir 'DuneServer.exe'
        $expectedTag = [string]$rel.tag
        $expectedCommit = [string]$resolvedReleaseCommit
        # Arguments are selected only from these constants after strict mode/source
        # validation above. No request value is ever interpolated as executable code.
        $installArgsBase = if ($installMode -eq 'silent') {
            '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        } else {
            '/SP- /NORESTART'
        }
        $installArgs = "$installArgsBase /LOG=`"$innoLogPath`""
        $installModeLabel = if ($installMode -eq 'silent') { 'silently' } else { 'interactively' }
        # Defensive escapes: %TEMP% / install path can contain an apostrophe
        # (e.g. C:\Users\<user-with-apostrophe>\AppData\...) which would break the single-
        # quoted literals embedded in the relauncher heredoc below.
        # PowerShell escapes ' as '' inside single-quoted strings.
        $destEsc         = $dest         -replace "'", "''"
        $installArgsEsc  = $installArgs  -replace "'", "''"
        $installModeEsc  = $installModeLabel -replace "'", "''"
        $logPathEsc      = $logPath      -replace "'", "''"
        $innoLogPathEsc  = $innoLogPath  -replace "'", "''"
        $resultPathEsc   = $resultPath   -replace "'", "''"
        $installedExeEsc = $installedExe -replace "'", "''"
        $expectedTagEsc  = $expectedTag  -replace "'", "''"
        $expectedCommitEsc = $expectedCommit -replace "'", "''"
        $commitIdentityFunction = @"
function Test-DuneUpdateCommitIdentity {
$(${function:Test-DuneUpdateCommitIdentity}.ToString())
}
"@
        $embeddedIdentityFunction = @"
function Get-DuneEmbeddedBuildIdentityFromText {
$(${function:Get-DuneEmbeddedBuildIdentityFromText}.ToString())
}
"@
        $relaunchScript = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$logPathEsc' -Append | Out-Null

$commitIdentityFunction
$embeddedIdentityFunction

function Show-DuneUpdateFailure {
    param([string]`$Title, [string]`$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        # Off-screen, transparent, topmost owner so the MessageBox actually
        # comes foreground even though the PowerShell host is hidden.
        `$owner = New-Object System.Windows.Forms.Form
        `$owner.FormBorderStyle = 'FixedToolWindow'
        `$owner.StartPosition   = 'Manual'
        `$owner.Location        = [System.Drawing.Point]::new(-32000, -32000)
        `$owner.Size            = [System.Drawing.Size]::new(1, 1)
        `$owner.ShowInTaskbar   = `$false
        `$owner.TopMost         = `$true
        `$owner.Opacity         = 0
        `$owner.Show()
        `$owner.Activate()
        [System.Windows.Forms.MessageBox]::Show(`$owner, `$Message, `$Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        try { `$owner.Close(); `$owner.Dispose() } catch {}
    } catch {}
}

function Get-DuneInstalledBuildIdentity {
    param([Parameter(Mandatory)][string]`$Path)
    if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) {
        throw "Installed executable was not found: `$Path"
    }
    `$assembly = [Reflection.Assembly]::LoadFile(`$Path)
    `$resourceNames = @(`$assembly.GetManifestResourceNames() | Where-Object {
        `$_ -match '^DuneServer(?:\.[0-9a-f]{32})?\.generated\.ps1$'
    })
    if (`$resourceNames.Count -ne 1) {
        throw "Installed executable has `$(`$resourceNames.Count) recognized embedded script resources."
    }
    `$stream = `$assembly.GetManifestResourceStream(`$resourceNames[0])
    if (-not `$stream) { throw 'Installed executable has no embedded script resource.' }
    `$reader = [IO.StreamReader]::new(`$stream, [Text.Encoding]::UTF8, `$true)
    try { `$text = `$reader.ReadToEnd() } finally { `$reader.Dispose(); `$stream.Dispose() }
    return Get-DuneEmbeddedBuildIdentityFromText -Text `$text
}

function Resolve-DuneInstalledExecutablePath {
    `$keyName = '{B3F8A2C1-7E5D-4F9A-8B2C-1D6E3A4F5C7D}_is1'
    foreach (`$root in @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        try {
            `$entry = Get-ItemProperty -LiteralPath (Join-Path `$root `$keyName) -ErrorAction Stop
            `$location = ([string]`$entry.InstallLocation).Trim()
            if (-not `$location) { continue }
            `$candidate = Join-Path `$location 'DuneServer.exe'
            if (Test-Path -LiteralPath `$candidate -PathType Leaf) {
                return [IO.Path]::GetFullPath(`$candidate)
            }
        } catch {}
    }
    throw 'The installed Dune Server Tool directory could not be resolved from the uninstall registry.'
}

function Save-DuneUpdateResult {
    param(
        [bool]`$Success,
        [string]`$Message,
        [int]`$InstallerExitCode = -1,
        `$Identity = `$null
    )
    try {
        `$payload = [ordered]@{
            success = `$Success
            message = `$Message
            expectedTag = '$expectedTagEsc'
            expectedCommit = '$expectedCommitEsc'
            actualTag = if (`$Identity) { [string]`$Identity.tag } else { '' }
            actualCommit = if (`$Identity) { [string]`$Identity.commit } else { '' }
            installerExitCode = `$InstallerExitCode
            checkedAt = (Get-Date).ToUniversalTime().ToString('o')
            relaunchLog = '$logPathEsc'
            installerLog = '$innoLogPathEsc'
        }
        `$json = `$payload | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText('$resultPathEsc', `$json, [Text.UTF8Encoding]::new(`$false))
    } catch {}
}

try {
    Add-Type -Namespace DuneUpd -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool AllowSetForegroundWindow(int dwProcessId);
'@ -ErrorAction SilentlyContinue

    # 1-second grace between user clicking Update and the install kicking off.
    # Lets the HTTP response finish flushing so the "Updater launched" takeover
    # renders in the portal before the app closes.
    # (v11.4.4: cut from 3s to 1s; v11.4.3 and earlier wasted ~2s here.)
    Start-Sleep -Seconds 1

    Write-Host "[`$(Get-Date -Format o)] Stopping DuneServer.exe (PID $parentPid)"
    Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
    # Sibling DuneServer instances + the standalone app window
    # (DuneShell.exe). Kill by .Id (no Stop-Process -Name).
    Get-Process -Name DuneServer -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name DuneShell -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
    }
    # Brief settle so WebView2 children and file handles in
    # C:\Program Files\Dune Server are released before Inno tries to
    # overwrite them. With the app already killed above, files are free; the
    # interactive wizard would also surface an in-use retry prompt if needed.
    # (v11.4.4: cut from 1s to 250ms. Stop-Process -Force is synchronous
    # on the kill signal; the remaining wait is for WebView2 helper
    # processes to drop their MPK handles, which is sub-100ms in
    # practice.)
    Start-Sleep -Milliseconds 250

    # Grant foreground rights to whatever we launch next (ASFW_ANY = -1)
    # so the installer wizard and the post-install DuneServer.exe -> DuneShell.exe
    # chain can take focus.
    try { [DuneUpd.Win]::AllowSetForegroundWindow(-1) | Out-Null } catch {}

    Write-Host "[`$(Get-Date -Format o)] Launching installer $installModeEsc`: $destEsc"
    `$proc = Start-Process -FilePath '$destEsc' -ArgumentList '$installArgsEsc' -PassThru

    # Wait up to 30 minutes for install to finish. This is generous for the
    # interactive wizard and a safety bound for silent mode. Inno runs the
    # applicable [Run] postinstall "Launch Dune Server"
    # action, then exits. We were spawned from an already-elevated DuneServer.exe,
    # so Inno runs in-place rather than re-elevating -- WaitForExit on the
    # spawned PID is meaningful end-to-end. Inno returns exit code 0 on success
    # AND when the user cancels the wizard (a deliberate no-op), so only a
    # genuine non-zero failure surfaces the error dialog.
    if (-not `$proc.WaitForExit(1800000)) {
        Write-Host "[`$(Get-Date -Format o)] Installer still open after 30 minutes"
        try { Stop-Process -Id `$proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        Save-DuneUpdateResult -Success `$false -Message 'Installer timed out.'
        Show-DuneUpdateFailure -Title 'Dune Server Update Timed Out' -Message (
            "The installer was still open after 30 minutes, so it was closed. The Dune Server app has been shut down.``r``n``r``n" +
            "Relaunch log:``r``n  $logPathEsc``r``n``r``nInstaller log:``r``n  $innoLogPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } elseif (`$proc.ExitCode -ne 0) {
        `$code = `$proc.ExitCode
        Write-Host "[`$(Get-Date -Format o)] Installer exited with code `$code"
        Save-DuneUpdateResult -Success `$false -Message "Installer exited with code `$code." -InstallerExitCode `$code
        Show-DuneUpdateFailure -Title 'Dune Server Update Failed' -Message (
            "The installer exited with code `$code. The Dune Server app has been closed.``r``n``r``n" +
            "Relaunch log:``r``n  $logPathEsc``r``n``r``nInstaller log:``r``n  $innoLogPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } else {
        try {
            `$actualInstalledExe = Resolve-DuneInstalledExecutablePath
            `$identity = Get-DuneInstalledBuildIdentity -Path `$actualInstalledExe
            `$tagOk = `$identity.present -and (`$identity.tag -eq '$expectedTagEsc')
            `$commitOk = Test-DuneUpdateCommitIdentity -Expected '$expectedCommitEsc' -Actual `$identity.commit
            if (-not `$tagOk -or -not `$commitOk) {
                throw "Installed identity mismatch. Expected tag '$expectedTagEsc' commit '$expectedCommitEsc'; found tag '`$(`$identity.tag)' commit '`$(`$identity.commit)'."
            }
            Write-Host "[`$(Get-Date -Format o)] Installed identity verified: tag=`$(`$identity.tag) commit=`$(`$identity.commit)"
            Save-DuneUpdateResult -Success `$true -Message 'Installed identity verified.' -InstallerExitCode 0 -Identity `$identity
        } catch {
            `$verifyMessage = `$_.Exception.Message
            Write-Host "[`$(Get-Date -Format o)] Post-install verification failed: `$verifyMessage"
            Save-DuneUpdateResult -Success `$false -Message `$verifyMessage -InstallerExitCode 0 -Identity `$identity
            Show-DuneUpdateFailure -Title 'Dune Server Update Not Verified' -Message (
                "The installer returned success, but DST could not verify the installed build:``r``n  `$verifyMessage``r``n``r``n" +
                "Relaunch log:``r``n  $logPathEsc``r``n``r``nInstaller log:``r``n  $innoLogPathEsc``r``n``r``n" +
                "You can reinstall manually by running:``r``n  $destEsc")
        }
    }
} catch {
    `$errMsg = `$_.Exception.Message
    Write-Host "[`$(Get-Date -Format o)] Relauncher error: `$errMsg"
    Save-DuneUpdateResult -Success `$false -Message `$errMsg
    try {
        Show-DuneUpdateFailure -Title 'Dune Server Update Error' -Message (
            "The updater hit an unexpected error:``r``n  `$errMsg``r``n``r``n" +
            "Relaunch log:``r``n  $logPathEsc``r``n``r``nInstaller log:``r``n  $innoLogPathEsc``r``n``r``n" +
            "You can reinstall manually by running:``r``n  $destEsc")
    } catch {}
} finally {
    Stop-Transcript | Out-Null
}
"@
        $scriptPath = Join-Path $updateDir ("DuneRelaunch-$safeTag-$launchId.ps1")
        Set-Content -LiteralPath $scriptPath -Value $relaunchScript -Encoding UTF8

        # Spawn the relauncher in a HIDDEN window. The relauncher itself is
        # invisible (the grace sleep + app kill chain), but it then launches the
        # installer in the validated mode. Both modes relaunch through their
        # corresponding Inno [Run] entry. Failures still surface in a topmost box.
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) `
            -WindowStyle Hidden | Out-Null
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
      }
    } finally {
        [void]$updLock.Release()
    }
}
