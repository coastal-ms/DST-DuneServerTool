// Unit coverage for the category-aware catalog filtering that backs the
// ItemPicker category selector. The selector lets users browse a category with
// an empty search box, or narrow a text search to one category.

import { describe, expect, it } from 'vitest'
import {
  catalogCategories,
  filterCatalog,
  filterCosmeticsCatalog,
  getHouseSwatchCosmetics,
  type CatalogItem,
  type CosmeticEntry,
} from '../../src/api/gameplay'

const CATALOG: CatalogItem[] = [
  { template_id: 'CopperBar',   name: 'Copper Ingot',  category: 'Resources' },
  { template_id: 'AzuriteOre',  name: 'Copper Ore',    category: 'Resources' },
  { template_id: 'IronSword',   name: 'Iron Sword',    category: 'Weapons - Melee' },
  { template_id: 'PlasmaRifle', name: 'Plasma Rifle',  category: 'Weapons - Ranged' },
  { template_id: 'Stillsuit',   name: 'Stillsuit',     category: 'Garments - Chest' },
  { template_id: 'D_AmmoBlueprint', name: 'Ammo Blueprint', category: 'Developer - Blueprints' },
]

describe('catalogCategories', () => {
  it('returns distinct categories sorted alphabetically', () => {
    expect(catalogCategories(CATALOG)).toEqual([
      'Developer - Blueprints', 'Garments - Chest', 'Resources', 'Weapons - Melee', 'Weapons - Ranged',
    ])
  })
})

describe('filterCatalog category narrowing', () => {
  it('empty query + no category returns nothing (no 1.3k dump)', () => {
    expect(filterCatalog(CATALOG, '')).toEqual([])
  })

  it('empty query + category browses that category alphabetically', () => {
    const out = filterCatalog(CATALOG, '', 20, 'Resources')
    expect(out.map(i => i.template_id)).toEqual(['CopperBar', 'AzuriteOre'])
    // sorted by name: "Copper Ingot" < "Copper Ore"
    expect(out.map(i => i.name)).toEqual(['Copper Ingot', 'Copper Ore'])
  })

  it('text query is restricted to the selected category', () => {
    // "Copper" matches both Resources rows; the Weapons category excludes them.
    expect(filterCatalog(CATALOG, 'Copper', 20, 'Weapons - Melee')).toEqual([])
    expect(filterCatalog(CATALOG, 'Copper', 20, 'Resources').map(i => i.template_id))
      .toEqual(['CopperBar', 'AzuriteOre'])
  })

  it('text query with no category still searches across everything', () => {
    expect(filterCatalog(CATALOG, 'sword').map(i => i.template_id)).toEqual(['IronSword'])
  })

  it('matches category names and normalizes separators', () => {
    expect(filterCatalog(CATALOG, 'developer_').map(i => i.template_id)).toEqual(['D_AmmoBlueprint'])
  })
})

describe('filterCosmeticsCatalog', () => {
  const cosmetics: CosmeticEntry[] = [
    { template: 'Atreides_Buggy_Variant', name: 'Atreides Buggy Variant', group: 'Vehicle Skins' },
    { template: 'D_Choam_HeavyArmor_Swatch', name: 'CHOAM Heavy Armor Swatch', group: 'Swatches (Dyes)' },
    { template: 'Atreides_Placeables_Swatch', name: 'Atreides Buildables Swatch', group: 'Swatches (Dyes)' },
    { template: 'Ecaz_HeavyArmor_Swatch', name: 'House Ecaz Garment Swatch', group: 'Swatches (Dyes)' },
    { template: 'Ecaz_Placeables_Swatch', name: 'House Ecaz Placeables Swatch', group: 'Swatches (Dyes)' },
    { template: 'NotASwatch', name: 'House Example Swatch', group: 'Other Customization' },
  ]

  it('uses contains matching instead of prefix-only matching', () => {
    expect(filterCosmeticsCatalog(cosmetics, 'buggy')).toEqual([cosmetics[0]])
    expect(filterCosmeticsCatalog(cosmetics, 'heavy armor')).toEqual([cosmetics[1]])
  })

  it('matches group names so vehicle search returns every vehicle skin', () => {
    expect(filterCosmeticsCatalog(cosmetics, 'vehicle')).toEqual([cosmetics[0]])
  })

  it('selects only vendor House Swatches in stable name order', () => {
    expect(getHouseSwatchCosmetics(cosmetics)).toEqual([cosmetics[3], cosmetics[4]])
  })

  it('can select only buildable/placeables House Swatches', () => {
    expect(getHouseSwatchCosmetics(cosmetics, 'placeables')).toEqual([cosmetics[2], cosmetics[4]])
  })
})
