import { describe, expect, it } from 'vitest'
import {
  buildSoloCosmeticGrant,
  getSoloCosmeticBackpackDestination,
  groupSoloCosmetics,
  SOLO_COSMETIC_ENTITLEMENT_WARNING,
} from '../src/pages/SoloMode'
import type { CosmeticEntry } from '../src/api/gameplay'

const catalog: CosmeticEntry[] = [
  { template: 'DesertSwatch', name: 'Desert Dye', group: 'Swatches (Dyes)' },
  { template: 'ScoutSetVariant', name: 'Scout Set', group: 'Armor & Suit Sets' },
  { template: 'ObserverPatent', name: 'Observer Patent', group: 'Building Sets - Observer (Twitch)' },
]

describe('Solo cosmetic grants', () => {
  it('filters and groups the shared cosmetics catalog', () => {
    const groups = groupSoloCosmetics(catalog, 'scout')

    expect(groups).toEqual([
      ['Armor & Suit Sets', [catalog[1]]],
    ])
  })

  it('sorts matching groups for a stable picker', () => {
    expect(groupSoloCosmetics(catalog, '').map(([group]) => group)).toEqual([
      'Armor & Suit Sets',
      'Building Sets - Observer (Twitch)',
      'Swatches (Dyes)',
    ])
  })

  it('states that grants do not create account ownership', () => {
    expect(SOLO_COSMETIC_ENTITLEMENT_WARNING).toContain('only to this Solo save')
    expect(SOLO_COSMETIC_ENTITLEMENT_WARNING).toContain('do not create Funcom account ownership')
  })

  it('forces unlock delivery to the backpack instead of Developer Storage', () => {
    const inventories = [
      {
        id: 2,
        key: 'inventory:2',
        label: 'Developer Storage',
        kind: 'developer-storage',
        itemRows: 0,
        maxItemCount: 100,
        maxItemVolume: 0,
        usedVolume: 0,
      },
      {
        id: 1,
        key: 'inventory:1',
        label: 'Backpack',
        kind: 'backpack',
        itemRows: 5,
        maxItemCount: 35,
        maxItemVolume: 1000,
        usedVolume: 100,
      },
    ] as const

    expect(getSoloCosmeticBackpackDestination([...inventories])).toBe('inventory:1')
    expect(buildSoloCosmeticGrant('ScoutSetVariant', [...inventories])).toEqual({
      destination: 'inventory:1',
      items: [{ templateId: 'ScoutSetVariant', quantity: 1, quality: 0 }],
    })
  })
})
