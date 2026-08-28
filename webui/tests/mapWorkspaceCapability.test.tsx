import React from 'react'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BrowserRouter } from '../src/router'
import MapWorkspace from '../src/pages/workspaces/MapWorkspace'

const capabilityState = vi.hoisted(() => ({
  loading: false,
  dataPresent: true,
  error: null as string | null,
  ids: new Set<string>(),
  refresh: vi.fn(),
}))
const liveRender = vi.hoisted(() => vi.fn())

vi.mock('../src/hooks/usePlatformCapabilities', () => ({
  usePlatformCapabilities: () => ({
    data: capabilityState.dataPresent ? { data: { capabilities: [] } } : null,
    loading: capabilityState.loading,
    error: capabilityState.error,
    refresh: capabilityState.refresh,
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
  capabilityState.dataPresent = true
  capabilityState.error = null
  capabilityState.ids.clear()
  capabilityState.refresh.mockClear()
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
    capabilityState.dataPresent = false
    window.history.replaceState(null, '', '/map?view=live')

    render(<BrowserRouter><MapWorkspace /></BrowserRouter>)

    expect(screen.getByText('Checking live map availability…')).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Live state' })).not.toBeInTheDocument()
    await waitFor(() => expect(liveRender).not.toHaveBeenCalled())
  })

  it('keeps an errored Live State request in place and offers retry without polling', async () => {
    const user = userEvent.setup()
    capabilityState.dataPresent = false
    capabilityState.error = 'Capability request failed.'
    window.history.replaceState(null, '', '/map?view=live&source=bookmark#field-detail')

    render(<BrowserRouter><MapWorkspace /></BrowserRouter>)

    expect(screen.getByText('Could not check live map availability')).toBeInTheDocument()
    expect(screen.getByText('Capability request failed.')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/map')
    expect(window.location.search).toBe('?view=live&source=bookmark')
    expect(window.location.hash).toBe('#field-detail')
    expect(liveRender).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Retry capability check' }))
    expect(capabilityState.refresh).toHaveBeenCalledOnce()
  })
})
