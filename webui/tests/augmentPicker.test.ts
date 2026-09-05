import { describe, expect, it } from 'vitest'
import { augmentSlotLimit, resolveAugmentItemTags } from '../src/components/AugmentPicker'
import type { AugmentCatalog } from '../src/api/gameplay'

const catalog: AugmentCatalog = {
  augments: {},
  methodItems: {
    'Named Rifle': ['Items.Holsters.RangedWeapons.Light.Rifle'],
  },
  itemAliases: {
    ArmorTemplate: ['Items.Clothes.HeavyArmor.Torso'],
    ArmorTemplate_Schematic: ['Items.Clothes.HeavyArmor.Torso'],
  },
}

describe('AugmentPicker compatibility', () => {
  it('prefers exact template aliases and applies the armor slot limit', () => {
    const tags = resolveAugmentItemTags(catalog, 'ArmorTemplate', 'Named Rifle')
    expect(tags).toEqual(['Items.Clothes.HeavyArmor.Torso'])
    expect(augmentSlotLimit(tags)).toBe(2)
  })

  it('falls back to the display-name mapping for weapon templates', () => {
    const tags = resolveAugmentItemTags(catalog, 'RifleTemplate', 'Named Rifle')
    expect(tags).toEqual(['Items.Holsters.RangedWeapons.Light.Rifle'])
    expect(augmentSlotLimit(tags)).toBe(3)
  })

  it('fails closed when no verified mapping exists', () => {
    expect(augmentSlotLimit(resolveAugmentItemTags(catalog, 'Unknown', 'Unknown'))).toBe(0)
  })

  it('never treats a schematic alias as augmentable gear', () => {
    expect(resolveAugmentItemTags(catalog, 'ArmorTemplate_Schematic', 'Named Rifle')).toEqual([])
  })
})
