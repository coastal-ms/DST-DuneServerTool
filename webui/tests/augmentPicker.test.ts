import { describe, expect, it } from 'vitest'
import shippedAugments from '../../app/data/augment-compatibility.json'
import shippedItems from '../../app/data/gameplay-item-data.json'
import {
  augmentEffectsForGrade,
  augmentGrades,
  augmentSlotLimit,
  maxAugmentGrade,
  minAugmentGrade,
  resolveAugmentItemTags,
} from '../src/components/AugmentPicker'
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

  it('maps relative effect rows to actual grades ending at grade 5', () => {
    const pressurizer = { 1: ['grade 4 effect'], 2: ['grade 5 effect'] }
    expect(augmentGrades(pressurizer)).toEqual([
      { quality: 4, effectKey: '1' },
      { quality: 5, effectKey: '2' },
    ])
    expect(minAugmentGrade(pressurizer)).toBe(4)
    expect(maxAugmentGrade(pressurizer)).toBe(5)
    expect(augmentEffectsForGrade(pressurizer, 4)).toEqual(['grade 4 effect'])
    expect(augmentEffectsForGrade(pressurizer, 5)).toEqual(['grade 5 effect'])
  })

  it('maps three effect rows to actual grades 3 through 5', () => {
    expect(augmentGrades({ 1: ['low'], 2: ['mid'], 3: ['high'] })
      .map(value => value.quality)).toEqual([3, 4, 5])
  })

  it('keeps the shipped relative rows consistent with explicit game quality metadata', () => {
    const items = shippedItems.items as Record<string, { min_quality_level?: number }>
    let checked = 0
    for (const [id, augment] of Object.entries(shippedAugments.augments)) {
      const keys = Object.keys(augment.gradeEffects).map(Number).sort((a, b) => a - b)
      expect(keys.length, id).toBeGreaterThanOrEqual(1)
      expect(keys.length, id).toBeLessThanOrEqual(5)
      expect(keys, id).toEqual(Array.from({ length: keys.length }, (_, index) => index + 1))
      const minimum = items[id]?.min_quality_level
      if (minimum !== undefined) {
        expect(minAugmentGrade(augment.gradeEffects), id).toBe(minimum)
        checked++
      }
    }
    expect(checked).toBeGreaterThan(0)
  })

  it('does not resolve effects for qualities outside the actual range', () => {
    const effects = { 1: ['grade 4'], 2: ['grade 5'] }
    expect(augmentEffectsForGrade(effects, 3)).toEqual([])
    expect(augmentEffectsForGrade(effects, 6)).toEqual([])
  })
})
