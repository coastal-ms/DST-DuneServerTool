import React from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
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
  return { ...actual, getSharedInventory: inventoryApi }
})

const fixture = {
  schemaVersion: 1,
  requestId: 'request-1',
  generatedAt: '2026-09-02T10:00:00Z',
  source: 'live',
  freshness: {
    observedAt: '2026-09-02T10:00:00Z',
    cachedAt: null,
    ageSeconds: null,
    state: 'fresh',
    lastErrorCode: null,
  },
  capabilities: ['inventory.read'],
  data: {
    mode: 'live',
    query: '',
    supportedEntityTypes: ['player', 'storage'],
    unavailableEntityTypes: ['base', 'vehicle'],
    items: [{
      id: 42,
      templateId: 'MelangeSpice',
      displayName: 'Spice Melange',
      kind: 'item',
      quantity: 12,
      quality: 3,
      durability: 'N/A',
      maxDurability: 'N/A',
      waterAmount: 'N/A',
      waterType: '',
      metadata: {
        category: 'Resources',
        tier: 2,
        rarity: 'Common',
        icon: '',
        stackMaximum: 100,
        volume: 0.1,
        vendorPrice: 5,
        isGradeable: false,
      },
      entity: {
        type: 'storage',
        id: 50001,
        label: 'Spice Vault',
        owner: 'Stilgar',
        map: 'Hagga Basin',
        class: 'SpiceSilo_Placeable',
        inventoryId: 60001,
        inventoryType: 4,
        workspacePath: '/bases?view=inventory&scope_type=storage&scope_id=50001',
      },
    }],
  },
  page: { limit: 100, nextCursor: null, truncated: false },
} as const

afterEach(() => {
  cleanup()
  capabilityState.loading = false
  capabilityState.dataPresent = true
  capabilityState.error = null
  capabilityState.enabled = true
  capabilityState.refresh.mockClear()
  inventoryApi.mockReset()
  window.history.replaceState(null, '', '/')
})

describe('Shared Inventory Explorer', () => {
  it('shows live item, owner, source, freshness, and read-only detail without write controls', async () => {
    const user = userEvent.setup()
    inventoryApi.mockResolvedValue(fixture)
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['player', 'storage']} />
      </BrowserRouter>,
    )

    expect(await screen.findByText('Spice Melange')).toBeInTheDocument()
    expect(screen.getByText('Spice Vault')).toBeInTheDocument()
    expect(screen.getByText('Stilgar')).toBeInTheDocument()
    expect(screen.getByText('Live database')).toHaveAttribute('data-freshness-state', 'fresh')
    expect(screen.getAllByText('Read-only').length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: /give|delete|repair/i })).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Spice Melange/ }))
    expect(screen.getByRole('dialog', { name: 'Spice Melange' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Open owning container' }))
      .toHaveAttribute('href', '/bases?view=inventory&scope_type=storage&scope_id=50001')
  })

  it('submits one typed search and preserves the bounded entity filter', async () => {
    const user = userEvent.setup()
    inventoryApi.mockResolvedValue(fixture)
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )
    await screen.findByText('Spice Melange')
    await user.clear(screen.getByRole('textbox', { name: 'Search inventory' }))
    await user.type(screen.getByRole('textbox', { name: 'Search inventory' }), 'vault')
    await user.click(screen.getByRole('button', { name: 'Search' }))

    await waitFor(() => expect(inventoryApi).toHaveBeenLastCalledWith(expect.objectContaining({
      q: 'vault',
      types: ['storage'],
      limit: 100,
    })))
  })

  it('renders vehicle cargo as honestly unavailable without calling inventory APIs', () => {
    render(
      <BrowserRouter>
        <SharedInventoryExplorer
          entityTypes={[]}
          title="Vehicle cargo"
          unavailableReason="No proven vehicle cargo join."
        />
      </BrowserRouter>,
    )

    expect(screen.getByText('Inventory scope not yet available')).toBeInTheDocument()
    expect(screen.getByText('No proven vehicle cargo join.')).toBeInTheDocument()
    expect(inventoryApi).not.toHaveBeenCalled()
  })

  it('fails closed when the capability is not advertised', () => {
    capabilityState.enabled = false
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['player']} />
      </BrowserRouter>,
    )

    expect(screen.getByText('Shared inventory is not included in this backend')).toBeInTheDocument()
    expect(inventoryApi).not.toHaveBeenCalled()
  })
})
