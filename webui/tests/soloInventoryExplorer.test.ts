import { describe, expect, it } from 'vitest'
import { buildSoloInventoryGroups } from '../src/components/solo/SoloInventoryExplorer'

describe('Solo inventory explorer', () => {
  it('groups matching templates across Solo inventory locations', () => {
    const groups = buildSoloInventoryGroups([
      {
        inventoryId: 1,
        destinationKey: 'inventory:1',
        destinationLabel: 'Backpack',
        destinationKind: 'backpack',
        templateId: 'Copper',
        displayName: 'Copper Ore',
        totalQuantity: 10,
        occurrenceCount: 1,
        minQuality: 0,
        maxQuality: 0,
      },
      {
        inventoryId: 2,
        destinationKey: 'inventory:2',
        destinationLabel: 'Storage Container #1',
        destinationKind: 'storage',
        templateId: 'copper',
        displayName: 'Copper Ore',
        totalQuantity: 25,
        occurrenceCount: 2,
        minQuality: 1,
        maxQuality: 2,
      },
    ])

    expect(groups).toHaveLength(1)
    expect(groups[0]).toMatchObject({
      groupKey: 'copper',
      totalQuantity: 35,
      occurrenceCount: 3,
      locationCount: 2,
      quality: { min: 0, max: 2, mixed: true },
    })
  })
})
