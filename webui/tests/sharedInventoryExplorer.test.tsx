import React from 'react'
import { act, cleanup, render, screen, waitFor } from '@testing-library/react'
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

function navigateTo(url: string) {
  act(() => {
    window.history.pushState(null, '', url)
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { promise, resolve }
}

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

  it('sends a complete valid scope and explicit demo request without broadening', async () => {
    window.history.replaceState(
      null,
      '',
      '/bases?view=inventory&scope_type=storage&scope_id=50001&demo=1',
    )
    inventoryApi.mockResolvedValue({
      ...fixture,
      source: 'static',
      data: { ...fixture.data, mode: 'demo' },
    })
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )

    await waitFor(() => expect(inventoryApi).toHaveBeenCalledWith(expect.objectContaining({
      types: ['storage'],
      scopeType: 'storage',
      scopeId: 50001,
      demo: true,
    })))
    expect(screen.getByText('Showing bundled demo inventory')).toBeInTheDocument()
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

  it.each([
    '/players?view=inventory&scope_type=player',
    '/players?view=inventory&scope_id=20001',
    '/players?view=inventory&scope_type=player&scope_id=bad',
    '/players?view=inventory&scope_type=player&scope_id=0',
    '/players?view=inventory&scope_type=player&scope_id=-1',
  ])('does not broaden invalid scoped URL %s', route => {
    window.history.replaceState(null, '', route)
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['player']} />
      </BrowserRouter>,
    )

    expect(screen.getByText('Invalid inventory scope')).toBeInTheDocument()
    expect(inventoryApi).not.toHaveBeenCalled()
  })

  it('removes demo rows, metadata, cursor, and selection when a replacement live request fails', async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, '', '/bases?view=inventory&demo=1')
    inventoryApi
      .mockResolvedValueOnce({
        ...fixture,
        source: 'static',
        data: { ...fixture.data, mode: 'demo' },
        page: { ...fixture.page, nextCursor: 'demo-cursor', truncated: true },
      })
      .mockRejectedValueOnce(new Error('live database unavailable'))
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )

    await user.click(await screen.findByRole('button', { name: /Spice Melange/ }))
    expect(screen.getByRole('dialog', { name: 'Spice Melange' })).toBeInTheDocument()
    expect(screen.getByText('Demo inventory')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Load more' })).toBeInTheDocument()

    navigateTo('/bases?view=inventory')

    expect(await screen.findByText('Inventory search failed')).toBeInTheDocument()
    expect(screen.getByText('live database unavailable')).toBeInTheDocument()
    expect(screen.queryByRole('list', { name: 'Inventory results' })).not.toBeInTheDocument()
    expect(screen.queryByText('Spice Melange')).not.toBeInTheDocument()
    expect(screen.queryByText('x12')).not.toBeInTheDocument()
    expect(screen.queryByText('Showing bundled demo inventory')).not.toBeInTheDocument()
    expect(screen.queryByText('Demo inventory')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Load more' })).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('removes broader unscoped results when a replacement scoped request fails', async () => {
    const user = userEvent.setup()
    window.history.replaceState(null, '', '/bases?view=inventory')
    inventoryApi
      .mockResolvedValueOnce({
        ...fixture,
        page: { ...fixture.page, nextCursor: 'live-cursor', truncated: true },
      })
      .mockRejectedValueOnce(new Error('scoped inventory unavailable'))
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )

    await user.click(await screen.findByRole('button', { name: /Spice Melange/ }))
    expect(screen.getByRole('dialog', { name: 'Spice Melange' })).toBeInTheDocument()
    expect(screen.getByText('Live database')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Load more' })).toBeInTheDocument()

    navigateTo('/bases?view=inventory&scope_type=storage&scope_id=50001')

    expect(await screen.findByText('Inventory search failed')).toBeInTheDocument()
    expect(screen.getByText('scoped inventory unavailable')).toBeInTheDocument()
    expect(screen.getByText('Scoped to storage container actor 50001.')).toBeInTheDocument()
    expect(screen.queryByRole('list', { name: 'Inventory results' })).not.toBeInTheDocument()
    expect(screen.queryByText('Spice Melange')).not.toBeInTheDocument()
    expect(screen.queryByText('x12')).not.toBeInTheDocument()
    expect(screen.queryByText('Live database')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Load more' })).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('synchronizes URL query navigation and ignores a late response from the prior query', async () => {
    const user = userEvent.setup()
    const lateFooPage = deferred<unknown>()
    const barPage = deferred<unknown>()
    const fooResponse = {
      ...fixture,
      data: { ...fixture.data, query: 'foo' },
      page: { ...fixture.page, nextCursor: 'foo-cursor', truncated: true },
    }
    const barResponse = {
      ...fixture,
      data: {
        ...fixture.data,
        query: 'bar',
        items: [{
          ...fixture.data.items[0],
          id: 84,
          templateId: 'BarItem',
          displayName: 'Bar Result',
        }],
      },
    }
    window.history.replaceState(null, '', '/bases?view=inventory&q=foo')
    inventoryApi
      .mockResolvedValueOnce(fooResponse)
      .mockReturnValueOnce(lateFooPage.promise)
      .mockReturnValueOnce(barPage.promise)
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )

    await user.click(await screen.findByRole('button', { name: /Spice Melange/ }))
    expect(screen.getByRole('dialog', { name: 'Spice Melange' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Load more' }))
    await waitFor(() => expect(inventoryApi).toHaveBeenLastCalledWith(expect.objectContaining({
      q: 'foo',
      cursor: 'foo-cursor',
    })))

    navigateTo('/bases?view=inventory&q=bar')

    expect(screen.getByRole('textbox', { name: 'Search inventory' })).toHaveValue('bar')
    expect(screen.queryByText('Spice Melange')).not.toBeInTheDocument()
    expect(screen.queryByText('Live database')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Load more' })).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await waitFor(() => expect(inventoryApi).toHaveBeenLastCalledWith(expect.objectContaining({
      q: 'bar',
      cursor: undefined,
    })))

    await act(async () => {
      barPage.resolve(barResponse)
      await barPage.promise
    })
    expect(await screen.findByText('Bar Result')).toBeInTheDocument()

    await act(async () => {
      lateFooPage.resolve(fooResponse)
      await lateFooPage.promise
    })
    expect(screen.getByText('Bar Result')).toBeInTheDocument()
    expect(screen.queryByText('Spice Melange')).not.toBeInTheDocument()
  })

  it('synchronizes and requests an explicitly cleared URL query', async () => {
    const clearPage = deferred<unknown>()
    window.history.replaceState(null, '', '/bases?view=inventory&q=bar')
    inventoryApi
      .mockResolvedValueOnce({ ...fixture, data: { ...fixture.data, query: 'bar' } })
      .mockReturnValueOnce(clearPage.promise)
    render(
      <BrowserRouter>
        <SharedInventoryExplorer entityTypes={['storage']} />
      </BrowserRouter>,
    )
    expect(await screen.findByText('Spice Melange')).toBeInTheDocument()

    navigateTo('/bases?view=inventory')

    expect(screen.getByRole('textbox', { name: 'Search inventory' })).toHaveValue('')
    expect(screen.queryByText('Spice Melange')).not.toBeInTheDocument()
    await waitFor(() => expect(inventoryApi).toHaveBeenLastCalledWith(expect.objectContaining({
      q: '',
      cursor: undefined,
    })))

    await act(async () => {
      clearPage.resolve(fixture)
      await clearPage.promise
    })
    expect(await screen.findByText('Spice Melange')).toBeInTheDocument()
  })
})
