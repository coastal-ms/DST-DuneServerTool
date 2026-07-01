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

# Funcom stores ALL Landsraad settings as scalar members inside ONE nested struct
# value: [/Script/DuneSandbox.LandsraadSettings] Data=(m_TaskGoalAmount=5000.0,...).
# Schema fields tagged StructKey='Data' are read from / written to that struct via
# the UE struct-member engine (Get/Set-DuneStructScalarMember), so they edit the
# member in place and leave the nested members (messages/curves/widgets) intact.
$script:DuneGcLandsraadStructKey = 'Data'

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
    'Resources & Economy','Crafting','Building','Inventory','Guilds & Economy',
    'Storm Cycle','Landsraad','PvP & Security','Spice','Taxation','Encounters','Sandworm','Vehicles'
)

# Keys DST USED to expose but removed after proving them no-ops via UserGame.ini
# (2026-06-15 live test, issue #225). The managed-block writer actively scrubs
# these from the DST-owned managed block on every save, so they don't linger
# orphaned in existing users' files now that the schema no longer carries them.
# Only touches the managed block — never the user's own (body) sections.
$script:DuneGameConfigDeprecatedManagedKeys = @(
    'm_GlobalHealthMultiplier'
    'm_GlobalDamageToNpcsMultiplier'
    'm_GlobalDamageToPlayersMultiplier'
    'm_GlobalXPMultiplier'
    'm_GlobalProgressionSpeedMultiplier'
    'm_GlobalFameMultiplier'
    'm_GlobalHarvestAmountMultiplier'
    'm_GlobalHarvestHealthMultiplier'
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
    @{ Section=$script:DuneGcSecHydration; Key='m_BiomeTierUpdateRateSeconds'; File='game'; Type='float'; Min=0; Unit='sec'; Default='2.5'; Label='Biome Tier Update Rate'; Help='How often (seconds) the biome hydration tier is re-evaluated. Also needs client-side apply.'; ClientApply=$true; Category='Hydration' }

    # --- Loot & Death (DuneSandboxGameModeBase) ---
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersDropLootOnDeath'; File='game'; Type='bool'; Default='False'; Label='Players Drop Loot on Death'; Help='Whether a player drops their inventory as loot when killed (PvP looting). Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersDropLootOnDefeat'; File='game'; Type='bool'; Default='True'; Label='Players Drop Loot on Defeat'; Help='Whether a player drops loot when downed/defeated (not a full death). Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldPlayersLoseItemsOnDeath'; File='game'; Type='bool'; Default='True'; Label='Players Lose Items on Death'; Help='Whether a player loses items from their inventory on death. Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }
    @{ Section=$script:DuneGcSecGameBase; Key='m_bShouldNpcDropLootOnDeath'; File='game'; Type='bool'; Default='True'; Label='NPCs Drop Loot on Death'; Help='Whether NPCs drop loot when killed. Also needs client-side apply.'; ClientApply=$true; Category='Loot & Death' }

    # --- Resources & Economy (engine ConsoleVariables) ---
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Global Mining Multiplier'; Help='Scales hand-mining resource output.'; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='Dune.GlobalVehicleMiningOutputMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='Vehicle Mining Multiplier'; Help='Scales vehicle-mining resource output.'; Category='Resources & Economy' }
    @{ Section=$script:DuneGcSecConsole; Key='SecurityZones.PvpResourceMultiplier'; File='engine'; Type='float'; Min=0; Default='1.0'; Label='PvP Resource Multiplier'; Help='Resource yield multiplier inside PvP zones.'; Category='Resources & Economy' }

    # --- Crafting ---
    @{ Section=$script:DuneGcSecCrafting; Key='m_RepairCostWeight'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Repair Cost Weight'; Help='Scales repair costs. Also needs client-side apply.'; ClientApply=$true; Category='Crafting' }
    @{ Section=$script:DuneGcSecCrafting; Key='m_RecyclerOutputWeight'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Recycler Output Weight'; Help='Scales recycler output. Also needs client-side apply.'; ClientApply=$true; Category='Crafting' }

    # --- Building ---
    @{ Section=$script:DuneGcSecBuilding; Key='m_MaxNumLandclaimSegments'; File='game'; Type='int'; Min=1; Default='6'; Label='Max Landclaim Segments'; Help='Maximum territory claim segments. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingBlueprintMaxExtensions'; File='game'; Type='int'; Min=0; Default='4'; Label='Blueprint Max Extensions'; Help='Maximum blueprint extension slots.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupMaxExtensions'; File='game'; Type='int'; Min=0; Default='8'; Label='Base Backup Max Extensions'; Help='Backup (reconstruction) extension slots per base.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_bBuildingRestrictionLimitsEnabled'; File='game'; Type='bool'; Default='True'; Label='Building Restriction Limits'; Help='Enforce building restriction limits. Also needs client-side apply.'; ClientApply=$true; Category='Building' }
    @{ Section=$script:DuneGcSecGame; Key='m_GlobalBuildingDamageMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Damage Multiplier'; Help='Scales damage dealt to player buildings (0.5 = stronger bases). Also needs client-side apply.'; ClientApply=$true; Category='Building' }

    # --- Inventory ---
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingSize'; File='game'; Type='int'; Min=1; Default='35'; Label='Starting Inventory Slots'; Help='Number of inventory slots at spawn. Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }
    @{ Section=$script:DuneGcSecInventory; Key='PlayerInventoryStartingVolumeCapacity'; File='game'; Type='float'; Min=0; Default='175.0'; Label='Starting Inventory Volume'; Help='Volume capacity of the starting inventory. Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }
    @{ Section=$script:DuneGcSecGame; Key='m_InventoryWeightMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Inventory Weight Multiplier'; Help='Scales item weight across all inventories (carry-capacity scalar). Also needs client-side apply.'; ClientApply=$true; Category='Inventory' }

    # --- Guilds & Economy ---
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildMembersAllowed'; File='game'; Type='int'; Min=1; Default='32'; Label='Max Guild Members'; Help='Maximum players per guild.'; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_MaxGuildsAllowed'; File='game'; Type='int'; Min=1; Default='3'; Label='Max Guilds per Player'; Help='How many guilds a player may belong to.'; Category='Guilds & Economy' }
    @{ Section=$script:DuneGcSecGuilds; Key='m_GuildCreationCost'; File='game'; Type='int'; Min=0; Unit='Solari'; Default='1000'; Label='Guild Creation Cost'; Help='Solari required to create a guild.'; Category='Guilds & Economy' }

    # --- Storm Cycle ---
    @{ Section=$script:DuneGcSecCoriolis; Key='m_CycleDurationInDays'; File='game'; Type='int'; Min=1; Unit='days'; Default='7'; Label='Coriolis Cycle Length'; Help='In-game days between Coriolis storm / season events. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bCoriolisAutoSpawnEnabled'; File='game'; Type='bool'; Default='True'; Label='Coriolis Auto-Spawn'; Help='Whether Coriolis storms spawn automatically.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecCoriolis; Key='m_bIsDbWipeEnabled'; File='game'; Type='bool'; Default='True'; Label='Database Wipe on Season End'; Help='Wipe the database when the season ends. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecCoriolis; Key='m_bShouldRestartServerOnCycleEnd'; File='game'; Type='bool'; Default='True'; Label='Restart Server on Cycle End'; Help='Whether the dedicated server restarts itself when a Coriolis cycle (season) ends.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm'; Help='Enable rolling sandstorms.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandstorm.Treasure.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandstorm Treasure Spawns'; Help='Spawn treasure during sandstorms.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bCoriolisDoesDamage'; File='game'; Type='bool'; Default='False'; Label='Coriolis Storm Does Damage'; Help='Whether being caught in a Coriolis storm damages players. Also needs client-side apply.'; ClientApply=$true; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_bSandStormDebrisEnabled'; File='game'; Type='bool'; Default='True'; Label='Sandstorm Debris'; Help='Whether sandstorms spawn flying debris.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecTimeOfDay; Key='m_bTimeOfDayEnabled'; File='game'; Type='bool'; Default='True'; Label='Time of Day Cycle'; Help='Whether the day/night cycle advances.'; Category='Storm Cycle' }

    # --- Landsraad (scalar members of [LandsraadSettings] Data=(...)) ---
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_TaskGoalAmount'; File='game'; Type='float'; Min=0; Default='70000'; Label='Task Goal Amount'; Help='Contribution target for each House task before it completes. Funcom default is 70000. Applies when the next Landsraad term begins; the term currently running keeps its existing goal until it rolls over.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfWeeksTermRetention'; File='game'; Type='int'; Min=1; Unit='weeks'; Default='4'; Label='Term Retention'; Help='How many weeks of term history are kept.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfDecreesToNominate'; File='game'; Type='int'; Min=0; Default='3'; Label='Decrees to Nominate'; Help='Number of decrees put up for voting each term. Applies when the next Landsraad term begins, not the current one. Note: the in-game board UI only displays 3 by default.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_NumberOfGuildsInHighscoreList'; File='game'; Type='int'; Min=0; Default='5'; Label='Guilds in Highscore List'; Help='How many guilds appear on the contribution highscore list.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_ControlPointsPerCycle'; File='game'; Type='int'; Min=0; Default='2'; Label='Control Points per Cycle'; Help='Territory control points awarded per cycle.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_bIsPlayerVotingEnabled'; File='game'; Type='bool'; Default='True'; Label='Player Voting Enabled'; Help='Whether players can vote on Landsraad decrees.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_bIsTerritoryControlEnabled'; File='game'; Type='bool'; Default='True'; Label='Territory Control Enabled'; Help='Whether the territory-control mechanic is active.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_VotingPeriodDurationInSec'; File='game'; Type='float'; Min=0; Unit='sec'; Default='118500.0'; Label='Voting Period Duration'; Help='Length of the voting window, in seconds.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_VotingPeriodStartBeforeCoriolisCycleInSec'; File='game'; Type='float'; Min=0; Unit='sec'; Default='118800.0'; Label='Voting Starts Before Cycle'; Help='How many seconds before the Coriolis cycle voting opens.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsMaxActiveAmount'; File='game'; Type='int'; Min=0; Default='3'; Label='Max Active Contracts'; Help='Maximum simultaneously-active Landsraad contracts per player.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsPerVotingBlock'; File='game'; Type='int'; Min=0; Default='3'; Label='Contracts per Voting Block'; Help='Number of contracts offered per voting block.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsDailyBonusPerDay'; File='game'; Type='int'; Min=0; Default='5'; Label='Daily Contract Bonus'; Help='Bonus contracts granted per day.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadContractsDailyBonusMax'; File='game'; Type='int'; Min=0; Default='35'; Label='Daily Contract Bonus Max'; Help='Maximum accumulated daily contract bonus.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadTaskDailyRevealFrequency'; File='game'; Type='float'; Min=0; Default='25.0'; Label='Task Daily Reveal Frequency'; Help='How often new House tasks are revealed each day.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; StructKey=$script:DuneGcLandsraadStructKey; Key='m_LandsraadTaskProgressUpdateFrequency'; File='game'; Type='float'; Min=0; Default='15.0'; Label='Task Progress Update Frequency'; Help='How often House task progress is recomputed.'; ClientApply=$true; Category='Landsraad' }
    @{ Section=$script:DuneGcSecLandsraad; Key='bIsLandsraadEnabled'; File='game'; Type='bool'; Default='True'; Label='Landsraad Enabled'; Help='Master toggle for the entire Landsraad system. Also needs client-side apply.'; ClientApply=$true; Category='Landsraad' }

    # --- PvP & Security ---
    @{ Section=$script:DuneGcSecPvP; Key='m_bShouldForceEnablePvpOnAllPartitions'; File='game'; Type='bool'; Default='False'; Label='Force PvP on All Partitions'; Help='Override per-partition PvP settings (PvP everywhere).'; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecSecurity; Key='m_bAreSecurityZonesEnabled'; File='game'; Type='bool'; Default='True'; Label='Security Zones Enabled'; Help='Off = PvP and ability usage allowed everywhere.'; Category='PvP & Security' }

    # --- Spice ---
    @{ Section=$script:DuneGcSecSpice; Key='m_PrimeRateInSeconds'; File='game'; Type='float'; Min=0; Unit='sec'; Default='30.0'; Label='Spice Prime Rate'; Help='Seconds between spice node priming ticks. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_NodeValueToSpiceResourceRatio'; File='game'; Type='float'; Min=0; Default='10.0'; Label='Node Value to Spice Ratio'; Help='Converts node value into harvestable spice. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpiceAddict; Key='m_bIsSpiceAddictionEnabled'; File='game'; Type='bool'; Default='True'; Label='Spice Addiction Enabled'; Help='Whether players develop spice addiction over time. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpiceAddict; Key='m_bIsSpiceVisionEnabled'; File='game'; Type='bool'; Default='True'; Label='Spice Vision Enabled'; Help='Whether spice vision effects are active. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }

    # --- Taxation ---
    @{ Section=$script:DuneGcSecTaxation; Key='m_bTaxationEnabled'; File='game'; Type='bool'; Default='False'; Label='Taxation Enabled'; Help='Whether the taxation system is active.'; Category='Taxation' }
    @{ Section=$script:DuneGcSecTaxation; Key='m_TaxationCycleLengthSeconds'; File='game'; Type='int'; Min=0; Unit='sec'; Default='1209600'; Label='Taxation Cycle'; Help='Seconds between taxation collection cycles.'; Category='Taxation' }

    # --- Sandworm (engine cvars + game settings) ---
    @{ Section=$script:DuneGcSecConsole; Key='sandworm.dune.Enabled'; File='engine'; Type='bool01'; Default='1'; Label='Sandworm Enabled'; Help='Master toggle for the sandworm.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Sandworm.SandwormDangerZonesEnabled'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Danger Zones'; Help='Enable danger zones where the sandworm can attack.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormCollisionInteraction'; File='engine'; Type='boolLower'; Default='true'; Label='Sandworm Pushes Vehicles'; Help='Sandworm can push / damage vehicles.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnExit'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='5.0'; Label='Invulnerability on Vehicle Exit'; Help='Seconds of sandworm invulnerability after exiting a vehicle.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecConsole; Key='Vehicle.SandwormInvulnerabilitySecondsOnServerRestart'; File='engine'; Type='float'; Min=0; Unit='sec'; Default='60.0'; Label='Invulnerability on Server Restart'; Help='Seconds of sandworm invulnerability after a server restart.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='WormDetectionDistance'; File='game'; Type='float'; Min=0; Default='5000.0'; Label='Worm Detection Distance'; Help='Distance at which worms detect players. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinWormSpawnInternal'; File='game'; Type='float'; Min=0; Unit='sec'; Default='300.0'; Label='Min Worm Spawn Interval'; Help='Minimum seconds between worm spawns. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecHazards; Key='m_SandwormQuicksandSpeedModifier'; File='game'; Type='float'; Min=0; Default='0.25'; Label='Quicksand Speed Modifier'; Help='Movement speed multiplier in quicksand.'; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bEnableDangerZones'; File='game'; Type='bool'; Default='True'; Label='Worm Danger Zones'; Help='Whether sandworm danger zones are generated. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bGiantWormSystemEnabled'; File='game'; Type='bool'; Default='True'; Label='Giant Worm System'; Help='Whether the giant sandworm system is active. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_bEnableHibernation'; File='game'; Type='bool'; Default='True'; Label='Worm Hibernation'; Help='Whether sandworms hibernate when no players are nearby (performance).'; Category='Sandworm' }

    # --- Encounters ---
    @{ Section=$script:DuneGcSecEncounters; Key='m_bAreRandomEncountersEnabled'; File='game'; Type='bool'; Default='True'; Label='Random Encounters'; Help='Whether random world encounters spawn. Also needs client-side apply.'; ClientApply=$true; Category='Encounters' }
    @{ Section=$script:DuneGcSecContracts; Key='m_bIsEnabled'; File='game'; Type='bool'; Default='True'; Label='Contracts Enabled'; Help='Master toggle for the contracts subsystem. Also needs client-side apply.'; ClientApply=$true; Category='Encounters' }

    # --- Vehicles (engine cvars) ---
    @{ Section=$script:DuneGcSecConsole; Key='dw.VehicleDurabilityDamageMultiplier'; File='engine'; Type='float'; Min=0; Max=10; Default='1.0'; Label='Vehicle Durability Damage'; Help='Durability damage multiplier for vehicles. 0 = off.'; Category='Vehicles' }

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
    @{ Section=$script:DuneGcSecBuilding; Key='m_BuildingDecayRateMultiplier'; File='game'; Type='float'; Min=0; Default='1.0'; Label='Building Decay Rate Multiplier'; Help='Scales how fast player buildings decay over time.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='bEnableBuildingStability'; File='game'; Type='bool'; Default='True'; Label='Enable Building Stability'; Help='Whether structural / stability rules apply to player constructions.'; Category='Building' }
    @{ Section=$script:DuneGcSecBuilding; Key='m_BaseBackupExtensions'; File='game'; Type='int'; Min=0; Unit='slots'; Default='2'; Label='Base Backup Extensions'; Help='Default number of backup extension slots per base.'; Category='Building' }
    # Guilds & Economy
    @{ Section=$script:DuneGcSecPermission; Key='m_MaxPermissionsPerActor'; File='game'; Type='int'; Min=0; Unit='rules'; Default='32'; Label='Max Permissions per Actor'; Help='Maximum number of permission rules per actor / structure.'; Category='Guilds & Economy' }
    # Storm Cycle
    @{ Section=$script:DuneGcSecStorm; Key='m_StormCycleDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='3600'; Label='Storm Cycle Duration'; Help='Total wall-clock duration of one full storm cycle (calm + storm + warning).'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='900'; Label='Storm Duration'; Help='How long the active sandstorm phase lasts per cycle.'; Category='Storm Cycle' }
    @{ Section=$script:DuneGcSecStorm; Key='m_StormWarningDuration'; File='game'; Type='int'; Min=0; Unit='sec'; Default='300'; Label='Storm Warning Duration'; Help='Warning period (dust / audio cues) before the active storm phase begins.'; Category='Storm Cycle' }
    # PvP & Security
    @{ Section=$script:DuneGcSecPvP; Key='bPvPEnabled'; File='game'; Type='bool'; Default='False'; Label='PvP Enabled'; Help='Allow player-vs-player combat globally across the server.'; Category='PvP & Security' }
    @{ Section=$script:DuneGcSecPvP; Key='bServerPVE'; File='game'; Type='bool'; Default='True'; Label='Server PvE Mode'; Help='Enables global PvE protection (inverse of PvP; both can be set independently).'; Category='PvP & Security' }
    # Spice
    @{ Section=$script:DuneGcSecSpice; Key='m_bSpawningActive'; File='game'; Type='bool'; Default='True'; Label='Spice Spawning Active'; Help='Master switch - whether spice nodes spawn on the map at all. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    @{ Section=$script:DuneGcSecSpice; Key='m_bPlayerMustWitnessBloom'; File='game'; Type='bool'; Default='False'; Label='Player Must Witness Bloom'; Help='If true, a player must be present in the area for a spice bloom to register / count. Also needs client-side apply.'; ClientApply=$true; Category='Spice' }
    # Taxation
    @{ Section=$script:DuneGcSecTaxation; Key='m_SpicePerHour'; File='game'; Type='float'; Min=0; Unit='spice/hr'; Default='11.904750'; Label='Spice Yield per Hour'; Help='Base spice amount generated per hour per active spice field under taxation.'; Category='Taxation' }
    # Sandworm
    @{ Section=$script:DuneGcSecSandworm; Key='m_MinDistanceBetweenSandworms'; File='game'; Type='float'; Min=0; Unit='UU'; Default='80000.0'; Label='Min Distance Between Sandworms'; Help='Minimum world-unit separation required between two simultaneously active sandworms. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
    @{ Section=$script:DuneGcSecSandworm; Key='m_GiantWormMinimumPlayersOnSpiceField'; File='game'; Type='int'; Min=0; Unit='players'; Default='4'; Label='Giant Worm Min Players on Field'; Help='Minimum number of players on a spice field to trigger a giant sandworm spawn. Also needs client-side apply.'; ClientApply=$true; Category='Sandworm' }
)

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

# Build the post-save "apply this on each client too" reminder from a set of
# structured updates (@{ file; section; key; value }). Returns @{ path; items }
# where items = the saved keys whose schema entry is flagged ClientApply. Empty
# items means nothing client-side to do.
function Get-DuneGameConfigClientApplyNotice {
    param([object[]]$Updates)
    $byKey = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.ContainsKey('ClientApply') -and $f.ClientApply) { $byKey[$f.Key] = $f }
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($u in $Updates) {
        $k = "$($u.key)"
        if ($byKey.ContainsKey($k)) {
            $f = $byKey[$k]
            $items.Add(@{ key = $k; label = $f.Label; section = $f.Section; value = "$($u.value)" })
        }
    }
    return @{ path = $script:DuneGameConfigClientPath; items = $items.ToArray() }
}

# -----------------------------------------------------------------------------
# LOCAL CLIENT CONFIG (admin's own machine; no SSH). DST runs locally, so it can
# read/write the player's client Game.ini directly. Used by the optional
# "apply to my client too" flow + the read-only client viewer.
# -----------------------------------------------------------------------------
$script:DuneGameConfigClientDirDefault = '%LOCALAPPDATA%\DuneSandbox\Saved\Config\WindowsClient'
$script:DuneGameConfigClientFileName   = 'Game.ini'

# The admin's configured client-config FOLDER (persisted as ClientConfigPath in
# dune-server.config). Falls back to the per-user default. Returned UNEXPANDED so
# the UI box round-trips the literal value the user typed.
function Get-DuneGameConfigClientDir {
    $configured = ''
    if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
        try {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.ContainsKey('ClientConfigPath')) { $configured = "$($cfg['ClientConfigPath'])".Trim() }
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

# Full path to the client Game.ini under the configured (or given) folder.
function Get-DuneGameConfigClientFilePath {
    param([string]$Dir = '')
    $resolved = Resolve-DuneGameConfigClientDir -Dir $Dir
    return (Join-Path $resolved $script:DuneGameConfigClientFileName)
}

# Read the LOCAL client Game.ini and project it the same way the VM read does.
function Get-DuneGameConfigClient {
    param([string]$Dir = '')
    $dirRaw      = if ($Dir) { $Dir } else { Get-DuneGameConfigClientDir }
    $dirResolved = Resolve-DuneGameConfigClientDir -Dir $dirRaw
    $path        = Get-DuneGameConfigClientFilePath -Dir $dirRaw
    $exists      = Test-Path -LiteralPath $path -PathType Leaf
    $raw         = ''
    if ($exists) { try { $raw = [IO.File]::ReadAllText($path) } catch { $raw = '' } }
    return @{
        dir             = $dirRaw
        dirResolved     = $dirResolved
        path            = $path
        exists          = [bool]$exists
        dirExists       = [bool](Test-Path -LiteralPath $dirResolved)
        default         = $script:DuneGameConfigClientDirDefault
        raw             = $raw
        sections        = (ConvertTo-DuneIniSectionsApi -Raw $raw)
        effective       = (Get-DuneIniEffective -Raw $raw)
        effectiveByKey  = (Get-DuneIniEffectiveByKey -Raw $raw)
        managedSections = (Get-DuneIniManagedSectionNames -Raw $raw)
    }
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

# Apply client-apply updates to the LOCAL client Game.ini. Validates that every
# key is schema-flagged ClientApply (blocks arbitrary local writes) and routes
# the write through the same managed-block writer the server-side files use.
# That way every DST-touched key sits in a clearly marked block at the bottom
# of the file (issue #YYY — users want to copy-paste the DST section to share
# with friends connecting to their server, without hand-picking edits scattered
# through the file). Also scrubs the deprecated no-op multiplier keys so the
# client file stays clean. Does NOT auto-backup (manual backups only).
# Returns @{ ok; path; backup; created; applied; items } (backup always '').
function Save-DuneGameConfigClient {
    param([object[]]$Updates, [string]$Dir = '', [string]$DefaultsRaw = '')
    if (-not $Updates -or $Updates.Count -eq 0) { throw 'No updates supplied.' }

    $allowed = @{}
    foreach ($f in $script:DuneGameConfigSchema) {
        if ($f.ContainsKey('ClientApply') -and $f.ClientApply) { $allowed[$f.Key] = $f }
    }
    $clean = New-Object 'System.Collections.Generic.List[object]'
    foreach ($u in $Updates) {
        $k = "$($u.key)"
        if (-not $allowed.ContainsKey($k)) { continue }
        $f = $allowed[$k]
        $rm = if ($null -ne $u['remove']) { [bool]$u['remove'] } else { (Test-DuneGameConfigValueIsDefault -Key $k -Value "$($u.value)") }
        $clean.Add(@{ section = $f.Section; key = $k; value = "$($u.value)"; remove = $rm })
    }
    if ($clean.Count -eq 0) { throw 'No client-applicable keys in the supplied updates.' }

    # Also scrub the deprecated no-op multiplier keys from the client file so a
    # user's local Game.ini doesn't keep orphaned values DST no longer manages.
    # (Same server-wins / keep-it-clean intent as the server managed block.)
    foreach ($dk in $script:DuneGameConfigDeprecatedManagedKeys) {
        $clean.Add(@{ section = $script:DuneGcSecGame; key = $dk; value = ''; remove = $true })
    }

    $dirResolved = Resolve-DuneGameConfigClientDir -Dir $Dir
    if (-not (Test-Path -LiteralPath $dirResolved)) { throw "Client config folder not found: $dirResolved" }
    $path = Get-DuneGameConfigClientFilePath -Dir $Dir

    $existing = ''
    $created  = $true
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = [IO.File]::ReadAllText($path)
        $created  = $false
    }

    $quoted = Get-DuneGameConfigQuotedKeys
    # Fold any struct-member updates (e.g. LandsraadSettings Data members) into a
    # single Data write against the CLIENT file's current blob, exactly like the
    # server path -- the client reads the same Data=(...) struct. When the client
    # Game.ini has no prior struct, seed the full DefaultGame.ini struct so the
    # other members are preserved (the route supplies $DefaultsRaw).
    $folded = Convert-DuneStructUpdates -Raw $existing -Updates $clean.ToArray() -DefaultsRaw $DefaultsRaw
    # Route through the managed-block writer (same as the server files). Every
    # DST-touched section lands in a marker-delimited block at the bottom; the
    # user's unrelated sections (audio, video, etc.) stay where they were.
    $new    = ConvertTo-DuneIniManaged -Raw $existing -Updates $folded -QuotedKeys $quoted
    $new    = $new -replace "`r?`n", "`r`n"   # local file is Windows CRLF

    # No auto-backup: client backups are manual to avoid piling up .dstbak files.
    $backup = ''
    [IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding($false)))

    return @{ ok = $true; path = $path; backup = $backup; created = $created; applied = $clean.Count; items = $clean.ToArray() }
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
        if ($u['remove']) {
            # Reset-to-default: strip the key so the default is implied, not written.
            Remove-DuneScalarFromBody -Body $entry.body -Key $key
        } else {
            $fmt = Format-DuneIniValue -Key $key -Value $u.value -QuotedKeys $QuotedKeys
            Set-DuneScalarInBody -Body $entry.body -Key $key -Formatted $fmt
        }
    }

    # Scrub deprecated keys from DST-owned managed sections. These keys were once
    # in the schema but were removed after being proven no-ops (see issue #225).
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
    return $eff
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

# Save structured updates. $Updates = array of @{ file; section; key; value }.
# Does NOT auto-backup — backups are manual (Backup settings button) to avoid
# cluttering the server PVC with a .dstbak per save.
function Save-DuneGameConfig {
    param([string]$Ip, [object[]]$Updates)
    if (-not $Updates -or $Updates.Count -eq 0) { return }
    $paths  = Resolve-DuneGameConfigPaths -Ip $Ip
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
    if (Test-DuneUpdatesHaveStructMember -Updates $Updates) {
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
        $fileUpdates = Convert-DuneStructUpdates -Raw $raw -Updates $byFile[$f].ToArray() -DefaultsRaw $defRaw
        $new  = ConvertTo-DuneIniManaged -Raw $raw -Updates $fileUpdates -QuotedKeys $quoted
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($new))
        Invoke-V6Ssh -Ip $Ip -Cmd "base64 -d | sudo tee '$path' > /dev/null" -StdinData $b64 -TimeoutSec 30 | Out-Null
    }
}

# =============================================================================
# DEFAULTS CATALOG — full DefaultGame.ini + DefaultEngine.ini from a sg-* pod
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
    param([string]$Ip)
    $paths = Resolve-DuneGameConfigPaths -Ip $Ip
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
