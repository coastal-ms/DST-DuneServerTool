import React from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BrowserRouter } from '../src/router'
import MapWorkspace from '../src/pages/workspaces/MapWorkspace'

const capabilityState = vi.hoisted(() => ({
  loading: false,
  ids: new Set<string>(),
}))
const liveRender = vi.hoisted(() => vi.fn())

vi.mock('../src/hooks/usePlatformCapabilities', () => ({
  usePlatformCapabilities: () => ({
    data: null,
    loading: capabilityState.loading,
    error: null,
    refresh: vi.fn(),
    hasCapability: (id: string) => capabilityState.ids.has(id),
  }),
}))
vi.mock('../src/pages/WickMaps', () => ({
  WickMaps: () => <div>Atlas fixture</div>,
}))
vi.mock('../src/pages/MapSpinUp', () => ({
  MapSpinUp: () => <div>Lifecycle fixture</div>,
}))
vi.mock('../src/pages/workspaces/MapLiveState', () => ({
  MapLiveState: () => {
    liveRender()
    return <div>Live state fixture</div>
  },
}))

afterEach(() => {
  cleanup()
  capabilityState.loading = false
  capabilityState.ids.clear()
  liveRender.mockClear()
  window.history.replaceState(null, '', '/')
})

describe('Map workspace capability gating', () => {
  it('renders and polls Live State only when the capability is advertised', async () => {
    capabilityState.ids.add('map.live-cache')
    window.history.replaceState(null, '', '/map?view=live')

    render(<BrowserRouter><MapWorkspace /></BrowserRouter>)

    expect(await screen.findByText('Live state fixture')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Live state' })).toBeInTheDocument()
    expect(liveRender).toHaveBeenCalledOnce()
  })

  it('hides Live State and preserves bookmark state while redirecting to Atlas', async () => {
    window.history.replaceState(null, '', '/map?view=live&source=bookmark#field-detail')

    render(<BrowserRouter><MapWorkspace /></BrowserRouter>)

    expect(await screen.findByText('Atlas fixture')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Live state' })).not.toBeInTheDocument()
    expect(liveRender).not.toHaveBeenCalled()
    expect(window.location.pathname).toBe('/map')
    expect(window.location.search).toBe('?source=bookmark&view=atlas')
    expect(window.location.hash).toBe('#field-detail')
  })

  it('does not mount Live State while capability discovery is pending', async () => {
    capabilityState.loading = true
    window.history.replaceState(null, '', '/map?view=live')

    render(<BrowserRouter><MapWorkspace /></BrowserRouter>)

    expect(screen.getByText('Checking live map availability…')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Live state' })).not.toBeInTheDocument()
    await waitFor(() => expect(liveRender).not.toHaveBeenCalled())
  })
})
