import { act, cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Dashboard } from '../src/pages/Dashboard'

const getLinks = vi.hoisted(() => vi.fn())
vi.mock('../src/api/links', () => ({ getLinks }))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({ status: null, loading: false }) }))
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

beforeEach(() => { vi.useFakeTimers(); getLinks.mockReset(); localStorage.clear() })
afterEach(() => { cleanup(); vi.useRealTimers() })

describe('dashboard web interfaces after VM startup', () => {
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
