import React from 'react'
import { act, cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SharedInventoryExplorer } from '../src/components/inventory/SharedInventoryExplorer'
import { BrowserRouter } from '../src/router'

const capabilityState = vi.hoisted(() => ({
  loading: false,
  dataPresent: true,
  error: null as string | null,
  enabled: true,
  refresh: vi.fn(),
}))
const inventoryApi = vi.hoisted(() => vi.fn())
const occurrenceApi = vi.hoisted(() => vi.fn())
const itemIconResolver = vi.hoisted(() => vi.fn())

vi.mock('../src/hooks/usePlatformCapabilities', () => ({
  usePlatformCapabilities: () => ({
    data: capabilityState.dataPresent ? { data: { capabilities: [] } } : null,
    loading: capabilityState.loading,
    error: capabilityState.error,
    refresh: capabilityState.refresh,
    hasCapability: (id: string) => id === 'inventory.read' && capabilityState.enabled,
  }),
}))
vi.mock('../src/api/gameplay', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/api/gameplay')>()
  return { ...actual, getSharedInventory: inventoryApi, getSharedInventoryOccurrences: occurrenceApi }
})
vi.mock('../src/components/inventory/InventoryItemIcon', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/components/inventory/InventoryItemIcon')>()
  return { ...actual, resolveItemIcon: itemIconResolver }
})

const metadata = {
  category: 'Resources', tier: 2, rarity: 'Common', icon: '', stackMaximum: 100,
  volume: 0.1, vendorPrice: 5, isGradeable: false,
}
const players = [
  { id: 20001, name: 'Coastal', occurrenceCount: 5 },
  { id: 20002, name: 'Coastal', occurrenceCount: 2 },
]
const locations = [
  { type: 'player', id: 20001, label: 'Backpack', owner: 'Coastal', playerId: 20001, playerName: 'Coastal', occurrenceCount: 2 },
  { type: 'storage', id: 50001, label: 'Copper box', owner: 'Coastal', playerId: 20001, playerName: 'Coastal', occurrenceCount: 3 },
  { type: 'storage', id: 50002, label: 'Copper box', owner: 'Coastal', playerId: 20002, playerName: 'Coastal', occurrenceCount: 2 },
] as const
const copperGroup = {
  groupKey: 'copper',
  templateId: 'Copper',
  displayName: 'Copper',
  totalQuantity: 30,
  occurrenceCount: 3,
  locationCount: 3,
  quality: { min: 0, max: 2, mixed: true },
  metadata,
}
const fixture = {
  schemaVersion: 1,
  requestId: 'group-request',
  generatedAt: '2026-09-02T10:00:00Z',
  source: 'live',
  freshness: { observedAt: '2026-09-02T10:00:00Z', cachedAt: null, ageSeconds: null, state: 'fresh', lastErrorCode: null },
  capabilities: ['inventory.read'],
  data: {
    mode: 'live',
    query: '',
    playerId: null,
    location: null,
    selectedPlayerValid: true,
    selectedLocationValid: true,
    supportedEntityTypes: ['player', 'storage'],
    unavailableEntityTypes: ['base', 'vehicle'],
    groups: [copperGroup],
    players,
    locations,
  },
  page: { limit: 100, nextCursor: null, truncated: false },
} as const
const occurrence = {
  id: 42, templateId: 'Copper', displayName: 'Copper', kind: 'item', quantity: 10,
  quality: 2, durability: '80', maxDurability: '100', waterAmount: 'N/A', waterType: '',
  metadata, player: { id: 20001, name: 'Coastal' },
  entity: {
    type: 'storage', id: 50001, label: 'Copper box', owner: 'Coastal', map: 'Hagga Basin',
    class: 'GenericContainer_Placeable', inventoryId: 60001, inventoryType: 4,
    workspacePath: '/bases?view=inventory&scope_type=storage&scope_id=50001',
  },
} as const
const occurrenceFixture = {
  ...fixture,
  requestId: 'occurrence-request',
  data: { mode: 'live', templateId: 'Copper', playerId: null, items: [occurrence], players, locations },
  page: { limit: 50, nextCursor: null, truncated: false },
} as const

function renderExplorer() {
  return render(<BrowserRouter><SharedInventoryExplorer entityTypes={['player', 'storage']} /></BrowserRouter>)
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { promise, resolve }
}

beforeEach(() => {
  inventoryApi.mockResolvedValue(fixture)
  occurrenceApi.mockResolvedValue(occurrenceFixture)
  itemIconResolver.mockResolvedValue('https://cdn-hosted.gaming.tools/dune/images/dune/items/copper.webp')
})

afterEach(() => {
  cleanup()
  inventoryApi.mockReset()
  occurrenceApi.mockReset()
  itemIconResolver.mockReset()
  window.history.replaceState(null, '', '/')
})

describe('Shared Inventory Explorer grouped catalog', () => {
  it('defaults to all players and locations and renders one aggregate slot', async () => {
    renderExplorer()
    const slot = await screen.findByRole('button', { name: /Copper, total quantity 30, 3 occurrences across 3 locations, quality 0-2/ })
    expect(slot).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'Player' })).toHaveValue('')
    expect(screen.getByRole('combobox', { name: 'Location' })).toHaveValue('')
    expect(screen.getByText('3 loc')).toBeInTheDocument()
    expect(inventoryApi).toHaveBeenCalledWith(expect.objectContaining({ playerId: undefined, locationId: undefined, sort: 'name-asc' }))
  })

  it('keeps duplicate player and storage names visibly distinct without raw IDs', async () => {
    renderExplorer()
    await screen.findByText('Copper')
    expect(screen.getByRole('option', { name: 'Coastal (1)' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Coastal (2)' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Copper box - Coastal (1)' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Copper box - Coastal (2)' })).toBeInTheDocument()
    expect(screen.queryByText('50001')).not.toBeInTheDocument()
  })

  it('writes player, location, and sort filters to URL and clears dependent location on player change', async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, '', '/economy?view=inventory&location_type=storage&location_id=50001')
    renderExplorer()
    await screen.findByText('Copper')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Player' }), '20001')
    expect(window.location.search).toContain('player_id=20001')
    expect(window.location.search).not.toContain('location_id')
    await screen.findByText('Copper')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Sort by' }), 'quantity-desc')
    expect(window.location.search).toContain('sort=quantity-desc')
  })

  it('fails closed for a malformed player deep link', async () => {
    window.history.replaceState(null, '', '/economy?view=inventory&player_id=bad')
    renderExplorer()
    expect(await screen.findByText('The requested player ID must be a positive integer.')).toBeInTheDocument()
    expect(inventoryApi).not.toHaveBeenCalled()
  })

  it('keeps a valid selected location when search returns no facet matches', async () => {
    window.history.replaceState(null, '', '/economy?view=inventory&q=missing&player_id=20001&location_type=storage&location_id=50001')
    inventoryApi.mockResolvedValue({
      ...fixture,
      data: {
        ...fixture.data,
        query: 'missing',
        playerId: 20001,
        location: { type: 'storage', id: 50001 },
        groups: [],
        players: [],
        locations: [],
        selectedPlayerValid: true,
        selectedLocationValid: true,
      },
    })
    renderExplorer()
    expect(await screen.findByText('No matching inventory items')).toBeInTheDocument()
    expect(screen.queryByText('Location does not match this player')).not.toBeInTheDocument()
  })

  it('opens a lazy occurrence panel with inherited filters and adjustable sorting', async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, '', '/economy?view=inventory&player_id=20001&location_type=storage&location_id=50001')
    renderExplorer()
    await user.click(await screen.findByRole('button', { name: /Copper/ }))
    expect(await screen.findByRole('dialog', { name: 'Copper' })).toBeInTheDocument()
    await waitFor(() => expect(occurrenceApi).toHaveBeenCalledWith(expect.objectContaining({
      templateId: 'Copper', playerId: 20001, locationType: 'storage', locationId: 50001, sort: 'player-asc',
    })))
    expect(screen.getByRole('list', { name: 'Item occurrences' })).toHaveTextContent('Copper box')
    const occurrencePlayer = screen.getByRole('combobox', { name: 'Occurrence player' })
    expect(within(occurrencePlayer).getByRole('option', { name: 'Coastal (1)' })).toBeInTheDocument()
    expect(within(occurrencePlayer).getByRole('option', { name: 'Coastal (2)' })).toBeInTheDocument()
    await user.selectOptions(screen.getByRole('combobox', { name: 'Sort occurrences' }), 'quality-desc')
    await waitFor(() => expect(occurrenceApi).toHaveBeenLastCalledWith(expect.objectContaining({ sort: 'quality-desc' })))
  })

  it('omits gaming.tools attribution when icon verification fails', async () => {
    const user = userEvent.setup()
    itemIconResolver.mockResolvedValue(null)
    renderExplorer()
    await user.click(await screen.findByRole('button', { name: /Copper/ }))
    await screen.findByRole('dialog', { name: 'Copper' })
    await waitFor(() => expect(itemIconResolver).toHaveBeenCalledWith('Copper'))
    expect(screen.queryByRole('link', { name: 'View on dune.gaming.tools' })).not.toBeInTheDocument()
  })

  it('isolates late grouped responses after URL filter changes', async () => {
    const late = deferred<typeof fixture>()
    inventoryApi.mockReset()
    inventoryApi.mockReturnValueOnce(late.promise).mockResolvedValueOnce({
      ...fixture,
      data: { ...fixture.data, groups: [{ ...copperGroup, groupKey: 'iron', templateId: 'Iron', displayName: 'Iron' }] },
    })
    renderExplorer()
    act(() => {
      window.history.pushState(null, '', '/economy?view=inventory&q=iron')
      window.dispatchEvent(new PopStateEvent('popstate'))
    })
    expect(await screen.findByText('Iron')).toBeInTheDocument()
    await act(async () => { late.resolve(fixture); await late.promise })
    expect(screen.queryByText('Copper')).not.toBeInTheDocument()
  })

  it('fails closed for malformed direct location links', () => {
    window.history.replaceState(null, '', '/economy?view=inventory&location_type=storage')
    renderExplorer()
    expect(screen.getByText('Invalid inventory scope')).toBeInTheDocument()
    expect(inventoryApi).not.toHaveBeenCalled()
  })
})
