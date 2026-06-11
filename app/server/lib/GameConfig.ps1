# GameConfig lib - section-aware visual editor for UserGame.ini + UserEngine.ini.
#
# Reads the LIVE INI files inside the battlegroup PVC (same files FileBrowser
# exposes under /files/UserSettings/), NOT the setup templates under
# /home/dune/.dune/download/scripts/setup/config/ which are only used at
# first-boot provisioning.
#
# WRITE MODEL (DST-managed block):
#   UE5 reads these files top-to-bottom with last-key-wins semantics. DST owns a
#   single marker-delimited block at the BOTTOM of each file. Whenever DST changes
#   ANY key in a section, the ENTIRE section (all its keys, including array +/-
#   lines and values DST does not recognise) is relocated into the DST block and
#   removed from the body, so there is exactly one copy and DST is the sole author
#   of that section going forward. Structure (comments, array lines, complex
#   single-line values) is preserved verbatim. Duplicate scalar keys are collapsed
#   to the last-wins value. Any pre-existing dune-admin managed block is migrated
#   (adopted) into the DST block and its markers removed. If a BEGIN marker is
#   found without a matching END the writer refuses to touch the file (data-loss
#   guard). The file is backed up server-side before every write.

# -----------------------------------------------------------------------------
# DST managed-block markers. ASCII ONLY (dune-admin used a non-ASCII em-dash that
# mangles to mojibake under CP1252 round-trips).
# -----------------------------------------------------------------------------
$script:DstManagedBegin = '; ===== Dune Server Tool (DST) managed section BEGIN - do not hand-edit between these markers ====='
$script:DstManagedEnd   = '; ===== Dune Server Tool (DST) managed section END ====='
# Legacy markers we migrate FROM (matched by stable ASCII prefix, mojibake tail ignored).
$script:DuneAdminBeginPrefix = '; >>>>> dune-admin managed section BEGIN'
$script:DuneAdminEndPrefix   = '; <<<<< dune-admin managed section END'

# -----------------------------------------------------------------------------
# Schema. Flat list of fields; each carries the real INI Section + File so the
# writer can place it correctly. Grouped into categories for the UI.
# Type: float | int | bool (True/False) | bool01 (1/0) | boolLower (true/false)
#       | string | select(Options)
# -----------------------------------------------------------------------------
$script:DuneGcSecGame      = '/Script/DuneSandbox.DuneGameMode'
$script:DuneGcSecStorm     = '/Script/DuneSandbox.SandStormConfig'
$script:DuneGcSecBuilding  = '/Script/DuneSandbox.BuildingSettings'
$script:DuneGcSecInventory = '/Script/DuneSandbox.InventorySystemSettings'
$script:DuneGcSecPvP       = '/Script/DuneSandbox.PvpPveSettings'
$script:DuneGcSecSecurity  = '/Script/DuneSandbox.SecurityZonesSubsystem'
$script:DuneGcSecSpice     = '/Script/DuneSandbox.SpiceHarvestingSystem'
$script:DuneGcSecTaxation  = '/Script/DuneSandbox.TaxationSettings'
$script:DuneGcSecSandworm  = '/Script/DuneSandbox.SandwormSettings'
$script:DuneGcSecDurab     = '/DeteriorationSystem.ItemDeteriorationConstants'
$script:DuneGcSecGuilds    = '/Script/DuneSandbox.GuildSettings'
$script:DuneGcSecOnline    = '/Script/DuneSandbox.PlayerOnlineStateSettings'
$script:DuneGcSecConsole   = 'ConsoleVariables'
$script:DuneGcSecUrl       = 'URL'

# Category display order (UI renders in this order; unknown categories appended).
$script:DuneGameConfigCategoryOrder = @(
    'Server Identity','Network','Survival','Progression','Harvesting',
    'Resources & Economy','Building','Inventory','Guilds & Economy',
    'Storm Cycle','PvP & Security','Spice','Taxation','Sandworm','Vehicles'
)

$script:DuneGameConfigSchema = @(
    # --- Server Identity (engine ConsoleVariables) ---
    @{ Section=$script:DuneGcSecConsole; Key='Bgd.ServerDisplayName'; File='engine'; Type='string'; Quoted=$true; Wide=$true; Default=''; Label='Server Display Name'; Help='Name shown to players for every Sietch in the battlegroup.'; Category='Server Identity'; Placeholder='Not set (uses world name)' }
    @{ Section=$script:DuneGcSecConsole; Key='Bgd.ServerLoginPassword'; File='engine'; Type='string'; Quoted=$true; Wide=$true; Default=''; Label='Server Login Password'; Help='Blank = no password. Applies to every Sietch in the battlegroup.'; Category='Server Identity'; Placeholder='No password' }

    # --- Network (engine URL) ---
    @{ Section=$script:DuneGcSecUrl; Key='Port'; File='engine'; Type='int'; Min=1024; Max=65535; Default='7777'; Label='Game Port (starting)'; Help='Starting player port; each server uses the next free port.'; Category='Network' }
    @{ Section=$script:DuneGcSecUrl; Key='IGWPort'; File='engine'; Type='int'; Min=1024; Max=65535; Default='7780'; Label='IGW Port (starting)'; Help='Starting inter-server port; must not overlap the game port range.'; Category='Network' }

    # --- Survival ---
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalHealthMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Global Health Multiplier'; Help='Scales the health pool of all entities (players + NPCs).'; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalDamageToNpcsMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Damage to NPCs Multiplier'; Help='Scales damage dealt to NPCs.'; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalDamageToPlayersMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Damage to Players Multiplier'; Help='Scales damage dealt to players.'; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_WaterConsumptionRate'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Water Consumption Rate'; Help='How quickly players consume water.'; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_WaterConsumptionInStormMultiplier'; File='game'; Type='float'; Min=0; Default='2.0'; Label='Water Consumption in Storm'; Help='Additional water drain during sandstorms.'; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_PlayerStartingWater'; File='game'; Type='float'; Min=0; Default='100.0'; Label='Player Starting Water'; Help='Water amount when a player spawns.'; Category='Survival' }
    @{ Section=$script:DuneGcSecOnline; Key='m_DefaultReconnectGracePeriodSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Reconnect Grace Period'; Help="Seconds a player's corpse persists after disconnect."; Category='Survival' }
    @{ Section=$script:DuneGcSecDurab; Key='m_ItemDurabilityLossMultiplier'; File='game'; Type='float'; Min=0; Max=10; Default='1.0'; Label='Item Durability Loss Multiplier'; Help='Scales durability loss for all items. 0 = off.'; Category='Survival' }
    @{ Section=$script:DuneGcSecDurab; Key='UpdateRateInSeconds'; File='game'; Type='float'; Min=0; Max=10; Unit='sec'; Default='1.0'; Label='Item Decay Rate'; Help='Deterioration tick rate. 0 = off, 1-10 typical.'; Category='Survival' }

    # --- Progression ---
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalXPMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='XP Multiplier'; Help='Scales XP gained from all sources.'; Category='Progression' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalProgressionSpeedMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Progression Speed Multiplier'; Help='Scales overall progression speed.'; Category='Progression' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalFameMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Fame Multiplier'; Help='Scales fame gained from all sources.'; Category='Progression' }

    # --- Harvesting ---
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalHarvestAmountMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Harvest Amount Multiplier'; Help='Scales resource yield from harvesting.'; Category='Harvesting' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalHarvestHealthMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Harvest Health Multiplier'; Help='Scales node health (how long nodes last).'; Category='Harvesting' }

    # --- Resources & Economy (engine ConsoleVariables) ---
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Global Mining Multiplier'; Help='Scales hand-mining resource output.'; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalVehicleMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Mining Multiplier'; Help='Scales vehicle-mining resource output.'; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='SecurityZones.PvpResourceMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='PvP Resource Multiplier'; Help='Resource yield multiplier inside PvP zones.'; Category='Resources & Economy' }

    # --- Building ---
    @{ Section=$script:DuneGcSecBuilding; Key='m_MaxNumLandclaimSegments'; File='game'; Type='int'; Min=1; Default='100'; Label='Max Landclaim Segments'; Help='Maximum territory claim segments. Also needs client-side apply.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='int'; Min=0; Default='5'; Label='Blueprint Max Extensions'; Help='Maximum blueprint extension slots.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupMaxExtensions'; File='game'; Type='int'; Min=0; Default='2'; Label='Base Backup Max Extensions'; Help='Backup (reconstruction) extension slots per base.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='bool'; Default='False'; Label='Building Restriction Limits'; Help='Enforce building restriction limits. Also needs client-side apply.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_GlobalBuildingDamageMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Damage Multiplier'; Help='Scales damage dealt to player buildings.'; Category='Building' }

    # --- Inventory ---
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingSize'; File='game'; Type='int'; Min=1; Default='40'; Label='Starting Inventory Slots'; Help='Number of inventory slots at spawn.'; Category='Inventory' }
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingVolumeCapacity'; File='game'; Type='float'; Min=0; Default='225.0'; Label='Starting Inventory Volume'; Help='Volume capacity of the starting inventory.'; Category='Inventory' }
    @{ Section=$script:DuneGcSecGame; Key='m_InventoryWeightMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Inventory Weight Multiplier'; Help='Scales item weight across all inventories.'; Category='Inventory' }

    # --- Guilds & Economy ---
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildMembersAllowed'; File='game'; Type='int'; Min=1; Default='32'; Label='Max Guild Members'; Help='Maximum players per guild.'; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildsAllowed'; File='game'; Type='int'; Min=1; Default='3'; Label='Max Guilds per Player'; Help='How many guilds a player may belong to.'; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_GuildCreationCost'; File='game'; Type='int'; Min=0; Unit='Solari'; Default='1000'; Label='Guild Creation Cost'; Help='Solari required to create a guild.'; Category='Guilds & Economy' }

    # --- Storm Cycle ---
    @{ Section=$script:DuneGcSecStorm; Key='m_CycleDurationInDays'; File='game'; Type='int'; Min=1; Unit='days'; Default='7'; Label='Coriolis Cycle Length'; Help='In-game days between Coriolis storm / season events.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecGame; Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='bool'; Default='True'; Label='Coriolis Auto-Spawn'; Help='Whether Coriolis storms spawn automatically.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecGame; Key='m_bIsDbWipeEnabled'; File='game'; Type='bool'; Default='False'; Label='Database Wipe on Season End'; Help='Wipe the database when the season ends.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm'; Help='Enable rolling sandstorms.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm Treasure Spawns'; Help='Spawn treasure during sandstorms.'; Category='Storm Cycle' }

    # --- PvP & Security ---
    @{ Section=$script:DuneGcSecPvP; Key='m_bShouldForceEnablePvpOnAllPartitions'; File='game'; Type='bool'; Default='False'; Label='Force PvP on All Partitions'; Help='Override per-partition PvP settings (PvP everywhere).'; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecSecurity; Key='m_bAreSecurityZonesEnabled'; File='game'; Type='bool'; Default='True'; Label='Security Zones Enabled'; Help='Off = PvP and ability usage allowed everywhere.'; Category='PvP & Security' }

    # --- Spice ---
    @{ Section=$script:DuneGcSecSpice; Key='m_PrimeRateInSeconds'; File='game'; Type='float'; Min=0; Unit='sec'; Default='30.0'; Label='Spice Prime Rate'; Help='Seconds between spice node priming ticks.'; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_NodeValueToSpiceResourceRatio'; File='game'; Type='float'; Min=0; Default='10.0'; Label='Node Value to Spice Ratio'; Help='Converts node value into harvestable spice.'; Category='Spice' }

    # --- Taxation ---
    @{ Section=$script:DuneGcSecTaxation; Key='m_bTaxationEnabled'; File='game'; Type='bool'; Default='True'; Label='Taxation Enabled'; Help='Whether the taxation system is active.'; Category='Taxation' }
    @{ Section=$script:DuneGcSecTaxation; Key='m_TaxationCycleLengthSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='86400'; Label='Taxation Cycle'; Help='Seconds between taxation collection cycles.'; Category='Taxation' }

    # --- Sandworm (engine cvars + game settings) ---
    @{ Section=$script:DuneGcSecConsole; Key='sandworm.dune.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandworm Enabled'; Help='Master toggle for the sandworm.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormDangerZonesEnabled'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Danger Zones'; Help='Enable danger zones where the sandworm can attack.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormCollisionInteraction'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Pushes Vehicles'; Help='Sandworm can push / damage vehicles.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnExit'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='5.0'; Label='Invulnerability on Vehicle Exit'; Help='Seconds of sandworm invulnerability after exiting a vehicle.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnServerRestart'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='60.0'; Label='Invulnerability on Server Restart'; Help='Seconds of sandworm invulnerability after a server restart.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='WormDetectionDistance'; File='game'; Type='float'; Min=0; Default='5000.0'; Label='Worm Detection Distance'; Help='Distance at which worms detect players.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinWormSpawnInternal'; File='game'; Type='float'; Min=0; Unit='sec'; Default='300.0'; Label='Min Worm Spawn Interval'; Help='Minimum seconds between worm spawns.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_SandwormQuicksandSpeedModifier'; File='game'; Type='float'; Min=0; Default='0.5'; Label='Quicksand Speed Modifier'; Help='Movement speed multiplier in quicksand.'; Category='Sandworm' }

    # --- Vehicles (engine cvars) ---
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleDurabilityDamageMultiplier'; File='engine'; Type='float'; Min=0; Max=10; Default='1.0'; Label='Vehicle Durability Damage'; Help='Durability damage multiplier for vehicles. 0 = off.'; Category='Vehicles' }

    # --- Parity additions (dune-admin serverSettingsSchema) ---
    # Building
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingDecayRateMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Decay Rate Multiplier'; Help='Scales how fast player buildings decay over time.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='bEnableBuildingStability'; File='game'; Type='bool'; Default='True'; Label='Enable Building Stability'; Help='Whether structural / stability rules apply to player constructions.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupExtensions'; File='game'; Type='int'; Min=0; Unit='slots'; Default='2'; Label='Base Backup Extensions'; Help='Default number of backup extension slots per base.'; Category='Building' }
    # Guilds & Economy
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxPermissionsPerActor'; File='game'; Type='int'; Min=0; Unit='rules'; Default='20'; Label='Max Permissions per Actor'; Help='Maximum number of permission rules per actor / structure.'; Category='Guilds & Economy' }
    # Storm Cycle
    @{ Section=$script:DuneGcSecStorm; Key='m_StormCycleDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='3600'; Label='Storm Cycle Duration'; Help='Total wall-clock duration of one full storm cycle (calm + storm + warning).'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='900'; Label='Storm Duration'; Help='How long the active sandstorm phase lasts per cycle.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormWarningDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Storm Warning Duration'; Help='Warning period (dust / audio cues) before the active storm phase begins.'; Category='Storm Cycle' }
    # PvP & Security
    @{ Section=$script:DuneGcSecPvP; Key='bPvPEnabled'; File='game'; Type='bool'; Default='False'; Label='PvP Enabled'; Help='Allow player-vs-player combat globally across the server.'; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecPvP; Key='bServerPVE'; File='game'; Type='bool'; Default='True'; Label='Server PvE Mode'; Help='Enables global PvE protection (inverse of PvP; both can be set independently).'; Category='PvP & Security' }
    # Spice
    @{ Section=$script:DuneGcSecSpice; Key='m_bSpawningActive'; File='game'; Type='bool'; Default='True'; Label='Spice Spawning Active'; Help='Master switch - whether spice nodes spawn on the map at all.'; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_bPlayerMustWitnessBloom'; File='game'; Type='bool'; Default='True'; Label='Player Must Witness Bloom'; Help='If true, a player must be present in the area for a spice bloom to register / count.'; Category='Spice' }
    # Taxation
    @{ Section=$script:DuneGcSecTaxation; Key='m_SpicePerHour'; File='game'; Type='int'; Min=0; Unit='spice/hr'; Default='100'; Label='Spice Yield per Hour'; Help='Base spice amount generated per hour per active spice field under taxation.'; Category='Taxation' }
    # Sandworm
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinDistanceBetweenSandworms'; File='game'; Type='float'; Min=0; Unit='UU'; Default='10000.0'; Label='Min Distance Between Sandworms'; Help='Minimum world-unit separation required between two simultaneously active sandworms.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_GiantWormMinimumPlayersOnSpiceField'; File='game'; Type='int'; Min=0; Unit='players'; Default='1'; Label='Giant Worm Min Players on Field'; Help='Minimum number of players on a spice field to trigger a giant sandworm spawn.'; Category='Sandworm' }
)

# -----------------------------------------------------------------------------
# Live INI paths inside the BG PVC (resolved via sudo glob, cached per session).
# Templates are the fallback used when no BG has been provisioned yet.
# -----------------------------------------------------------------------------
$script:DuneGameConfigLiveGlobGame   = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserGame.ini'
$script:DuneGameConfigLiveGlobEngine = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings/UserEngine.ini'
$script:DuneGameConfigTplGamePath    = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
$script:DuneGameConfigTplEnginePath  = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'
$script:DuneGameConfigResolvedGame   = $null
$script:DuneGameConfigResolvedEngine = $null

# =============================================================================
# INI ENGINE (pure functions, no SSH - unit-testable)
# =============================================================================

# Parse one body line; returns @{ key; isArray } or $null for comments/blank/headers.
function Get-DuneIniLineKey {
    param([string]$Line)
    if ($null -eq $Line) { return $null }
    $t = $Line.Trim()
    if (-not $t) { return $null }
    if ($t.StartsWith(';')) { return $null }
    if ($t.StartsWith('[')) { return $null }
    $isArray = $false
    $core = $t
    if ($t.StartsWith('+') -or $t.StartsWith('-')) { $isArray = $true; $core = $t.Substring(1) }
    $eq = $core.IndexOf('=')
    if ($eq -lt 0) { return $null }
    $key = $core.Substring(0, $eq).Trim()
    if (-not $key) { return $null }
    return @{ key = $key; isArray = $isArray }
}

function Get-DuneIniLineValue {
    param([string]$Line)
    $t = $Line.Trim()
    if ($t.StartsWith('+') -or $t.StartsWith('-')) { $t = $t.Substring(1) }
    $eq = $t.IndexOf('=')
    if ($eq -lt 0) { return '' }
    return $t.Substring($eq + 1)
}

function Test-DuneIniHeader {
    param([string]$Line)
    $t = $Line.Trim()
    return ($t.StartsWith('[') -and $t.EndsWith(']') -and $t.Length -ge 3)
}

# Parse raw INI into an ordered document model:
#   @{ preamble=[List]; sections=[List of @{name;header;body=[List];managed}]; malformed=$bool; hadManaged=$bool }
function ConvertFrom-DuneIniDoc {
    param([string]$Raw)
    $preamble = New-Object 'System.Collections.Generic.List[string]'
    $sections = New-Object 'System.Collections.Generic.List[object]'
    $cur = $null
    $inManaged = $false
    $sawManagedHeaderSection = $false
    $hadManaged = $false
    $malformed = $false

    if ($null -eq $Raw) { $Raw = '' }
    $lines = $Raw -replace "`r", '' -split "`n"
    foreach ($line in $lines) {
        $t = $line.Trim()

        # Marker detection. END is checked BEFORE BEGIN because the DST begin and
        # end lines share a long common prefix; matching END first prevents the
        # end line from being mistaken for a new begin.
        $isDstMarker = $t.StartsWith('; ===== Dune Server Tool')
        if (($isDstMarker -and $t -match 'END') -or $t.StartsWith($script:DuneAdminEndPrefix)) {
            $inManaged = $false
            continue
        }
        if (($isDstMarker -and $t -match 'BEGIN') -or $t.StartsWith($script:DuneAdminBeginPrefix)) {
            $inManaged = $true; $hadManaged = $true; $sawManagedHeaderSection = $false
            continue
        }

        if (Test-DuneIniHeader $line) {
            $name = $t.Substring(1, $t.Length - 2)
            $cur = @{ name = $name; header = $t; body = (New-Object 'System.Collections.Generic.List[string]'); managed = $inManaged }
            $sections.Add($cur)
            if ($inManaged) { $sawManagedHeaderSection = $true }
            continue
        }

        if ($inManaged -and -not $sawManagedHeaderSection) {
            # dune-admin block header comments before the first managed section: drop.
            continue
        }
        if ($null -ne $cur) {
            $cur.body.Add($line)
        } else {
            $preamble.Add($line)
        }
    }

    if ($inManaged) { $malformed = $true }
    return @{ preamble = $preamble; sections = $sections; malformed = $malformed; hadManaged = $hadManaged }
}

# Collapse a section's combined body lines: keep all comments / blanks / array
# (+/-) lines verbatim and in order; for duplicate SCALAR keys keep one line at
# the FIRST position carrying the LAST (last-wins) value.
function Merge-DuneSectionBody {
    param([System.Collections.Generic.List[string]]$Lines)
    $lastVal = @{}
    $firstIdx = @{}
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $info = Get-DuneIniLineKey $Lines[$i]
        if ($info -and -not $info.isArray) {
            $k = $info.key
            $lastVal[$k] = (Get-DuneIniLineValue $Lines[$i])
            if (-not $firstIdx.ContainsKey($k)) { $firstIdx[$k] = $i }
        }
    }
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $info = Get-DuneIniLineKey $Lines[$i]
        if ($info -and -not $info.isArray) {
            $k = $info.key
            if ($firstIdx[$k] -eq $i) { $out.Add("$k=$($lastVal[$k])") }
            # else: duplicate scalar, drop
        } else {
            $out.Add($Lines[$i])
        }
    }
    return ,$out
}

function Format-DuneIniValue {
    param([string]$Key, $Value, [hashtable]$QuotedKeys)
    $s = "$Value"
    if ($QuotedKeys -and $QuotedKeys.ContainsKey($Key)) {
        if ($s -eq '') { return '""' }
        if (-not $s.StartsWith('"')) { return '"' + $s + '"' }
    }
    return $s
}

# Set (or append) a scalar key within a section body list.
function Set-DuneScalarInBody {
    param([System.Collections.Generic.List[string]]$Body, [string]$Key, [string]$Formatted)
    for ($i = 0; $i -lt $Body.Count; $i++) {
        $info = Get-DuneIniLineKey $Body[$i]
        if ($info -and -not $info.isArray -and $info.key -eq $Key) {
            $Body[$i] = "$Key=$Formatted"
            return
        }
    }
    $Body.Add("$Key=$Formatted")
}

function Remove-DuneTrailingBlankLines {
    param([System.Collections.Generic.List[string]]$Lines)
    while ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim() -eq '') {
        $Lines.RemoveAt($Lines.Count - 1)
    }
}

# Core writer: take raw + a list of @{section;key;value} updates, return new raw.
# Throws on a malformed managed block (BEGIN without END).
function ConvertTo-DuneIniManaged {
    param(
        [string]$Raw,
        [object[]]$Updates,
        [hashtable]$QuotedKeys
    )
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    if ($doc.malformed) {
        throw 'Managed block is malformed (BEGIN marker without matching END). Refusing to write to avoid data loss.'
    }
    if (-not $QuotedKeys) { $QuotedKeys = @{} }
    if (-not $Updates) { $Updates = @() }

    # Determine managed target section names: every section already inside a
    # managed block (migrate/adopt) PLUS every section touched by an update.
    $targetNames = New-Object 'System.Collections.Generic.List[string]'
    $targetSet = @{}
    foreach ($s in $doc.sections) {
        if ($s.managed -and -not $targetSet.ContainsKey($s.name)) { $targetSet[$s.name] = $true; $targetNames.Add($s.name) }
    }
    foreach ($u in $Updates) {
        $n = "$($u.section)"
        if ($n -and -not $targetSet.ContainsKey($n)) { $targetSet[$n] = $true; $targetNames.Add($n) }
    }

    # Build managed sections by absorbing ALL occurrences of each target name,
    # in file order, then removing them from the body.
    $managed = New-Object 'System.Collections.Generic.List[object]'
    $managedByName = @{}
    foreach ($name in $targetNames) {
        $combined = New-Object 'System.Collections.Generic.List[string]'
        foreach ($s in $doc.sections) {
            if ($s.name -eq $name) {
                foreach ($l in $s.body) { $combined.Add($l) }
            }
        }
        $merged = Merge-DuneSectionBody -Lines $combined
        $entry = @{ name = $name; body = $merged }
        $managed.Add($entry)
        $managedByName[$name] = $entry
    }
    # Remaining body sections = those whose name is NOT a managed target.
    $remaining = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in $doc.sections) {
        if (-not $targetSet.ContainsKey($s.name)) { $remaining.Add($s) }
    }

    # Apply updates into their managed sections.
    foreach ($u in $Updates) {
        $n = "$($u.section)"
        if (-not $n) { continue }
        $entry = $managedByName[$n]
        if (-not $entry) {
            $entry = @{ name = $n; body = (New-Object 'System.Collections.Generic.List[string]') }
            $managed.Add($entry); $managedByName[$n] = $entry
        }
        $fmt = Format-DuneIniValue -Key "$($u.key)" -Value $u.value -QuotedKeys $QuotedKeys
        Set-DuneScalarInBody -Body $entry.body -Key "$($u.key)" -Formatted $fmt
    }

    # Render body (preamble + remaining sections).
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $doc.preamble) { $out.Add($l) }
    foreach ($s in $remaining) {
        $out.Add($s.header)
        foreach ($l in $s.body) { $out.Add($l) }
    }
    Remove-DuneTrailingBlankLines -Lines $out

    if ($managed.Count -gt 0) {
        $sorted = $managed | Sort-Object { $_.name }
        $out.Add('')
        $out.Add('')
        $out.Add($script:DstManagedBegin)
        $out.Add('; Managed by DST - Dune Server Tool. UE5 reads top-to-bottom with last-key-wins,')
        $out.Add('; so values in this block override anything above. Do not hand-edit.')
        $out.Add('; Last write: ' + ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')))
        $out.Add(';')
        foreach ($s in $sorted) {
            $body = $s.body
            Remove-DuneTrailingBlankLines -Lines $body
            $out.Add('')
            $out.Add('[' + $s.name + ']')
            foreach ($l in $body) { $out.Add($l) }
        }
        $out.Add('')
        $out.Add($script:DstManagedEnd)
    }
    return (($out -join "`n") + "`n")
}

# -----------------------------------------------------------------------------
# Read-side projection for the API: list every section + its keys, mark managed,
# and compute the effective (last-wins) value for each section||key.
# -----------------------------------------------------------------------------
function ConvertTo-DuneIniSectionsApi {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $sections = @($doc.sections | ForEach-Object {
        $s = $_
        $keys = New-Object 'System.Collections.Generic.List[object]'
        foreach ($l in $s.body) {
            $info = Get-DuneIniLineKey $l
            if ($info) {
                $keys.Add(@{
                    key     = $info.key
                    value   = (Get-DuneIniLineValue $l).Trim()
                    isArray = [bool]$info.isArray
                    raw     = $l
                })
            }
        }
        @{ name = $s.name; managed = [bool]$s.managed; keys = $keys.ToArray() }
    })
    return $sections
}

# effective[section||key] = last-wins value (managed wins because it is last).
function Get-DuneIniEffective {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $eff = @{}
    foreach ($s in $doc.sections) {
        foreach ($l in $s.body) {
            $info = Get-DuneIniLineKey $l
            if ($info -and -not $info.isArray) {
                $eff["$($s.name)||$($info.key)"] = (Get-DuneIniLineValue $l).Trim()
            }
        }
    }
    return $eff
}

function Get-DuneIniManagedSectionNames {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $names = @{}
    foreach ($s in $doc.sections) { if ($s.managed) { $names[$s.name] = $true } }
    return @($names.Keys)
}

# =============================================================================
# VM CONTEXT + PATH RESOLUTION (SSH plumbing - unchanged behaviour)
# =============================================================================
function Get-DuneGameConfigContext {
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='SSH helper unavailable (Db-Postgres.ps1 not loaded).' }
    }
    if (-not (Get-Command Get-DuneVmStatus -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='VM status helper unavailable.' }
    }
    $vm = Get-DuneVmStatus
    if (-not $vm.exists) { return @{ ok=$false; status=503; message='VM does not exist on this host.' } }
    if (-not $vm.running) { return @{ ok=$false; status=503; message='VM is not running. Start it before editing game config.' } }
    if (-not $vm.ip) { return @{ ok=$false; status=503; message='VM is running but has no IP yet - wait for it to finish booting.' } }
    return @{ ok=$true; ip=$vm.ip; vm=$vm }
}

function Resolve-DuneGameConfigPaths {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:DuneGameConfigResolvedGame -and $script:DuneGameConfigResolvedEngine) {
        return @{ game = $script:DuneGameConfigResolvedGame; engine = $script:DuneGameConfigResolvedEngine; source = 'cache' }
    }
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

# =============================================================================
# READ + WRITE (SSH)
# =============================================================================
function Get-DuneGameConfig {
    param([string]$Ip)
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
    $gameOut   = Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.game)' 2>/dev/null"
    $engineOut = Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.engine)' 2>/dev/null"
    $gameRaw   = ($gameOut   -join "`n")
    $engineRaw = ($engineOut -join "`n")
    return @{
        source = $paths.source
        game = @{
            path            = $paths.game
            raw             = $gameRaw
            sections        = (ConvertTo-DuneIniSectionsApi -Raw $gameRaw)
            effective       = (Get-DuneIniEffective -Raw $gameRaw)
            managedSections = (Get-DuneIniManagedSectionNames -Raw $gameRaw)
        }
        engine = @{
            path            = $paths.engine
            raw             = $engineRaw
            sections        = (ConvertTo-DuneIniSectionsApi -Raw $engineRaw)
            effective       = (Get-DuneIniEffective -Raw $engineRaw)
            managedSections = (Get-DuneIniManagedSectionNames -Raw $engineRaw)
        }
    }
}

# Quoted-key lookup for the writer (string keys that must be wrapped in quotes).
function Get-DuneGameConfigQuotedKeys {
    $q = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.ContainsKey('Quoted') -and $f.Quoted) { $q[$f.Key] = $true }
    }
    return $q
}

# Save structured updates. $Updates = array of @{ file; section; key; value }.
# Backs the file up server-side before writing.
function Save-DuneGameConfig {
    param([string]$Ip, [object[]]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return }
    $paths  = Resolve-DuneGameConfigPaths -Ip $Ip
    $quoted = Get-DuneGameConfigQuotedKeys
    $ts     = (Get-Date).ToString('yyyyMMddHHmmss')

    $byFile = @{ game = (New-Object 'System.Collections.Generic.List[object]'); engine = (New-Object 'System.Collections.Generic.List[object]') }
    foreach ($u in $Updates) {
        $f = "$($u.file)"
        if ($byFile.ContainsKey($f)) { $byFile[$f].Add($u) }
    }

    foreach ($f in @('game','engine')) {
        if ($byFile[$f].Count -eq 0) { continue }
        $path = if ($f -eq 'game') { $paths.game } else { $paths.engine }
        $raw  = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$path' 2>/dev/null") -join "`n"
        $new  = ConvertTo-DuneIniManaged -Raw $raw -Updates $byFile[$f].ToArray() -QuotedKeys $quoted
        # Backup before write (best-effort; ignore failure of cp on template path).
        Invoke-V6Ssh -Ip $Ip -Cmd "sudo cp '$path' '$path.dstbak-$ts' 2>/dev/null" -TimeoutSec 20 | Out-Null
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
        Invoke-V6Ssh -Ip $Ip -Cmd "base64 -d | sudo tee '$path' > /dev/null" -StdinData $b64 -TimeoutSec 30 | Out-Null
    }
}

# =============================================================================
# SCHEMA API (grouped by category)
# =============================================================================
function Get-DuneGameConfigSchemaApi {
    $byCat = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        $cat = "$($f.Category)"
        if (-not $byCat.ContainsKey($cat)) { $byCat[$cat] = New-Object 'System.Collections.Generic.List[object]' }
        $field = @{
            section = $f.Section
            key     = $f.Key
            file    = $f.File
            type    = $f.Type
            label   = $f.Label
            default = [string]$f.Default
        }
        if ($f.ContainsKey('Help'))        { $field.help        = $f.Help }
        if ($f.ContainsKey('Unit'))        { $field.unit        = $f.Unit }
        if ($f.ContainsKey('Min'))         { $field.min         = $f.Min }
        if ($f.ContainsKey('Max'))         { $field.max         = $f.Max }
        if ($f.ContainsKey('Placeholder')) { $field.placeholder = $f.Placeholder }
        if ($f.ContainsKey('Wide'))        { $field.wide        = [bool]$f.Wide }
        if ($f.ContainsKey('Quoted'))      { $field.quoted      = [bool]$f.Quoted }
        if ($f.ContainsKey('Options')) {
            $field.options = @($f.Options | ForEach-Object { @{ value = $_.V; label = $_.L } })
        }
        $byCat[$cat].Add($field)
    }
    $ordered = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($cat in $script:DuneGameConfigCategoryOrder) {
        if ($byCat.ContainsKey($cat)) {
            $grp = @{ category = $cat; fields = $byCat[$cat].ToArray() }
            $ordered.Add($grp)
            $seen[$cat] = $true
        }
    }
    foreach ($cat in $byCat.Keys) {
        if (-not $seen.ContainsKey($cat)) {
            $grp = @{ category = $cat; fields = $byCat[$cat].ToArray() }
            $ordered.Add($grp)
        }
    }
    return $ordered.ToArray()
}
