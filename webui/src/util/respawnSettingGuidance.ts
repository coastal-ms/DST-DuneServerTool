// Funcom Custom Settings UI, v1.5.3.7: these similarly named keys run in opposite directions.
export const RESPAWN_SETTING_GUIDANCE: Record<string, { label: string; effect: string }> = {
  ResourceRespawnSpeed: {
    label: 'Resource Respawn Speed',
    effect: 'Higher values make harvested resources respawn faster; lower positive values make them respawn slower. This is the opposite direction to Loot Respawn Time.',
  },
  LootRespawnSpeed: {
    label: 'Loot Respawn Time',
    effect: 'Shown in-game as Loot Respawn Speed. Higher values make loot chests replenish slower; lower positive values make them replenish faster. This is the opposite direction to Resource Respawn Speed.',
  },
}
