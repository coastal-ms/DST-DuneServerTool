import { createElement } from 'react'
import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import {
  buildSoloInventoryLocations,
  buildSoloInventoryGroups,
  filterSoloInventoryItemsByLocation,
  SoloInventoryExplorer,
} from '../src/components/solo/SoloInventoryExplorer'

describe('Solo inventory explorer', () => {
  it('groups matching templates across Solo inventory locations', () => {
    const items = [
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
      {
        inventoryId: 35,
        destinationKey: 'inventory:35',
        destinationLabel: 'Bank Storage',
        destinationKind: 'bank',
        templateId: 'copper',
        displayName: 'Copper Ore',
        totalQuantity: 5,
        occurrenceCount: 1,
        minQuality: 0,
        maxQuality: 0,
      },
    ]
    const groups = buildSoloInventoryGroups(items)

    expect(groups).toHaveLength(1)
    expect(groups[0]).toMatchObject({
      groupKey: 'copper',
      totalQuantity: 40,
      occurrenceCount: 4,
      locationCount: 3,
      quality: { min: 0, max: 2, mixed: true },
    })
    expect(filterSoloInventoryItemsByLocation(items, 'inventory:2')).toEqual([items[1]])
    expect(filterSoloInventoryItemsByLocation(items, 'inventory:35')).toEqual([items[2]])
    expect(filterSoloInventoryItemsByLocation(items, '')).toEqual(items)
  })

  it('keeps an empty Bank Storage destination visible in the location picker', () => {
    const items = [{
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
    }]
    const inventories = [{
      id: 1,
      key: 'inventory:1',
      label: 'Backpack',
      kind: 'backpack' as const,
      itemRows: 1,
      maxItemCount: 60,
      maxItemVolume: 1050,
      usedVolume: 10,
    }, {
      id: 11,
      key: 'inventory:11',
      label: 'Bank Storage',
      kind: 'bank' as const,
      itemRows: 0,
      maxItemCount: 500,
      maxItemVolume: 30000,
      usedVolume: 0,
    }]

    expect(buildSoloInventoryLocations(items, inventories)).toEqual([
      { key: 'inventory:1', label: 'Backpack' },
      { key: 'inventory:11', label: 'Bank Storage' },
    ])
  })

  it('deletes an exact Solo occurrence with a bounded quantity', () => {
    const onDelete = vi.fn()
    const item = {
      inventoryId: 1,
      destinationKey: 'inventory:1',
      destinationLabel: 'Backpack',
      destinationKind: 'backpack' as const,
      templateId: 'PlantFiber',
      displayName: 'Plant Fiber',
      totalQuantity: 50,
      occurrenceCount: 1,
      minQuality: 0,
      maxQuality: 0,
      occurrences: [{ itemId: 42, stackSize: 50, quality: 0, templateId: 'PlantFiber' }],
    }

    render(createElement(SoloInventoryExplorer, {
      items: [item],
      inventories: [],
      connected: true,
      disabled: false,
      busyItemId: null,
      onDelete,
    }))

    fireEvent.click(screen.getByText('Plant Fiber'))
    const quantity = screen.getByLabelText('Delete quantity')
    fireEvent.change(quantity, { target: { value: '12' } })
    fireEvent.click(screen.getByTitle('Delete item'))

    expect(onDelete).toHaveBeenCalledWith(item.occurrences[0], item, 12)
  })
})
