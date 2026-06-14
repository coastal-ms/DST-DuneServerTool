// Unit coverage for the category-aware catalog filtering that backs the
// ItemPicker category selector. The selector lets users browse a category with
// an empty search box, or narrow a text search to one category.

import { describe, expect, it } from 'vitest'
import { catalogCategories, filterCatalog, type CatalogItem } from '../../src/api/gameplay'

const CATALOG: CatalogItem[] = [
  { template_id: 'CopperBar',   name: 'Copper Ingot',  category: 'Resources' },
  { template_id: 'AzuriteOre',  name: 'Copper Ore',    category: 'Resources' },
  { template_id: 'IronSword',   name: 'Iron Sword',    category: 'Weapons - Melee' },
  { template_id: 'PlasmaRifle', name: 'Plasma Rifle',  category: 'Weapons - Ranged' },
  { template_id: 'Stillsuit',   name: 'Stillsuit',     category: 'Garments - Chest' },
]

describe('catalogCategories', () => {
  it('returns distinct categories sorted alphabetically', () => {
    expect(catalogCategories(CATALOG)).toEqual([
      'Garments - Chest', 'Resources', 'Weapons - Melee', 'Weapons - Ranged',
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
})
