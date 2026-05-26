# GameConfig lib — visual editor backing for UserGame.ini + UserEngine.ini.
# Reads the LIVE INI files inside the battlegroup PVC (same files FileBrowser
# exposes under /files/UserSettings/), NOT the setup templates under
# /home/dune/.dune/download/scripts/setup/config/ which are only used at
# first-boot provisioning.
#
# Schema, INI parser, and field set ported verbatim from app/pages/GameConfig.ps1
# (the v6.0.x WPF page). SSH plumbing reuses Invoke-V6Ssh from Db-Postgres.ps1.

# -----------------------------------------------------------------------------
# Field schema — 6 sections, ~25 fields.
# type: select | number | text
# file: game | engine
# -----------------------------------------------------------------------------
$script:DuneGameConfigSchema = @(
    @{ Section = 'Combat Rules'; Fields = @(
        @{ Key='m_bShouldForceEnablePvpOnAllPartitions'; File='game'; Type='select'; Label='Force PvP on All Partitions';
           Options=@(@{V='False';L='Off'},@{V='True';L='On'}) }
        @{ Key='m_bAreSecurityZonesEnabled'; File='game'; Type='select'; Label='Security Zones Enabled';
           Options=@(@{V='True';L='On'},@{V='False';L='Off (PvP everywhere)'}) }
    )}
    @{ Section = 'World & Weather'; Fields = @(
        @{ Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='select'; Label='Coriolis Storm';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
        @{ Key='Sandstorm.Enabled'; File='engine'; Type='select'; Label='Sandstorm';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
        @{ Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='select'; Label='Sandstorm Treasure Spawns';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
    )}
    @{ Section = 'Shai-Hulud'; Fields = @(
        @{ Key='sandworm.dune.Enabled'; File='engine'; Type='select'; Label='Sandworm Enabled';
           Options=@(@{V='1';L='On'},@{V='0';L='Off'}) }
        @{ Key='Sandworm.SandwormDangerZonesEnabled'; File='engine'; Type='select'; Label='Danger Zones Enabled';
           Options=@(@{V='true';L='On'},@{V='false';L='Off'}) }
        @{ Key='Vehicle.SandwormCollisionInteraction'; File='engine'; Type='select'; Label='Sandworm Pushes Vehicles';
           Options=@(@{V='false';L='Off'},@{V='true';L='On'}) }
        @{ Key='Vehicle.SandwormInvulnerabilitySecondsOnExit'; File='engine'; Type='number'; Label='Invulnerability on Vehicle Exit';
           Step=1; Min=0; Unit='sec' }
        @{ Key='Vehicle.SandwormInvulnerabilitySecondsOnServerRestart'; File='engine'; Type='number'; Label='Invulnerability on Server Restart';
           Step=1; Min=0; Unit='sec' }
    )}
    @{ Section = 'Resources & Loot'; Fields = @(
        @{ Key='Dune.GlobalMiningOutputMultiplier'; File='engine'; Type='number'; Label='Global Mining Multiplier';
           Step=0.1; Min=0 }
        @{ Key='Dune.GlobalVehicleMiningOutputMultiplier'; File='engine'; Type='number'; Label='Vehicle Mining Multiplier';
           Step=0.1; Min=0 }
        @{ Key='SecurityZones.PvpResourceMultiplier'; File='engine'; Type='number'; Label='PvP Resource Multiplier';
           Step=0.1; Min=0 }
        @{ Key='UpdateRateInSeconds'; File='game'; Type='number'; Label='Item Decay Rate';
           Step=0.1; Min=0; Max=10; Hint='0=off, 1-10' }
        @{ Key='dw.VehicleDurabilityDamageMultiplier'; File='engine'; Type='number'; Label='Vehicle Durability Damage';
           Step=0.1; Min=0; Max=10; Hint='0=off, 1-10' }
    )}
    @{ Section = 'Bases & Land Claims'; Fields = @(
        @{ Key='m_MaxNumLandclaimSegments'; File='game'; Type='number'; Label='Max Landclaim Segments'; Step=1; Min=1 }
        @{ Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='number'; Label='Blueprint Max Extensions'; Step=1; Min=0 }
        @{ Key='m_BaseBackupMaxExtensions'; File='game'; Type='number'; Label='Base Backup Max Extensions'; Step=1; Min=0 }
        @{ Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='select'; Label='Building Restriction Limits';
           Options=@(@{V='True';L='On'},@{V='False';L='Off'}) }
    )}
    @{ Section = 'Server Identity'; Fields = @(
        @{ Key='Bgd.ServerDisplayName'; File='engine'; Type='text'; Label='Server Display Name';
           Hint='shown to players'; Placeholder='Not set (uses world name)'; Wide=$true }
        @{ Key='Bgd.ServerLoginPassword'; File='engine'; Type='text'; Label='Server Login Password';
           Hint='blank = no password'; Placeholder='No password'; Wide=$true }
        @{ Key='Port'; File='engine'; Type='number'; Label='Game Port (starting)'; Step=1; Min=1024; Max=65535 }
        @{ Key='IGWPort'; File='engine'; Type='number'; Label='IGW Port (starting)'; Step=1; Min=1024; Max=65535 }
    )}
)

# Keys whose values must be wrapped in double-quotes when written back.
$script:DuneGameConfigQuotedKeys = @('Bgd.ServerDisplayName','Bgd.ServerLoginPassword')

# -----------------------------------------------------------------------------
# Live INI paths inside the BG PVC. PVC name includes a sietch-specific hash so
# we resolve via a sudo glob rather than hardcoding. Templates are the fallback
# used when no BG has been provisioned yet.
# -----------------------------------------------------------------------------
$script:DuneGameConfigLiveGlobGame   = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserGame.ini'
$script:DuneGameConfigLiveGlobEngine = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserEngine.ini'
$script:DuneGameConfigTplGamePath    = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
$script:DuneGameConfigTplEnginePath  = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'

# Cache resolved live paths per session (PVC name is stable across BG restarts)
$script:DuneGameConfigResolvedGame   = $null
$script:DuneGameConfigResolvedEngine = $null

# -----------------------------------------------------------------------------
# INI parse / apply — ported from app/pages/GameConfig.ps1
# -----------------------------------------------------------------------------
function ConvertFrom-DuneIni {
    param([string]$Raw)
    $result = @{}
    if (-not $Raw) { return $result }
    foreach ($line in ($Raw -split "`n")) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('[')) { continue }
        $active = $true
        $content = $t
        if ($t.StartsWith(';')) {
            $rest = $t.Substring(1).Trim()
            if ($rest -notmatch '^[A-Za-z]') { continue }
            $eq2 = $rest.IndexOf('=')
            if ($eq2 -lt 0) { continue }
            $active = $false
            $content = $rest
        }
        $eq = $content.IndexOf('=')
        if ($eq -lt 0) { continue }
        $key = $content.Substring(0, $eq).Trim()
        if ($active) {
            $result[$key] = $content.Substring($eq + 1).Trim()
        } elseif (-not $result.ContainsKey($key)) {
            $result[$key] = ''
        }
    }
    return $result
}

function ConvertTo-DuneIni {
    param([string]$Raw, [hashtable]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return $Raw }
    $lines = $Raw -split "`n"
    $applied = @{}
    $quoted = @{}
    foreach ($q in $script:DuneGameConfigQuotedKeys) { $quoted[$q] = $true }

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('[')) { $out.Add($line); continue }
        $content = $t
        if ($t.StartsWith(';')) {
            $content = $t.Substring(1).Trim()
            if ($content -notmatch '^[A-Za-z]') { $out.Add($line); continue }
        }
        $eq = $content.IndexOf('=')
        if ($eq -lt 0) { $out.Add($line); continue }
        $key = $content.Substring(0, $eq).Trim()

        if ($Updates.ContainsKey($key)) {
            $applied[$key] = $true
            $val = $Updates[$key]
            if ([string]::IsNullOrEmpty([string]$val) -and "$val" -ne '0') {
                $def = $content.Substring($eq + 1).Trim()
                if (-not $def) { $def = '""' }
                $out.Add(";$key=$def")
            } else {
                $formatted = "$val"
                if ($quoted.ContainsKey($key) -and -not $formatted.StartsWith('"')) {
                    $formatted = '"' + $formatted + '"'
                }
                $out.Add("$key=$formatted")
            }
        } else {
            $out.Add($line)
        }
    }
    # Append keys not present in original
    foreach ($k in $Updates.Keys) {
        if ($applied.ContainsKey($k)) { continue }
        $val = $Updates[$k]
        if ([string]::IsNullOrEmpty([string]$val) -and "$val" -ne '0') { continue }
        $formatted = "$val"
        if ($quoted.ContainsKey($k) -and -not $formatted.StartsWith('"')) {
            $formatted = '"' + $formatted + '"'
        }
        $out.Add("$k=$formatted")
    }
    return ($out -join "`n")
}

# -----------------------------------------------------------------------------
# VM context — game config only needs VM running + IP, not BG fully up.
# Returns @{ok=$true; ip=...} or @{ok=$false; status=...; message='...'}.
# -----------------------------------------------------------------------------
function Get-DuneGameConfigContext {
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='SSH helper unavailable (Db-Postgres.ps1 not loaded).' }
    }
    if (-not (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM status helper unavailable.' }
    }
    $vm = Get-DuneVmStatus
    if (-not $vm.exists) {
        return @{ ok=$false; status=503; message='VM does not exist on this host.' }
    }
    if (-not $vm.running) {
        return @{ ok=$false; status=503; message='VM is not running. Start it before editing game config.' }
    }
    if (-not $vm.ip) {
        return @{ ok=$false; status=503; message='VM is running but has no IP yet — wait for it to finish booting.' }
    }
    return @{ ok=$true; ip=$vm.ip; vm=$vm }
}

# -----------------------------------------------------------------------------
# Resolve live PVC paths (cached). Falls back to setup templates if no BG
# has been provisioned yet.
# -----------------------------------------------------------------------------
function Resolve-DuneGameConfigPaths {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:DuneGameConfigResolvedGame -and $script:DuneGameConfigResolvedEngine) {
        return @{ game = $script:DuneGameConfigResolvedGame; engine = $script:DuneGameConfigResolvedEngine; source = 'cache' }
    }
    # ls -t orders by mtime descending so we pick the live BG's PVC if multiple
    # exist (e.g. after re-provision). sudo because /var/lib/rancher is root-only.
    $liveGame   = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'ls -t $($script:DuneGameConfigLiveGlobGame) 2>/dev/null | head -1'") -join ''
    $liveEngine = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'ls -t $($script:DuneGameConfigLiveGlobEngine) 2>/dev/null | head -1'") -join ''
    $liveGame   = "$liveGame".Trim()
    $liveEngine = "$liveEngine".Trim()
    if ($liveGame -and $liveEngine) {
        $script:DuneGameConfigResolvedGame   = $liveGame
        $script:DuneGameConfigResolvedEngine = $liveEngine
        return @{ game = $liveGame; engine = $liveEngine; source = 'live' }
    }
    $script:DuneGameConfigResolvedGame   = $script:DuneGameConfigTplGamePath
    $script:DuneGameConfigResolvedEngine = $script:DuneGameConfigTplEnginePath
    return @{ game = $script:DuneGameConfigTplGamePath; engine = $script:DuneGameConfigTplEnginePath; source = 'template' }
}

# -----------------------------------------------------------------------------
# Fetch both INI files + parse. Returns:
#   { game: { values{}, raw, path }, engine: { values{}, raw, path }, source }
# -----------------------------------------------------------------------------
function Get-DuneGameConfig {
    param([string]$Ip)
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
    # Files live under /var/lib/rancher which is root-only, so cat via sudo.
    # Templates under /home/dune are readable as dune, but sudo cat works for
    # both — harmless extra privilege for the template path.
    $gameOut   = Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.game)' 2>/dev/null"
    $engineOut = Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.engine)' 2>/dev/null"
    $gameRaw   = ($gameOut   -join "`n")
    $engineRaw = ($engineOut -join "`n")
    return @{
        source = $paths.source
        game = @{
            path   = $paths.game
            raw    = $gameRaw
            values = ConvertFrom-DuneIni -Raw $gameRaw
        }
        engine = @{
            path   = $paths.engine
            raw    = $engineRaw
            values = ConvertFrom-DuneIni -Raw $engineRaw
        }
    }
}

# -----------------------------------------------------------------------------
# Save: fetch raw, apply, base64 → sudo tee back. Per-file (only writes the
# file that has updates).
# -----------------------------------------------------------------------------
function Save-DuneGameConfig {
    param(
        [string]$Ip,
        [hashtable]$GameUpdates,
        [hashtable]$EngineUpdates
    )
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip

    if ($GameUpdates -and $GameUpdates.Count -gt 0) {
        $gameRaw = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.game)' 2>/dev/null") -join "`n"
        $newGame = ConvertTo-DuneIni -Raw $gameRaw -Updates $GameUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newGame))
        Invoke-V6Ssh -Ip $Ip -Cmd "echo '$b64' | base64 -d | sudo tee '$($paths.game)' > /dev/null" -TimeoutSec 30 | Out-Null
    }
    if ($EngineUpdates -and $EngineUpdates.Count -gt 0) {
        $engineRaw = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.engine)' 2>/dev/null") -join "`n"
        $newEng = ConvertTo-DuneIni -Raw $engineRaw -Updates $EngineUpdates
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($newEng))
        Invoke-V6Ssh -Ip $Ip -Cmd "echo '$b64' | base64 -d | sudo tee '$($paths.engine)' > /dev/null" -TimeoutSec 30 | Out-Null
    }
}

# -----------------------------------------------------------------------------
# Schema serializer — returns the schema in a JSON-friendly form for the API.
# -----------------------------------------------------------------------------
function Get-DuneGameConfigSchemaApi {
    @($script:DuneGameConfigSchema | ForEach-Object {
        @{
            section = $_.Section
            fields  = @($_.Fields | ForEach-Object {
                $f = @{
                    key   = $_.Key
                    file  = $_.File
                    type  = $_.Type
                    label = $_.Label
                }
                if ($_.ContainsKey('Hint'))        { $f.hint        = $_.Hint }
                if ($_.ContainsKey('Placeholder')) { $f.placeholder = $_.Placeholder }
                if ($_.ContainsKey('Unit'))        { $f.unit        = $_.Unit }
                if ($_.ContainsKey('Wide'))        { $f.wide        = [bool]$_.Wide }
                if ($_.ContainsKey('Step'))        { $f.step        = $_.Step }
                if ($_.ContainsKey('Min'))         { $f.min         = $_.Min }
                if ($_.ContainsKey('Max'))         { $f.max         = $_.Max }
                if ($_.ContainsKey('Options')) {
                    $f.options = @($_.Options | ForEach-Object { @{ value = $_.V; label = $_.L } })
                }
                $f
            })
        }
    })
}

# Build a quick lookup of every key in the schema → which file it belongs to.
# Used by the save endpoint to filter unknown keys.
function Get-DuneGameConfigKeyFileMap {
    $map = @{}
    foreach ($section in $script:DuneGameConfigSchema) {
        foreach ($field in $section.Fields) {
            $map[$field.Key] = $field.File
        }
    }
    return $map
}
