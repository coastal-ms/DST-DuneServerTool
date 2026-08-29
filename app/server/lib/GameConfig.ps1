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
#   to the last-wins value. Any pre-existing the reference implementation managed block is migrated
#   (adopted) into the DST block and its markers removed. If a BEGIN marker is
#   found without a matching END the writer refuses to touch the file (data-loss
#   guard). The file is backed up server-side before every write.

# -----------------------------------------------------------------------------
# DST managed-block markers. ASCII ONLY (the reference implementation used a non-ASCII em-dash that
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
$script:DuneGcSecCoriolis   = '/Script/DuneSandbox.CoriolisSubsystem'
$script:DuneGcSecHazards    = '/Script/DuneSandbox.HazardsSettings'
$script:DuneGcSecPermission = '/Script/DuneSandbox.PermissionSettings'
$script:DuneGcSecConsole   = 'ConsoleVariables'
$script:DuneGcSecUrl       = 'URL'
$script:DuneGcSecLandsraad = '/Script/DuneSandbox.LandsraadSettings'
$script:DuneGcSecHydration = '/Script/DuneSandbox.HydrationSubsystem'
$script:DuneGcSecGameBase  = '/Script/DuneSandbox.DuneSandboxGameModeBase'
$script:DuneGcSecSpiceAddict = '/Script/DuneSandbox.SpiceAddictionSubsystem'
$script:DuneGcSecTimeOfDay = '/Script/DuneSandbox.TimeOfDaySettings'
$script:DuneGcSecRespawn   = '/Script/DuneSandbox.RespawnSettings'
$script:DuneGcSecEncounters = '/Script/DuneSandbox.EncountersSubsystem'
$script:DuneGcSecContracts = '/Script/DuneSandbox.ContractsSubsystem'
$script:DuneGcSecCrafting  = '/Script/DuneSandbox.CraftingSettings'
$script:DuneGcSecTechKnowledge = '/Script/DuneSandbox.TechKnowledgeSettings'

function Test-DuneGameConfigRawTargetBlocked {
    param(
        [string]$File,
        [string]$Section,
        [string]$Key
    )
    $canonicalKey = ([string]$Key).Trim() -replace '^[+-]+', ''
    return (
        ([string]$File).Trim() -ieq 'game' -and
        ([string]$Section).Trim() -ieq $script:DuneGcSecTimeOfDay -and
        $canonicalKey -ieq 'm_StartTime'
    )
}

function Test-DuneGameConfigRawTextSafe {
    param([AllowEmptyString()][string]$Value)
    return $null -ne $Value -and $Value.IndexOf([char]0) -lt 0 -and $Value -notmatch '[\r\n]'
}

function Test-DuneGameConfigArrayLineMatchesKey {
    param(
        [string]$Line,
        [string]$Key
    )
    if (-not $Key -or -not $Line -or
        -not (Test-DuneGameConfigRawTextSafe -Value $Key) -or
        -not (Test-DuneGameConfigRawTextSafe -Value $Line)) {
        return $false
    }
    return ([string]$Line).Trim() -match "^[+-]$([regex]::Escape($Key))="
}

$script:DuneTwilightCandidateHours = @('17.0', '18.0', '19.0')

function Get-DuneTwilightLockExperiment {
    return [ordered]@{
        available = $true
        evidenceStatus = 'candidate-only'
        candidates = @($script:DuneTwilightCandidateHours | ForEach-Object {
            [ordered]@{
                value = $_
                label = "Candidate $_"
            }
        })
        clientApply = [ordered]@{
            available = $false
            reason = 'm_StartTime client behavior is unverified, so DST will not write a client override.'
        }
        restartRequired = $true
        minimumObservationMinutes = 30
    }
}

function Test-DuneTwilightCandidateHour {
    param($Value)
    $text = "$Value".Trim()
    if (-not (Test-DuneGameConfigRawTextSafe -Value $text)) { return $false }
    $number = 0.0
    if (-not [double]::TryParse(
        $text,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $false
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $false }
    return $text -in $script:DuneTwilightCandidateHours
}

function Resolve-DuneTwilightLiveGameConfigTarget {
    param([Parameter(Mandatory)][string]$Ip)
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
    $liveGamePattern = '^/var/lib/rancher/k3s/storage/[^/]+/Saved/UserSettings/UserGame\.ini$'
    if ("$($paths.source)" -ne 'live' -or "$($paths.game)" -notmatch $liveGamePattern) {
        throw 'Twilight experiment requires a live battlegroup UserGame.ini; setup templates are never modified.'
    }
    return $paths
}

function Read-DuneTwilightLiveGameConfig {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Path
    )
    $raw = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$Path' 2>/dev/null") -join "`n")
    if ([string]::IsNullOrWhiteSpace($raw) -or $raw.TrimStart().StartsWith('ERROR:')) {
        throw 'Twilight experiment could not verify the live UserGame.ini after writing it.'
    }
    return $raw
}

function Assert-DuneTwilightStageReadback {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Candidate
    )
    $effective = Get-DuneIniEffective -Raw $Raw
    $prefix = "$script:DuneGcSecTimeOfDay||"
    if ("$($effective["${prefix}m_StartTime"])" -ne $Candidate -or
        "$($effective["${prefix}m_bTimeOfDayEnabled"])" -ine 'False') {
        throw 'Twilight experiment write verification failed; the live UserGame.ini does not contain the exact staged values.'
    }
}

function Assert-DuneTwilightRestoreReadback {
    param([Parameter(Mandatory)][string]$Raw)
    $effective = Get-DuneIniEffective -Raw $Raw
    $prefix = "$script:DuneGcSecTimeOfDay||"
    if ($effective.ContainsKey("${prefix}m_StartTime") -or
        $effective.ContainsKey("${prefix}m_bTimeOfDayEnabled")) {
        throw 'Normal-cycle restore verification failed; a DST-managed twilight override remains in the live UserGame.ini.'
    }
}

function Invoke-DuneTwilightLockStage {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)]$Candidate
    )
    $candidateText = "$Candidate".Trim()
    if (-not (Test-DuneTwilightCandidateHour -Value $candidateText)) {
        throw "Candidate must be one of: $($script:DuneTwilightCandidateHours -join ', ')."
    }
    $paths = Resolve-DuneTwilightLiveGameConfigTarget -Ip $Ip
    $backup = Backup-DuneGameConfig -Ip $Ip -ResolvedPaths $paths
    $gameBackup = @($backup.files | Where-Object file -eq 'game' | Select-Object -First 1)
    if ($gameBackup.Count -ne 1 -or -not $gameBackup[0].ok) {
        throw 'Twilight experiment was not staged because the server Game.ini backup could not be verified.'
    }
    Save-DuneGameConfigLocked -Ip $Ip -ResolvedPaths $paths -Updates @(
        @{
            file = 'game'
            section = $script:DuneGcSecTimeOfDay
            key = 'm_StartTime'
            value = $candidateText
            remove = $false
        },
        @{
            file = 'game'
            section = $script:DuneGcSecTimeOfDay
            key = 'm_bTimeOfDayEnabled'
            value = 'False'
            remove = $false
        }
    )
    $readback = Read-DuneTwilightLiveGameConfig -Ip $Ip -Path $paths.game
    Assert-DuneTwilightStageReadback -Raw $readback -Candidate $candidateText
    return [ordered]@{
        ok = $true
        staged = $true
        candidate = $candidateText
        backup = $gameBackup[0].backup
        restartRequired = $true
        clientApplied = $false
        message = 'Candidate staged on the server. Apply INIs & restart to begin the field experiment.'
    }
}

function Invoke-DuneTwilightLockRestore {
    param([Parameter(Mandatory)][string]$Ip)
    $paths = Resolve-DuneTwilightLiveGameConfigTarget -Ip $Ip
    $backup = Backup-DuneGameConfig -Ip $Ip -ResolvedPaths $paths
    $gameBackup = @($backup.files | Where-Object file -eq 'game' | Select-Object -First 1)
    if ($gameBackup.Count -ne 1 -or -not $gameBackup[0].ok) {
        throw 'Normal cycle was not restored because the server Game.ini backup could not be verified.'
    }
    Save-DuneGameConfigLocked -Ip $Ip -ResolvedPaths $paths -Updates @(
        @{
            file = 'game'
            section = $script:DuneGcSecTimeOfDay
            key = 'm_StartTime'
            value = ''
            remove = $true
        },
        @{
            file = 'game'
            section = $script:DuneGcSecTimeOfDay
            key = 'm_bTimeOfDayEnabled'
            value = ''
            remove = $true
        }
    )
    $readback = Read-DuneTwilightLiveGameConfig -Ip $Ip -Path $paths.game
    Assert-DuneTwilightRestoreReadback -Raw $readback
    return [ordered]@{
        ok = $true
        restored = $true
        backup = $gameBackup[0].backup
        restartRequired = $true
        clientApplied = $false
        message = 'DST-managed twilight overrides removed. Apply INIs & restart to restore the shipped normal cycle.'
    }
}

# Funcom stores ALL Landsraad settings as scalar members inside ONE nested struct
# value: [/Script/DuneSandbox.LandsraadSettings] Data=(m_TaskGoalAmount=5000.0,...).
# Schema fields tagged StructKey='Data' are read from / written to that struct via
# the UE struct-member engine (Get/Set-DuneStructScalarMember), so they edit the
# member in place and leave the nested members (messages/curves/widgets) intact.
$script:DuneGcLandsraadStructKey = 'Data'

# -----------------------------------------------------------------------------
# Land-claim (staking unit) extension timer. A single admin-entered seconds value
# is written as the two BuildingSettings scalar defaults, and the game's built-in
# doubling schedule (60..30720s) is stripped via array-remove (-) lines so only the
# custom value remains. Applied to BOTH the server 'game' file (UserGame.ini) and
# the local client Game.ini. These keys are NOT in the visual schema — they are
# managed through a dedicated card/endpoint because they mix a scalar with array
# (-) lines, which the scalar-only schema editor does not model.
# -----------------------------------------------------------------------------
$script:DuneLandclaimKeys            = @('m_StakingUnitExtensionDefaultTimes','m_StakingUnitVerticalExtensionDefaultTimes')
$script:DuneLandclaimDefaultRemovals = @(60,120,240,480,960,1920,3840,7680,15360,30720)

# Category display order (UI renders in this order; unknown categories appended).
# NOTE: 'Progression' and 'Harvesting' categories were removed 2026-06-15 along
# with their m_Global* multiplier keys (XP / Progression Speed / Fame / Harvest
# Amount / Harvest Health) plus Health / Damage-to-NPCs / Damage-to-Players,
# after live in-game testing proved them no-ops on self-hosted (the UE INI parser
# accepts the keys but no gameplay system reads them from UserGame.ini). See
# issue #225. Do NOT re-add them as UserGame.ini fields without a fresh in-game
# test showing an actual effect through that channel.
$script:DuneGameConfigCategoryOrder = @(
    'Server Identity','Network','Survival','Hydration','Loot & Death',
    'Resources & Economy','Crafting','Building','BaseBackUp','Inventory','Guilds & Economy',
    'Storm Cycle','Landsraad','PvP & Security','Spice','Taxation','Encounters','Sandworm','Vehicles',
    'Experimental','Experimental 2','Experimental Lab'
)

# Keys DST USED to expose but later removed once they were shown not to work.
# The managed-block writer actively scrubs these from the DST-owned managed block
# on every save, so they don't linger orphaned in existing users' files after the
# schema drops them. Only touches the managed block — never the user's own (body)
# sections. Works for BOTH files: the scrub in ConvertTo-DuneIniManaged is
# section-agnostic, so an engine [ConsoleVariables] key is cleaned the same way a
# game-file key is.
$script:DuneGameConfigDeprecatedManagedKeys = @(
    # Removed after field testing showed no in-game effect.
    'm_GlobalHealthMultiplier'
    'm_GlobalDamageToNpcsMultiplier'
    'm_GlobalDamageToPlayersMultiplier'
    'm_GlobalXPMultiplier'
    'm_GlobalProgressionSpeedMultiplier'
    'm_GlobalFameMultiplier'
    'm_GlobalHarvestAmountMultiplier'
    'm_GlobalHarvestHealthMultiplier'

    # Funcom confirmed these reward packs are not enabled for self-hosted servers.
    # Remove old managed values so the game stops attempting the unsupported login
    # grant and displaying its empty returning-player popup.
    'dw.ReturningPlayer.GiveAward.Enabled'
    'dw.ReturningPlayer.DaysBeforeEligibleForReward'
    'dw.ReturningPlayer.GiveAward.TierOverride'

)

$script:DuneGameConfigSchema = @(
    # --- Server Identity (engine ConsoleVariables) ---
    @{ Section=$script:DuneGcSecConsole; Key='Bgd.ServerDisplayName'; File='engine'; Type='string'; Quoted=$true; Wide=$true; Default=''; Label='Server Display Name'; Help='Name shown to players for every Sietch in the battlegroup.'; Category='Server Identity'; Placeholder='Not set (uses world name)' }
    @{ Section=$script:DuneGcSecConsole; Key='Bgd.ServerLoginPassword'; File='engine'; Type='string'; Quoted=$true; Wide=$true; Default=''; Label='Server Login Password'; Help='Blank = no password. Applies to every Sietch in the battlegroup.'; Category='Server Identity'; Placeholder='No password' }

    # --- Network (engine URL) ---
    @{ Section=$script:DuneGcSecUrl; Key='Port'; File='engine'; Type='int'; Min=1024; Max=65535; Default='7777'; Label='Game Port (starting)'; Help='Starting player port; each server uses the next free port.'; Category='Network' }
    @{ Section=$script:DuneGcSecUrl; Key='IGWPort'; File='engine'; Type='int'; Min=1024; Max=65535; Default='7780'; Label='IGW Port (starting)'; Help='Starting inter-server port; must not overlap the game port range.'; Category='Network' }

    # --- Survival ---
    @{ Section=$script:DuneGcSecGame; Key='m_WaterConsumptionRate'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Water Consumption Rate'; Help='How quickly players consume water. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_WaterConsumptionInStormMultiplier'; File='game'; Type='float'; Min=0; Default='2.0'; Label='Water Consumption in Storm'; Help='Additional water drain during sandstorms. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecGame; Key='m_PlayerStartingWater'; File='game'; Type='float'; Min=0; Default='100.0'; Label='Player Starting Water'; Help='Water amount when a player spawns. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecOnline; Key='m_DefaultReconnectGracePeriodSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Reconnect Grace Period'; Help="Seconds a player's corpse persists after disconnect. Also needs client-side apply."; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecDurab; Key='m_ItemDurabilityLossMultiplier'; File='game'; Type='float'; Min=0; Max=10; Default='1.0'; Label='Item Durability Loss Multiplier'; Help='Scales durability loss for all items. 0 = off. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecDurab; Key='UpdateRateInSeconds'; File='game'; Type='float'; Min=0; Max=10; Unit='sec'; Default='1.0'; Label='Item Decay Rate'; Help='Deterioration tick rate. 0 = off, 1-10 typical. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecRespawn; Key='m_bCrossMapRespawnDropItems'; File='game'; Type='bool'; Default='True'; Label='Drop Items on Cross-Map Respawn'; Help='Whether items are dropped when a player respawns on a different map. Also needs client-side apply.'; ClientApply=$true; Category='Survival' }

    # --- Hydration ---
    @{ Section=$script:DuneGcSecHydration; Key='m_bHydrationEnabled'; File='game'; Type='bool'; Default='True'; Label='Hydration Enabled'; Help='Master toggle for the hydration / thirst system. Off = players never get thirsty. Also needs client-side apply.'; ClientApply=$true; Category='Hydration' }
    # Server-side console variable rather than a game INI key, so it applies on
    # the server alone and needs no client-side apply. Reported working by a
    # community tester; the compiled default was not recovered, but sun exposure
    # is active in shipping gameplay.
    @{ Section=$script:DuneGcSecConsole; Key='Hydration.SunExposureEnabled'; File='engine'; Type='bool01'; Default='1'; Label='Sun Exposure Enabled'; Help='Whether players take sun-exposure water drain. 0 disables sun exposure; field-reported working. Server-side only - no client apply needed.'; Startup=$true; Category='Hydration' }
    @{ Section=$script:DuneGcSecHydration; Key='m_BiomeTierUpdateRateSeconds'; File='game'; Type='float'; Min=0; Unit='sec'; Default='2.5'; Label='Biome Tier Update Rate'; Help='How often (seconds) the biome hydration tier is re-evaluated. Also needs client-side apply.'; ClientApply=$true; Category='Hydration' }

    # --- Loot & Death (DuneSandboxGameModeBase) ---
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersDropLootOnDeath'; File='game'; Type='bool'; Default='False'; Label='Players Drop Loot on Death'; Help='Whether a player drops their inventory as loot when killed (PvP looting). Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersDropLootOnDefeat'; File='game'; Type='bool'; Default='True'; Label='Players Drop Loot on Defeat'; Help='Whether a player drops loot when downed/defeated (not a full death). Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersLoseItemsOnDeath'; File='game'; Type='bool'; Default='True'; Label='Players Lose Items on Death'; Help='Whether a player loses items from their inventory on death. Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldNpcDropLootOnDeath'; File='game'; Type='bool'; Default='True'; Label='NPCs Drop Loot on Death'; Help='Whether NPCs drop loot when killed. Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }

    # --- Resources & Economy (engine ConsoleVariables) ---
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Global Mining Multiplier'; Help='Scales hand-mining resource output.'; Startup=$true; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalVehicleMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Mining Multiplier'; Help='Scales vehicle-mining resource output.'; Startup=$true; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='SecurityZones.PvpResourceMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='PvP Resource Multiplier'; Help='Resource yield multiplier inside PvP zones.'; Startup=$true; Category='Resources & Economy' }

    # --- Crafting ---
    @{ Section=$script:DuneGcSecCrafting; Key='m_RepairCostWeight'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Repair Cost Weight'; Help='Scales repair costs. Also needs client-side apply.'; ClientApply=$true; Category='Crafting' }
    @{ Section=$script:DuneGcSecCrafting; Key='m_RecyclerOutputWeight'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Recycler Output Weight'; Help='Scales recycler output. Also needs client-side apply.'; ClientApply=$true; Category='Crafting' }
    @{ Section=$script:DuneGcSecTechKnowledge; Key='m_bRevealItemOnDistributedToCharacter'; File='game'; Type='bool'; Default='False'; Label='Reveal Distributed Research Items (Experimental)'; Help='When enabled, asks the game to reveal research items distributed directly to a character, including admin-granted developer blueprints and schematics. Unconfirmed: this may make hidden entries visible, but it cannot reconstruct missing schematic research-cost metadata. Restart the battlegroup, then grant a fresh copy for testing. Also needs client-side apply.'; ClientApply=$true; Category='Crafting' }

    # --- Building ---
    @{ Section=$script:DuneGcSecBuilding; Key='m_MaxNumLandclaimSegments'; File='game'; Type='int'; Min=1; Default='6'; Label='Max Landclaim Segments'; Help='Maximum territory claim segments. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='int'; Min=0; Default='4'; Label='Blueprint Max Extensions'; Help='Maximum blueprint extension slots. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='bool'; Default='True'; Label='Building Restriction Limits'; Help='Enforce building restriction limits. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalBuildingDamageMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Damage Multiplier'; Help='Scales damage dealt to player buildings (0.5 = stronger bases). Also needs client-side apply.'; ClientApply=$true; Category='Building' }

    # --- BaseBackUp ---
    # Every key here is read by the CLIENT as well as the server, so each player
    # needs the same values in their own Game.ini for the tool to behave.
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupToolMapRestriction'; File='game'; Type='string'; Wide=$true; Default='((Name="HaggaBasin"), (Name="Editor_Default"), (Name="IGW_Test_Small"))'; Label='Allowed Maps'; Help='Maps the base backup tool works on. Add (Name="DeepDesert") to allow it in the Deep Desert. Also needs client-side apply.'; ClientApply=$true; Category='BaseBackUp' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupToolTimeRestrictionInSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='604800'; Label='Cooldown Between Backups'; Help='How long a player waits between base backups. Default 604800 = 7 days. Also needs client-side apply.'; ClientApply=$true; Category='BaseBackUp' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupMaxExtensions'; File='game'; Type='int'; Min=0; Default='8'; Label='Max Extensions'; Help='Backup (reconstruction) extension slots per base. Also needs client-side apply.'; ClientApply=$true; Category='BaseBackUp' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingBlueprintSnapToOriginBaseBackupMaxAllowedDistance'; File='game'; Type='float'; Min=0; Default='5000.0'; Label='Snap-To-Origin Max Distance'; Help='How far from its original location a base backup may still snap back to that origin. Also needs client-side apply.'; ClientApply=$true; Category='BaseBackUp' }

    # --- Inventory ---
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingSize'; File='game'; Type='int'; Min=1; Default='35'; Label='Starting Inventory Slots'; Help='Number of inventory slots at spawn. Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingVolumeCapacity'; File='game'; Type='float'; Min=0; Default='175.0'; Label='Starting Inventory Volume'; Help='Volume capacity of the starting inventory. Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }
    @{ Section=$script:DuneGcSecGame; Key='m_InventoryWeightMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Inventory Weight Multiplier'; Help='Scales item weight across all inventories (carry-capacity scalar). Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }

    # --- Guilds & Economy ---
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildMembersAllowed'; File='game'; Type='int'; Min=1; Default='32'; Label='Max Guild Members'; Help='Maximum players per guild. Also needs client-side apply.'; ClientApply=$true; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildsAllowed'; File='game'; Type='int'; Min=1; Default='3'; Label='Max Guilds per Player'; Help='How many guilds a player may belong to. Also needs client-side apply.'; ClientApply=$true; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_GuildCreationCost'; File='game'; Type='int'; Min=0; Unit='Solari'; Default='1000'; Label='Guild Creation Cost'; Help='Solari required to create a guild. Also needs client-side apply.'; ClientApply=$true; Category='Guilds & Economy' }

    # --- Storm Cycle ---
    @{ Section=$script:DuneGcSecCoriolis; Key='m_CycleDurationInDays'; File='game'; Type='int'; Min=1; Unit='days'; Default='7'; Label='Coriolis Cycle Length'; Help='In-game days between Coriolis storm / season events. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='bool'; Default='True'; Label='Coriolis Auto-Spawn'; Help='Whether Coriolis storms spawn automatically. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecCoriolis; Key='m_bIsDbWipeEnabled'; File='game'; Type='bool'; Default='True'; Label='Database Wipe on Season End'; Help='Wipe the database when the season ends. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecCoriolis; Key='m_bShouldRestartServerOnCycleEnd'; File='game'; Type='bool'; Default='True'; Label='Restart Server on Cycle End'; Help='Whether the dedicated server restarts itself when a Coriolis cycle (season) ends. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecCoriolis; Key='m_ForcedCoriolisWorldSeed'; File='game'; Type='int'; Min=-1; Max=11; Default='-1'; Label='Forced Coriolis World Seed'; Help='Pins which of the twelve pre-built world layouts the Coriolis storm generates. -1 = automatic (the game picks a fresh layout each Coriolis cycle); 0-11 = pin that layout until you change it. This is server-wide (farm-scoped): it pins EVERY map, not just the Deep Desert. Each map adopts the value the next time that map regenerates, so maps flip at different moments as they restart - it is not immediate. The Deep Desert regenerates because it sits outside the shieldwall; shieldwall-protected maps keep their bases and resource fields, and only player map markers (plus surveyed areas, if surveyed-area clearing is enabled) are affected. This INI key is the real control - the world-reset seed rows in the database are the output the game writes, not an input. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm'; Help='Enable rolling sandstorms.'; Startup=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm Treasure Spawns'; Help='Spawn treasure during sandstorms.'; Startup=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bCoriolisDoesDamage'; File='game'; Type='bool'; Default='False'; Label='Coriolis Storm Does Damage'; Help='Whether being caught in a Coriolis storm damages players. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bSandStormDebrisEnabled'; File='game'; Type='bool'; Default='True'; Label='Sandstorm Debris'; Help='Whether sandstorms spawn flying debris. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecTimeOfDay; Key='m_bTimeOfDayEnabled'; File='game'; Type='bool'; Default='True'; Label='Time of Day Cycle'; Help='Whether the day/night cycle advances. This switch does not select a phase, and DST has not proven that disabling it freezes only visuals while simulation timers continue. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }

    # --- Landsraad (scalar members of [LandsraadSettings] Data=(...)) ---
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_TaskGoalAmount'; File='game'; Type='float'; Min=0; Default='70000'; Label='Task Goal Amount'; Help='Contribution target for each House task before it completes. Funcom default is 70000. DST also applies the new goal to the currently-running term''s live House rows (dune.landsraad_tasks.goal_amount) so the change takes effect immediately.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfWeeksTermRetention'; File='game'; Type='int'; Min=1; Unit='weeks'; Default='4'; Label='Term Retention'; Help='How many weeks of term history are kept.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfDecreesToNominate'; File='game'; Type='int'; Min=0; Default='3'; Label='Decrees to Nominate'; Help='Number of decrees put up for voting each term. Applies when the next Landsraad term begins, not the current one. Note: the in-game board UI only displays 3 by default.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfGuildsInHighscoreList'; File='game'; Type='int'; Min=0; Default='5'; Label='Guilds in Highscore List'; Help='How many guilds appear on the contribution highscore list.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_ControlPointsPerCycle'; File='game'; Type='int'; Min=0; Default='2'; Label='Control Points per Cycle'; Help='Territory control points awarded per cycle.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_bIsPlayerVotingEnabled'; File='game'; Type='bool'; Default='True'; Label='Player Voting Enabled'; Help='Whether players can vote on Landsraad decrees.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_bIsTerritoryControlEnabled'; File='game'; Type='bool'; Default='True'; Label='Territory Control Enabled'; Help='Whether the territory-control mechanic is active.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_VotingPeriodDurationInSec'; File='game'; Type='float'; Min=0; Unit='sec'; Default='118500.0'; Label='Legacy Voting Period Duration'; Help='Legacy / unconfirmed member retained so existing server and rollback values remain visible and editable. Current Funcom builds use Landsraad Voting Period Duration below. DST does not copy or delete either value automatically.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_VotingPeriodStartBeforeCoriolisCycleInSec'; File='game'; Type='float'; Min=0; Unit='sec'; Default='118800.0'; Label='Legacy Voting Starts Before Cycle'; Help='Legacy / unconfirmed member retained for existing servers and rollback. Current Funcom builds do not expose a one-to-one replacement, so DST preserves this value without mapping or deleting it.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadVotingPeriodDurationInSec'; File='game'; Type='int'; Min=0; Unit='sec'; Default='118500'; Label='Voting Period Duration'; Help='Length of the Landsraad voting window. Applies when the game schedules the next voting period.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadCycleDurationInSeconds'; File='game'; Type='int'; Min=1; Unit='sec'; Default='604800'; Label='Landsraad Cycle Duration'; Help='Length of a Landsraad term. Changing this setting does not immediately shorten the term already in progress.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadSuspendedPeriodDurationInSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Suspended Period Duration'; Help='Gap between the end of one Landsraad term and the start of the next.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsMaxActiveAmount'; File='game'; Type='int'; Min=0; Default='3'; Label='Max Active Contracts'; Help='Maximum simultaneously-active Landsraad contracts per player.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsPerVotingBlock'; File='game'; Type='int'; Min=0; Default='3'; Label='Contracts per Voting Block'; Help='Number of contracts offered per voting block.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsAbandonCooldownSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='3600'; Label='Contract Abandon Cooldown'; Help='How long a player must wait after abandoning a Landsraad contract. Field-confirmed at 5 seconds.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsDailyBonusPerDay'; File='game'; Type='int'; Min=0; Default='5'; Label='Daily Contract Bonus'; Help='Bonus contracts granted per day.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsDailyBonusMax'; File='game'; Type='int'; Min=0; Default='35'; Label='Daily Contract Bonus Max'; Help='Maximum accumulated daily contract bonus.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadTaskDailyRevealFrequency'; File='game'; Type='float'; Min=0; Default='25.0'; Label='Task Daily Reveal Frequency'; Help='How often new House tasks are revealed each day.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadTaskProgressUpdateFrequency'; File='game'; Type='float'; Min=0; Default='15.0'; Label='Task Progress Update Frequency'; Help='How often House task progress is recomputed.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; Key='bIsLandsraadEnabled'; File='game'; Type='bool'; Default='True'; Label='Landsraad Enabled'; Help='Master toggle for the entire Landsraad system. Also needs client-side apply.'; ClientApply=$true; Category='Landsraad' }

    # --- PvP & Security ---
    @{ Section=$script:DuneGcSecSecurity; Key='m_bAreSecurityZonesEnabled'; File='game'; Type='bool'; Default='True'; Label='Security Zones Enabled'; Help='Off = PvP and ability usage allowed everywhere. Also needs client-side apply.'; ClientApply=$true; Category='PvP & Security' }

    # --- Spice ---
    @{ Section=$script:DuneGcSecSpice; Key='m_PrimeRateInSeconds'; File='game'; Type='float'; Min=0; Unit='sec'; Default='30.0'; Label='Spice Prime Rate'; Help='Seconds between spice node priming ticks. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_NodeValueToSpiceResourceRatio'; File='game'; Type='float'; Min=0; Default='10.0'; Label='Node Value to Spice Ratio'; Help='Converts node value into harvestable spice. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpiceAddict; Key='m_bIsSpiceAddictionEnabled'; File='game'; Type='bool'; Default='True'; Label='Spice Addiction Enabled'; Help='Whether players develop spice addiction over time. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpiceAddict; Key='m_bIsSpiceVisionEnabled'; File='game'; Type='bool'; Default='True'; Label='Spice Vision Enabled'; Help='Whether spice vision effects are active. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }

    # --- Deep Desert startup caps (members of SpiceHarvestingSystem m_PerMapSystemSettings) ---
    @{ Section=$script:DuneGcSecSpice; Key='DST.SpiceStartup.DeepDesert.Small.Max'; File='game'; Type='int'; Min=0; Default='60'; Label='Deep Desert Small Fields at Startup'; Help='Caps both active and primed Small fields after Apply INIs & restart. Guidance: 60 is Funcom''s normal high cap. This is a ceiling, not a forced count; if the current layout provides fewer fields, only those fields can appear.'; SpiceMap='DeepDesert_1'; SpiceFieldType='Small'; SpiceLimit='Both'; ClientStructKey='m_PerMapSystemSettings'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='DST.SpiceStartup.DeepDesert.Medium.Max'; File='game'; Type='int'; Min=0; Default='12'; Label='Deep Desert Medium Fields at Startup'; Help='Caps both active and primed Medium fields after Apply INIs & restart. Guidance: 12 is Funcom''s normal high cap. This is a ceiling, not a forced count; if the current layout provides fewer fields, only those fields can appear.'; SpiceMap='DeepDesert_1'; SpiceFieldType='Medium'; SpiceLimit='Both'; ClientStructKey='m_PerMapSystemSettings'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='DST.SpiceStartup.DeepDesert.Large.Max'; File='game'; Type='int'; Min=0; Default='1'; Label='Deep Desert Large Fields at Startup'; Help='Caps both active and primed Large fields after Apply INIs & restart. Guidance: use up to 6 to cover the largest known layouts. This is a ceiling, not a forced count: a max of 6 with only 4 fields in the seed still produces at most 4.'; SpiceMap='DeepDesert_1'; SpiceFieldType='Large'; SpiceLimit='Both'; ClientStructKey='m_PerMapSystemSettings'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='DST.SpiceStartup.Hagga.Small.Max'; File='game'; Type='int'; Min=0; Default='5'; Label='Hagga Small Fields at Startup'; Help='Caps both active and primed Small fields after Apply INIs & restart. Guidance: 5 is Funcom''s normal active cap. This is a ceiling; it does not create fields beyond what Hagga can place.'; SpiceMap='Survival_1'; SpiceFieldType='Small'; SpiceLimit='Both'; ClientStructKey='m_PerMapSystemSettings'; ClientApply=$true; Category='Spice' }

    # --- Taxation ---
    @{ Section=$script:DuneGcSecTaxation; Key='m_bTaxationEnabled'; File='game'; Type='bool'; Default='False'; Label='Taxation Enabled'; Help='Whether the taxation system is active. Also needs client-side apply.'; ClientApply=$true; Category='Taxation' }
    @{ Section=$script:DuneGcSecTaxation; Key='m_TaxationCycleLengthSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='1209600'; Label='Taxation Cycle'; Help='Seconds between taxation collection cycles. Also needs client-side apply.'; ClientApply=$true; Category='Taxation' }

    # --- Sandworm (engine cvars + game settings) ---
    @{ Section=$script:DuneGcSecConsole; Key='sandworm.dune.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandworm Enabled'; Help='Master toggle for the sandworm.'; Startup=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormDangerZonesEnabled'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Danger Zones'; Help='Enable danger zones where the sandworm can attack.'; Startup=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormCollisionInteraction'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Pushes Vehicles'; Help='Sandworm can push / damage vehicles.'; Startup=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnExit'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='5.0'; Label='Invulnerability on Vehicle Exit'; Help='Seconds of sandworm invulnerability after exiting a vehicle.'; Startup=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnServerRestart'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='60.0'; Label='Invulnerability on Server Restart'; Help='Seconds of sandworm invulnerability after a server restart.'; Startup=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='WormDetectionDistance'; File='game'; Type='float'; Min=0; Default='5000.0'; Label='Worm Detection Distance'; Help='Distance at which worms detect players. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinWormSpawnInternal'; File='game'; Type='float'; Min=0; Unit='sec'; Default='300.0'; Label='Min Worm Spawn Interval'; Help='Minimum seconds between worm spawns. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecHazards; Key='m_SandwormQuicksandSpeedModifier'; File='game'; Type='float'; Min=0; Default='0.25'; Label='Quicksand Speed Modifier'; Help='Movement speed multiplier in quicksand. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bEnableDangerZones'; File='game'; Type='bool'; Default='True'; Label='Worm Danger Zones'; Help='Whether sandworm danger zones are generated. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bGiantWormSystemEnabled'; File='game'; Type='bool'; Default='True'; Label='Giant Worm System'; Help='Whether the giant sandworm system is active. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bEnableHibernation'; File='game'; Type='bool'; Default='True'; Label='Worm Hibernation'; Help='Whether sandworms hibernate when no players are nearby (performance). Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }

    # --- Encounters ---
    @{ Section=$script:DuneGcSecEncounters; Key='m_bAreRandomEncountersEnabled'; File='game'; Type='bool'; Default='True'; Label='Random Encounters'; Help='Whether random world encounters spawn. Also needs client-side apply.'; ClientApply=$true; Category='Encounters' }
    @{ Section=$script:DuneGcSecContracts; Key='m_bIsEnabled'; File='game'; Type='bool'; Default='True'; Label='Contracts Enabled'; Help='Master toggle for the contracts subsystem. Also needs client-side apply.'; ClientApply=$true; Category='Encounters' }

    # --- Vehicles (engine cvars) ---
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleDurabilityDamageMultiplier'; File='engine'; Type='float'; Min=0; Max=10; Default='1.0'; Label='Vehicle Durability Damage'; Help='Funcom: "Vehicle Durability Damage multiplier." Field testing found that 0 does not disable ordinary use wear or welding/repair-station permanent durability loss; exact damage scope remains unconfirmed.'; Startup=$true; Category='Experimental' }

    # --- Experimental binary-discovered engine cvars ---
    # These registered controls and their compiled help/defaults were decoded
    # from DuneSandboxServer-Linux-Shipping 1.4.10.4. Keep them isolated until
    # broader field testing establishes their gameplay behavior. Unknown
    # compiled defaults stay unset rather than presenting an invented default.
    # Hazard.DehydrationZonesEnabled is intentionally excluded because its
    # compiled Funcom help explicitly warns that enabling it crashes clients.
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GiveDoubleDifficultyLoot'; File='engine'; Type='bool01'; Default='0'; Label='Double Difficulty Loot'; Help='Give double loot when encounter difficulty is above 0. Field-confirmed with dungeon loot.'; Status='Confirmed'; Startup=$true; Category='Loot & Death' }
    # Field testing established that INI-only application did not take effect,
    # while applying the same value through the Survival pod's ExecCmds did.
    # Existing generator fuel reflected the new duration after restart.
    @{ Section=$script:DuneGcSecConsole; Key='dw.FuelBurningMultiplier'; File='engine'; Type='float'; Default='1.0'; Label='Fuel Burning Duration'; Help='Scales how long all fuel burns. DST applies the value in UserEngine.ini and the Hagga server startup command because INI-only application did not take effect in field testing. Restart the battlegroup to apply it; existing generator fuel updates after restart.'; Status='Confirmed'; Startup=$true; Category='Building' }
    @{ Section=$script:DuneGcSecConsole; Key='Abilities.RespecCooldownTotalDurationSeconds'; File='engine'; Type='int'; Min=0; Unit='sec'; Default='172800'; Label='Ability Respec Cooldown'; Help='Total ability-respec cooldown in seconds. Compiled default is 172800 (2 days); 0 may remove the cooldown but has not been field-verified.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.LandsraadMissionRewardMultiplierFactionXP'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Landsraad Faction XP'; Help='Scales Faction XP from Landsraad missions. Field-confirmed at 10; mission preview may still show the base reward.'; Status='Confirmed'; Startup=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.LandsraadMissionRewardMultiplierHouseCredit'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Landsraad House Credit'; Help='Scales House Credit from Landsraad missions. Field-confirmed at 10; mission preview may still show the base reward.'; Status='Confirmed'; Startup=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.LandsraadMissionRewardMultiplierSpecializationXP'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Landsraad Specialization XP'; Help='Scales Specialization XP from Landsraad missions. Field-confirmed at 10; mission preview may still show the base reward.'; Status='Confirmed'; Startup=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleHeatMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Heat Multiplier'; Help='Scales vehicle heat generation. 0 = no heat, 1 = normal, 2 = double. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleHeatInterpolationSpeed'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Heat Interpolation Speed'; Help='Speeds up or slows down vehicle heat interpolation. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehiclePowerConsumptionMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Power Consumption'; Help='Scales vehicle power use. 0 = no consumption, 1 = normal, 2 = double. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleCanOverHeat'; File='engine'; Type='bool01'; Default='1'; Label='Vehicles Can Overheat'; Help='Whether vehicles can overheat. 0 = disabled, 1 = enabled. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleAbandonedDecayAllowed'; File='engine'; Type='bool01'; Label='Abandoned Vehicle Decay'; Help='Allows abandoned vehicles to decay over time. 0 disables decay. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleAbandonedDecayTimeMultiplier'; File='engine'; Type='float'; Default='1.0'; Label='Abandoned Vehicle Decay Speed'; Help='Scales abandoned-vehicle decay speed. Values above 1 should decay faster; 1 is shipping behavior.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.DisassemblySpeedMultiplier'; File='engine'; Type='float'; Default='1.0'; Label='Vehicle Disassembly Speed'; Help='Scales vehicle disassembly speed. Not yet field-verified.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.RecoveryChassisDurabilityReductionFraction'; File='engine'; Type='float'; Default='0.150000006'; Label='Recovery Chassis Durability Reduction'; Help='Fraction of maximum chassis durability lost during recovery. Set 0 for no durability loss; use 0.15 for 15 percent.'; Status='Confirmed'; Startup=$true; Category='Vehicles' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.RecoveryCurrencyBaseCost'; File='engine'; Type='int'; Min=0; Default='2500'; Label='Vehicle Recovery Base Cost'; Help='Base currency cost to recover a vehicle before vehicle-specific multipliers.'; Status='Confirmed'; Startup=$true; Category='Vehicles' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.RecoveryTimeLimit'; File='engine'; Type='int'; Min=0; Unit='sec'; Label='Vehicle Recovery Time Limit'; Help='Seconds a destroyed vehicle remains available for recovery. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxActiveVehicles'; File='engine'; Type='int'; Min=-1; Default='-1'; Label='Maximum Active Vehicles'; Help='Rejects attempts to enter vehicle seats after this active-vehicle limit. -1 = unlimited. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxVehicles'; File='engine'; Type='int'; Min=-1; Default='-1'; Label='Maximum Vehicles'; Help='Rejects vehicle assembly or recovery after this total-vehicle limit. -1 = unlimited. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxVehiclesForSpawner'; File='engine'; Type='int'; Min=0; Default='400'; Label='Maximum Spawned Vehicles'; Help='Stops vehicle spawners after this many vehicles exist. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxVehiclesPerPlayer'; File='engine'; Type='int'; Min=0; Default='10'; Label='Maximum Vehicles Per Player'; Help='Limits vehicles each player may spawn or claim. 0 = unlimited. DST applies it in UserEngine.ini and the Hagga server startup command. Field-confirmed: the limit is client-enforced, so every player also needs an equal or higher value in their own client Engine.ini before the raised cap shows in game.'; Status='Confirmed'; Startup=$true; Category='Vehicles' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxVehiclesWarning'; File='engine'; Type='int'; Min=0; Label='Vehicle Count Warning Threshold'; Help='Vehicle count at which the amount notification becomes a warning. Applied through INI and Hagga startup command for local testing.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.CharacterHitDamageModifier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Impact Character Damage'; Help='Scales damage dealt to characters by vehicle impacts. 0 should disable impact damage.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.DamagePlayerOnVehicleCollision'; File='engine'; Type='bool01'; Label='Vehicle Collision Damages Players'; Help='Whether vehicle collisions damage players. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Player.IsThrowOffPlayerFromVehicleActive'; File='engine'; Type='bool01'; Default='1'; Label='Throw Players Off Moving Vehicles'; Help='Whether players standing on moving vehicles are thrown off. Funcom help states 1 is the default.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Player.ThrowOffPlayerFromVehicleVelocityMultiplier'; File='engine'; Type='float'; Min=0; Default='3'; Label='Vehicle Throw-Off Force'; Help='Velocity multiplier used to calculate force when throwing a player off a moving vehicle.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Player.ThrowOffPlayerFromVehicleVelocityThreshold'; File='engine'; Type='float'; Min=0; Default='2000'; Label='Vehicle Throw-Off Speed Threshold'; Help='Vehicle velocity that starts throwing off standing players. Binary value is 2000 although compiled help mentions 500.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilityOnExitInAir'; File='engine'; Type='bool01'; Label='Worm Protection on Mid-Air Exit'; Help='Grants short sandworm invulnerability when the pilot exits a vehicle in mid-air. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilityOnLeavingGame'; File='engine'; Type='bool01'; Label='Worm Protection on Disconnect'; Help='Grants short sandworm invulnerability when the pilot disconnects. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormAttackDifficultyGroup'; File='engine'; Type='select'; Default='-1'; Options=@(@{V='-1';L='Default / unspecified'},@{V='0';L='Easy'},@{V='1';L='Medium'},@{V='2';L='Hard'},@{V='3';L='Death'}); Label='Sandworm Attack Difficulty'; Help='Forces the difficulty group used when selecting a sandworm attack.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='SandwormSubsystem.DelayedRestartSeconds'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='600'; Label='Sandworm Delayed Restart'; Help='Delays sandworm spawning after restart. Funcom help states a default of 600 seconds; binary default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='SpiceHarvesting.dune.SpawnCraterRocksAfterBloom'; File='engine'; Type='bool01'; Default='0'; Label='Spawn Crater Rocks After Bloom'; Help='Spawns and distributes crater rocks after a spice bloom. Binary default is 0 although compiled help labels 1 as default.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.MitigateAllDamageToBuildables'; File='engine'; Type='bool01'; Label='Mitigate All Buildable Damage'; Help='Enables mitigation for all damage to buildables. Exact mitigation behavior and compiled default are unknown.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.EnableOutsideBuildablesToAffectShelter'; File='engine'; Type='bool01'; Label='Outside Buildables Affect Shelter'; Help='Allows buildables outside a structure to affect its shelter calculation. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.BuildingShelterThresholdOverride'; File='engine'; Type='float'; Min=-1; Max=1; Default='-1'; Label='Building Shelter Threshold Override'; Help='Overrides the building shelter threshold from 0 to 1. Any negative value disables the override.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.SandBuildUpPlaceableShelteredTargetValueOverride'; File='engine'; Type='float'; Default='-1'; Label='Sheltered Sand Buildup Target'; Help='Overrides target sand buildup for sheltered placeables. Valid range and disable behavior are undocumented.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.SandBuildUpPlaceableUnShelteredTargetValueOverride'; File='engine'; Type='float'; Default='-1'; Label='Unsheltered Sand Buildup Target'; Help='Overrides target sand buildup for unsheltered placeables. Valid range and disable behavior are undocumented.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.FriendlyPvPDamageMultiplier'; File='engine'; Type='float'; Label='Friendly PvP Damage Multiplier'; Help='Overrides the security-zone friendly PvP damage multiplier when positive. Negative values disable the override; compiled default is unknown.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.HealingDurationReductionByDamageMultiplier'; File='engine'; Type='float'; Min=-1; Max=1; Label='Damage Healing-Duration Reduction'; Help='Reduces healing-over-time after taking damage: -1 = no override, 0 to 1 = partial through complete removal. Compiled default is unknown.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.AttackLimitOverride'; File='engine'; Type='int'; Default='0'; Label='NPC Attack Limit Override'; Help='When above 0, limits NPCs attacking the same target. Also requires NPC.EnableNpcAttackLimits, which is not exposed here.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='JourneyStory.Instance.Cap'; File='engine'; Type='int'; Min=-1; Default='-1'; Label='Journey Story Instance Cap'; Help='Maximum instances players may occupy per instance type. -1 = unlimited.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='SafeZone.EnableScale'; File='engine'; Type='bool01'; Label='Enable Safe-Zone Scaling'; Help='Enables the safe-zone scale override. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='SafeZone.Scale'; File='engine'; Type='float'; Default='1.0'; Label='Safe-Zone Scale'; Help='Scales safe-zone geometry. May alter PvP boundaries and world behavior; test cautiously.'; Category='Experimental' }

    # --- Second decode pass (build 2051294-0-shipping) ---
    # The earlier catalogue was incomplete because the scan that produced it read
    # the server binary as ASCII. Unreal stores console-variable names and their
    # help text as UTF-16, so those scans reported nothing for controls that are
    # demonstrably present. Re-reading the binary as UTF-16 and pairing each name
    # with the help string its registration code references recovers the full set;
    # the help below is Funcom's own wording, quoted rather than paraphrased.
    #
    # None of these are field-confirmed. Funcom's help says what a control was
    # meant to do, which is not evidence that the shipped build does it - the
    # m_Global*Multiplier keys parsed cleanly for months and did nothing. Where
    # Funcom's help does not state a default, the field is left unset instead of
    # inventing one.

    # Fills gaps in controls DST already exposes.
    @{ Section=$script:DuneGcSecConsole; Key='NPC.EnableNpcAttackLimits'; File='engine'; Type='bool01'; Label='Enable NPC Attack Limits'; Help='Funcom: "If set to 1, NPCs will utilize the attack limit curve when determining if they can attack a target". NPC Attack Limit Override above has no effect unless this is on. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.FuelsBurningDuration'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Fuel Burn Time (seconds)'; Help='Funcom: "Time in seconds that every fuel consumed by the fuel powered generator will take to burn". An absolute time, unlike Fuel Burning Duration which is a multiplier. Field-confirmed. Setting both at once is still untested — use one or the other. Compiled default was not recovered.'; Status='Confirmed'; Startup=$true; Category='Building' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.PlaceableShelterThresholdOverride'; File='engine'; Type='float'; Min=-1; Max=1; Default='-1'; Label='Placeable Shelter Threshold Override'; Help='Funcom: "The threshold value override for the placeable shelter, from 0 to 1. Negative value means it is disabled". Counterpart to Building Shelter Threshold Override.'; Category='Experimental' }

    # Survival and server ruleset.
    @{ Section=$script:DuneGcSecConsole; Key='Deathstill.ConversionTimeOverride'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Deathstill Conversion Time'; Help='Overrides how long a deathstill takes to process a body, in seconds. Field-confirmed; restart the battlegroup to apply it. Compiled default was not recovered.'; Status='Confirmed'; Startup=$true; Category='Survival' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.DisablePvpDamage'; File='engine'; Type='bool01'; Label='Disable PvP Damage'; Help='Funcom: "If true, pvp damage will be disabled. Pve/Evp damage will always work regardless". Server-wide, unlike the per-partition Deep Desert PvP setting. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.EnableShelterSystem'; File='engine'; Type='bool01'; Label='Shelter System'; Help='Funcom: "Enable and disable the shelter system". Disabling it removes sandstorm shelter requirements entirely; expect wide-reaching effects. Compiled default was not recovered.'; Category='Experimental' }

    # Base backup tool.
    @{ Section=$script:DuneGcSecConsole; Key='dw.bBaseBackupToolBackupEnabled'; File='engine'; Type='bool01'; Label='Base Backup Tool - Backups'; Help='Funcom: "If the base backup tool should be enabled or disabled". Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.bBaseBackupToolPlacementEnabled'; File='engine'; Type='bool01'; Label='Base Backup Tool - Placement'; Help='Funcom: "If the base backup tool should be enabled or disabled" - the placement half, letting you allow backups while blocking blueprint placement. Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.bBaseBackupToolRecycleEnabled'; File='engine'; Type='bool01'; Label='Base Backup Tool - Recycle'; Help='Funcom: "If the base backup tool recycle should be enabled or disabled". Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.OverrideBaseBackupToolTimeRestrictionInSeconds'; File='engine'; Type='int'; Min=0; Unit='sec'; Label='Base Backup Time Restriction Override'; Help='Funcom: "Override the base backup tool time restriction". The game also has a UserGame.ini setting for the same restriction that DST does not surface; if both are set, which one wins is untested. Compiled default was not recovered.'; Category='Experimental' }

    # Landsraad.
    @{ Section=$script:DuneGcSecConsole; Key='Landsraad.ControlPointCaptureProgressTarget'; File='engine'; Type='float'; Min=0; Default='100'; Label='Control Point Capture Target'; Help='Funcom: "Set a custom ProgressTarget for all Landsraad ControlPoints, 100 being the Default". Lower values make control points quicker to capture, which suits small or solo servers.'; Category='Experimental' }

    # Sandworm behaviour.
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormEnrageThreshold'; File='engine'; Type='int'; Min=-1; Default='-1'; Label='Worm Enrage Threshold'; Help='Funcom: "The amount of attacks that the worm will do before enraging. -1 = not specified."'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormTargetChangeThreshold'; File='engine'; Type='int'; Min=0; Default='0'; Label='Worm Target Change Threshold'; Help='Funcom: "The amount of attacks that the worm will do before switching target. 0 = not specified."'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormTargetDropThreshold'; File='engine'; Type='int'; Min=0; Default='0'; Label='Worm Target Drop Threshold'; Help='Funcom: "The amount of attacks that the worm will do before dropping its target and adding it to the ignore list. 0 = not specified."'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.ThreatWarning.DefaultDistance'; File='engine'; Type='float'; Min=0; Label='Worm Threat Warning Distance'; Help='Funcom: "Distance for when the sandworm threat warning will appear on normal maps". Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.ThreatWarning.DeepDesertDistance'; File='engine'; Type='float'; Min=0; Label='Worm Threat Warning Distance (Deep Desert)'; Help='Funcom: "Distance for when the sandworm threat warning will appear on deep desert maps". Compiled default was not recovered.'; Category='Experimental' }

    # Vehicles.
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.RecoveryEnabled'; File='engine'; Type='bool01'; Label='Vehicle Recovery'; Help='Funcom: "Enables vehicle recovery. If enabled, vehicles will not be deleted but kept in database for recovery via backup tool". Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.BackupTool.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Vehicle Backup Tool'; Help='Funcom: "If false player wont be able to backup or restore vehicles and an onscreen notification will be shown if they try."'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.WreckedStateDespawnDuration'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Vehicle Wreck Despawn Time'; Help='Funcom: "The duration in seconds until a vehicle is despawned when in wrecked state". Compiled default was not recovered.'; Category='Experimental' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.AmmoBlocksBackup'; File='engine'; Type='bool01'; Default='0'; Label='Ammo Blocks Vehicle Backup'; Help='Funcom: "Set whether ammo can remain in the vehicle ammo inventory when backing it up". 0 makes players empty ammo first.'; Category='Experimental' }

    # Server instance. Bgd.* is deliberately server-only: it is not mirrored to a
    # player client config (see the ClientApply pass below).
    @{ Section=$script:DuneGcSecConsole; Key='Bgd.ServerPlayerHardCap'; File='engine'; Type='int'; Min=-1; Default='-1'; Label='Player Hard Cap'; Help='Funcom: "Override for player CCU hard cap for this server instance. -1 corresponds to using the default value provided by the director." Raising it above what the VM can feed costs RAM and CPU per extra player; watch Server Health after changing it.'; Category='Experimental' }


    # --- Experimental 2 -------------------------------------------------------
    # The wider set recovered from the same decode pass. These are separated from
    # Experimental only so the list stays navigable: they are applied the same
    # way, are equally unconfirmed, and Funcom's own help is quoted rather than
    # paraphrased.
    #
    # Two recovered controls are DELIBERATELY NOT LISTED because DST already
    # exposes the same behaviour as a game setting, and shipping both would give
    # one behaviour two switches that can disagree with no known precedence:
    #   Dune.PlayerDeathLootEnabled        -> Players Drop Loot on Death (m_bShouldPlayersDropLootOnDeath)
    #   Sandworm.SandwormHibernationActive -> Worm Hibernation (m_bEnableHibernation)
    # Also excluded: string-valued CVars (the startup-argument path parses values
    # as numbers), server ports and telemetry, replication/LOD/streaming
    # internals, dw.FatalLogOnDupItemDetected ("will purposedly crash the
    # server"), fault-injection and cheat switches, and the item-duplication
    # guards. tests/GameConfig.Tests.ps1 enforces the exclusions.
    @{ Section=$script:DuneGcSecConsole; Key='Combat.DuelingSystem.Enabled'; File='engine'; Type='bool01'; Label='Dueling System'; Help='Funcom: "Whether or not the dueling system is enabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Combat.CanDamageNonCombatNpc'; File='engine'; Type='bool01'; Label='Damage Non-Combat NPCs'; Help='Funcom: "Whether players can damage and apply effects to non combat NPCs".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.EnableNearDeathDamageMitigation'; File='engine'; Type='bool01'; Label='Near-Death Damage Mitigation'; Help='Funcom: "If true, enable damage mitigation based on remaining health". Softens incoming damage as health drops.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.EnableKnockbackDurationDamageScaling'; File='engine'; Type='bool01'; Label='Stagger Damage Scaling'; Help='Funcom: "If true, damage can be increased based on how long the target has been in stagger state".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dac.ShieldBreakWhileAirborne'; File='engine'; Type='bool01'; Label='Shield Break While Airborne'; Help='Funcom: "Apply shield break stagger type when character is airborne".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.DisableShieldOnShooting'; File='engine'; Type='bool01'; Label='Shield Drops While Shooting'; Help='Funcom: "Toggles if the shield should go down w". Funcom''s help text is truncated in the binary. Field-confirmed: turning this off keeps a player''s shield up while they fire.'; Status='Confirmed'; Startup=$true; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecConsole; Key='Abilities.HoltzmanShield.UsePowerWhenDisabled'; File='engine'; Type='bool01'; Default='0'; Label='Shield Uses Power When Disabled'; Help='Funcom: "0 (Default): off, 1 : on - When on shield will use power even if it''s disabled by ADS".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Abilities.AllowRepsecOutsideLandclaim'; File='engine'; Type='bool01'; Label='Respec Outside Land Claim'; Help='Funcom: "Allow players to repsec outside landclaim or socialhub". Funcom''s spelling is preserved in the key name.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.LootNpcDroppedOnCorpseEnabled'; File='engine'; Type='bool01'; Label='NPC Loot On Corpses'; Help='Funcom: "Allows the client to enable or disable NPC loot dropped on NPC corpses". Controls where NPC loot lands, not whether NPCs drop loot - that is NPCs Drop Loot on Death under Loot & Death.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.LootNpcDroppedOnContainerEnabled'; File='engine'; Type='bool01'; Label='NPC Loot In Containers'; Help='Funcom: "Allows the client to enable or disable NPC loot dropped on loot containers". Companion to NPC Loot On Corpses; both describe placement, not whether loot drops.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Loot.ShouldAlwaysRegeneratePerPlayerLoot'; File='engine'; Type='bool01'; Label='Regenerate Per-Player Loot'; Help='Funcom: "Should per player loot be regenerated each time player interact with loot container". Field-confirmed. Enabling this can make a single container farmable indefinitely.'; Status='Confirmed'; Startup=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecConsole; Key='Inventory.GiveDefaultInventory.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Give Default Inventory On Respawn'; Help='Funcom: "If false player wont be given default inventory on respawn. (default=true)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.Inventory.Item.Event.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Event Items Enabled'; Help='Funcom: "Are items which are only available from events enabled: 1 = enabled (default); 0 = disabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.Inventory.Item.Quest.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Quest Items Enabled'; Help='Funcom: "Are quest items which can be only looted and delivered enabled; 1: enabled (default); 0: disabled;".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.Inventory.Item.Slotless.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Slotless Items Enabled'; Help='Funcom: "Are items which don''t take slots and corresponding inventories enabled; 1: enabled (default); 0: disabled;".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.Exchange.AllowUncategorizedItems'; File='engine'; Type='bool01'; Default='0'; Label='Exchange Uncategorized Items'; Help='Funcom: "Display uncategorized items in the UI and allow them to be added to orders (default=false)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Contracts.Map.Markers.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Contract Map Markers'; Help='Funcom: "Toggle contracts map markers; 1: enabled (default); 0: disabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Contracts.IsHiddingOfContractLootItemsEnabled'; File='engine'; Type='bool01'; Label='Hide Contract Loot Items'; Help='Funcom: "Should contract loot items be hidden from the player". Funcom''s spelling is preserved in the key name.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.Contracts.Board.ShowAllContracts'; File='engine'; Type='bool01'; Default='0'; Label='Show Hidden Contracts'; Help='Funcom: "If true will show hidden contracts, like ones which only NPC can give. (default=false)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='All Encounters'; Help='Funcom: "Toggles encounters spawning: both random and static; Change to 0 at runtime destroys all existing encounters. Same as EncountersSetEnabled; 1: enabled (default); 0: disabled;". Broader than Random Encounters under Encounters: this covers static encounters too. Setting it to 0 while the server is running destroys existing encounters.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.LocationCooldown'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Encounter Location Cooldown'; Help='Funcom: "Encounter location remains on cooldown after an encounter is removed before it can be used again".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.PrioritizeNew'; File='engine'; Type='bool01'; Label='Prefer New Encounters'; Help='Funcom: "Any new encounter is preferred, disregarding encounter probability".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.LandscapeLocationsOnly'; File='engine'; Type='bool01'; Label='Landscape-Only Encounters'; Help='Funcom: "Only allows encounter spawns on landscape geometry".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.ExcludeCoveredLocations'; File='engine'; Type='bool01'; Label='Exclude Covered Encounter Spots'; Help='Funcom: "Excludes encounter spawn locations which are covered by other levels".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.InstigatorArea.Enabled'; File='engine'; Type='bool01'; Label='Encounter Instigator Areas'; Help='Funcom: "Allows encounter instigator areas".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.AllowExclusivityRange'; File='engine'; Type='bool01'; Label='Encounter Exclusivity Range'; Help='Funcom: "Allows checking exclusivity range".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.encounters.AreaLimits.Enabled.Override'; File='engine'; Type='select'; Default='-1'; Options=@(@{V='-1';L='No override'},@{V='0';L='Disabled'},@{V='1';L='Enabled'}); Label='Encounter Area Limits Override'; Help='Funcom: "Overrides area limits settings from ini file. -1 - not override. 0 - disabled. 1 - enabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Hazard.ZonesEnabled'; File='engine'; Type='bool01'; Label='Hazard Zones'; Help='Funcom: "Enables Hazard Zones". Environmental hazard zones such as quicksand. Sandworm danger zones are a separate setting under Sandworm.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Hazard.DestructionTime'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Hazard Destruction Time'; Help='Funcom: "Time it takes for a hazard to be removed from world after it is flagged for destruction".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Hazard.OrnithoptersSinkInQuicksandEnabled'; File='engine'; Type='bool01'; Default='0'; Label='Ornithopters Sink In Quicksand'; Help='Funcom: "[Default 0] If 0, no ornithopter will sink in quicksand".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Hazard.EnableQuicksandOnIGWBorders'; File='engine'; Type='bool01'; Default='0'; Label='Quicksand On Map Borders'; Help='Funcom: "[Default 0] If 0, quicksand placed along igw borders will be disabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Journey.EnableSpiceExposureEvents'; File='engine'; Type='bool01'; Default='1'; Label='Spice Exposure Events'; Help='Funcom: "Toggle to disable/enable spice exposure events. (0) Disabled; (1) Enabled (default)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Journey.EnableSimplifiedChallengeCompletion'; File='engine'; Type='bool01'; Label='Simplified Challenge Completion'; Help='Funcom: "Enable this to complete challenge when interacting with altar. Otherwise, complete on returning from challenge room after succefully completing it. (0) Disabled (default); (1) Enabled".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Progression.IgnorePrereqs'; File='engine'; Type='bool01'; Label='Ignore Training Module Prerequisites'; Help='Funcom: "If true, Training Modules can be equipped even if pre-reqs aren''t met".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Progression.ShowAllPerks'; File='engine'; Type='bool01'; Label='Show All Perks'; Help='Funcom: "If true, all Perks defined in data will be shown in the player''s Perks menu". May reveal perks that are defined in data but not finished.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.EnableFacingTargetCheck'; File='engine'; Type='bool01'; Label='NPCs Must Face Target To Fire'; Help='Funcom: "If set to 1, NPCs will check if facing their target before firing their weapon".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.FacingTargetAngleStartThreshold'; File='engine'; Type='float'; Min=0; Label='NPC Facing Angle To Start Firing'; Help='Funcom: "Set yaw angle threshold to prevent NPCs from start shooting their weapon if they aren''t facing their target". Only applies while NPCs Must Face Target To Fire is on.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.FacingTargetAngleStopThreshold'; File='engine'; Type='float'; Min=0; Label='NPC Facing Angle To Stop Firing'; Help='Funcom: "Set yaw angle threshold to stop NPCs shooting their weapon if they aren''t facing their target". Only applies while NPCs Must Face Target To Fire is on.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.EnableWeaponRotationRateOverride'; File='engine'; Type='bool01'; Label='NPC Weapon Rotation Rate Override'; Help='Funcom: "If set to 1, NPC''s yaw rotation rate is overriden if the rotation rate override firing pattern config has a or dummy weapon rotation rate override is set".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.DummyWeaponRotationRateOverride'; File='engine'; Type='float'; Min=0; Label='NPC Dummy Weapon Rotation Rate'; Help='Funcom: "If set value > 0, shooting weapon will use dummy rotation rate override instead of the weapon''s configured one". Only applies while NPC Weapon Rotation Rate Override is on.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.Respawn.StartCountdownOnEachNPCKilled'; File='engine'; Type='bool01'; Label='Restart NPC Respawn Timer Per Kill'; Help='Funcom: "If true, the respawn timer for NPC content will be restarted for each NPC killed".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.AllowDoorAutoAccessToAllNPCs'; File='engine'; Type='bool01'; Label='NPCs Use Pentashield Doors'; Help='Funcom: "if this option is on, all the NPCs can walk through the pentashield doors. If not, only assigned room descriptors can have a access".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.AllowDoorAutoAccessToAllNPCsRadius'; File='engine'; Type='float'; Min=0; Label='All-NPC Door Access Radius'; Help='Funcom: "When a radius is set, all NPCs will be granted access to doors within the radius when they spawn. This is applied when NPCAllowDoorAutoAccessToAllNPCs is on. default: 100000(1km)". Applies while NPCs Use Pentashield Doors is on.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='NPC.DoorAutoAccessRadius'; File='engine'; Type='float'; Min=0; Default='25000'; Label='NPC Door Access Radius'; Help='Funcom: "When a radius is set, NPCs will be granted access to doors within the radius when they spawn. default: 25000(250m)". 25000 is 250 metres.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormSharkwormRoam'; File='engine'; Type='select'; Default='0'; Options=@(@{V='0';L='Always off'},@{V='1';L='Always on'},@{V='2';L='Cooldown based'}); Label='Sharkworm Roaming'; Help='Funcom: "Determines if sharkworm roam is always on, always off or cooldown based. 0 = Always Off. 1 = Always On. 2 = Cooldown based. (default=0)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormDeathVolumeEnabled'; File='engine'; Type='bool01'; Default='1'; Label='Worm Death Volume'; Help='Funcom: "Specifies if the sandworm death volume is enabled. (default=true)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormCheckIfBreachLocationIsFreeOfPlayers'; File='engine'; Type='bool01'; Default='1'; Label='Worm Avoids Breaching On Players'; Help='Funcom: "Specifies if the sandworm should check if breach location is free of players. (default=true)". Turning this off lets a worm surface directly underneath players.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormCheckIfBreachLocationIsFreeOfVehicles'; File='engine'; Type='bool01'; Default='1'; Label='Worm Avoids Breaching On Vehicles'; Help='Funcom: "Specifies if the sandworm should check if breach location is free of vehicles. (default=true)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormOnTargetedCommuninetMessageEnabled'; File='engine'; Type='bool01'; Default='0'; Label='Worm Targeting Message'; Help='Funcom: "Specifies if a communinet message will be send to the player once they get targeted by the Sandworm. (default=false)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SafezoneExpansionOffset'; File='engine'; Type='float'; Min=-1; Default='-1'; Label='Worm Safe-Zone Expansion'; Help='Funcom: "Offset that will be used to expand the generated safezone. -1 = default value". Larger values make rock safe zones more forgiving.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.InflatedSafezoneExpansionOffset'; File='engine'; Type='float'; Min=-1; Default='-1'; Label='Worm Inflated Safe-Zone Expansion'; Help='Funcom: "Offset that will be used to create a inflated safezone around the regular safezone. -1 = default value".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='SecurityZones.UsePvPOverrideTable'; File='engine'; Type='bool01'; Default='0'; Label='Use PvP Override Security Zones'; Help='Funcom: "0: Using default SecurityZones table; 1: Using PvP Override SecurityZones table". Swaps the whole security-zone table, so it can change PvP rules across every zone at once.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.RelocationEnabled'; File='engine'; Type='bool01'; Label='Vehicle Relocation'; Help='Funcom: "Enables vehicle relocation". Relocation moves vehicles out of invalid positions.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.BackupTool.ChannelingTimer.Enabled'; File='engine'; Type='bool01'; Label='Vehicle Backup Channeling Timer'; Help='Funcom: "Enables vehicle BackupTool Channeling Timer. If enabled, backup tool operations will use a timer to delay execution. Timings defined in VehicleBackupToolBase". Adds the channel delay to vehicle backup actions; the tool itself is Vehicle Backup Tool.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.BlockDisassemblyInvalidLandclaim'; File='engine'; Type='bool01'; Default='1'; Label='Block Disassembly On Foreign Land Claim'; Help='Funcom: "Block vehicle disassembly on landclaim that the player does not have any permission; 0: off; 1: on (default)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.BlockDisassemblyVehicleHarnessed'; File='engine'; Type='bool01'; Default='1'; Label='Block Disassembly While Harnessed'; Help='Funcom: "Block vehicle disassembly if the vehicle is being harnessed; 0: off; 1: on (default)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.BlockDisassemblyVehicleInAir'; File='engine'; Type='bool01'; Default='1'; Label='Block Disassembly In Air'; Help='Funcom: "Block vehicle disassembly if the vehicle is in air; 0: off; 1: on (default)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.DisableWheeledVehicleTransfer'; File='engine'; Type='bool01'; Label='Disable Wheeled Vehicle Transfer'; Help='Funcom: "Defines wether wheeled (without being harnessed) vehicle transfer is allowed". Transfer here means moving a vehicle between map servers.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.LaunchCharacterOnVehicleCollision'; File='engine'; Type='bool01'; Default='1'; Label='Launch Characters On Collision'; Help='Funcom: "Launch the character on vehicle collision. Default 10: Disable, 1: Enable". Distinct from Vehicle Collision Damages Players, which controls damage rather than the push.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.CharacterHitVelocityModifier'; File='engine'; Type='float'; Min=0; Label='Vehicle Hit Push Force'; Help='Funcom: "Defines how hard character ragdoll gets pushed after getting hit by vehicle (limited by Vehicle.CharacterHitVelocityLimit)". How hard a struck character is thrown, capped by Vehicle Hit Push Limit.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.CharacterHitVelocityLimit'; File='engine'; Type='float'; Min=0; Label='Vehicle Hit Push Limit'; Help='Funcom: "Defines a limit (sanity check) to how hard character ragdoll gets pushed after getting hit by vehicle".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.TerminalVelocityOverride'; File='engine'; Type='float'; Min=0; Default='0'; Label='Vehicle Terminal Velocity Override'; Help='Funcom: "Override value for setting terminal velocity on a vehicle, 0.0f default (disabled)".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.MaxWeldingDistance'; File='engine'; Type='float'; Min=0; Label='Max Welding Distance'; Help='Funcom: "Maximum distance in centimeters a player can be away from a vehicle to do any welding action". In centimetres.'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SeatChangeHotkeysEnabled'; File='engine'; Type='bool01'; Label='Seat Change Hotkeys'; Help='Funcom: "If true, F1 - F8 while in a vehicle seat will change seat to the corresponding seat index.0: Disable, 1: Enable".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SeatChangeCooldown'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Seat Change Cooldown'; Help='Funcom: "Client-side cooldown for changing seats using hotkeys.While this cooldown is active, changing seats via hotkeys is blocked".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.VehicleSpawnerCheckVehicleRate'; File='engine'; Type='float'; Min=0; Unit='sec'; Label='Vehicle Spawner Check Rate'; Help='Funcom: "Time in seconds after which a vehicle spawner checks if the spawned vehicle is valid and still at the spawn area".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.VehicleDamageSmokeEnabled'; File='engine'; Type='bool01'; Label='Vehicle Damage Smoke'; Help='Funcom: "Enables vehicle damage smoke".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.VehicleSmokeTrailEnabled'; File='engine'; Type='bool01'; Label='Vehicle Smoke Trails'; Help='Funcom: "Enables vehicle smoke trails".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.BaseBackupShouldDetectNpcs'; File='engine'; Type='bool01'; Label='Base Backup Detects NPCs'; Help='Funcom: "Should the base backup tool detect NPCs inside the landclaim area".'; Category='Experimental 2' }
    @{ Section=$script:DuneGcSecConsole; Key='dw.EnableShelterInvestigation'; File='engine'; Type='bool01'; Label='Shelter Investigation'; Help='Funcom: "Enable and disable the shelter Investigation". A sub-system of the shelter system; the master switch is Shelter System.'; Category='Experimental 2' }

    # --- Parity additions (the reference implementation serverSettingsSchema) ---
    # ACCURACY NOTE (pending validation against the live UserGame.ini): the keys
    # below were NOT found in the stock DefaultGame.ini dump (docs/Dune_Server_INI_Field_Sheet.md,
    # game 1.4.0.0) and are NOT in the reference implementation's evidence-validated schema. They may
    # be no-ops as written and need confirmation before relying on them:
    #   - m_BuildingDecayRateMultiplier / bEnableBuildingStability / m_BaseBackupExtensions
    #     (m_BaseBackupExtensions duplicates the real m_BaseBackupMaxExtensions above)
    #   - m_StormCycleDuration / m_StormDuration / m_StormWarningDuration (real storm
    #     timing lives in SandStormConfig m_Coriolis*Duration* keys)
    #   - bPvPEnabled / bServerPVE (only m_bShouldForceEnablePvpOnAllPartitions is confirmed real)
    # Also suspect elsewhere in this schema: WormDetectionDistance (only valid nested
    # inside SandwormSettings RoamingSettings=(...), no-op as a standalone key) and
    # m_MinWormSpawnInternal (likely a typo'd / non-existent key name).
    # Building
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingDecayRateMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Decay Rate Multiplier'; Help='Scales how fast player buildings decay over time. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='bEnableBuildingStability'; File='game'; Type='bool'; Default='True'; Label='Enable Building Stability'; Help='Whether structural / stability rules apply to player constructions. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupExtensions'; File='game'; Type='int'; Min=0; Unit='slots'; Default='2'; Label='Starting Extensions'; Help='Default number of backup extension slots per base. Also needs client-side apply.'; ClientApply=$true; Category='BaseBackUp' }
    # Guilds & Economy
    @{ Section=$script:DuneGcSecPermission; Key='m_MaxPermissionsPerActor'; File='game'; Type='int'; Min=0; Unit='rules'; Default='32'; Label='Max Permissions per Actor'; Help='Maximum number of permission rules per actor / structure. Also needs client-side apply.'; ClientApply=$true; Category='Guilds & Economy' }
    # Storm Cycle
    @{ Section=$script:DuneGcSecStorm; Key='m_StormCycleDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='3600'; Label='Storm Cycle Duration'; Help='Total wall-clock duration of one full storm cycle (calm + storm + warning). Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='900'; Label='Storm Duration'; Help='How long the active sandstorm phase lasts per cycle. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormWarningDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Storm Warning Duration'; Help='Warning period (dust / audio cues) before the active storm phase begins. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    # PvP & Security
    @{ Section=$script:DuneGcSecPvP; Key='bPvPEnabled'; File='game'; Type='bool'; Default='False'; Label='PvP Enabled'; Help='Allow player-vs-player combat globally across the server. Also needs client-side apply.'; ClientApply=$true; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecPvP; Key='bServerPVE'; File='game'; Type='bool'; Default='True'; Label='Server PvE Mode'; Help='Enables global PvE protection (inverse of PvP; both can be set independently). Also needs client-side apply.'; ClientApply=$true; Category='PvP & Security' }
    # Spice
    @{ Section=$script:DuneGcSecSpice; Key='m_bSpawningActive'; File='game'; Type='bool'; Default='True'; Label='Spice Spawning Active'; Help='Master switch - whether spice nodes spawn on the map at all. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_bPlayerMustWitnessBloom'; File='game'; Type='bool'; Default='False'; Label='Player Must Witness Bloom'; Help='If true, a player must be present in the area for a spice bloom to register / count. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    # Taxation
    @{ Section=$script:DuneGcSecTaxation; Key='m_SpicePerHour'; File='game'; Type='float'; Min=0; Unit='spice/hr'; Default='11.904750'; Label='Spice Yield per Hour'; Help='Base spice amount generated per hour per active spice field under taxation. Also needs client-side apply.'; ClientApply=$true; Category='Taxation' }
    # Sandworm
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinDistanceBetweenSandworms'; File='game'; Type='float'; Min=0; Unit='UU'; Default='80000.0'; Label='Min Distance Between Sandworms'; Help='Minimum world-unit separation required between two simultaneously active sandworms. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_GiantWormMinimumPlayersOnSpiceField'; File='game'; Type='int'; Min=0; Unit='players'; Default='4'; Label='Giant Worm Min Players on Field'; Help='Minimum number of players on a spice field to trigger a giant sandworm spawn. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
)

# Experimental Lab catalog is intentionally lazy. Normal DST startup and Game
# Config schema requests must not parse or serialize 5,000+ recovered controls.
# The first Lab category request loads the catalog once; later category requests
# reuse the process cache.
$script:DuneAdvancedCvarCatalogPath = Join-Path $PSScriptRoot '..\..\data\advanced-cvars.json'
$script:DuneAdvancedCvarCatalogCache = $null
$script:DuneAdvancedCvarKeyMapCache = $null

function Initialize-DuneAdvancedCvarCatalog {
    if ($null -ne $script:DuneAdvancedCvarCatalogCache) { return }

    if (-not (Test-Path -LiteralPath $script:DuneAdvancedCvarCatalogPath)) {
        throw "Advanced CVar catalog not found: $script:DuneAdvancedCvarCatalogPath"
    }

    $advancedAliasesAlreadySurfaced = @(
        'Dune.PlayerDeathLootEnabled'
        'Sandworm.SandwormHibernationActive'
    )
    $existingCvars = @{}
    foreach ($field in $script:DuneGameConfigSchema) {
        if ($field.Section -eq $script:DuneGcSecConsole) {
            $existingCvars["$($field.Key)"] = $true
        }
    }

    # Windows PowerShell 5.1 emits a top-level JSON array as one pipeline object.
    # Direct assignment preserves its enumerable shape; @(... | ConvertFrom-Json)
    # would nest it and concatenate every property into one enormous field.
    $catalog = Get-Content -LiteralPath $script:DuneAdvancedCvarCatalogPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop
    $fields = New-Object 'System.Collections.Generic.List[object]'
    $keyMap = @{}
    foreach ($entry in $catalog) {
        $key = "$($entry.key)".Trim()
        if (-not $key -or $existingCvars.ContainsKey($key) -or $advancedAliasesAlreadySurfaced -contains $key) { continue }
        $fields.Add(@{
            section    = $script:DuneGcSecConsole
            key        = $key
            file       = 'engine'
            type       = 'string'
            default    = ''
            label      = if ($entry.label) { [string]$entry.label } else { $key }
            help       = [string]$entry.help
            group      = [string]$entry.group
            status     = [string]$entry.status
            source     = [string]$entry.source
            scope      = [string]$entry.scope
            risk       = [string]$entry.risk
            consoleVar = $true
        })
        $keyMap[$key] = $true
        $existingCvars[$key] = $true
    }
    $script:DuneAdvancedCvarCatalogCache = $fields.ToArray()
    $script:DuneAdvancedCvarKeyMapCache = $keyMap
}

function Get-DuneAdvancedCvarCatalog {
    Initialize-DuneAdvancedCvarCatalog
    return $script:DuneAdvancedCvarCatalogCache
}

function Get-DuneAdvancedCvarKeyMap {
    Initialize-DuneAdvancedCvarCatalog
    return $script:DuneAdvancedCvarKeyMapCache
}

function Test-DuneAdvancedCvarKey {
    param([string]$Key)
    if (-not $Key) { return $false }
    return (Get-DuneAdvancedCvarKeyMap).ContainsKey($Key)
}

function Get-DuneAdvancedCvarCategoriesApi {
    $groups = @{}
    foreach ($field in @(Get-DuneAdvancedCvarCatalog)) {
        $group = if ($field.group) { [string]$field.group } else { 'Uncategorized' }
        if (-not $groups.ContainsKey($group)) { $groups[$group] = 0 }
        $groups[$group]++
    }
    return @($groups.Keys | Sort-Object | ForEach-Object {
        @{ category = $_; count = [int]$groups[$_] }
    })
}

function Get-DuneAdvancedCvarCategoryApi {
    param([Parameter(Mandatory)][string]$Category)
    if ($Category -eq 'All') {
        return @(Get-DuneAdvancedCvarCatalog | Sort-Object key)
    }
    return @(
        Get-DuneAdvancedCvarCatalog |
            Where-Object { "$($_.group)" -eq $Category } |
            Sort-Object key
    )
}

function Search-DuneAdvancedCvarCatalogApi {
    param([Parameter(Mandatory)][string]$Query)
    $needle = $Query.Trim()
    if (-not $needle) { return @() }
    return @(
        Get-DuneAdvancedCvarCatalog |
            Where-Object {
                $haystack = @($_.key, $_.label, $_.help, $_.group) -join "`n"
                $haystack.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            Sort-Object key
    )
}

# Console variables are applied to the SERVER by the Hagga startup command, not
# by any INI - field-proven 2026-08-02, in both directions: the injection alone
# applied a value with both INIs blank, and both INIs set with the injection
# stripped did nothing. So mirroring a console variable into a player's client
# Engine.ini is never what makes it work on the server.
#
# A client copy only matters for the few console variables the CLIENT evaluates
# independently for its own UI. That has to be established per control, because
# mirroring one that the client does not read is not free:
#
#   1. It invites players to edit a file the game rewrites, for no effect.
#   2. It contaminates field testing. Client apply mirrors the whole managed set
#      onto the admin's own machine, so any result observed on his own server
#      could be coming from either side - which is exactly how the Maximum
#      Vehicles Per Player "Confirmed" status ended up resting on client-side
#      evidence.
#
# So this list is EVIDENCE-ONLY: a key earns a place by being field-proven to be
# read by the client, not by looking like it might be. Everything else stays
# server-side, where the injection already applies it. Bgd.* could never qualify
# regardless - those configure this server instance.
$script:DuneClientEvaluatedConsoleVariables = @(
    # Proven 2026-08-02: with this set ONLY in the client's Engine.ini, both a
    # live retail Funcom server and a DST server displayed the client's value,
    # overriding a server injection of 24. Retail cannot know that value, so the
    # client is reading its own file. (Display only - whether a server refuses
    # the extra vehicle is still untested.)
    'Vehicle.MaxVehiclesPerPlayer'

    # Proven 2026-08-03 by two independent tests. (1) Toggled ONLY in the
    # client's Engine.ini with the server left untouched: on and off each
    # produced the matching in-game behaviour. (2) Two players in the SAME
    # session on the SAME server saw different behaviour, decided by which of
    # them had the key in their own file. The client reads its own value.
    'Dune.DisableShieldOnShooting'
)

foreach ($field in $script:DuneGameConfigSchema) {
    if ($field.File -eq 'engine' -and
        $field.Section -eq $script:DuneGcSecConsole -and
        $script:DuneClientEvaluatedConsoleVariables -contains "$($field.Key)") {
        $field.ClientApply = $true
    }
}

# Experimental engine controls are binary-discovered console variables. Every
# explicitly configured non-default value is applied through both UserEngine.ini
# and the Hagga startup command, because INI-only application was field-tested
# and had no effect. The commands are rebuilt from the INI at battlegroup restart
# (see Invoke-DuneBattlegroupRestart), not on save. Both Experimental categories
# qualify - they differ only in how the UI groups them.
#
# Startup=$true carries that same injection with a control once it is PROMOTED
# out of Experimental into a real category. Without it, promotion would silently
# drop the control from the startup command and break the very setting being
# promoted - INI-only does nothing for these. Never widen this to every
# [ConsoleVariables] field: Bgd.ServerLoginPassword lives there and must never
# be written into a process command line.
#
# The same gap existed for the console variables that shipped in real categories
# BEFORE the Startup flag was introduced: they were written to UserEngine.ini and
# nowhere else, so they never reached the startup command either. Those controls
# now carry Startup=$true as well, and a test requires it of every engine-file
# console variable outside Experimental except the Bgd.* pair - Bgd.ServerDisplayName
# is injected per partition by the Sietch code, and Bgd.ServerLoginPassword must
# never reach a command line.
$script:DuneStartupConsoleVariableKeys = @(
    $script:DuneGameConfigSchema |
        Where-Object { $_.File -eq 'engine' -and ($_.Category -like 'Experimental*' -or $_.Startup -eq $true) } |
        ForEach-Object { $_.Key } |
        Sort-Object -Unique
)

$script:DuneStartupConsoleVariableCleanupOnlyKeys = @(
    'Travel.BgdRetryCount'
    'dw.ReturningPlayer.GiveAward.Enabled'
    'dw.ReturningPlayer.DaysBeforeEligibleForReward'
    'dw.ReturningPlayer.GiveAward.TierOverride'
    'Travel.CVarTravelBgdRetrySecondsGap'
    'Travel.CVarTravelBgdServerStatsTicker'
)

function Get-DuneStartupConsoleVariableCleanupOnlyKeyMap {
    $cleanupOnly = @{}
    foreach ($key in $script:DuneStartupConsoleVariableCleanupOnlyKeys) { $cleanupOnly[$key] = $true }
    return $cleanupOnly
}

function Get-DuneManagedStartupConsoleVariableKeyMap {
    $managed = @{}
    foreach ($key in $script:DuneStartupConsoleVariableKeys) { $managed[$key] = $true }
    foreach ($key in (Get-DuneAdvancedCvarKeyMap).Keys) { $managed[$key] = $true }
    foreach ($key in $script:DuneStartupConsoleVariableCleanupOnlyKeys) { $managed[$key] = $true }
    return $managed
}

function Test-DuneStartupConsoleVariableKey {
    param([string]$Key)
    if ($script:DuneStartupConsoleVariableKeys -contains $Key) { return $true }
    if ($script:DuneGameConfigSchema.Key -contains $Key) { return $false }
    return (Test-DuneAdvancedCvarKey -Key $Key)
}

# Experimental controls live on their own page, grouped by what they affect
# rather than by which decode pass found them. Namespace rules come first
# because they are exact - Sandworm.SandwormCheckIfBreachLocationIsFreeOfVehicles
# is a sandworm control, not a vehicle one - and keyword rules only catch the
# `dw.*` / `Dune.*` grab-bag afterwards. Anything unmatched is reported as
# Uncategorized rather than being forced into a group it does not belong in.
$script:DuneExperimentalGroupRules = @(
    @{ Name = 'Sandworm';               Match = '^(Sandworm|SandwormSubsystem)\.' }
    @{ Name = 'Vehicles';               Match = '^Vehicle\.' }
    @{ Name = 'Hazards & Storms';       Match = '^(Hazard|Sandstorm|Coriolis|SafeZone)\.' }
    @{ Name = 'NPCs & Encounters';      Match = '^(NPC|Ai|AI)\.' }
    @{ Name = 'Combat & Shields';       Match = '^(Dac|Combat)\.' }
    @{ Name = 'Progression & Contracts'; Match = '^(Landsraad|Contract|Contracts|Progression|Journey|JourneyStory|Abilities|TechKnowledge)\.' }
    @{ Name = 'Loot & Inventory';       Match = '^(Loot|Inventory|Exchange|Market)\.' }
    @{ Name = 'Survival & Shelter';     Match = '^(Deathstill|Hydration)\.' }
    @{ Name = 'Server & Session';       Match = '^Bgd\.' }
    @{ Name = 'Spice & Harvesting';     Match = '^SpiceHarvesting\.|spice|harvest|melange|bloom' }
    @{ Name = 'Survival & Shelter';     Match = 'deathstill|hydrat|water|thirst|blood|corpse|dehydr|shelter|temperature' }
    @{ Name = 'Fuel & Power';           Match = 'fuel|generator|power|energy|battery' }
    @{ Name = 'Vehicles';               Match = 'vehicle|ornithopter|harness|welding' }
    @{ Name = 'NPCs & Encounters';      Match = 'npc|encounter|critter' }
    @{ Name = 'Base Building & Backups'; Match = 'build|placeable|decay|claim|totem|deterior|repair|recycle|backup' }
    @{ Name = 'Loot & Inventory';       Match = 'loot|inventory|item|exchange|market|currency|solaris' }
    @{ Name = 'Combat & Shields';       Match = 'combat|damage|shield|stagger|knockback|duel|melee|weapon|pvp' }
    @{ Name = 'Progression & Contracts'; Match = 'contract|landsraad|progress|journey|perk|skill|abilit|respec|repsec|returningplayer' }
    @{ Name = 'Hazards & Storms';       Match = 'hazard|quicksand|storm|coriolis|safezone|sandbuildup' }
    @{ Name = 'Server & Session';       Match = 'server|session|hardcap|ccu' }
)

# Display order for these groups lives in the web UI (webui/src/pages/GameConfig.tsx),
# since ordering is presentation - keeping a second copy here would just drift.

function Get-DuneExperimentalGroup {
    param([Parameter(Mandatory)][string]$Key)
    foreach ($rule in $script:DuneExperimentalGroupRules) {
        if ($Key -match $rule.Match) { return $rule.Name }
    }
    return 'Uncategorized'
}

# -----------------------------------------------------------------------------
# Live INI paths inside the running battlegroup's PVC. These are resolved LIVE on
# every read/write (never cached): the PVC directory carries a hash that is
# UNIQUE per battlegroup, so a cached path would point at the wrong - or a
# deleted - battlegroup's INI after a VM switch or a battlegroup rebuild, even on
# the same IP. Templates are the fallback used when no BG has been provisioned.
# -----------------------------------------------------------------------------
$script:DuneGameConfigLiveGlobDir    = '/var/lib/rancher/k3s/storage/*/Saved/UserSettings'
$script:DuneGameConfigTplGamePath    = '/home/dune/.dune/download/scripts/setup/config/UserGame.ini'
$script:DuneGameConfigTplEnginePath  = '/home/dune/.dune/download/scripts/setup/config/UserEngine.ini'

# Cached, player-facing server name shown in the in-game server browser. This is
# the battlegroup title (CRD spec.title, e.g. "Reapers") — NOT Bgd.ServerDisplayName
# (which is the per-Sietch/world label). Read from the battlegroup CRD over SSH so
# the header status bar can show it; cached with a short TTL so the 10 s status poll
# never pays for a fresh SSH read every tick.
$script:DuneServerNameCache   = $null
$script:DuneServerNameFetched = [datetime]::MinValue
$script:DuneServerNameTtlSecs = 300

# The /api handler runs in a runspace POOL; each runspace has its own $script:
# scope, so an in-memory-only name cache flickers in the UI - whichever runspace
# serves a given 10 s status poll either has a warm cache (shows "Reapers") or a
# cold one (shows "Unknown"). Persist the last-known-good name + fetch time to a
# shared host-local JSON file so every runspace converges on the same value and
# only one runspace per TTL window pays for the SSH read.
function Get-DuneServerNameStatePath {
    $dir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'server-name.json')
}
function Read-DuneServerNameState {
    try {
        $p = Get-DuneServerNameStatePath
        if (Test-Path -LiteralPath $p) {
            $o = Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $n = if ($o.PSObject.Properties['name']) { [string]$o.name } else { '' }
            $t = [datetime]::MinValue
            if ($o.PSObject.Properties['fetchedAt']) {
                try { $t = [datetime]::Parse([string]$o.fetchedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
            }
            return @{ name = $n; fetchedAt = $t }
        }
    } catch {}
    return @{ name = ''; fetchedAt = [datetime]::MinValue }
}
function Write-DuneServerNameState {
    param([string]$Name)
    try {
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        $obj = [pscustomobject]@{ name = $Name.Trim(); fetchedAt = ([datetime]::UtcNow.ToString('o')) }
        Set-Content -LiteralPath (Get-DuneServerNameStatePath) -Value ($obj | ConvertTo-Json) -Encoding UTF8 -Force
    } catch {}
}

# Where each player applies the "client-side too" settings. These keys are read
# by BOTH server and client; changing them server-side only takes full effect
# once each player mirrors them in their LOCAL client config. Funcom's setup
# template flags some keys as "!Needs to also be applied to each client!"
# (corroborated for BuildingSettings by the snapetech RE index of Funcom's
# shipped DefaultGame.ini). The remaining flagged keys were confirmed by live
# in-game testing on a self-hosted server: the change had NO effect until the
# same value was also set in the client Game.ini. Sections currently flagged
# ClientApply=$true above include DuneGameMode, PlayerOnlineStateSettings,
# ItemDeteriorationConstants, CraftingSettings, BuildingSettings,
# InventorySystemSettings, CoriolisSubsystem, LandsraadSettings,
# SpiceHarvestingSystem, SandstormConfig, HydrationSubsystem,
# DuneSandboxGameModeBase, SpiceAddictionSubsystem, RespawnSettings,
# EncountersSubsystem, ContractsSubsystem, and SandwormSettings.
$script:DuneGameConfigClientPath = '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient\Game.ini'
$script:DuneGameConfigClientEnginePath = '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient\Engine.ini'

# Build the post-save "apply this on each client too" reminder from a set of
# structured updates (@{ file; section; key; value }). Returns @{ path; items }
# where items = the saved keys whose schema entry is flagged ClientApply. Empty
# items means nothing client-side to do.
function Get-DuneGameConfigClientApplyNotice {
    param([object[]]$Updates)
    $engineEnabled = Get-DuneGameConfigClientEngineEnabled
    $byKey = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        if (-not ($f.ContainsKey('ClientApply') -and $f.ClientApply)) { continue }
        if ($f.File -eq 'engine' -and -not $engineEnabled) { continue }
        $byKey[$f.Key] = $f
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($u in $Updates) {
        $k = "$($u.key)"
        if ($byKey.ContainsKey($k)) {
            $f = $byKey[$k]
            $items.Add(@{
                key       = $k
                label     = $f.Label
                section   = $f.Section
                file      = $f.File
                value     = "$($u.value)"
                structKey = $(if ($f.ContainsKey('StructKey')) {
                    "$($f.StructKey)"
                } elseif ($f.ContainsKey('ClientStructKey')) {
                    "$($f.ClientStructKey)"
                } else { '' })
            })
        }
    }
    return @{
        path  = $script:DuneGameConfigClientPath
        paths = @{ game = $script:DuneGameConfigClientPath; engine = $script:DuneGameConfigClientEnginePath }
        items = $items.ToArray()
    }
}

# -----------------------------------------------------------------------------
# LOCAL CLIENT CONFIG (admin's own machine; no SSH). DST runs locally, so it can
# read/write the player's client Game.ini directly. Used by the optional
# "apply to my client too" flow + the read-only client viewer.
# -----------------------------------------------------------------------------
$script:DuneGameConfigClientDirDefault     = '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient'
$script:DuneGameConfigClientGameFileName   = 'Game.ini'
$script:DuneGameConfigClientEngineFileName = 'Engine.ini'

# Engine.ini management is a disabled-by-default opt-in because the game
# rewrites this file and client-side CVar overrides can materially change play.
function Get-DuneGameConfigClientEngineEnabled {
    if (-not (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue)) { return $false }
    try {
        $cfg = Read-DuneConfig
        $value = if ($cfg -and $cfg.Contains('ClientEngineIniEnabled')) { "$($cfg['ClientEngineIniEnabled'])".Trim() } else { '' }
        return ($value -match '^(?i:true|1|yes|on)$')
    } catch {
        return $false
    }
}

# The admin's configured client-config FOLDER (persisted as ClientConfigPath in
# dune-server.config). Falls back to the per-user default. Returned UNEXPANDED so
# the UI box round-trips the literal value the user typed.
function Get-DuneGameConfigClientDir {
    $configured = ''
    if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
        try {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.Contains('ClientConfigPath')) { $configured = "$($cfg['ClientConfigPath'])".Trim() }
        } catch { }
    }
    if ($configured) { return $configured }
    return $script:DuneGameConfigClientDirDefault
}

# Expand env tokens (%LOCALAPPDATA% etc.) to a concrete filesystem path.
function Resolve-DuneGameConfigClientDir {
    param([string]$Dir = '')
    if (-not $Dir) { $Dir = Get-DuneGameConfigClientDir }
    return [Environment]::ExpandEnvironmentVariables($Dir)
}

# Full path to one client INI under the configured (or given) folder.
function Get-DuneGameConfigClientFilePath {
    param([string]$Dir = '', [ValidateSet('game','engine')][string]$File = 'game')
    $resolved = Resolve-DuneGameConfigClientDir -Dir $Dir
    $fileName = if ($File -eq 'engine') { $script:DuneGameConfigClientEngineFileName } else { $script:DuneGameConfigClientGameFileName }
    return (Join-Path $resolved $fileName)
}

# Read one LOCAL client INI and project it the same way the VM read does.
function Get-DuneGameConfigClientFile {
    param([string]$Dir = '', [ValidateSet('game','engine')][string]$File = 'game')
    $path   = Get-DuneGameConfigClientFilePath -Dir $Dir -File $File
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $raw    = ''
    if ($exists) { try { $raw = [IO.File]::ReadAllText($path) } catch { $raw = '' } }
    return @{
        file            = $File
        path            = $path
        exists          = [bool]$exists
        raw             = $raw
        sections        = (ConvertTo-DuneIniSectionsApi -Raw $raw)
        effective       = (Get-DuneIniEffective -Raw $raw)
        effectiveByKey  = (Get-DuneIniEffectiveByKey -Raw $raw)
        managedSections = (Get-DuneIniManagedSectionNames -Raw $raw)
    }
}

# Read the LOCAL client Game.ini + Engine.ini. Legacy top-level file fields keep
# representing Game.ini so existing land-claim callers remain compatible.
function Get-DuneGameConfigClient {
    param([string]$Dir = '')
    $dirRaw      = if ($Dir) { $Dir } else { Get-DuneGameConfigClientDir }
    $dirResolved = Resolve-DuneGameConfigClientDir -Dir $dirRaw
    $game        = Get-DuneGameConfigClientFile -Dir $dirRaw -File 'game'
    $engine      = Get-DuneGameConfigClientFile -Dir $dirRaw -File 'engine'
    return @{
        file            = 'game'
        dir             = $dirRaw
        dirResolved     = $dirResolved
        path            = $game.path
        exists          = $game.exists
        dirExists       = [bool](Test-Path -LiteralPath $dirResolved)
        default         = $script:DuneGameConfigClientDirDefault
        engineEnabled   = (Get-DuneGameConfigClientEngineEnabled)
        raw             = $game.raw
        sections        = $game.sections
        effective       = $game.effective
        effectiveByKey  = $game.effectiveByKey
        managedSections = $game.managedSections
        game            = $game
        engine          = $engine
    }
}

function Test-DuneGameClientRunning {
    return [bool](Get-Process -Name 'DuneSandbox-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Remove every client-applicable Engine.ini value DST can manage while leaving
# unrelated sections and keys intact. Used when the explicit opt-in is disabled.
function Remove-DuneGameConfigClientEngineValues {
    param([string]$Dir = '')
    $dirResolved = Resolve-DuneGameConfigClientDir -Dir $Dir
    $path = Get-DuneGameConfigClientFilePath -Dir $Dir -File 'engine'
    if (-not (Test-Path -LiteralPath $dirResolved)) {
        return @{ ok = $true; path = $path; removed = 0; changed = $false }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ ok = $true; path = $path; removed = 0; changed = $false }
    }

    $raw = [IO.File]::ReadAllText($path)
    $updates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.File -ne 'engine') { continue }
        # Removal sweeps everything DST could EVER have written here, not just
        # what it mirrors today. Earlier versions flagged every non-Bgd console
        # variable for client apply, so a user who had the opt-in on already has
        # those keys in their file; narrowing the write set must not orphan them.
        $wasManaged = ($f.ContainsKey('ClientApply') -and $f.ClientApply) -or
                      ($f.Section -eq $script:DuneGcSecConsole -and "$($f.Key)" -notlike 'Bgd.*')
        if (-not $wasManaged) { continue }
        if ($raw -match ('(?m)^\s*' + [regex]::Escape("$($f.Key)") + '\s*=')) {
            $updates.Add(@{ file = 'engine'; section = $f.Section; key = $f.Key; value = ''; remove = $true })
        }
    }
    if ($updates.Count -eq 0) {
        return @{ ok = $true; path = $path; removed = 0; changed = $false }
    }
    if (Test-DuneGameClientRunning) {
        throw 'Close Dune: Awakening before disabling client Engine.ini management; the game overwrites Engine.ini when it exits.'
    }

    $new = ConvertTo-DuneIniManaged -Raw $raw -Updates $updates.ToArray() -QuotedKeys (Get-DuneGameConfigQuotedKeys)
    $new = $new -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($false)))
    return @{ ok = $true; path = $path; removed = $updates.Count; changed = $true }
}

# Surgically upsert scalar keys into raw INI, preserving everything else. Used
# for the LOCAL client file so we touch only the requested keys (no whole-section
# absorption like the server-side managed-block writer). $Updates = array of
# @{ section; key; value }. Returns the new raw text (LF-joined).
function Set-DuneIniValuesInPlace {
    param([string]$Raw, [object[]]$Updates, [hashtable]$QuotedKeys)
    if ($null -eq $Raw) { $Raw = '' }
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    foreach ($u in $Updates) {
        $secName = "$($u.section)"
        $key     = "$($u.key)"
        if (-not $secName -or -not $key) { continue }
        # Target the LAST section with this name (UE5 last-wins ordering).
        $target = $null
        foreach ($s in $doc.sections) { if ($s.name -eq $secName) { $target = $s } }
        if ($u['remove']) {
            # Reset-to-default: remove every scalar occurrence of the key (if the
            # section doesn't exist there's nothing to do).
            if ($null -ne $target) {
                $removeAll = New-Object 'System.Collections.Generic.List[int]'
                for ($i = 0; $i -lt $target.body.Count; $i++) {
                    $info = Get-DuneIniLineKey $target.body[$i]
                    if ($info -and -not $info.isArray -and $info.key -eq $key) { $removeAll.Add($i) }
                }
                for ($j = $removeAll.Count - 1; $j -ge 0; $j--) { $target.body.RemoveAt($removeAll[$j]) }
            }
            continue
        }
        $valLine = "$key=" + (Format-DuneIniValue -Key $key -Value $u.value -QuotedKeys $QuotedKeys)
        if ($null -eq $target) {
            $target = @{ name = $secName; header = "[$secName]"; body = (New-Object 'System.Collections.Generic.List[string]'); managed = $false }
            $doc.sections.Add($target)
        }
        # Replace the FIRST scalar occurrence and strip any later duplicates of the
        # same key in this section. UE5 (and Get-DuneIniEffective) are last-wins, so
        # leaving a trailing duplicate would shadow our write and the value would
        # never appear to change. Collapsing to a single line keeps effective==written.
        $replaced  = $false
        $removeIdx = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $target.body.Count; $i++) {
            $info = Get-DuneIniLineKey $target.body[$i]
            if ($info -and -not $info.isArray -and $info.key -eq $key) {
                if (-not $replaced) { $target.body[$i] = $valLine; $replaced = $true }
                else { $removeIdx.Add($i) }
            }
        }
        for ($j = $removeIdx.Count - 1; $j -ge 0; $j--) { $target.body.RemoveAt($removeIdx[$j]) }
        if (-not $replaced) { $target.body.Add($valLine) }
    }
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in $doc.preamble) { $out.Add($l) }
    foreach ($s in $doc.sections) {
        $out.Add($s.header)
        foreach ($l in $s.body) { $out.Add($l) }
    }
    return (($out -join "`n") + "`n")
}

# Apply client-apply updates to LOCAL Game.ini / Engine.ini. Schema metadata,
# not caller input, selects the destination file. Both files use the same
# managed-block writer and preserve unrelated user settings.
function Save-DuneGameConfigClient {
    param([object[]]$Updates, [string]$Dir = '', [string]$DefaultsRaw = '')
    if (-not $Updates -or $Updates.Count -eq 0) { throw 'No updates supplied.' }

    $allowed = @{}
    $engineEnabled = Get-DuneGameConfigClientEngineEnabled
    foreach ($f in $script:DuneGameConfigSchema) {
        if (-not ($f.ContainsKey('ClientApply') -and $f.ClientApply)) { continue }
        if ($f.File -eq 'engine' -and -not $engineEnabled) { continue }
        $allowed[$f.Key] = $f
    }
    $clean = New-Object 'System.Collections.Generic.List[object]'
    foreach ($u in $Updates) {
        $k = "$($u.key)"
        if (-not $allowed.ContainsKey($k)) { continue }
        $f = $allowed[$k]
        $rm = if ($null -ne $u['remove']) { [bool]$u['remove'] } else { (Test-DuneGameConfigValueIsDefault -Key $k -Value "$($u.value)") }
        $clean.Add(@{ file = $f.File; section = $f.Section; key = $k; value = "$($u.value)"; remove = $rm })
    }
    if ($clean.Count -eq 0) { throw 'No client-applicable keys in the supplied updates.' }

    $dirResolved = Resolve-DuneGameConfigClientDir -Dir $Dir
    if (-not (Test-Path -LiteralPath $dirResolved)) { throw "Client config folder not found: $dirResolved" }
    if (@($clean | Where-Object { $_.file -eq 'engine' }).Count -gt 0 -and (Test-DuneGameClientRunning)) {
        throw 'Close Dune: Awakening before applying client Engine.ini settings; the game overwrites Engine.ini when it exits.'
    }

    $plans = New-Object 'System.Collections.Generic.List[object]'
    $quoted = Get-DuneGameConfigQuotedKeys
    foreach ($file in @('game','engine')) {
        $fileUpdates = New-Object 'System.Collections.Generic.List[object]'
        foreach ($u in $clean) {
            if ($u.file -eq $file) { $fileUpdates.Add($u) }
        }
        if ($fileUpdates.Count -eq 0) { continue }

        $path = Get-DuneGameConfigClientFilePath -Dir $Dir -File $file
        $existing = ''
        $created = $true
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $existing = [IO.File]::ReadAllText($path)
            $created = $false
        }

        if ($file -eq 'game') {
            foreach ($dk in $script:DuneGameConfigDeprecatedManagedKeys) {
                if ($existing -match ('(?m)^\s*' + [regex]::Escape($dk) + '\s*=')) {
                    $deprecated = @{ file = 'game'; section = $script:DuneGcSecGame; key = $dk; value = ''; remove = $true }
                    $fileUpdates.Add($deprecated)
                    $clean.Add($deprecated)
                }
            }
        }

        $defaultsForFile = if ($file -eq 'game') { $DefaultsRaw } else { '' }
        $folded = Convert-DuneSpicefieldUpdates -Raw $existing -Updates $fileUpdates.ToArray() -DefaultsRaw $defaultsForFile
        $folded = Convert-DuneStructUpdates -Raw $existing -Updates $folded -DefaultsRaw $defaultsForFile
        $new = ConvertTo-DuneIniManaged -Raw $existing -Updates $folded -QuotedKeys $quoted
        $new = $new -replace "`r?`n", "`r`n"
        $plans.Add(@{ file = $file; path = $path; created = $created; raw = $new; applied = $fileUpdates.Count })
    }

    $files = @{}
    foreach ($plan in $plans) {
        [IO.File]::WriteAllText($plan.path, $plan.raw, (New-Object System.Text.UTF8Encoding($false)))
        $files[$plan.file] = @{ file = $plan.file; path = $plan.path; created = $plan.created; applied = $plan.applied }
    }
    $first = $plans[0]
    return @{
        ok      = $true
        path    = $first.path
        paths   = @{
            game   = (Get-DuneGameConfigClientFilePath -Dir $Dir -File 'game')
            engine = (Get-DuneGameConfigClientFilePath -Dir $Dir -File 'engine')
        }
        files   = $files
        backup  = ''
        created = [bool](@($plans | Where-Object { $_.created }).Count -gt 0)
        applied = $clean.Count
        items   = $clean.ToArray()
    }
}

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

# =============================================================================
# UE STRUCT-MEMBER ENGINE (for settings Funcom stores as one nested struct, e.g.
# [/Script/DuneSandbox.LandsraadSettings] Data=(m_TaskGoalAmount=5000.0,...)).
# We only ever touch SCALAR members (key=number / key=True/False) via an anchored
# regex, so nested members (messages, curves, widget paths, gameplay tags) are
# preserved byte-for-byte. We never fully parse the struct — corrupting that line
# would break the whole feature in-game.
# =============================================================================

# Read every flat scalar member from a struct blob "(k1=v1,k2=v2,...)". Members
# whose value opens a nested paren or a quote are SKIPPED (not scalar). Returns a
# hashtable key -> value (trimmed).
function Get-DuneStructScalarMembers {
    param([string]$Blob)
    $out = @{}
    if ([string]::IsNullOrWhiteSpace($Blob)) { return $out }
    # key=value where value has no comma / paren / quote (a flat scalar). Anchored
    # to a member boundary: start-of-string, '(' or ','.
    $rx = [regex]'(?:^|[(,])\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^,()"]+?)\s*(?=[,)]|$)'
    foreach ($m in $rx.Matches($Blob)) {
        $out[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
    }
    return $out
}

# Set (or insert) a scalar member's value inside a struct blob, returning the new
# blob. If the key exists as a scalar member, its value is replaced in place
# (anchored so we never match a substring of another key or dive into a nested
# value). If it doesn't exist, it's inserted right after the opening '('.
function Set-DuneStructScalarMember {
    param([string]$Blob, [string]$Key, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $Blob }
    if ([string]::IsNullOrWhiteSpace($Blob)) { $Blob = '()' }
    $escKey = [regex]::Escape($Key)
    # (boundary)(key=)(value)  -> keep boundary+key, swap value. Value is a flat
    # scalar: no comma/paren/quote. Lookahead stops at the next member or ')'.
    $rx = [regex]("(?<pre>^|[(,])(?<k>\s*" + $escKey + "\s*=\s*)(?<v>[^,()`"]+?)(?=\s*[,)]|$)")
    if ($rx.IsMatch($Blob)) {
        return $rx.Replace($Blob, { param($m) $m.Groups['pre'].Value + $m.Groups['k'].Value + $Value }, 1)
    }
    # Insert after the first '('. Handle empty "()" without a leading comma.
    $open = $Blob.IndexOf('(')
    if ($open -lt 0) { return $Blob }
    $afterOpen = $Blob.Substring($open + 1)
    $sep = if ($afterOpen.TrimStart().StartsWith(')')) { '' } else { ',' }
    return $Blob.Substring(0, $open + 1) + "$Key=$Value$sep" + $afterOpen
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
            # the reference implementation block header comments before the first managed section: drop.
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

# Remove every scalar occurrence of $Key from a section body (leaves array +/-
# lines and other keys untouched). Used when a field is reset to its Funcom
# default so the key disappears from the managed block instead of being written.
function Remove-DuneScalarFromBody {
    param([System.Collections.Generic.List[string]]$Body, [string]$Key)
    for ($i = $Body.Count - 1; $i -ge 0; $i--) {
        $info = Get-DuneIniLineKey $Body[$i]
        if ($info -and -not $info.isArray -and $info.key -eq $Key) {
            $Body.RemoveAt($i)
        }
    }
}

function Remove-DuneTrailingBlankLines {
    param([System.Collections.Generic.List[string]]$Lines)
    while ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1].Trim() -eq '') {
        $Lines.RemoveAt($Lines.Count - 1)
    }
}

# Ensure each literal array line ("-Key=Value" / "+Key=Value") exists in a section
# body exactly once, appended in order after existing content. Match is exact on
# the trimmed line so re-applies de-dupe rather than piling duplicates. Used to
# inject the land-claim timer removal lines.
function Set-DuneArrayLinesInBody {
    param([System.Collections.Generic.List[string]]$Body, [string[]]$Lines)
    if (-not $Lines) { return }
    foreach ($line in $Lines) {
        $want = "$line".Trim()
        if (-not $want) { continue }
        $present = $false
        foreach ($b in $Body) { if ($b.Trim() -eq $want) { $present = $true; break } }
        if (-not $present) { $Body.Add($want) }
    }
}

# Remove every array (+/-) line for a given key from a section body, leaving that
# key's scalar line and all other keys untouched. Pairs with Remove-DuneScalarFromBody
# so a full land-claim disable clears both the scalar and its removal lines.
function Remove-DuneArrayLinesForKey {
    param([System.Collections.Generic.List[string]]$Body, [string]$Key)
    for ($i = $Body.Count - 1; $i -ge 0; $i--) {
        $info = Get-DuneIniLineKey $Body[$i]
        if ($info -and $info.isArray -and $info.key -eq $Key) { $Body.RemoveAt($i) }
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
    # De-dupe: a section name may legitimately appear more than once in the input
    # body (a pre-existing duplicate header). Emitting both copies leaves a
    # duplicate header in the output, and UE5 honours the FIRST header while
    # last-key-wins on values, silently dropping later keys. Collapse duplicates
    # into a single section at the FIRST occurrence's position, appending later
    # bodies in file order, so every section name appears exactly once.
    $remaining = New-Object 'System.Collections.Generic.List[object]'
    $remainingByName = @{}
    $remainingCount = @{}
    foreach ($s in $doc.sections) {
        if ($targetSet.ContainsKey($s.name)) { continue }
        if ($remainingByName.ContainsKey($s.name)) {
            $existing = $remainingByName[$s.name]
            foreach ($l in $s.body) { $existing.body.Add($l) }
            $remainingCount[$s.name] = $remainingCount[$s.name] + 1
        } else {
            $entry = @{ name = $s.name; header = $s.header; body = (New-Object 'System.Collections.Generic.List[string]') }
            foreach ($l in $s.body) { $entry.body.Add($l) }
            $remaining.Add($entry)
            $remainingByName[$s.name] = $entry
            $remainingCount[$s.name] = 1
        }
    }
    # Only merge bodies for names that actually collapsed (>1 occurrence) so a
    # normal single-occurrence section round-trips byte-for-byte. Merge keeps the
    # first scalar-key position carrying the last-wins value (engine semantics).
    foreach ($entry in $remaining) {
        if ($remainingCount[$entry.name] -gt 1) {
            $entry.body = Merge-DuneSectionBody -Lines $entry.body
        }
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
        # Single-section-per-key consistency: a schema key must live in EXACTLY one
        # section (its canonical one). The same key sitting in two sections (e.g.
        # m_CycleDurationInDays under both DuneGameMode and SandStormConfig) makes
        # edits/resets unpredictable — DST would update one copy while a stale copy
        # in another section shadows it. So whenever we touch a key, first strip it
        # from EVERY other section, then set/remove it in the target.
        #
        # This includes UNMANAGED body sections: a stale/foreign copy of the key
        # under a non-canonical section (e.g. an older DST schema that placed
        # m_bCoriolisAutoSpawnEnabled under CoriolisSubsystem, or a hand edit) would
        # otherwise survive a reset-to-default and shadow our write via the UI's
        # by-key fallback — leaving the setting stuck on its old value (the
        # "Coriolis Auto-Spawn won't toggle back On" bug). Consolidating every
        # occurrence into the declared section makes that section authoritative.
        $key = "$($u.key)"
        foreach ($other in $managed) {
            if ($other -ne $entry) { Remove-DuneScalarFromBody -Body $other.body -Key $key }
        }
        foreach ($other in $remaining) {
            Remove-DuneScalarFromBody -Body $other.body -Key $key
        }
        # An arrayLines-only update targets the +/-key= lines of an INI array
        # (e.g. one of the m_CraftingOutputMultiplierPerRecipeList entries) and
        # must NOT write a scalar `key=...` line. Detect it by the presence of
        # arrayLines / arrayRemove without a scalar 'value' payload.
        $hasArrayLines = $u.Contains('arrayLines')
        $hasArrayRemove = ($u['arrayRemove'] -eq $true)
        $hasScalarValue = $u.Contains('value')
        $isArrayOnly = (($hasArrayLines -or $hasArrayRemove) -and -not $hasScalarValue)
        if (-not $isArrayOnly) {
            if ($u['remove']) {
                # Reset-to-default: strip the key so the default is implied, not written.
                Remove-DuneScalarFromBody -Body $entry.body -Key $key
            } else {
                $fmt = Format-DuneIniValue -Key $key -Value $u.value -QuotedKeys $QuotedKeys
                Set-DuneScalarInBody -Body $entry.body -Key $key -Formatted $fmt
            }
        }
        # Optional array (+/-) line management for keys that carry them (the
        # land-claim staking timer and every array row surfaced in the
        # Advanced Settings editor as of v12.18.14). Only engaged when the
        # update explicitly supplies 'arrayLines' or 'arrayRemove', so every
        # existing scalar update is unaffected. On remove/arrayRemove, strip
        # every +/- line for the key; otherwise ensure the supplied literal
        # lines are present (de-duped).
        if ($u['remove'] -or $hasArrayRemove) {
            Remove-DuneArrayLinesForKey -Body $entry.body -Key $key
        } elseif ($hasArrayLines) {
            # Strip existing +/- lines first when this is an array-only edit
            # so the new set is authoritative (matches the UI's "edit these
            # entries" model). The land-claim path already supplies the full
            # replacement set inline, so this is safe there too.
            if ($isArrayOnly) {
                Remove-DuneArrayLinesForKey -Body $entry.body -Key $key
            }
            Set-DuneArrayLinesInBody -Body $entry.body -Lines ([string[]]$u['arrayLines'])
        }
    }

    # Scrub deprecated keys from DST-owned managed sections. These keys were once
    # in the schema but were removed after field testing proved them ineffective.
    # Because the managed block otherwise PRESERVES keys DST no longer recognises,
    # without this they would be orphaned in every existing user's file forever.
    # DST owns the managed block ("do not hand-edit"), so scrubbing known-dead keys
    # from it (and ONLY from it, never the user's own body sections) is safe.
    if ($managed.Count -gt 0 -and $script:DuneGameConfigDeprecatedManagedKeys.Count -gt 0) {
        foreach ($entry in $managed) {
            foreach ($dk in $script:DuneGameConfigDeprecatedManagedKeys) {
                Remove-DuneScalarFromBody -Body $entry.body -Key $dk
            }
        }
    }

    # Drop any managed section whose body is now empty (every key removed) so a
    # reset-to-default doesn't leave a bare [section] header behind.
    if ($managed.Count -gt 0) {
        $kept = New-Object 'System.Collections.Generic.List[object]'
        foreach ($entry in $managed) {
            $hasContent = $false
            foreach ($l in $entry.body) { if ($l.Trim() -ne '') { $hasContent = $true; break } }
            if ($hasContent) { $kept.Add($entry) }
        }
        $managed = $kept
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
                # Preserve the original line's array prefix ('+' array-append,
                # '-' array-remove, '' scalar) so the catalog can pass it up to
                # the UI. Without this the array editor can't rebuild the
                # correct +/-key= lines when saving edits, and would silently
                # convert '-'-remove entries into '+'-append entries.
                $prefix = ''
                $t = ([string]$l).TrimStart()
                if ($t.StartsWith('+')) { $prefix = '+' }
                elseif ($t.StartsWith('-')) { $prefix = '-' }
                $keys.Add(@{
                    key     = $info.key
                    value   = (Get-DuneIniLineValue $l).Trim()
                    isArray = [bool]$info.isArray
                    prefix  = $prefix
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

# Effective value indexed by KEY ALONE (last-wins across every section in file
# order). The UI uses this as a fallback when a schema field's value isn't in its
# declared section but DOES exist in another section, so the page reflects what
# is actually in UserGame.ini/UserEngine.ini instead of falling back to the
# Funcom default. (DST's write path consolidates such a key back into its
# canonical section on the next save.)
function Get-DuneIniEffectiveByKey {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $eff = @{}
    foreach ($s in $doc.sections) {
        foreach ($l in $s.body) {
            $info = Get-DuneIniLineKey $l
            if ($info -and -not $info.isArray) {
                $eff["$($info.key)"] = (Get-DuneIniLineValue $l).Trim()
            }
        }
    }
    # Struct-member fields (e.g. LandsraadSettings Data=(...)) aren't flat keys, so
    # surface their scalar members by-key too, so the UI shows their real values.
    foreach ($sm in (Get-DuneSchemaStructTargets)) {
        $sec = $null
        foreach ($s in $doc.sections) { if ($s.name -eq $sm.section) { $sec = $s } }
        if ($null -eq $sec) { continue }
        foreach ($l in $sec.body) {
            $info = Get-DuneIniLineKey $l
            if ($info -and -not $info.isArray -and $info.key -eq $sm.structKey) {
                $members = Get-DuneStructScalarMembers -Blob (Get-DuneIniLineValue $l)
                foreach ($k in $members.Keys) { $eff[$k] = $members[$k] }
            }
        }
    }
    $spiceMaps = Get-DuneIniSectionScalarValue -Raw $Raw -Section $script:DuneGcSecSpice -Key 'm_PerMapSystemSettings'
    $spiceFallback = Get-DuneIniSectionScalarValue -Raw $Raw -Section $script:DuneGcSecSpice -Key 'm_DefaultSystemSettings'
    foreach ($field in @($script:DuneGameConfigSchema | Where-Object { $_.ContainsKey('SpiceMap') })) {
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $spiceMaps `
            -MapId "$($field.SpiceMap)" -FieldType "$($field.SpiceFieldType)"
        if (-not $state.found) {
            $state = Get-DuneSpicefieldDefaultLimitsFromBlob -Blob $spiceFallback `
                -FieldType "$($field.SpiceFieldType)"
        }
        if ($state.found) {
            $eff[$field.Key] = if ("$($field.SpiceLimit)" -in @('Active', 'Both')) {
                "$($state.maxActive)"
            } else {
                "$($state.maxPrimed)"
            }
        }
    }
    return $eff
}

# Return the last scalar value for one exact section/key pair.
function Get-DuneIniSectionScalarValue {
    param([string]$Raw, [string]$Section, [string]$Key)
    $value = ''
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    foreach ($s in $doc.sections) {
        if ("$($s.name)" -ne $Section) { continue }
        foreach ($line in $s.body) {
            $info = Get-DuneIniLineKey $line
            if ($info -and -not $info.isArray -and "$($info.key)" -eq $Key) {
                $value = (Get-DuneIniLineValue $line).Trim()
            }
        }
    }
    return $value
}

# Find the balanced parenthesized range beginning at OpenIndex. Quotes are
# skipped so parentheses inside UE string values cannot terminate the range.
function Find-DuneBalancedParenthesisRange {
    param([string]$Text, [int]$OpenIndex)
    if ([string]::IsNullOrEmpty($Text) -or $OpenIndex -lt 0 -or
        $OpenIndex -ge $Text.Length -or $Text[$OpenIndex] -ne '(') {
        return $null
    }
    $depth = 0
    $quoted = $false
    for ($i = $OpenIndex; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '"' -and ($i -eq 0 -or $Text[$i - 1] -ne '\')) {
            $quoted = -not $quoted
            continue
        }
        if ($quoted) { continue }
        if ($ch -eq '(') { $depth++ }
        elseif ($ch -eq ')') {
            $depth--
            if ($depth -eq 0) {
                return @{ start = $OpenIndex; end = $i; length = ($i - $OpenIndex + 1) }
            }
            if ($depth -lt 0) { return $null }
        }
    }
    return $null
}

function Find-DuneSpicefieldMapRange {
    param([string]$Blob, [string]$MapId)
    if ([string]::IsNullOrWhiteSpace($Blob) -or [string]::IsNullOrWhiteSpace($MapId)) { return $null }
    $rx = [regex]('\(\s*"' + [regex]::Escape($MapId) + '"\s*,\s*\(')
    $match = $rx.Match($Blob)
    if (-not $match.Success) { return $null }
    return Find-DuneBalancedParenthesisRange -Text $Blob -OpenIndex $match.Index
}

function Find-DuneSpicefieldSizeRange {
    param([string]$MapBlob, [string]$FieldType)
    if ([string]::IsNullOrWhiteSpace($MapBlob) -or [string]::IsNullOrWhiteSpace($FieldType)) { return $null }
    $rx = [regex]('\(\s*\(\s*Name\s*=\s*"' + [regex]::Escape($FieldType) + '"\s*\)\s*,\s*\(')
    $match = $rx.Match($MapBlob)
    if (-not $match.Success) { return $null }
    return Find-DuneBalancedParenthesisRange -Text $MapBlob -OpenIndex $match.Index
}

function Get-DuneSpicefieldLimitsFromBlob {
    param([string]$Blob, [string]$MapId, [string]$FieldType)
    $mapRange = Find-DuneSpicefieldMapRange -Blob $Blob -MapId $MapId
    if (-not $mapRange) { return @{ found = $false } }
    $mapBlob = $Blob.Substring($mapRange.start, $mapRange.length)
    $sizeRange = Find-DuneSpicefieldSizeRange -MapBlob $mapBlob -FieldType $FieldType
    if (-not $sizeRange) { return @{ found = $false; mapFound = $true } }
    $sizeBlob = $mapBlob.Substring($sizeRange.start, $sizeRange.length)
    $primed = [regex]::Match($sizeBlob, '(?:^|[(,])\s*MaxGloballyPrimed\s*=\s*(\d+)')
    $active = [regex]::Match($sizeBlob, '(?:^|[(,])\s*MaxGloballyActive\s*=\s*(\d+)')
    if (-not $primed.Success -or -not $active.Success) {
        return @{ found = $false; mapFound = $true; malformed = $true }
    }
    return @{
        found     = $true
        mapFound  = $true
        maxPrimed = [int]$primed.Groups[1].Value
        maxActive = [int]$active.Groups[1].Value
    }
}

function Get-DuneSpicefieldDefaultLimitsFromBlob {
    param([string]$Blob, [string]$FieldType)
    if ([string]::IsNullOrWhiteSpace($Blob)) { return @{ found = $false } }
    $sizeRange = Find-DuneSpicefieldSizeRange -MapBlob $Blob -FieldType $FieldType
    if (-not $sizeRange) { return @{ found = $false } }
    $sizeBlob = $Blob.Substring($sizeRange.start, $sizeRange.length)
    $primed = [regex]::Match($sizeBlob, '(?:^|[(,])\s*MaxGloballyPrimed\s*=\s*(\d+)')
    $active = [regex]::Match($sizeBlob, '(?:^|[(,])\s*MaxGloballyActive\s*=\s*(\d+)')
    if (-not $primed.Success -or -not $active.Success) { return @{ found = $false; malformed = $true } }
    return @{
        found     = $true
        maxPrimed = [int]$primed.Groups[1].Value
        maxActive = [int]$active.Groups[1].Value
    }
}

function Set-DuneSpicefieldLimitsInBlob {
    param(
        [string]$Blob,
        [string]$MapId,
        [string]$FieldType,
        [int]$MaxActive,
        [int]$MaxPrimed,
        [string]$DefaultsBlob = ''
    )
    if ($MaxActive -lt 0 -or $MaxPrimed -lt 0) { throw 'Spicefield startup limits must be zero or greater.' }
    $mapRange = Find-DuneSpicefieldMapRange -Blob $Blob -MapId $MapId
    if (-not $mapRange -and -not [string]::IsNullOrWhiteSpace($DefaultsBlob)) {
        $defaultRange = Find-DuneSpicefieldMapRange -Blob $DefaultsBlob -MapId $MapId
        $outerOpen = $Blob.IndexOf('(')
        $outerRange = Find-DuneBalancedParenthesisRange -Text $Blob -OpenIndex $outerOpen
        if ($defaultRange -and $outerRange) {
            $defaultMap = $DefaultsBlob.Substring($defaultRange.start, $defaultRange.length)
            $inner = $Blob.Substring($outerRange.start + 1, $outerRange.length - 2).Trim()
            $separator = if ($inner) { ',' } else { '' }
            $Blob = $Blob.Substring(0, $outerRange.end) + $separator + $defaultMap +
                $Blob.Substring($outerRange.end)
            $mapRange = Find-DuneSpicefieldMapRange -Blob $Blob -MapId $MapId
        }
    }
    if (-not $mapRange) { throw "Spicefield startup map '$MapId' is absent from m_PerMapSystemSettings and live defaults." }
    $mapBlob = $Blob.Substring($mapRange.start, $mapRange.length)
    $sizeRange = Find-DuneSpicefieldSizeRange -MapBlob $mapBlob -FieldType $FieldType
    if ($sizeRange) {
        $sizeBlob = $mapBlob.Substring($sizeRange.start, $sizeRange.length)
        $primedRx = [regex]'(?<key>(?:^|[(,])\s*MaxGloballyPrimed\s*=\s*)\d+'
        $activeRx = [regex]'(?<key>(?:^|[(,])\s*MaxGloballyActive\s*=\s*)\d+'
        if ($primedRx.Matches($sizeBlob).Count -ne 1 -or $activeRx.Matches($sizeBlob).Count -ne 1) {
            throw "Spicefield startup entry '$MapId/$FieldType' is malformed."
        }
        $patchedSize = $primedRx.Replace($sizeBlob, { param($m) $m.Groups['key'].Value + $MaxPrimed }, 1)
        $patchedSize = $activeRx.Replace($patchedSize, { param($m) $m.Groups['key'].Value + $MaxActive }, 1)
        $patchedMap = $mapBlob.Substring(0, $sizeRange.start) + $patchedSize +
            $mapBlob.Substring($sizeRange.end + 1)
    } else {
        $settingsMatch = [regex]::Match($mapBlob, 'm_SpiceFieldTypeSettings\s*=\s*\(')
        if (-not $settingsMatch.Success) { throw "Spicefield settings list for '$MapId' is malformed." }
        $settingsOpen = $mapBlob.IndexOf('(', $settingsMatch.Index)
        $settingsRange = Find-DuneBalancedParenthesisRange -Text $mapBlob -OpenIndex $settingsOpen
        if (-not $settingsRange) { throw "Spicefield settings list for '$MapId' is unbalanced." }
        $entry = ',((Name="' + $FieldType + '"), (MaxGloballyPrimed=' + $MaxPrimed +
            ',MaxGloballyActive=' + $MaxActive + '))'
        $patchedMap = $mapBlob.Substring(0, $settingsRange.end) + $entry +
            $mapBlob.Substring($settingsRange.end)
    }
    return $Blob.Substring(0, $mapRange.start) + $patchedMap + $Blob.Substring($mapRange.end + 1)
}

# Distinct (section, structKey) pairs that the schema declares as struct parents.
function Get-DuneSchemaStructTargets {
    $seen = @{}
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.ContainsKey('StructKey') -and $f.StructKey) {
            $id = "$($f.Section)||$($f.StructKey)"
            if (-not $seen.ContainsKey($id)) {
                $seen[$id] = $true
                $out.Add(@{ section = $f.Section; structKey = $f.StructKey; file = $f.File })
            }
        }
    }
    return $out.ToArray()
}

function Get-DuneIniManagedSectionNames {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $names = @{}
    foreach ($s in $doc.sections) { if ($s.managed) { $names[$s.name] = $true } }
    # Comma operator forces array preservation through the function return so
    # ConvertTo-Json always serializes [] / ["one"] / [...] rather than
    # collapsing to {} (empty hashtable) or unwrapping a single-element array
    # to a scalar string. The webui's sectionIsManaged() expects an array.
    return ,[string[]]@($names.Keys)
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
    # Resolve LIVE every call - never cache. The User*.ini live under the running
    # battlegroup's PVC dir, whose hash is UNIQUE per battlegroup, so any cached
    # path would silently read/write the wrong (or a deleted) battlegroup's INI
    # after a VM switch or battlegroup rebuild - even on the same IP. We pick the
    # newest UserGame.ini (file mtime - the game touches it on write) and take
    # UserEngine.ini from that same dir, so both always come from one battlegroup.
    # $Force is accepted for call-site compatibility but is a no-op (always live).
    $dir = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'ls -t $($script:DuneGameConfigLiveGlobDir)/UserGame.ini 2>/dev/null | head -1 | xargs -r dirname'") -join '').Trim()
    if ($dir) {
        $g = "$dir/UserGame.ini"
        $e = "$dir/UserEngine.ini"
        $chk = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'test -f ''$g'' && test -f ''$e'' && echo ok'") -join '').Trim()
        if ($chk -eq 'ok') {
            return @{ game = $g; engine = $e; source = 'live' }
        }
    }
    # No live User*.ini yet (fresh server / battlegroup not provisioned). Fall back
    # to the seed template so the editor still renders sane defaults.
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
            effectiveByKey  = (Get-DuneIniEffectiveByKey -Raw $gameRaw)
            managedSections = (Get-DuneIniManagedSectionNames -Raw $gameRaw)
        }
        engine = @{
            path            = $paths.engine
            raw             = $engineRaw
            sections        = (ConvertTo-DuneIniSectionsApi -Raw $engineRaw)
            effective       = (Get-DuneIniEffective -Raw $engineRaw)
            effectiveByKey  = (Get-DuneIniEffectiveByKey -Raw $engineRaw)
            managedSections = (Get-DuneIniManagedSectionNames -Raw $engineRaw)
        }
    }
}

function Set-DuneStartupConsoleVariableOverrides {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [hashtable]$Values = @{}
    )
    if (-not (Get-Command Set-V6ConsoleVariableOverrides -ErrorAction SilentlyContinue)) {
        throw 'Battlegroup helper unavailable (K8s.ps1 not loaded).'
    }
    $result = Set-V6ConsoleVariableOverrides -Ip $Ip `
        -Names @($Values.Keys | Sort-Object) `
        -Values $Values `
        -ManagedNames (Get-DuneManagedStartupConsoleVariableKeyMap)
    if (-not $result.Success) {
        $why = if ($result.Error) { $result.Error } else { $result.Raw }
        throw "Startup CVar override failed: $why"
    }
    return $result
}

function Sync-DuneStartupConsoleVariableOverrides {
    param([Parameter(Mandatory)][string]$Ip)
    $config = Get-DuneGameConfig -Ip $Ip
    $values = @{}
    $managed = Get-DuneManagedStartupConsoleVariableKeyMap
    $cleanupOnly = Get-DuneStartupConsoleVariableCleanupOnlyKeyMap
    foreach ($key in @($config.engine.effectiveByKey.Keys)) {
        if (-not $managed.ContainsKey($key)) { continue }
        if ($cleanupOnly.ContainsKey($key)) { continue }
        if ($config.engine.effectiveByKey.ContainsKey($key)) {
            $candidate = "$($config.engine.effectiveByKey[$key])".Trim()
            if (-not (Test-DuneGameConfigValueIsDefault -Key $key -Value $candidate)) {
                $values[$key] = $candidate
            }
        }
    }
    return Set-DuneStartupConsoleVariableOverrides -Ip $Ip -Values $values
}

# Player-facing server name (the battlegroup title shown in the in-game server
# browser, e.g. "Reapers") for the status header. Read from the battlegroup CRD's
# spec.title, falling back to the operator-managed annotation. Returns '' when the
# VM is down, no battlegroup exists, or SSH is unavailable. Cached for
# $DuneServerNameTtlSecs so the frequent status poll repaints from cache; -Force
# re-reads (used by the manual refresh).
function Get-DuneServerName {
    param([switch]$Force, [switch]$CachedOnly)

    # Shared cross-runspace cache (see Read/Write-DuneServerNameState above) takes
    # precedence over the per-runspace in-memory cache so the pooled status poll
    # never flickers between the real name and "Unknown".
    $shared = Read-DuneServerNameState
    $sharedAge = ([datetime]::UtcNow - $shared.fetchedAt).TotalSeconds

    if (-not $Force -and $shared.name -and $sharedAge -lt $script:DuneServerNameTtlSecs) {
        $script:DuneServerNameCache   = $shared.name
        $script:DuneServerNameFetched = [datetime]::UtcNow
        return $shared.name
    }
    if ($CachedOnly) {
        if ($shared.name) { return $shared.name }
        if ($script:DuneServerNameCache) { return $script:DuneServerNameCache }
        return ''
    }

    $name = ''
    try {
        $ctx = Get-DuneGameConfigContext
        if ($ctx.ok -and (Get-Command Get-V6Battlegroup -ErrorAction SilentlyContinue)) {
            $info = Get-V6Battlegroup -Ip $ctx.ip
            $bg   = $info.Bg
            $title = $null
            if ($bg.PSObject.Properties['spec'] -and $bg.spec.PSObject.Properties['title']) {
                $title = "$($bg.spec.title)"
            }
            if ([string]::IsNullOrWhiteSpace($title) -and
                $bg.PSObject.Properties['metadata'] -and
                $bg.metadata.PSObject.Properties['annotations']) {
                $ann = $bg.metadata.annotations
                if ($ann.PSObject.Properties['igw.funcom.com/battlegroup-title']) {
                    $title = "$($ann.'igw.funcom.com/battlegroup-title')"
                }
            }
            if ($title) { $name = $title.Trim() }
        }
    } catch {
        $name = if ($shared.name) { $shared.name } else { '' }
    }

    if ($name) {
        $script:DuneServerNameCache   = $name
        $script:DuneServerNameFetched = [datetime]::UtcNow
        Write-DuneServerNameState -Name $name
        return $name
    }

    # Fetch yielded nothing (e.g. VM/BG down) - keep showing the last known good
    # name rather than blanking the header.
    if ($shared.name) { return $shared.name }
    $script:DuneServerNameCache   = ''
    $script:DuneServerNameFetched = [datetime]::UtcNow
    return ''
}

# Rename the server: patches the battlegroup CRD's spec.title (the name shown in
# the in-game server browser / status pages). This is a RESTART-class action -
# the operator recreates the battlegroup pods to apply the new title, so players
# are disconnected briefly and the server blips out of the browser then returns
# under the new name. No data is touched (identity/world key off the immutable
# metadata.name, not the title). Busts the cached name so the status header
# repaints immediately.
function Set-DuneServerName {
    param([Parameter(Mandatory)][string]$Name)

    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }
    if (-not (Get-Command Set-V6BattlegroupTitle -ErrorAction SilentlyContinue)) {
        return @{ ok=$false; status=503; message='Battlegroup helper unavailable (K8s.ps1 not loaded).' }
    }

    try {
        $res = Set-V6BattlegroupTitle -Ip $ctx.ip -Title $Name
    } catch {
        return @{ ok=$false; status=400; message=$_.Exception.Message }
    }
    if (-not $res.Success) {
        return @{ ok=$false; status=502; message="kubectl patch failed: $($res.Raw)" }
    }

    $script:DuneServerNameCache   = $res.NewTitle
    $script:DuneServerNameFetched = [datetime]::UtcNow
    Write-DuneServerNameState -Name $res.NewTitle

    return @{
        ok      = $true
        oldName = $res.OldTitle
        newName = $res.NewTitle
        message = "Server renamed to `"$($res.NewTitle)`". The battlegroup is restarting to apply the new name - players are disconnected briefly and it may take a minute to reappear in the server browser."
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

# Numeric/bool-aware comparison of a submitted value against a field's Funcom
# default. When they match, the caller drops the key from the INI (a reset) so
# defaults never clutter the managed block or the client Game.ini. Mirrors the
# webui valuesEqual() logic: 4 == 4.0, True == true, trimmed, case-insensitive.
function Test-DuneGameConfigValueIsDefault {
    param([string]$Key, [string]$Value)
    $field = $null
    foreach ($f in $script:DuneGameConfigSchema) { if ($f.Key -eq $Key) { $field = $f; break } }
    if ($null -eq $field) { return $false }
    if (-not $field.ContainsKey('Default')) { return $false }
    $def = [string]$field.Default
    $a = "$Value".Trim()
    $b = "$def".Trim()
    if ($a -ne '' -and $b -ne '') {
        $na = 0.0; $nb = 0.0
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        $sa = [double]::TryParse($a, [System.Globalization.NumberStyles]::Float, $ci, [ref]$na)
        $sb = [double]::TryParse($b, [System.Globalization.NumberStyles]::Float, $ci, [ref]$nb)
        if ($sa -and $sb) { return ($na -eq $nb) }
    }
    return ($a.ToLowerInvariant() -eq $b.ToLowerInvariant())
}

function Test-DuneStartupConsoleVariableValue {
    param([AllowEmptyString()][string]$Value)
    $raw = "$Value".Trim()
    if (-not $raw) { return $true }
    return ($raw.Length -le 512 -and $raw -notmatch '[,\x00-\x1F\x7F"]')
}

# Build a lookup: key -> @{ section; structKey; default } for every struct-member
# schema field, so the save path can recognise struct members and fold them.
function Get-DuneSchemaStructFieldMap {
    $map = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.ContainsKey('StructKey') -and $f.StructKey) {
            $map[$f.Key] = @{ section = $f.Section; structKey = $f.StructKey; default = [string]$f.Default }
        }
    }
    return $map
}

function Get-DuneSchemaSpicefieldFieldMap {
    $map = @{}
    foreach ($field in $script:DuneGameConfigSchema) {
        if (-not $field.ContainsKey('SpiceMap')) { continue }
        $map[$field.Key] = @{
            mapId     = "$($field.SpiceMap)"
            fieldType = "$($field.SpiceFieldType)"
            limit     = "$($field.SpiceLimit)"
            default   = [int]$field.Default
        }
    }
    return $map
}

# True if any of $Updates targets a struct-member schema field (e.g. a
# LandsraadSettings Data member). Callers use this to decide whether the
# (relatively expensive) DefaultGame.ini read is worth doing before saving.
function Test-DuneUpdatesHaveStructMember {
    param([object[]]$Updates)
    if (-not $Updates) { return $false }
    $structMap = Get-DuneSchemaStructFieldMap
    if ($structMap.Count -eq 0) { return $false }
    foreach ($u in $Updates) { if ($structMap.ContainsKey("$($u.key)")) { return $true } }
    return $false
}

function Test-DuneUpdatesHaveSpicefieldMember {
    param([object[]]$Updates)
    if (-not $Updates) { return $false }
    $spiceMap = Get-DuneSchemaSpicefieldFieldMap
    foreach ($update in $Updates) {
        if ($spiceMap.ContainsKey("$($update.key)")) { return $true }
    }
    return $false
}

# Find a struct blob "(...)" for ($Section, $StructKey) in a parsed INI doc.
# Returns the raw value (which may be the empty struct "()" the file explicitly
# carries) or $null when the section has no such (non-array) line at all.
function Get-DuneStructBlobFromDoc {
    param([object]$Doc, [string]$Section, [string]$StructKey)
    if (-not $Doc) { return $null }
    foreach ($s in $Doc.sections) {
        if ($s.name -eq $Section) {
            foreach ($l in $s.body) {
                $info = Get-DuneIniLineKey $l
                if ($info -and -not $info.isArray -and $info.key -eq $StructKey) { return (Get-DuneIniLineValue $l) }
            }
        }
    }
    return $null
}

# Fold struct-member updates (e.g. LandsraadSettings Data members) into ONE flat
# update that sets the parent struct key (Data) to the recomputed blob, leaving
# every non-struct update as-is. $Raw is the current file content (to read the
# existing blob). Returns the rewritten update list. A struct field's `remove`
# (reset to default) writes its Funcom default value into the struct rather than
# deleting the member, so the Data=() blob always stays well-formed.
#
# $DefaultsRaw is OPTIONAL raw DefaultGame.ini text. When the live file has NO
# struct line for a (section, structKey) -- typical of a fresh UserGame.ini -- we
# SEED the full default struct (all ~40 members the game ships) from $DefaultsRaw
# before folding the operator's edits, so the override does not REPLACE the UE
# struct with a stripped few-member stub. Two seeding triggers:
#   1. File has NO struct line at all (fresh UserGame.ini) -> seed full default.
#   2. File HAS a struct line but it's a legacy STUB (fewer scalar members than
#      the default box ships, written by an older DST build) -> rebuild from the
#      full default box and overlay the file's existing members so real
#      customizations survive while the ~35 dropped members are healed back.
# A struct box that is already at least as complete as the defaults is edited in
# place and NEVER reseeded (don't clobber a genuinely full/custom box). When
# $DefaultsRaw is empty/unavailable we can't reconstruct, so we keep the
# edit-in-place behaviour. The pure INI engine stays SSH-free: real callers fetch
# DefaultGame.ini and pass it in; unit tests can omit $DefaultsRaw entirely.
function Convert-DuneStructUpdates {
    param([string]$Raw, [object[]]$Updates, [string]$DefaultsRaw)
    $structMap = Get-DuneSchemaStructFieldMap
    if ($structMap.Count -eq 0) { return $Updates }
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $flat = New-Object 'System.Collections.Generic.List[object]'
    # Group struct member updates by "section||structKey".
    $structGroups = @{}
    foreach ($u in $Updates) {
        $k = "$($u.key)"
        if ($structMap.ContainsKey($k)) {
            $sm = $structMap[$k]
            $gid = "$($sm.section)||$($sm.structKey)"
            if (-not $structGroups.ContainsKey($gid)) {
                $structGroups[$gid] = @{ section = $sm.section; structKey = $sm.structKey; file = "$($u.file)"; members = (New-Object 'System.Collections.Generic.List[object]') }
            }
            $val = if ($u['remove']) { $sm.default } else { "$($u.value)" }
            $structGroups[$gid].members.Add(@{ key = $k; value = $val })
        } else {
            $flat.Add($u)
        }
    }
    $defaultsDoc = $null
    if (-not [string]::IsNullOrWhiteSpace($DefaultsRaw)) { $defaultsDoc = ConvertFrom-DuneIniDoc -Raw $DefaultsRaw }
    foreach ($gid in $structGroups.Keys) {
        $g = $structGroups[$gid]
        # Current blob for this section's struct key. $null means the live file has
        # NO struct line at all (distinct from an explicit, possibly-empty "()").
        $blob = Get-DuneStructBlobFromDoc -Doc $doc -Section $g.section -StructKey $g.structKey
        $seed = if ($defaultsDoc) { Get-DuneStructBlobFromDoc -Doc $defaultsDoc -Section $g.section -StructKey $g.structKey } else { $null }
        if ($null -eq $blob) {
            # Fresh file: seed the FULL default struct so the ~35 members the game
            # ships (board layouts, messages, curves, contract timings, ...) survive
            # the override instead of being wiped by a stripped few-member stub.
            $blob = if ($null -ne $seed) { $seed } else { '()' }
        } elseif ($null -ne $seed) {
            # File HAS a struct line. Heal a legacy STUB: if it carries fewer scalar
            # members than the default box ships, it's missing members the game needs
            # (an older DST build wrote a stripped box). Rebuild from the full default
            # box, then overlay the file's existing members so real customizations are
            # preserved. A box already at least as complete as defaults is left as-is.
            $existingMembers = Get-DuneStructScalarMembers -Blob $blob
            $defaultMembers  = Get-DuneStructScalarMembers -Blob $seed
            if ($existingMembers.Count -lt $defaultMembers.Count) {
                $healed = $seed
                foreach ($mk in $existingMembers.Keys) { $healed = Set-DuneStructScalarMember -Blob $healed -Key $mk -Value $existingMembers[$mk] }
                $blob = $healed
            }
        }
        foreach ($m in $g.members) { $blob = Set-DuneStructScalarMember -Blob $blob -Key $m.key -Value $m.value }
        $flat.Add(@{ file = $g.file; section = $g.section; key = $g.structKey; value = $blob })
    }
    return $flat.ToArray()
}

function Convert-DuneSpicefieldUpdates {
    param([string]$Raw, [object[]]$Updates, [string]$DefaultsRaw)
    $fieldMap = Get-DuneSchemaSpicefieldFieldMap
    if ($fieldMap.Count -eq 0) { return $Updates }
    $spiceUpdates = @($Updates | Where-Object { $fieldMap.ContainsKey("$($_.key)") })
    if ($spiceUpdates.Count -eq 0) { return $Updates }

    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $defaultsDoc = if ([string]::IsNullOrWhiteSpace($DefaultsRaw)) { $null } else {
        ConvertFrom-DuneIniDoc -Raw $DefaultsRaw
    }
    $blob = Get-DuneStructBlobFromDoc -Doc $doc -Section $script:DuneGcSecSpice `
        -StructKey 'm_PerMapSystemSettings'
    $defaultBlob = if ($defaultsDoc) {
        Get-DuneStructBlobFromDoc -Doc $defaultsDoc -Section $script:DuneGcSecSpice `
            -StructKey 'm_PerMapSystemSettings'
    } else { $null }
    if ($null -eq $blob) { $blob = $defaultBlob }
    if ([string]::IsNullOrWhiteSpace($blob)) {
        throw 'Funcom m_PerMapSystemSettings is unavailable; refusing to create a partial override.'
    }
    $existingFallback = Get-DuneStructBlobFromDoc -Doc $doc -Section $script:DuneGcSecSpice `
        -StructKey 'm_DefaultSystemSettings'
    $fallback = $existingFallback
    if ($null -eq $fallback -and $defaultsDoc) {
        $fallback = Get-DuneStructBlobFromDoc -Doc $defaultsDoc -Section $script:DuneGcSecSpice `
            -StructKey 'm_DefaultSystemSettings'
    }

    $flat = New-Object 'System.Collections.Generic.List[object]'
    foreach ($update in $Updates) {
        $key = "$($update.key)"
        if (-not $fieldMap.ContainsKey($key)) {
            $flat.Add($update)
            continue
        }
        $field = $fieldMap[$key]
        $state = Get-DuneSpicefieldLimitsFromBlob -Blob $blob -MapId $field.mapId `
            -FieldType $field.fieldType
        if (-not $state.found) {
            $state = Get-DuneSpicefieldDefaultLimitsFromBlob -Blob $fallback `
                -FieldType $field.fieldType
        }
        if ($update['remove']) {
            if ([string]::IsNullOrWhiteSpace($defaultBlob)) {
                throw 'Funcom spicefield defaults are unavailable; refusing an inexact reset.'
            }
            $defaultState = Get-DuneSpicefieldLimitsFromBlob -Blob $defaultBlob `
                -MapId $field.mapId -FieldType $field.fieldType
            if ($defaultState.malformed) {
                throw "Funcom spicefield default '$($field.mapId)/$($field.fieldType)' is malformed; refusing an inexact reset."
            }
            if (-not $defaultState.found) {
                throw "Funcom spicefield default '$($field.mapId)/$($field.fieldType)' is absent; refusing an inexact reset."
            }
            $active = [int]$defaultState.maxActive
            $primed = [int]$defaultState.maxPrimed
        } else {
            $parsed = 0
            if (-not [int]::TryParse("$($update.value)", [ref]$parsed) -or $parsed -lt 0) {
                throw "$key must be a whole number zero or greater."
            }
            $active = if ($state.found) { [int]$state.maxActive } else { [int]$field.default }
            $primed = if ($state.found) { [int]$state.maxPrimed } else { [int]$field.default }
            if ($field.limit -in @('Active', 'Both')) { $active = $parsed }
            if ($field.limit -in @('Primed', 'Both')) { $primed = $parsed }
        }
        $blob = Set-DuneSpicefieldLimitsInBlob -Blob $blob -MapId $field.mapId `
            -FieldType $field.fieldType -MaxActive $active -MaxPrimed $primed `
            -DefaultsBlob $defaultBlob
    }
    $flat.Add(@{
        file='game'; section=$script:DuneGcSecSpice; key='m_PerMapSystemSettings'
        value=$blob; remove=$false
    })
    if ($null -eq $existingFallback -and $null -ne $fallback) {
        $flat.Add(@{
            file='game'; section=$script:DuneGcSecSpice; key='m_DefaultSystemSettings'
            value=$fallback; remove=$false
        })
    }
    return $flat.ToArray()
}

# Save structured updates. $Updates = array of @{ file; section; key; value }.
# Does NOT auto-backup — backups are manual (Backup settings button) to avoid
# cluttering the server PVC with a .dstbak per save.
function Save-DuneGameConfig {
    param(
        [string]$Ip,
        [object[]]$Updates,
        [hashtable]$ResolvedPaths
    )
    if (-not $Updates -or $Updates.Count -eq 0) { return }
    $paths  = if ($ResolvedPaths) { $ResolvedPaths } else { Resolve-DuneGameConfigPaths -Ip $Ip }
    $quoted = Get-DuneGameConfigQuotedKeys

    $byFile = @{ game = (New-Object 'System.Collections.Generic.List[object]'); engine = (New-Object 'System.Collections.Generic.List[object]') }
    foreach ($u in $Updates) {
        $f = "$($u.file)"
        if ($byFile.ContainsKey($f)) { $byFile[$f].Add($u) }
    }

    # When any struct-member edit is present, read DefaultGame/Engine.ini ONCE so a
    # fresh UserGame.ini can seed the FULL default struct before folding edits
    # (otherwise the override wipes the ~35 nested LandsraadSettings members). A
    # defaults-read failure (e.g. no running pod) falls back to prior behaviour.
    $defaults = $null
    if ((Test-DuneUpdatesHaveStructMember -Updates $Updates) -or
        (Test-DuneUpdatesHaveSpicefieldMember -Updates $Updates)) {
        try { $defaults = Get-DuneGameConfigDefaults -Ip $Ip } catch { $defaults = $null }
    }

    foreach ($f in @('game','engine')) {
        if ($byFile[$f].Count -eq 0) { continue }
        $path = if ($f -eq 'game') { $paths.game } else { $paths.engine }
        $raw  = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$path' 2>/dev/null") -join "`n"
        $defRaw = if ($defaults) { if ($f -eq 'game') { "$($defaults.game)" } else { "$($defaults.engine)" } } else { '' }
        # Fold any struct-member updates (e.g. LandsraadSettings Data members) into
        # a single parent-key update against the file's current blob (seeding from
        # defaults when the file has no prior struct).
        $fileUpdates = Convert-DuneSpicefieldUpdates -Raw $raw -Updates $byFile[$f].ToArray() -DefaultsRaw $defRaw
        $fileUpdates = Convert-DuneStructUpdates -Raw $raw -Updates $fileUpdates -DefaultsRaw $defRaw
        $new  = ConvertTo-DuneIniManaged -Raw $raw -Updates $fileUpdates -QuotedKeys $quoted
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
        Invoke-V6Ssh -Ip $Ip -Cmd "base64 -d | sudo tee '$path' > /dev/null" -StdinData $b64 -TimeoutSec 30 | Out-Null
    }
}

function Save-DuneGameConfigLocked {
    param(
        [string]$Ip,
        [object[]]$Updates,
        [hashtable]$ResolvedPaths
    )
    Invoke-WithDuneLock -Name 'gameconfig-ini' -Script {
        Save-DuneGameConfig -Ip $Ip -Updates $Updates -ResolvedPaths $ResolvedPaths
    } | Out-Null
}

# =============================================================================
# DEEP DESERT PER-PARTITION PVP
# =============================================================================

function Get-DuneDeepDesertPvpIniState {
    param([string]$Raw)
    $forceAll = $false
    $selected = @{}
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    foreach ($section in $doc.sections) {
        if ("$($section.name)" -ne $script:DuneGcSecPvP) { continue }
        foreach ($line in $section.body) {
            $trim = "$line".Trim()
            if ($trim -match '^m_bShouldForceEnablePvpOnAllPartitions\s*=\s*(True|False)\s*$') {
                $forceAll = ($Matches[1] -eq 'True')
            } elseif ($trim -match '^\+?m_PvpEnabledPartitions\s*=\s*(\d+)\s*$') {
                $selected[[int]$Matches[1]] = $true
            }
        }
    }
    return @{
        forceAll            = [bool]$forceAll
        selectedPartitionIds = @($selected.Keys | Sort-Object)
    }
}

function New-DuneDeepDesertPvpUpdates {
    param([int[]]$PartitionIds)
    $ids = @($PartitionIds | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $updates = New-Object 'System.Collections.Generic.List[object]'
    $updates.Add(@{
        file='game'; section=$script:DuneGcSecPvP
        key='m_bShouldForceEnablePvpOnAllPartitions'; value='False'; remove=$false
    })
    if ($ids.Count -gt 0) {
        $updates.Add(@{
            file='game'; section=$script:DuneGcSecPvP; key='m_PvpEnabledPartitions'
            arrayLines=@($ids | ForEach-Object { "+m_PvpEnabledPartitions=$_" })
        })
    } else {
        $updates.Add(@{
            file='game'; section=$script:DuneGcSecPvP; key='m_PvpEnabledPartitions'
            arrayRemove=$true
        })
    }
    return ,$updates.ToArray()
}

function Get-DuneDeepDesertPvp {
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    $live = Get-DuneGameConfig -Ip $ctx.ip
    $iniState = Get-DuneDeepDesertPvpIniState -Raw "$($live.game.raw)"
    $dd = Get-V6DeepDesertInstances -Ip $ctx.ip
    $globalName = ''
    try { $globalName = "$($live.engine.effective["$script:DuneGcSecConsole||Bgd.ServerDisplayName"])" } catch {}
    if (-not $globalName) { $globalName = "$($dd.Title)" }

    $selectedLookup = @{}
    foreach ($id in @($iniState.selectedPartitionIds)) { $selectedLookup[[int]$id] = $true }
    $instances = @($dd.Instances | ForEach-Object {
        $id = [int]$_.PartitionId
        @{
            map               = "$($_.Map)"
            partitionId       = $id
            dimension         = [int]$_.Dimension
            phase             = "$($_.Phase)"
            ready             = [bool]$_.Ready
            gamePort          = [int]$_.GamePort
            serverDisplayName = if ($_.ServerDisplayName) { "$($_.ServerDisplayName)" } elseif ($globalName) { $globalName } else { "Deep Desert partition $id" }
            pvpEnabled        = $selectedLookup.ContainsKey($id) -or [bool]$iniState.forceAll
        }
    })
    $activeLookup = @{}
    foreach ($row in $instances) { $activeLookup[[int]$row.partitionId] = $true }
    $configuredLookup = @{}
    foreach ($id in @($dd.ConfiguredPartitionIds)) { $configuredLookup[[int]$id] = $true }
    $inactiveSelected = @($iniState.selectedPartitionIds | Where-Object {
        $configuredLookup.ContainsKey([int]$_) -and -not $activeLookup.ContainsKey([int]$_)
    })
    $staleSelected = @($iniState.selectedPartitionIds | Where-Object {
        -not $configuredLookup.ContainsKey([int]$_)
    })

    return @{
        ok                           = $true
        enabled                      = ([bool]$iniState.forceAll -or @($iniState.selectedPartitionIds).Count -gt 0)
        forceAll                     = [bool]$iniState.forceAll
        selectedPartitionIds         = @($iniState.selectedPartitionIds)
        inactiveSelectedPartitionIds = $inactiveSelected
        staleSelectedPartitionIds    = $staleSelected
        instances                    = $instances
    }
}

function Set-DuneDeepDesertPvp {
    param([Parameter(Mandatory)][bool]$Enabled, [int[]]$PartitionIds)
    $ctx = Get-DuneGameConfigContext
    if (-not $ctx.ok) { return @{ ok=$false; status=$ctx.status; message=$ctx.message } }

    $current = Get-DuneDeepDesertPvp
    if (-not $current.ok) { return $current }
    $activeLookup = @{}
    foreach ($row in @($current.instances)) { $activeLookup[[int]$row.partitionId] = $true }

    $requested = @($PartitionIds | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($Enabled -and $requested.Count -eq 0) {
        return @{ ok=$false; status=400; message='Select at least one running Deep Desert partition for PvP.' }
    }
    foreach ($id in $requested) {
        if (-not $activeLookup.ContainsKey([int]$id)) {
            return @{ ok=$false; status=400; message="Partition $id is not a currently running DeepDesert_1 instance. Refresh and try again." }
        }
    }

    $desired = @()
    if ($Enabled) {
        # Preserve selected partitions that are currently spun down and hidden.
        $desired = @($requested + @($current.inactiveSelectedPartitionIds) | Sort-Object -Unique)
    }
    Save-DuneGameConfigLocked -Ip $ctx.ip -Updates (New-DuneDeepDesertPvpUpdates -PartitionIds $desired)
    $restart = Restart-DuneMapPods -Key 'deepdesert'
    $state = Get-DuneDeepDesertPvp
    $state.ok = $true
    $state.restart = $restart
    $state.message = if ($Enabled) {
        "Saved Deep Desert PvP for partition(s) $($requested -join ', '). Running Deep Desert instances are restarting to apply it."
    } else {
        'Disabled Deep Desert partition PvP. Running Deep Desert instances are restarting to apply it.'
    }
    return $state
}

# =============================================================================
# LAND-CLAIM (STAKING UNIT) EXTENSION TIMER
# =============================================================================
# A single admin-entered "seconds" value collapses the game's default staking-unit
# extension schedule (a doubling 60..30720s array) down to one custom duration.
# Written into [/Script/DuneSandbox.BuildingSettings] of BOTH the server 'game'
# file and the local client Game.ini as: the two scalar *DefaultTimes keys set to
# the value, plus array-remove (-) lines that strip each built-in schedule entry.

# Build the literal array-remove lines for one staking key from the default schedule.
function Get-DuneLandclaimRemovalLines {
    param([string]$Key)
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($n in $script:DuneLandclaimDefaultRemovals) {
        $out.Add(('-{0}={1:F6}' -f $Key, [double]$n))
    }
    return ,$out.ToArray()
}

# Build the exact, shareable client Game.ini block for a given seconds value, so
# the admin can hand it to connecting players (this setting is client-side too and
# only takes effect for a player if THEIR Game.ini carries the same block). Uses
# the same keys + removal schedule as the writer, so the snippet always matches
# what DST writes. CRLF-joined for pasting into a Windows client Game.ini.
function Get-DuneLandclaimClientBlock {
    param([string]$Seconds)
    if ("$Seconds".Trim() -eq '') { return '' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('[' + $script:DuneGcSecBuilding + ']')
    foreach ($key in $script:DuneLandclaimKeys) { $lines.Add("$key=$Seconds") }
    foreach ($key in $script:DuneLandclaimKeys) {
        foreach ($line in (Get-DuneLandclaimRemovalLines -Key $key)) { $lines.Add($line) }
    }
    return ($lines -join "`r`n")
}

# Build the managed-writer update objects for the land-claim timer.
#   Enabled  -> set both scalars to $Seconds and inject the removal (-) lines.
#   Disabled -> remove both scalars and strip their removal lines (game default).
# $File is 'game' (server UserGame.ini) or 'client' (local Game.ini).
function Build-DuneLandclaimUpdates {
    param([bool]$Enabled, [string]$Seconds, [string]$File = 'game')
    $ups = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $script:DuneLandclaimKeys) {
        if ($Enabled) {
            $ups.Add(@{
                file       = $File
                section    = $script:DuneGcSecBuilding
                key        = $key
                value      = "$Seconds"
                remove     = $false
                arrayLines = (Get-DuneLandclaimRemovalLines -Key $key)
            })
        } else {
            $ups.Add(@{
                file        = $File
                section     = $script:DuneGcSecBuilding
                key         = $key
                value       = ''
                remove      = $true
                arrayRemove = $true
            })
        }
    }
    return ,$ups.ToArray()
}

# Parse land-claim timer state from raw INI text (pure / unit-testable).
# enabled     = both staking scalar keys have an effective value.
# seconds     = that shared value (empty when disabled).
# formattedOk = enabled AND both keys carry the full set of removal (-) lines AND
#               the two scalar values agree — i.e. DST's own well-formed block.
function Get-DuneLandclaimTimerState {
    param([string]$Raw)
    $doc = ConvertFrom-DuneIniDoc -Raw $Raw
    $scalar     = @{}
    $arrayCount = @{}
    foreach ($k in $script:DuneLandclaimKeys) { $arrayCount[$k] = 0 }
    foreach ($s in $doc.sections) {
        if ($s.name -ne $script:DuneGcSecBuilding) { continue }
        foreach ($line in $s.body) {
            $info = Get-DuneIniLineKey $line
            if (-not $info) { continue }
            if ($script:DuneLandclaimKeys -notcontains $info.key) { continue }
            if ($info.isArray) {
                if ("$line".Trim().StartsWith('-')) { $arrayCount[$info.key] = $arrayCount[$info.key] + 1 }
            } else {
                $scalar[$info.key] = (Get-DuneIniLineValue $line).Trim()
            }
        }
    }
    $k1 = $script:DuneLandclaimKeys[0]; $k2 = $script:DuneLandclaimKeys[1]
    $has1 = $scalar.ContainsKey($k1); $has2 = $scalar.ContainsKey($k2)
    $enabled = [bool]($has1 -and $has2)
    $seconds = if ($has1) { $scalar[$k1] } elseif ($has2) { $scalar[$k2] } else { '' }
    $expected = $script:DuneLandclaimDefaultRemovals.Count
    $formattedOk = [bool]($enabled -and ($arrayCount[$k1] -ge $expected) -and ($arrayCount[$k2] -ge $expected) -and ($scalar[$k1] -eq $scalar[$k2]))
    return @{ enabled = $enabled; seconds = "$seconds"; formattedOk = $formattedOk }
}

# Read the current land-claim timer state from the server game file + the local
# client Game.ini. Server read failure (no running VM) returns available=$false.
function Get-DuneLandclaimTimer {
    param([string]$Ip)
    $server = @{ available = $false; enabled = $false; seconds = ''; formattedOk = $false }
    try {
        $paths = Resolve-DuneGameConfigPaths -Ip $Ip
        $raw   = (Invoke-V6Ssh -Ip $Ip -Cmd "sudo cat '$($paths.game)' 2>/dev/null") -join "`n"
        $st    = Get-DuneLandclaimTimerState -Raw $raw
        $server = @{ available = $true; enabled = $st.enabled; seconds = $st.seconds; formattedOk = $st.formattedOk; path = $paths.game }
    } catch {
        $server = @{ available = $false; enabled = $false; seconds = ''; formattedOk = $false; error = "$($_.Exception.Message)" }
    }

    $client = Get-DuneGameConfigClient
    $cst    = Get-DuneLandclaimTimerState -Raw $client.raw
    # The seconds that actually govern play right now (server wins; fall back to
    # the local client file when the VM is down). Used to render the shareable block.
    $activeSeconds = ''
    if ($server.available -and $server.enabled) { $activeSeconds = $server.seconds }
    elseif ($cst.enabled) { $activeSeconds = $cst.seconds }
    return @{
        server = $server
        client = @{
            exists      = [bool]$client.exists
            dirExists   = [bool]$client.dirExists
            path        = $client.path
            dir         = $client.dir
            enabled     = $cst.enabled
            seconds     = $cst.seconds
            formattedOk = $cst.formattedOk
        }
        clientBlock = (Get-DuneLandclaimClientBlock -Seconds $activeSeconds)
    }
}

# Apply (enable) or clear (disable) the land-claim timer. Always writes the server
# 'game' file over SSH; also writes the local client Game.ini best-effort when the
# configured client folder exists. Returns per-target outcomes.
function Set-DuneLandclaimTimer {
    param([string]$Ip, [bool]$Enabled, [string]$Seconds)
    $result = @{ ok = $true; server = @{}; client = @{} }

    # --- server 'game' file (UserGame.ini) ---
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
    $ups   = Build-DuneLandclaimUpdates -Enabled $Enabled -Seconds $Seconds -File 'game'
    Save-DuneGameConfigLocked -Ip $Ip -Updates $ups
    $result.server = @{ ok = $true; path = $paths.game; applied = $true }

    # --- local client Game.ini (best-effort) ---
    try {
        $quoted = Get-DuneGameConfigQuotedKeys
        $dirResolved = Resolve-DuneGameConfigClientDir
        if (Test-Path -LiteralPath $dirResolved) {
            $path     = Get-DuneGameConfigClientFilePath
            $existing = ''
            if (Test-Path -LiteralPath $path -PathType Leaf) { $existing = [IO.File]::ReadAllText($path) }
            $cups = Build-DuneLandclaimUpdates -Enabled $Enabled -Seconds $Seconds -File 'client'
            $cnew = ConvertTo-DuneIniManaged -Raw $existing -Updates $cups -QuotedKeys $quoted
            $cnew = $cnew -replace "`r?`n", "`r`n"   # client file is Windows CRLF
            [IO.File]::WriteAllText($path, $cnew, (New-Object System.Text.UTF8Encoding($false)))
            $result.client = @{ ok = $true; path = $path; applied = $true }
        } else {
            $result.client = @{ ok = $false; applied = $false; reason = "Client config folder not found: $dirResolved" }
        }
    } catch {
        $result.client = @{ ok = $false; applied = $false; reason = "$($_.Exception.Message)" }
    }
    return $result
}
# =============================================================================
#
# These ship inside the actual UE server image, so the only reliable way to
# read them is `kubectl exec -- cat` against a running game-server pod. We do
# one SSH round-trip that finds the namespace + an sg-* pod and concatenates
# both files with sentinel markers; the result is cached per process so the
# (337KB + 143KB) reads only happen once until a deliberate refresh.
#
# Path inside the pod (confirmed 2026-06-11):
#   /home/dune/server/DuneSandbox/Config/DefaultGame.ini
#   /home/dune/server/DuneSandbox/Config/DefaultEngine.ini
#
# We deliberately do NOT use Resolve-DuneGameConfigPaths' template fallback
# here — defaults must come from the live image (or the catalog will be
# misleading when the game patches).
$script:DuneGameConfigDefaultsNs     = $null
$script:DuneGameConfigDefaultsPod    = $null
$script:DuneGameConfigDefaultsGame   = $null  # raw INI text
$script:DuneGameConfigDefaultsEngine = $null  # raw INI text
$script:DuneGameConfigDefaultsSource = $null  # ns + pod + timestamp

function Get-DuneGameConfigDefaults {
    param([string]$Ip, [switch]$Force)
    if (-not $Force -and $script:DuneGameConfigDefaultsGame -and $script:DuneGameConfigDefaultsEngine) {
        return @{
            game   = $script:DuneGameConfigDefaultsGame
            engine = $script:DuneGameConfigDefaultsEngine
            source = $script:DuneGameConfigDefaultsSource
            cached = $true
        }
    }

    # Single SSH round-trip: discover ns + a Running sg-* pod, then cat both
    # files between unmistakable sentinels so we can split the output cleanly.
    $bash = @'
set -e
NS=$(sudo kubectl get pods -A --no-headers 2>/dev/null | awk '/-sg-/ && / Running /{print $1; exit}')
if [ -z "$NS" ]; then echo "__NOPOD__"; exit 0; fi
POD=$(sudo kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/-sg-/ && / Running /{print $1; exit}')
if [ -z "$POD" ]; then echo "__NOPOD__"; exit 0; fi
echo "===META==="
echo "NS=$NS"
echo "POD=$POD"
echo "===GAME==="
sudo kubectl exec -n "$NS" "$POD" -- cat /home/dune/server/DuneSandbox/Config/DefaultGame.ini 2>/dev/null || echo "__READFAIL_GAME__"
echo "===ENGINE==="
sudo kubectl exec -n "$NS" "$POD" -- cat /home/dune/server/DuneSandbox/Config/DefaultEngine.ini 2>/dev/null || echo "__READFAIL_ENGINE__"
echo "===END==="
'@
    $raw = (Invoke-V6Ssh -Ip $Ip -Cmd $bash -TimeoutSec 60) -join "`n"
    if ($raw -match '__NOPOD__') {
        throw 'No running game-server (sg-*) pod found. Start the battlegroup and try again.'
    }

    $idxMeta   = $raw.IndexOf("===META===")
    $idxGame   = $raw.IndexOf("===GAME===")
    $idxEngine = $raw.IndexOf("===ENGINE===")
    $idxEnd    = $raw.IndexOf("===END===")
    if ($idxMeta -lt 0 -or $idxGame -lt 0 -or $idxEngine -lt 0 -or $idxEnd -lt 0) {
        throw 'Defaults read returned malformed output (missing sentinels).'
    }
    $metaBlock = $raw.Substring($idxMeta + "===META===".Length, $idxGame - ($idxMeta + "===META===".Length))
    $gameBlock = $raw.Substring($idxGame + "===GAME===".Length, $idxEngine - ($idxGame + "===GAME===".Length))
    $engBlock  = $raw.Substring($idxEngine + "===ENGINE===".Length, $idxEnd - ($idxEngine + "===ENGINE===".Length))

    if ($gameBlock -match '__READFAIL_GAME__') { throw 'kubectl exec failed reading DefaultGame.ini.' }
    if ($engBlock  -match '__READFAIL_ENGINE__') { throw 'kubectl exec failed reading DefaultEngine.ini.' }

    $ns = ''; $pod = ''
    foreach ($l in ($metaBlock -split "`n")) {
        $t = $l.Trim()
        if ($t -like 'NS=*')  { $ns  = $t.Substring(3) }
        if ($t -like 'POD=*') { $pod = $t.Substring(4) }
    }

    $script:DuneGameConfigDefaultsGame   = $gameBlock.Trim("`r","`n")
    $script:DuneGameConfigDefaultsEngine = $engBlock.Trim("`r","`n")
    $script:DuneGameConfigDefaultsNs     = $ns
    $script:DuneGameConfigDefaultsPod    = $pod
    $script:DuneGameConfigDefaultsSource = @{
        ns       = $ns
        pod      = $pod
        fetchedAt = (Get-Date).ToString('o')
    }

    return @{
        game   = $script:DuneGameConfigDefaultsGame
        engine = $script:DuneGameConfigDefaultsEngine
        source = $script:DuneGameConfigDefaultsSource
        cached = $false
    }
}

# Best-effort type inference for an arbitrary INI scalar — used so the UI can
# render the right input control (bool toggle vs number vs free text) for keys
# the static schema doesn't know about. Mirrors the reference implementation's inferType.
function Get-DuneGameConfigInferType {
    param([string]$Value)
    $v = "$Value".Trim()
    if ($v -eq '') { return 'string' }
    # Strip surrounding quotes for detection (still 'string' though).
    $isQuoted = $false
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $isQuoted = $true
        $v = $v.Substring(1, $v.Length - 2)
    }
    if ($isQuoted) { return 'string' }
    if ($v -ieq 'true' -or $v -ieq 'false') {
        if ($v.ToLowerInvariant() -eq $v) { return 'boolLower' } else { return 'bool' }
    }
    if ($v -eq '0' -or $v -eq '1') { return 'bool01' }
    if ($v -match '^-?\d+$') { return 'int' }
    if ($v -match '^-?\d+\.\d+$') { return 'float' }
    if ($v.StartsWith('(') -or $v.StartsWith('{')) { return 'string' } # struct literal
    return 'string'
}

# Build the full settings catalog merging live defaults with the current
# overrides from UserGame.ini / UserEngine.ini. Each section knows which file
# its overrides go to ('game' or 'engine'), so the UI can pass file+section+key
# straight to PUT /api/gameconfig (which already handles the explicit form).
function Get-DuneGameConfigCatalog {
    param([string]$Ip, [switch]$ForceDefaults)
    $defaults = Get-DuneGameConfigDefaults -Ip $Ip -Force:$ForceDefaults
    $live     = Get-DuneGameConfig -Ip $Ip

    $sectionsGame   = ConvertTo-DuneIniSectionsApi -Raw $defaults.game
    $sectionsEngine = ConvertTo-DuneIniSectionsApi -Raw $defaults.engine

    # User-override lookups: key = "<section>||<key>".
    $userGame   = $live.game.effective
    $userEngine = $live.engine.effective

    $out = New-Object 'System.Collections.Generic.List[object]'

    # Game-side defaults → write to UserGame.ini
    foreach ($s in $sectionsGame) {
        $keys = New-Object 'System.Collections.Generic.List[object]'
        $overridden = 0
        foreach ($k in $s.keys) {
            $defVal = "$($k.value)"
            $eff = $userGame["$($s.name)||$($k.key)"]
            $current = if ($null -ne $eff -and "$eff" -ne '') { "$eff" } else { $defVal }
            $isOverridden = ($null -ne $eff -and "$eff" -ne '' -and "$eff" -ne $defVal)
            if ($isOverridden) { $overridden++ }
            $keys.Add(@{
                key        = $k.key
                default    = $defVal
                current    = $current
                overridden = [bool]$isOverridden
                isArray    = [bool]$k.isArray
                prefix     = "$($k.prefix)"
                type       = (Get-DuneGameConfigInferType -Value $defVal)
            })
        }
        $out.Add(@{
            name            = $s.name
            file            = 'game'
            count           = $keys.Count
            overriddenCount = $overridden
            keys            = $keys.ToArray()
        })
    }

    # Engine-side defaults → write to UserEngine.ini
    foreach ($s in $sectionsEngine) {
        $keys = New-Object 'System.Collections.Generic.List[object]'
        $overridden = 0
        foreach ($k in $s.keys) {
            $defVal = "$($k.value)"
            $eff = $userEngine["$($s.name)||$($k.key)"]
            $current = if ($null -ne $eff -and "$eff" -ne '') { "$eff" } else { $defVal }
            $isOverridden = ($null -ne $eff -and "$eff" -ne '' -and "$eff" -ne $defVal)
            if ($isOverridden) { $overridden++ }
            $keys.Add(@{
                key        = $k.key
                default    = $defVal
                current    = $current
                overridden = [bool]$isOverridden
                isArray    = [bool]$k.isArray
                prefix     = "$($k.prefix)"
                type       = (Get-DuneGameConfigInferType -Value $defVal)
            })
        }
        $out.Add(@{
            name            = $s.name
            file            = 'engine'
            count           = $keys.Count
            overriddenCount = $overridden
            keys            = $keys.ToArray()
        })
    }

    return @{
        source   = $defaults.source
        cached   = [bool]$defaults.cached
        sections = $out.ToArray()
    }
}

# Back up the live INI files server-side WITHOUT writing any changes. Copies each
# resolved file to "<path>.dstbak-<ts>" and verifies the copy landed. Returns a
# summary the UI can show. Only meaningful for a live BG (templates aren't backed up).
function Backup-DuneGameConfig {
    param(
        [string]$Ip,
        [hashtable]$ResolvedPaths
    )
    $paths = if ($ResolvedPaths) { $ResolvedPaths } else { Resolve-DuneGameConfigPaths -Ip $Ip }
    $ts    = (Get-Date).ToString('yyyyMMddHHmmss')
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in @('game','engine')) {
        $path = if ($f -eq 'game') { $paths.game } else { $paths.engine }
        $bak  = "$path.dstbak-$ts"
        $exists = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'test -f ''$path'' && echo yes || echo no'") -join '').Trim()
        if ($exists -ne 'yes') {
            $files.Add(@{ file = $f; path = $path; backup = $null; ok = $false; reason = 'source file not found' })
            continue
        }
        Invoke-V6Ssh -Ip $Ip -Cmd "sudo cp '$path' '$bak'" -TimeoutSec 20 | Out-Null
        $ok = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'test -f ''$bak'' && echo yes || echo no'") -join '').Trim()
        $files.Add(@{ file = $f; path = $path; backup = $bak; ok = ($ok -eq 'yes') })
    }
    return @{ timestamp = $ts; source = $paths.source; files = $files.ToArray() }
}

# List existing DST backups (".dstbak-<ts>") next to each live INI, most-recent
# first. Returns a flat array the UI can show so users can find a restore point.
function Get-DuneGameConfigBackups {
    param([string]$Ip, [int]$Limit = 20)
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in @('game','engine')) {
        $path = if ($f -eq 'game') { $paths.game } else { $paths.engine }
        $dir  = Split-Path -Path $path -Parent
        $cmd  = "sudo bash -c 'for x in ''$path''.dstbak-*; do [ -e `"`$x`" ] && stat -c `"%n|%s|%Y`" `"`$x`"; done'"
        $lines = Invoke-V6Ssh -Ip $Ip -Cmd $cmd
        foreach ($ln in $lines) {
            $s = "$ln".Trim()
            if (-not $s -or $s -notmatch '\.dstbak-') { continue }
            $parts = $s -split '\|'
            if ($parts.Count -lt 3) { continue }
            $full = $parts[0]
            $name = Split-Path -Path $full -Leaf
            $ts   = ''
            if ($name -match '\.dstbak-(\d+)$') { $ts = $matches[1] }
            $size = 0L; [void][int64]::TryParse($parts[1], [ref]$size)
            $epoch = 0L; [void][int64]::TryParse($parts[2], [ref]$epoch)
            $out.Add(@{
                file    = $f
                path    = $full
                dir     = $dir
                name    = $name
                size    = $size
                stamp   = $ts
                modified = $epoch
            })
        }
    }
    $sorted = $out.ToArray() | Sort-Object -Property modified -Descending
    if ($Limit -gt 0) { $sorted = $sorted | Select-Object -First $Limit }
    return @{ source = $paths.source; backups = @($sorted) }
}

# Delete one or more DST backup files (".dstbak-<ts>") next to the live INI files.
# SECURITY: every path is validated to (a) sit in the same directory as a live
# UserGame.ini/UserEngine.ini and (b) match the "<inifile>.dstbak-<digits>" name
# pattern, so this can never rm an arbitrary file. Paths that fail validation are
# reported as skipped, never deleted. Returns @{ deleted; results = [@{path;ok;reason?}] }.
function Remove-DuneGameConfigBackups {
    param([string]$Ip, [string[]]$Paths)
    if (-not $Paths -or $Paths.Count -eq 0) { return @{ deleted = 0; results = @() } }
    $resolved = Resolve-DuneGameConfigPaths -Ip $Ip
    $allowed = @()
    foreach ($f in @('game','engine')) {
        $p = if ($f -eq 'game') { $resolved.game } else { $resolved.engine }
        if ($p) { $allowed += "$p.dstbak-" }
    }
    $results = New-Object 'System.Collections.Generic.List[object]'
    $deleted = 0
    foreach ($raw in $Paths) {
        $path = "$raw".Trim()
        $name = Split-Path -Path $path -Leaf
        $okPrefix = $false
        foreach ($pre in $allowed) { if ($path.StartsWith($pre)) { $okPrefix = $true; break } }
        if (-not $okPrefix -or $name -notmatch '\.dstbak-\d+$' -or $path.Contains("'")) {
            $results.Add(@{ path = $path; ok = $false; reason = 'not a recognized .dstbak path' })
            continue
        }
        Invoke-V6Ssh -Ip $Ip -Cmd "sudo rm -f '$path'" -TimeoutSec 20 | Out-Null
        $still = ((Invoke-V6Ssh -Ip $Ip -Cmd "sudo bash -c 'test -f ''$path'' && echo yes || echo no'") -join '').Trim()
        if ($still -eq 'no') { $deleted++; $results.Add(@{ path = $path; ok = $true }) }
        else { $results.Add(@{ path = $path; ok = $false; reason = 'delete did not remove the file' }) }
    }
    return @{ deleted = $deleted; results = $results.ToArray() }
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
        if ($f.ContainsKey('ClientApply')) { $field.clientApply = [bool]$f.ClientApply }
        if ($f.ContainsKey('Unit'))        { $field.unit        = $f.Unit }
        if ($f.ContainsKey('Min'))         { $field.min         = $f.Min }
        if ($f.ContainsKey('Max'))         { $field.max         = $f.Max }
        if ($f.ContainsKey('Placeholder')) { $field.placeholder = $f.Placeholder }
        if ($f.ContainsKey('Wide'))        { $field.wide        = [bool]$f.Wide }
        if ($f.ContainsKey('Quoted'))      { $field.quoted      = [bool]$f.Quoted }
        if ($f.ContainsKey('StructKey'))   { $field.structKey   = [string]$f.StructKey }
        elseif ($f.ContainsKey('ClientStructKey')) { $field.structKey = [string]$f.ClientStructKey }
        if ($f.ContainsKey('Options')) {
            $field.options = @($f.Options | ForEach-Object { @{ value = $_.V; label = $_.L } })
        }
        # Console variables live in UserEngine.ini [ConsoleVariables] and only take
        # effect once the battlegroup restarts and rebuilds its startup command -
        # unlike game INI keys, which apply on save. Flag them so the UI can say so
        # on the field instead of leaving the user to find out by nothing happening.
        if ($f.Section -eq $script:DuneGcSecConsole) { $field.consoleVar = $true }
        # Experimental controls are shown on their own page, grouped by what they
        # affect. Everything else keeps its Game Config category as the grouping.
        if ($cat -like 'Experimental*') {
            $field.group = if ($f.ContainsKey('Group') -and $f.Group) { [string]$f.Group } else { (Get-DuneExperimentalGroup -Key "$($f.Key)") }
            $field.status = if ($f.ContainsKey('Status')) { [string]$f.Status } else { 'Unconfirmed' }
            $field.source = if ($f.ContainsKey('Source')) { [string]$f.Source } else { 'Dune' }
            $field.scope = if ($f.ContainsKey('Scope')) { [string]$f.Scope } elseif ($f.ContainsKey('ClientApply') -and $f.ClientApply) { 'Server + client' } else { 'Server' }
            $field.risk = if ($f.ContainsKey('Risk')) { [string]$f.Risk } else { 'experimental' }
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
