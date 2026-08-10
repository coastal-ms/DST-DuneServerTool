[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\app\data\advanced-cvars.json')
)

$duneNamespace = '^(Dune|dw|Vehicle|Player|Sandworm|SandwormSubsystem|Hazard|Hydration|SpiceHarvesting|SafeZone|NPC|Dac|Abilities|JourneyStory|Journey|Deathstill|Landsraad|Contracts?|Loot|Inventory|Combat|Progression|SecurityZones|Sandstorm|Coriolis|Encounters?|Building|Crafting|Taxation|Guild|Exchange|Market|Respawn|Mnemonic|TechKnowledge|Bgd|Ornithopter|Sietch|Ai|AI)\.'

function Get-CvarGroup {
    param([string]$Key)
    if ($Key -match $duneNamespace) { return 'Dune gameplay' }
    if ($Key -match '^(r|Lumen|Nanite|Shadow|FX|Hair|Particles|SceneComponent|SmartGI|mutable|foliage)\.') { return 'Rendering & graphics' }
    if ($Key -match '^(au|ak|Audio)\.') { return 'Audio' }
    if ($Key -match '^(net|Network|Demo)\.') { return 'Network & replication' }
    if ($Key -match '^(p|Chaos|Physics)\.') { return 'Physics' }
    if ($Key -match '^(wp|Map|World|Landscape|Level)\.') { return 'World & streaming' }
    if ($Key -match '^(Slate|gui|UI|Settings)\.') { return 'UI & client' }
    if ($Key -match '^(gc|TaskGraph|Memory|Engine)\.') { return 'Runtime & memory' }
    return 'Other engine'
}

function Get-CvarRisk {
    param([string]$Key, [string]$Help)
    $text = "$Key $Help"
    if ($text -match '(?i)crash|fatal|disconnect|fault.?inject|duplicate|database|persistence|auth transfer|corrupt|bypass|forceenablepvp|developermode|playerprogressionunlock|overridechallengeroomrestriction|ignoreretraincost|dehydrationzonesenabled') {
        return 'critical'
    }
    if ($Key -match '^(net|p|Chaos|gc|TaskGraph|wp)\.' -or
        $text -match '(?i)replication|streaming|thread|memory|physics|tick.?rate|server') {
        return 'high'
    }
    if ($text -match '(?i)debug|draw|trace|log|profile|telemetry|editor') {
        return 'diagnostic'
    }
    return 'experimental'
}

$source = @(Get-Content -LiteralPath $InputPath -Raw -ErrorAction Stop |
    ConvertFrom-Json -ErrorAction Stop)
$seen = @{}
$catalog = foreach ($entry in $source) {
    $key = [string]$entry.key
    if ([string]::IsNullOrWhiteSpace($key) -or $key -match '\.(cpp|h|inl|so)$') { continue }
    $id = $key.ToLowerInvariant()
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true

    $help = ([string]$entry.help -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '').Trim()
    [ordered]@{
        key    = $key
        label  = $key
        help   = $help
        group  = Get-CvarGroup -Key $key
        risk   = Get-CvarRisk -Key $key -Help $help
        source = if ($key -match $duneNamespace) { 'Dune' } else { 'Engine' }
        scope  = 'Unknown'
        status = 'Unconfirmed'
    }
}

$target = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}
$json = $catalog | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($target, $json + "`n", (New-Object Text.UTF8Encoding($false)))
Write-Host "Wrote $($catalog.Count) CVars to $target"
