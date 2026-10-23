import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Dashboard } from '../src/pages/Dashboard'

const getLinks = vi.hoisted(() => vi.fn())
const snapshot = vi.hoisted(() => ({ value: null as Record<string, unknown> | null }))
vi.mock('../src/api/links', () => ({ getLinks }))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({ status: snapshot.value, loading: false }) }))
vi.mock('../src/router', () => ({ useNavigate: () => vi.fn() }))
vi.mock('../src/pages/dashboard/ScheduledRestarts', () => ({ ScheduledRestarts: () => null }))
vi.mock('../src/pages/dashboard/VmMemoryPressureBanner', () => ({ VmMemoryPressureBanner: () => null }))
vi.mock('../src/components/HealthRefreshControl', () => ({ HealthRefreshControl: () => null }))

const unavailable = {
  vmRunning: false, bgRunning: false,
  fileBrowser: { available: false, url: null, reason: 'VM state: Starting - start the VM first.' },
  director: { available: false, url: null, reason: 'VM state: Starting - start the VM first.' },
}
const ready = {
  vmRunning: true, bgRunning: true,
  fileBrowser: { available: true, url: 'http://192.0.2.1:18888/', reason: null },
  director: { available: true, url: 'http://192.0.2.1:31982/', reason: null },
}

beforeEach(() => { vi.useFakeTimers(); getLinks.mockReset(); localStorage.clear(); snapshot.value = null })
afterEach(() => { cleanup(); vi.useRealTimers() })

describe('dashboard web interfaces after VM startup', () => {
  it('keeps map phase details visible during startup and stopping without suggesting a memory change', async () => {
    getLinks.mockResolvedValue(ready)
    snapshot.value = { bg: { state: 'stopping', info: { status: 'Reconciling' }, gameServers: [
      { map: 'Survival_1', phase: 'Stopping', ready: 'false', players: '0', age: '2m' },
    ] } }
    const view = render(<Dashboard />)
    await act(async () => { await Promise.resolve() })
    expect(screen.getAllByText('Stopping').length).toBeGreaterThan(1)
    expect(screen.getAllByText('Hagga Basin')).toHaveLength(2)
    expect(screen.queryByText('Battlegroup must be running.')).toBeNull()
    expect(screen.queryByText(/Check VM Startup\/Minimum RAM/)).toBeNull()
    snapshot.value = { bg: { state: 'starting', info: { status: 'Healthy' }, gameServers: [
      { map: 'Survival_1', phase: 'PostLandscapePhysics', ready: 'false', players: '0', age: '2m' },
    ] } }
    view.rerender(<Dashboard />)
    expect(screen.getAllByText('Starting').length).toBeGreaterThan(1)
    expect(screen.getAllByText('PostLandscapePhysics').length).toBeGreaterThan(0)
  })
  it('recovers the initial Starting response without a click and stops polling on unmount', async () => {
    getLinks.mockResolvedValueOnce(unavailable).mockResolvedValue(ready)
    const view = render(<Dashboard />)
    await act(async () => { await Promise.resolve() })
    expect(screen.getAllByText('VM state: Starting - start the VM first.')).toHaveLength(2)
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
    expect(screen.queryByText('VM state: Starting - start the VM first.')).toBeNull()
    expect(getLinks).toHaveBeenCalledTimes(2)
    expect(screen.getAllByRole('link', { name: /Open/ })).toHaveLength(2)
    view.unmount()
    await act(async () => { await vi.advanceTimersByTimeAsync(120_000) })
    expect(getLinks).toHaveBeenCalledTimes(2)
  })

  it('does not overlap a slow initial link request with polling', async () => {
    let resolveInitial!: (value: typeof ready) => void
    getLinks.mockImplementationOnce(() => new Promise(resolve => { resolveInitial = resolve })).mockResolvedValue(ready)
    render(<Dashboard />)
    await act(async () => { await vi.advanceTimersByTimeAsync(120_000) })
    expect(getLinks).toHaveBeenCalledTimes(1)
    await act(async () => { resolveInitial(ready); await Promise.resolve() })
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
    expect(getLinks).toHaveBeenCalledTimes(2)
  })
})
