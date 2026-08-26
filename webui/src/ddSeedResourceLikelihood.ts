import data from './data/ddSeedResourceLikelihood.json'

export type ResourceLikelihoodTier = 'low' | 'medium' | 'high'
export type ResourceLikelihoodType = 'iron' | 'carbon' | 'erythrite'
export type ResourceLikelihoodSource = 'heatmap' | 'cave'

export type ResourceLikelihoodSector = {
  sector: string
  score: number
  tier: ResourceLikelihoodTier
}

export type ResourceLikelihoodEntry = {
  type: ResourceLikelihoodType
  label: string
  source: ResourceLikelihoodSource
  variantCount?: number
  evidenceCount?: number
  sectors: ResourceLikelihoodSector[]
}

export type ResourceLikelihoodSeed = {
  seed: number
  resources: ResourceLikelihoodEntry[]
}

type ResourceLikelihoodPayload = {
  schemaVersion: number
  generated: string
  status: 'test'
  name: string
  source: string
  seeds: ResourceLikelihoodSeed[]
}

const PAYLOAD = data as ResourceLikelihoodPayload

export const RESOURCE_LIKELIHOOD_STYLES: Record<
  ResourceLikelihoodType,
  { fill: string; stroke: string }
> = {
  iron: { fill: '#38a6d6', stroke: '#b9ebff' },
  carbon: { fill: '#465968', stroke: '#c7dce8' },
  erythrite: { fill: '#d65248', stroke: '#ffd0c9' },
}

export const RESOURCE_TIER_OPACITY: Record<ResourceLikelihoodTier, number> = {
  low: 0.12,
  medium: 0.22,
  high: 0.36,
}

export function getResourceLikelihoodSeed(seed: number): ResourceLikelihoodSeed | undefined {
  return PAYLOAD.seeds.find(entry => entry.seed === seed)
}

export function sectorsForTier(
  resource: ResourceLikelihoodEntry,
  tier: ResourceLikelihoodTier,
): string[] {
  return resource.sectors
    .filter(sector => sector.tier === tier)
    .map(sector => sector.sector)
}
