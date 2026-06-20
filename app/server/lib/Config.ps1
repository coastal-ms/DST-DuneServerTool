# Config — read/save dune-server.config (INI-style key=value).
#
# Location: <install-root>\dune-server.config, which is one level up from
# $script:AppDir (the app/ directory).

$script:DuneConfigKeys = @(
    'SteamPath',
    'SshKey',
    'WindowsUser',
    'PortCheckMode',
    'PortCheckUrlTemplate',
    'PublicIpMode',
    'DdnsHostname',
    'ManualPublicIp',
    'LastResolvedPublicIp',
    'LastAppliedPublicIp',
    'OpenInAppWindow',
    'ConsolePresence',
    'ConsolePresenceVersion',
    'MarketBotAddr',
    'MarketBotToken',
    'DecoupleNoticeAck',
    'ClientConfigPath',
    'DbPort',
    'UpdateChannel',
    'UpdatePreReleaseTag',
    'UpdateInstalledPrerelease',
    'UpdateInstalledTag'
)

# Default in-pod PostgreSQL port. All DST DB access runs as
# `kubectl exec <db-pod> -- psql -p <port>`, so this is the port the postgres
# process listens on INSIDE the cluster pod, not a port reachable from Windows.
# Funcom's stock self-hosted server uses 15432; some setups differ (e.g. 15433),
# which previously made Players/Bases/Storage show empty with no error.
$script:DuneDefaultDbPort = 15432

# Keys that ONLY a pre-decouple (<= 11.4.13) build ever wrote into
# dune-server.config. Their presence on disk is how we know a config was
# created before DST was split off from the companion admin tool — a fresh
# 12.x install never writes them. Used to drive the one-time decoupling notice.
$script:DuneLegacyAdminKeys = @(
    'DuneAdminExe',
    'AutoApplyPricingPatch',
    'GambleDieSize',
    'GambleTarget'
)

function Get-DuneConfigPath {
    if ($script:DuneConfigFile) { return $script:DuneConfigFile }
    # Primary location used by the installer and shared with the v6.0.x
    # business-logic script (dune-server.ps1 / app/lib/Db-Postgres.ps1).
    # Both the source/dev launcher and the installed launcher read & write
    # the same file here, so settings survive reinstalls and are consistent
    # across both invocation paths.
    $appdataPath = Join-Path $env:APPDATA 'DuneServer\dune-server.config'
    if (Test-Path -LiteralPath $appdataPath) { return $appdataPath }
    # Dev fallback: repo-root file next to dune-server.ps1.
    $root = Split-Path -Parent $script:AppDir
    $devPath = Join-Path $root 'dune-server.config'
    if (Test-Path -LiteralPath $devPath) { return $devPath }
    # Neither exists yet — return the canonical APPDATA path so a future
    # Save-DuneConfig creates it there.
    return $appdataPath
}

function Read-DuneConfigRaw {
    $path = Get-DuneConfigPath
    $cfg = [ordered]@{}
    foreach ($k in $script:DuneConfigKeys) { $cfg[$k] = '' }
    if (Test-Path -LiteralPath $path) {
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*?)\s*$') {
                $cfg[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $cfg
}

# True when the portal should open in the standalone DuneShell app window
# instead of a browser tab. Defaults to TRUE (app window is the preferred
# experience); only an explicit false/0/no/off falls back to the browser.
function Get-DstOpenInAppWindow {
    $raw = Read-DuneConfigRaw
    $v = if ($raw.Contains('OpenInAppWindow')) { [string]$raw['OpenInAppWindow'] } else { '' }
    if ($v -match '^(?i:false|0|no|off)$') { return $false }
    return $true
}

# Effective config view. Currently identical to the raw on-disk file; kept as a
# distinct function so callers have a single "resolved config" entry point.
function Read-DuneConfig {
    return Read-DuneConfigRaw
}

# Resolve the in-pod PostgreSQL port DST should use. Reads the DbPort config key,
# validates it as a 1-65535 integer, and falls back to the Funcom default
# (15432) when unset or invalid.
function Get-DuneDbPort {
    $default = if ($script:DuneDefaultDbPort) { $script:DuneDefaultDbPort } else { 15432 }
    try {
        $raw = Read-DuneConfigRaw
        $v = if ($raw.Contains('DbPort')) { [string]$raw['DbPort'] } else { '' }
        $parsed = 0
        if ($v -and [int]::TryParse($v.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
            return $parsed
        }
    } catch {}
    return $default
}

# Update channel the in-app updater follows: 'stable' (default) or 'test'.
# 'stable' serves the newest non-prerelease GitHub release (everyone). 'test'
# opts into GitHub pre-releases (targeted Discord test builds). Any value other
# than an explicit test/beta/prerelease token resolves to stable.
function Get-DuneUpdateChannel {
    try {
        $raw = Read-DuneConfigRaw
        $v = if ($raw.Contains('UpdateChannel')) { [string]$raw['UpdateChannel'] } else { '' }
        if ($v -match '^(?i:test|beta|prerelease|pre-release)$') { return 'test' }
    } catch {}
    return 'stable'
}

# Specific pre-release tag the user pinned on the test channel (e.g.
# 'v12.9.5-test1'). Empty string means "latest" (newest available build).
function Get-DuneUpdatePreReleaseTag {
    try {
        $raw = Read-DuneConfigRaw
        $v = if ($raw.Contains('UpdatePreReleaseTag')) { [string]$raw['UpdatePreReleaseTag'] } else { '' }
        return $v.Trim()
    } catch {}
    return ''
}

# Whether the build currently installed was itself a GitHub pre-release (a
# targeted Discord test build), as recorded by the in-app updater at the moment
# it launched that install. This is the truth source for the app-wide "running a
# test build" indicator — NOT the UpdateChannel preference. Merely toggling the
# channel to Test (a preference that takes effect on the NEXT install) must not
# light the indicator; only actually installing a pre-release build does. A
# subsequent stable install writes 'false' and clears it. Absent/blank => false
# (a normal stable install never wrote it).
function Get-DuneUpdateInstalledPrerelease {
    try {
        $raw = Read-DuneConfigRaw
        $v = if ($raw.Contains('UpdateInstalledPrerelease')) { [string]$raw['UpdateInstalledPrerelease'] } else { '' }
        return ($v -match '^(?i:true|1|yes)$')
    } catch {}
    return $false
}

function Save-DuneConfig {
    param([hashtable]$Config)
    $path = Get-DuneConfigPath
    $existing = Read-DuneConfigRaw
    foreach ($k in $Config.Keys) {
        if ($script:DuneConfigKeys -notcontains $k) { continue }
        $existing[$k] = "$($Config[$k])"
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Dune Server configuration')
    $lines.Add("# Managed by Dune Server v$script:DuneToolVersion")
    $lines.Add('')
    foreach ($k in $script:DuneConfigKeys) {
        $v = if ($existing.Contains($k)) { $existing[$k] } else { '' }
        $lines.Add("$k=$v")
    }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    return Read-DuneConfig
}

function Test-DuneConfigComplete {
    param([hashtable]$Config)
    if (-not $Config) { $Config = Read-DuneConfig }
    if (-not $Config.SshKey -or -not (Test-Path -LiteralPath $Config.SshKey)) { return $false }
    if (-not $Config.SteamPath) { return $false }
    return $true
}

# Decoupling notice ----------------------------------------------------------
#
# As of v12.x DST is a standalone tool: the bundled companion admin tool and
# its in-app launch commands were removed (that tool is now run separately and
# reached at https://dune-admin.layout.tools). Anyone upgrading from a
# pre-decouple build (<= 11.4.13) must be told this once, and shown where their
# old companion-tool folder lives so they can still launch it.
#
# Detection: pre-decouple builds wrote the reference implementation-era keys (see
# $script:DuneLegacyAdminKeys) into dune-server.config; a fresh 12.x install
# never does. We treat the presence of any of those keys as "this user came
# from the bundled-companion era". `DecoupleNoticeAck` is set once the user
# acknowledges, after which the notice never shows again.
function Get-DuneDecoupleNotice {
    $raw = Read-DuneConfigRaw
    $ack = if ($raw.Contains('DecoupleNoticeAck')) { [string]$raw['DecoupleNoticeAck'] } else { '' }
    $acknowledged = -not [string]::IsNullOrWhiteSpace($ack)

    $hasLegacy = $false
    foreach ($k in $script:DuneLegacyAdminKeys) {
        if ($raw.Contains($k)) { $hasLegacy = $true; break }
    }

    $exe = if ($raw.Contains('DuneAdminExe')) { [string]$raw['DuneAdminExe'] } else { '' }
    $folder = ''
    if ($exe) {
        try { $folder = Split-Path -Parent $exe } catch { $folder = '' }
    }

    return [pscustomobject]@{
        Needed          = ((-not $acknowledged) -and $hasLegacy)
        Acknowledged    = $acknowledged
        AckVersion      = $ack
        FromLegacy      = $hasLegacy
        DuneAdminExe    = $exe
        DuneAdminFolder = $folder
    }
}

function Set-DuneDecoupleAck {
    param([string]$Version)
    Save-DuneConfig -Config @{ DecoupleNoticeAck = $Version } | Out-Null
}
