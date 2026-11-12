// Writable native UserServerCustomSettings fields covered by game difficulty.
// Independent Game.ini overrides and console commands intentionally stay outside
// this list. New fields require review rather than inheriting a blanket warning.
const PRESET_CONTROLLED_SETTINGS = new Set([
  'GatheringAmount', 'CraftingCost', 'WaterExtractionRate', 'CraftingTimeMultiplier',
  'BuildingCostMultiplier', 'ResourceRespawnSpeed', 'LootRespawnSpeed', 'FuelBurnTimeMultiplier',
  'InventoryVolumeMultiplier', 'PlayerDamageToPlayer', 'PlayerDamageToNPC', 'PlayerDamageToVehicle',
  'PlayerStaminaDrain', 'IntelPointsGainMultiplier', 'NPCHealth', 'NPCDamageToPlayer',
  'NPCDamageToNPC', 'NPCRespawnMultiplier', 'PVPDamageStructures', 'GlobalXpMultiplier',
  'CombatXp', 'GatheringXp', 'MissionXp', 'ItemDurabilityDrainMultiplier',
  'bEnableItemMaxDurabilityLoss', 'PlayerShieldDamageAbsorptionMultiplier',
  'NPCShieldDamageAbsorptionMultiplier', 'HeatBuildupRate', 'ColdBuildupRate', 'ThirstMultiplier',
  'DropEquipmentOnDeath', 'bAllowDynamicBuildingDamage', 'bAllowSandstorms', 'bAllowSandworms',
  'SandwormConsequences', 'PlayerDeathLootRule', 'bIsBuildingRestrictionsEnabled', 'FiefdomLimit',
  'BuildingPieceLimitMultiplier', 'bBuildingInfiniteStability', 'BaseBackupToolTimeRestriction',
  'LandsraadContributionMultiplier', 'LandsraadSpecializationXpMultiplier',
  'LandsraadFactionStandingMultiplier', 'bLandsraadDisableDecreeRerollLimit',
])

export function needsSoloCustomPresetNotice(preset: string | undefined, changes: Readonly<Record<string, string>>): boolean {
  const current = preset?.trim().toLowerCase()
  if (!current || current === 'custom') return false
  return Object.keys(changes).some(key => PRESET_CONTROLLED_SETTINGS.has(key))
}
