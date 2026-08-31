import React from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DeepDesertMapSnapshot } from '../src/api/maps'
import { getMapLivePollDelayMs, MapLiveState } from '../src/pages/workspaces/MapLiveState'

const { getDeepDesertMapSnapshot } = vi.hoisted(() => ({
  getDeepDesertMapSnapshot: vi.fn(),
}))

vi.mock('../src/api/maps', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/api/maps')>()
  return { ...actual, getDeepDesertMapSnapshot }
})

function fixture(state: 'fresh' | 'stale' | 'partial' | 'unavailable' = 'fresh'): DeepDesertMapSnapshot {
  const unavailable = state === 'unavailable'
  return {
    schemaVersion: 1,
    requestId: 'fixture',
    generatedAt: '2026-08-28T10:00:00Z',
    source: unavailable ? 'unavailable' : 'mixed',
    freshness: {
      observedAt: unavailable ? null : '2026-08-28T09:59:55Z',
      cachedAt: '2026-08-28T10:00:00Z',
      ageSeconds: unavailable ? null : 5,
      state: unavailable ? 'unavailable' : 'partial',
      lastErrorCode: unavailable ? 'source-read-failed' : null,
    },
    capabilities: ['map.view'],
    data: {
      map: {
        farmId: 'local-farm',
        mapId: 'deep-desert',
        partitionId: 'current',
        label: 'Deep Desert',
      },
      health: {
        cache: {
          available: !unavailable,
          revision: 2,
          generation: 'maps-fixture',
          hydratedAt: '2026-08-28T10:00:00Z',
          publishedAt: '2026-08-28T10:00:00Z',
          lastErrorCode: null,
        },
        sources: [{
          sourceKey: 'maps.active-spice',
          schemaFingerprint: 'a'.repeat(64),
          lastAttemptAt: '2026-08-28T10:00:00Z',
          lastSuccessAt: unavailable ? null : '2026-08-28T09:59:55Z',
          expiresAt: unavailable ? null : '2026-08-28T10:00:55Z',
          lastErrorCode: unavailable ? 'source-read-failed' : null,
        }],
      },
      layers: [
        {
          layerId: 'active-spice',
          source: unavailable ? 'unavailable' : 'cache',
          freshness: {
            observedAt: unavailable ? null : '2026-08-28T09:59:55Z',
            cachedAt: '2026-08-28T10:00:00Z',
            ageSeconds: unavailable ? null : 5,
            state,
            lastErrorCode: state === 'stale' ? 'source-read-failed' : null,
          },
          count: unavailable ? 0 : 1,
          page: { limit: 200, nextCursor: null, truncated: state === 'partial' },
          error: state === 'stale' ? { code: 'source-read-failed' } : null,
          data: {
            summary: {
              activeCount: unavailable ? 0 : 1,
              state: unavailable ? 'none-active' : 'active',
              tier: null,
              spatialStatus: 'unresolved',
              historyStatus: unavailable ? 'unavailable' : 'cached-observations',
            },
            items: unavailable ? [] : [{
              fieldId: '101',
              state: 'active',
              tier: null,
              observedAt: '2026-08-28T09:59:55Z',
              position: {
                status: 'unresolved',
                coordinateSystem: null,
                x: null,
                y: null,
                reason: 'No independently verified spatial coordinates are available.',
              },
            }],
            history: unavailable ? [] : [{
              fieldId: '101',
              state: 'active',
              observedAt: '2026-08-28T09:59:55Z',
            }],
          },
        },
        {
          layerId: 'public-poi',
          source: 'unavailable',
          freshness: {
            observedAt: null,
            cachedAt: '2026-08-28T10:00:00Z',
            ageSeconds: null,
            state: 'unavailable',
            lastErrorCode: 'privacy-proof-unavailable',
          },
          count: 0,
          page: { limit: 0, nextCursor: null, truncated: false },
          error: {
            code: 'privacy-proof-unavailable',
            message: 'The production schema cannot prove that private or owned markers are excluded.',
          },
          data: [],
        },
      ],
    },
  }
}

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.clearAllMocks()
})

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

describe('Maps live-state workspace', () => {
  it('distinguishes server-derived state from preview visualization while loading', () => {
    getDeepDesertMapSnapshot.mockReturnValue(new Promise(() => {}))
    render(<MapLiveState />)

    expect(screen.getByRole('complementary', { name: 'Live Map preview disclosure' }))
      .toHaveTextContent(/derived from your server.*not yet live game telemetry/i)
  })

  it('keeps the preview disclosure visible when loading fails', async () => {
    getDeepDesertMapSnapshot.mockRejectedValue(new Error('offline'))
    render(<MapLiveState />)

    expect(await screen.findByText('Cached Maps API unavailable')).toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Live Map preview disclosure' }))
      .toHaveTextContent(/derived from your server.*not yet live game telemetry/i)
  })

  it('renders cached active fields without inventing unresolved markers', async () => {
    getDeepDesertMapSnapshot.mockResolvedValue(fixture())
    render(<MapLiveState />)

    expect(await screen.findByText('Deep Desert live state')).toBeInTheDocument()
    expect(screen.getAllByText('101')).toHaveLength(2)
    expect(screen.getByText('Location unresolved — intentionally not plotted.')).toBeInTheDocument()
    expect(screen.getByText('Public POI layer unavailable')).toBeInTheDocument()
    expect(screen.queryByRole('img', { name: /active spice/i })).not.toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Live Map preview disclosure' }))
      .toHaveTextContent(/derived from your server.*not yet live game telemetry/i)
  })

  it.each(['stale', 'partial', 'unavailable'] as const)('presents the %s source state explicitly', async state => {
    getDeepDesertMapSnapshot.mockResolvedValue(fixture(state))
    render(<MapLiveState />)

    if (state === 'unavailable') {
      expect(await screen.findByText('Active spice is unavailable')).toBeInTheDocument()
    } else {
      expect(await screen.findByText(`${state === 'partial' ? 'Partial' : 'Stale'} active-spice snapshot`)).toBeInTheDocument()
    }
  })

  it('keeps cache refresh touch-sized and performs only the cached GET again', async () => {
    const user = userEvent.setup()
    getDeepDesertMapSnapshot.mockResolvedValue(fixture())
    render(<MapLiveState />)

    const refresh = await screen.findByRole('button', { name: 'Refresh view' })
    expect(refresh).toHaveClass('min-h-11')
    await user.click(refresh)
    await waitFor(() => expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(2))
  })

  it('bounds the cached API poll around the accepted 15 second cadence', () => {
    expect(getMapLivePollDelayMs(0)).toBe(13_500)
    expect(getMapLivePollDelayMs(0.5)).toBe(15_000)
    expect(getMapLivePollDelayMs(1)).toBe(16_500)
  })

  it('coalesces a scheduled refresh with an in-flight manual refresh', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0.5)
    const manual = deferred<DeepDesertMapSnapshot>()
    getDeepDesertMapSnapshot
      .mockResolvedValueOnce(fixture())
      .mockReturnValueOnce(manual.promise)
      .mockResolvedValue(fixture('stale'))

    render(<MapLiveState />)
    await act(async () => {})
    expect(screen.getByText('Deep Desert live state')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Refresh view' }))
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(2)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000)
    })
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(2)

    await act(async () => {
      manual.resolve(fixture('partial'))
      await manual.promise
    })
    expect(screen.getByText('Partial active-spice snapshot')).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000)
    })
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(3)
    expect(screen.getByText('Stale active-spice snapshot')).toBeInTheDocument()
  })

  it('ignores an in-flight completion and schedules no further refresh after unmount', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0.5)
    const initial = deferred<DeepDesertMapSnapshot>()
    getDeepDesertMapSnapshot.mockReturnValue(initial.promise)

    const view = render(<MapLiveState />)
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledOnce()
    view.unmount()

    await act(async () => {
      initial.resolve(fixture())
      await initial.promise
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledOnce()
  })

  it('keeps one cadence timer through StrictMode effect replay and clears it on unmount', async () => {
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0.5)
    const initial = deferred<DeepDesertMapSnapshot>()
    getDeepDesertMapSnapshot
      .mockReturnValueOnce(initial.promise)
      .mockResolvedValue(fixture())

    const view = render(
      <React.StrictMode>
        <MapLiveState />
      </React.StrictMode>,
    )
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledOnce()

    await act(async () => {
      initial.resolve(fixture())
      await initial.promise
    })
    expect(vi.getTimerCount()).toBe(1)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(15_000)
    })
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(2)
    expect(vi.getTimerCount()).toBe(1)

    view.unmount()
    expect(vi.getTimerCount()).toBe(0)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(getDeepDesertMapSnapshot).toHaveBeenCalledTimes(2)
  })
})
