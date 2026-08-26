import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  getResourceLikelihoodSeed,
  sectorsForTier,
  type ResourceLikelihoodTier,
} from '../src/ddSeedResourceLikelihood'

describe('DD Seed Map resource likelihood test data', () => {
  it('is isolated to the seed 3 feedback build', () => {
    expect(getResourceLikelihoodSeed(2)).toBeUndefined()
    expect(getResourceLikelihoodSeed(3)?.resources.map(resource => resource.type))
      .toEqual(['iron', 'carbon', 'erythrite'])
    expect(getResourceLikelihoodSeed(4)).toBeUndefined()
  })

  it('contains valid unique sector scores and matching tiers', () => {
    const seed = getResourceLikelihoodSeed(3)
    expect(seed).toBeDefined()

    for (const resource of seed!.resources) {
      if (resource.source === 'heatmap') {
        expect(resource.variantCount).toBe(17)
      } else {
        expect(resource.evidenceCount).toBe(2)
      }
      expect(new Set(resource.sectors.map(sector => sector.sector)).size)
        .toBe(resource.sectors.length)

      for (const sector of resource.sectors) {
        expect(sector.sector).toMatch(/^[A-I][1-9]$/)
        expect(sector.score).toBeGreaterThan(0)
        expect(sector.score).toBeLessThanOrEqual(100)
        const expectedTier: ResourceLikelihoodTier = sector.score >= 70
          ? 'high'
          : sector.score >= 35
            ? 'medium'
            : 'low'
        expect(sector.tier).toBe(expectedTier)
      }
    }
  })

  it('sorts tier summaries in map order', () => {
    const iron = getResourceLikelihoodSeed(3)!.resources[0]
    expect(sectorsForTier(iron, 'high')).toEqual(['H3', 'H4', 'G6', 'F6', 'C4'])
  })

  it('includes the repeated seed 3 Erythrite cave evidence', () => {
    const erythrite = getResourceLikelihoodSeed(3)!.resources
      .find(resource => resource.type === 'erythrite')
    expect(erythrite?.source).toBe('cave')
    expect(erythrite?.sectors.map(sector => sector.sector)).toEqual(['E9', 'B3'])
  })

  it('keeps the resource layer off until the tester selects one', () => {
    const source = readFileSync(resolve(__dirname, '../src/pages/WickMaps.tsx'), 'utf8')
    expect(source).toContain(
      'useState<ResourceLikelihoodType | null>(null)',
    )
  })
})
