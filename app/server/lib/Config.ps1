# Config — read/save dune-server.config (INI-style key=value).
#
# Location: <install-root>\dune-server.config, which is one level up from
# $script:AppDir (the app/ directory).

$script:DuneConfigKeys = @(
    'SteamPath',
    'SshKey',
    'DuneAdminExe',
    'WindowsUser',
    'PortCheckMode',
    'PortCheckUrlTemplate',
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

function Read-DuneConfig {
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

function Save-DuneConfig {
    param([hashtable]$Config)
    $path = Get-DuneConfigPath
    $existing = Read-DuneConfig
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
