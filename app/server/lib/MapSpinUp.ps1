# MapSpinUp — per-map "keep at least one server warm" control.
#
# The battlegroup director keeps an INI config embedded in the BG CRD at:
#   spec.utilities.director.spec.configFiles.files["director.ini"]
#
# Each playable map is an INI section ([ MapName ]). Some maps carry a
#   MinServers=1
# key — when set to 1 the director keeps one instance of the map warm
# at all times (a "spin-up floor"). The key is binary: 0 (off) or 1 (on).
# Other values are not supported by the director. The format is strict:
# no spaces around the '=', no quoting.
#
# Funcom ships MinServers on a handful of persistent/instanced maps; the
# rest only have NumExtraServers (on-demand scaling, which we DO NOT touch
# here).
#
# As of director image 1979201-0-shipping (Funcom 2026-06 update), the
# MinServers floor is ONLY honored when the section also carries
#   EnableAutomaticInstanceScaling = true
# Funcom ships that key on Story/DLC sections (Story_ArtOfKanly,
# Story_ProcesVerbal, DLC_Story_LostHarvest_*) but NOT on DeepDesert_1,
# SH_Arrakeen, or SH_HarkoVillage — so a bare MinServers=1 on those
# sections silently no-ops. We therefore set both keys together on spin-up.
# The flag is left in place on spin-down (idempotent, also allows player
# travel-to spawn — a deliberate trade-off, not a side effect).
#
# This module:
#   * lists every real map section (anything with a NumExtraServers key),
#   * reports its current MinServers value (absent = 0 = off),
#   * toggles MinServers between 0 and 1 by rewriting director.ini and
#     patching the CRD (hot-swappable — the operator reconciles it live),
#   * ensures EnableAutomaticInstanceScaling = true is present on spin-up.
#
# Overmap / Survival_1 are always-on and aren't in director.ini at all, so
# they never appear. Config-only sections ([ Battlegroup ], [ InstancingModes ])
# have no NumExtraServers key and are excluded.
#
# Pattern (SSH + kubectl patch) cribbed from app/server/lib/Maps.ps1.

# Dot-source the K8s helpers (Get-V6Battlegroup). Db-Postgres.ps1 (Invoke-V6Ssh)
# is loaded earlier in the server lib load order via Characters.ps1.
$script:DuneSpinUpK8sPath = $null
foreach ($candidate in @(
    (Join-Path $PSScriptRoot '..\..\lib\K8s.ps1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) '..\lib\K8s.ps1')
)) {
    $full = $null
    try { $full = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch {}
    if ($full) { $script:DuneSpinUpK8sPath = $full; break }
}
if ($script:DuneSpinUpK8sPath -and -not (Get-Command Get-V6Battlegroup -ErrorAction SilentlyContinue)) {
    . $script:DuneSpinUpK8sPath
}

# JSON-pointer path to the director INI inside the BG CRD.
$script:DuneDirectorIniPath = '/spec/utilities/director/spec/configFiles/files/director.ini'

# Maps Funcom ships with native MinServers support. Used ONLY for grouping
# (Supported vs Experimental) — kept stable so maps we add MinServers to don't
# silently migrate from Experimental to Supported on the next load.
$script:DuneSpinUpNativeMaps = @(
    'SH_Arrakeen'
    'SH_HarkoVillage'
    'DeepDesert_1'
    'DLC_Story_LostHarvest_EcolabA'
    'DLC_Story_LostHarvest_EcolabB'
    'DLC_Story_LostHarvest_ForgottenLab'
)

# Friendly labels for the common maps. Anything not listed falls back to a
# generic prettifier (strip known prefixes, underscores -> spaces).
$script:DuneSpinUpLabels = @{
    'SH_Arrakeen'                        = 'Arrakeen'
    'SH_HarkoVillage'                    = 'Harko Village'
    'DeepDesert_1'                       = 'Deep Desert'
    'DLC_Story_LostHarvest_EcolabA'      = 'Lost Harvest: Ecolab A'
    'DLC_Story_LostHarvest_EcolabB'      = 'Lost Harvest: Ecolab B'
    'DLC_Story_LostHarvest_ForgottenLab' = 'Lost Harvest: Forgotten Lab'
    'CB_Dungeon_Hephaestus'              = 'Dungeon: Hephaestus'
    'CB_Dungeon_OldCarthag'              = 'Dungeon: Old Carthag'
    'CB_Dungeon_ThePit'                  = 'Dungeon: The Pit'
    'CB_Story_BanditFortress01'          = 'Bandit Fortress'
    'Story_ArtOfKanly'                   = 'The Art of Kanly'
    'Story_ProcesVerbal'                 = 'Procès-Verbal'
    'Story_Faction_Outpost_Atre'         = 'Faction Outpost: Atreides'
    'Story_Faction_Outpost_Hark'         = 'Faction Outpost: Harkonnen'
    'Story_HeighlinerDungeon'            = 'Heighliner Dungeon'
}

function _Get-DuneSpinUpLabel {
    param([Parameter(Mandatory)][string]$Map)
    if ($script:DuneSpinUpLabels.ContainsKey($Map)) { return $script:DuneSpinUpLabels[$Map] }
    $s = $Map
    foreach ($p in @('CB_Ecolab_', 'CB_Overland_', 'CB_Story_', 'CB_Dungeon_', 'DLC_Story_', 'Story_', 'CB_', 'SH_')) {
        if ($s.StartsWith($p)) { $s = $s.Substring($p.Length); break }
    }
    return ($s -replace '_', ' ').Trim()
}

function _Get-DuneDirectorIni {
    # Returns @{ ok; ctx; info; ini } or @{ ok=$false; status; message }.
    $ctx = Get-DuneMapsContext
    if (-not $ctx.ok) { return @{ ok = $false; status = $ctx.status; message = $ctx.message } }
    try {
        $info = Get-V6Battlegroup -Ip $ctx.vm.ip
    } catch {
        return @{ ok = $false; status = 502; message = "Could not read battlegroup CRD: $($_.Exception.Message)" }
    }
    $files = $null
    try { $files = $info.Bg.spec.utilities.director.spec.configFiles.files } catch {}
    if (-not $files -or -not $files.PSObject.Properties['director.ini']) {
        return @{ ok = $false; status = 404; message = 'director.ini not found in the battlegroup CRD.' }
    }
    return @{ ok = $true; ctx = $ctx; info = $info; ini = [string]$files.'director.ini' }
}

function _Parse-DuneDirectorIni {
    # Parses INI text into ordered section objects:
    #   @{ Name; IsMap; HasMinServers; MinServers; HasEnableAutoScaling; }
    param([Parameter(Mandatory)][string]$Ini)
    $sections = New-Object System.Collections.Generic.List[object]
    $current  = $null
    foreach ($rawLine in ($Ini -split "`n")) {
        $line = $rawLine -replace "`r", ''
        $trim = $line.Trim()
        if ($trim -match '^\[\s*(.+?)\s*\]$') {
            if ($current) { $sections.Add($current) }
            $current = [pscustomobject]@{
                Name                 = $matches[1]
                IsMap                = $false
                HasMinServers        = $false
                MinServers           = 0
                HasEnableAutoScaling = $false
            }
            continue
        }
        if (-not $current) { continue }
        if ($trim -match '^NumExtraServers\s*=') { $current.IsMap = $true }
        if ($trim -match '^MinServers\s*=\s*(-?\d+)') {
            $current.HasMinServers = $true
            $current.MinServers    = [int]$matches[1]
        }
        if ($trim -match '^EnableAutomaticInstanceScaling\s*=\s*true\s*$') {
            $current.HasEnableAutoScaling = $true
        }
    }
    if ($current) { $sections.Add($current) }
    return $sections
}

function Get-DuneSpinUpMaps {
    # Lists every map section with its current MinServers state, grouped into
    # supported (native MinServers) vs experimental (we'd add MinServers).
    $r = _Get-DuneDirectorIni
    if (-not $r.ok) { return $r }

    $sections = _Parse-DuneDirectorIni -Ini $r.ini
    $maps = @()
    foreach ($s in $sections) {
        if (-not $s.IsMap) { continue }
        $native = $script:DuneSpinUpNativeMaps -contains $s.Name
        $maps += [pscustomobject]@{
            map        = $s.Name
            label      = _Get-DuneSpinUpLabel -Map $s.Name
            group      = if ($native) { 'supported' } else { 'experimental' }
            minServers = [int]$s.MinServers
            enabled    = ([int]$s.MinServers -ge 1)
        }
    }
    return @{
        ok   = $true
        ns   = $r.info.Ns
        name = $r.info.Name
        maps = $maps
    }
}

function _Set-DuneIniMinServers {
    # Returns a new INI string with $Map's MinServers line set to $Value.
    # $Value must be 0 or 1 (the only values the director accepts). The
    # emitted line uses Funcom's strict format: "MinServers=1" — no spaces,
    # no quoting. Spaces around '=' have been observed to be silently
    # ignored by the director.
    #   - replaces an existing MinServers line in the section, or
    #   - inserts one (after NumExtraServers, or after the header) when
    #     missing and $Value -eq 1. When $Value -eq 0 and no line exists,
    #     leaves the section untouched (absent == 0) to keep the file minimal.
    param(
        [Parameter(Mandatory)][string]$Ini,
        [Parameter(Mandatory)][string]$Map,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$Value
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($Ini -split "`n")) { $lines.Add(($l -replace "`r", '')) }

    $secStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[\s*(.+?)\s*\]$' -and $matches[1] -eq $Map) { $secStart = $i; break }
    }
    if ($secStart -lt 0) { return $Ini }  # map not found — no change

    # Find the end of the section (next header or EOF).
    $secEnd = $lines.Count
    for ($i = $secStart + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[\s*.+?\s*\]$') { $secEnd = $i; break }
    }

    # Look for an existing MinServers line within the section.
    $msIdx       = -1
    $numExtraIdx = -1
    for ($i = $secStart + 1; $i -lt $secEnd; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^MinServers\s*=')     { $msIdx = $i }
        if ($t -match '^NumExtraServers\s*=') { $numExtraIdx = $i }
    }

    if ($msIdx -ge 0) {
        $lines[$msIdx] = "MinServers=$Value"
    } elseif ($Value -eq 1) {
        $insertAt = if ($numExtraIdx -ge 0) { $numExtraIdx + 1 } else { $secStart + 1 }
        $lines.Insert($insertAt, "MinServers=$Value")
    }
    return ($lines -join "`n")
}

function _Set-DuneIniEnableAutoScaling {
    # Returns a new INI string with EnableAutomaticInstanceScaling = true
    # ensured in $Map's section. No-ops if the key is already present.
    # Insert position: immediately after the section header, mirroring how
    # Funcom ships it on Story/DLC sections.
    param(
        [Parameter(Mandatory)][string]$Ini,
        [Parameter(Mandatory)][string]$Map
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in ($Ini -split "`n")) { $lines.Add(($l -replace "`r", '')) }

    $secStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[\s*(.+?)\s*\]$' -and $matches[1] -eq $Map) { $secStart = $i; break }
    }
    if ($secStart -lt 0) { return $Ini }

    $secEnd = $lines.Count
    for ($i = $secStart + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^\[\s*.+?\s*\]$') { $secEnd = $i; break }
    }

    for ($i = $secStart + 1; $i -lt $secEnd; $i++) {
        if ($lines[$i].Trim() -match '^EnableAutomaticInstanceScaling\s*=\s*true\s*$') {
            return $Ini  # already present
        }
    }

    $lines.Insert($secStart + 1, 'EnableAutomaticInstanceScaling = true')
    return ($lines -join "`n")
}

function Set-DuneSpinUpMap {
    # Toggles a single map's MinServers floor. $Enabled -> 1, else 0.
    param(
        [Parameter(Mandatory)][string]$Map,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $r = _Get-DuneDirectorIni
    if (-not $r.ok) { return $r }

    $sections = _Parse-DuneDirectorIni -Ini $r.ini
    $target = $sections | Where-Object { $_.IsMap -and $_.Name -eq $Map } | Select-Object -First 1
    if (-not $target) {
        return @{ ok = $false; status = 404; message = "Map '$Map' is not a controllable map section in director.ini." }
    }

    $value   = if ($Enabled) { 1 } else { 0 }
    $current = [int]$target.MinServers

    # Spin-up requires BOTH MinServers >= 1 AND EnableAutomaticInstanceScaling = true
    # (the latter is the gate added in director image 1979201-0-shipping). On
    # spin-down we only need to drop MinServers; the auto-scaling flag is left
    # in place so a future spin-up is a one-line change.
    $needsAutoScaling = ($value -ge 1) -and -not $target.HasEnableAutoScaling
    $minServersInSync = ($current -eq $value -and ($target.HasMinServers -or $value -eq 0))

    if ($minServersInSync -and -not $needsAutoScaling) {
        return @{
            ok         = $true
            map        = $Map
            label      = (_Get-DuneSpinUpLabel -Map $Map)
            minServers = $value
            enabled    = ($value -ge 1)
            noop       = $true
            message    = "$(_Get-DuneSpinUpLabel -Map $Map) is already set to MinServers = $value."
        }
    }

    $newIni = _Set-DuneIniMinServers -Ini $r.ini -Map $Map -Value $value
    if ($value -ge 1) {
        $newIni = _Set-DuneIniEnableAutoScaling -Ini $newIni -Map $Map
    }
    if ($newIni -eq $r.ini) {
        return @{
            ok = $false; status = 500
            message = "No change produced for '$Map' (parser/edit mismatch)."
        }
    }

    $patch = @(@{ op = 'replace'; path = $script:DuneDirectorIniPath; value = $newIni })
    $patchJson = $patch | ConvertTo-Json -Depth 30 -Compress
    if ($patchJson -notmatch '^\s*\[') { $patchJson = "[$patchJson]" }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($patchJson))
    # IMPORTANT: build a command with NO embedded double-quotes. The legacy
    # PowerShell runtime that hosts the server mangles embedded " when passing
    # the command to ssh.exe as a native argument, which corrupted the older
    # -p "$(echo .. | base64 -d)" form (kubectl saw a truncated patch value).
    # Decode the patch to a temp file and use --patch-file instead. The path is
    # generated host-side from a GUID so it contains only safe chars.
    $remoteFile = "/tmp/dst-mapspinup-$([guid]::NewGuid().ToString('N')).json"
    $cmd = "echo $b64 | base64 -d > $remoteFile && sudo kubectl patch battlegroup $($r.info.Name) -n $($r.info.Ns) --type=json --patch-file $remoteFile 2>&1; rm -f $remoteFile"
    $out = Invoke-V6Ssh -Ip $r.ctx.vm.ip -Cmd $cmd -TimeoutSec 60
    $outText = (($out -join "`n")).Trim()

    $success = ($outText -match 'patched' -and $outText -notmatch 'error|Error|ERROR')
    $label = _Get-DuneSpinUpLabel -Map $Map
    return @{
        ok         = $success
        map        = $Map
        label      = $label
        minServers = $value
        enabled    = ($value -ge 1)
        raw        = $outText
        message    = if ($success) {
            if ($value -ge 1) { "$label will now keep at least 1 server warm (MinServers = 1)." }
            else              { "$label spin-up floor disabled (MinServers = 0)." }
        } else {
            "kubectl patch may have failed: $outText"
        }
    }
}
