import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  getDeepDesertMapSnapshot,
  type DeepDesertMapSnapshot,
  type MapFreshnessState,
} from '../../api/maps'
import { Icon } from '../../components/Icon'
import { DataState, FreshnessBadge } from '../../components/platform/DataState'
import { LiveMapPreviewDisclosure } from './LiveMapPreviewDisclosure'

export const MAP_LIVE_POLL_MS = 15_000
export const MAP_LIVE_POLL_JITTER = 0.1

export function getMapLivePollDelayMs(sample = Math.random()) {
  const bounded = Math.min(1, Math.max(0, sample))
  return Math.round(MAP_LIVE_POLL_MS * ((1 - MAP_LIVE_POLL_JITTER) + (2 * MAP_LIVE_POLL_JITTER * bounded)))
}

function formatTime(value: string | null | undefined) {
  if (!value) return 'Never'
  const parsed = new Date(value)
  return Number.isNaN(parsed.valueOf()) ? value : parsed.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

function freshnessLabel(state: MapFreshnessState, ageSeconds: number | null) {
  if (ageSeconds === null) return state === 'unavailable' ? 'Unavailable' : state
  return `${state[0].toUpperCase()}${state.slice(1)} · ${ageSeconds}s old`
}

export function MapLiveState() {
  const [snapshot, setSnapshot] = useState<DeepDesertMapSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const mountedRef = useRef(false)
  const requestGenerationRef = useRef(0)
  const inFlightRef = useRef<Promise<void> | null>(null)

  const load = useCallback(() => {
    if (inFlightRef.current) return inFlightRef.current

    const generation = ++requestGenerationRef.current
    if (mountedRef.current) setRefreshing(true)
    const request = getDeepDesertMapSnapshot()
      .then(next => {
        if (!mountedRef.current || generation !== requestGenerationRef.current) return
        setSnapshot(next)
        setError(null)
      })
      .catch(reason => {
        if (!mountedRef.current || generation !== requestGenerationRef.current) return
        setError(reason instanceof Error ? reason.message : String(reason))
      })
      .finally(() => {
        if (inFlightRef.current === request) inFlightRef.current = null
        if (mountedRef.current && generation === requestGenerationRef.current) {
          setRefreshing(false)
        }
      })
    inFlightRef.current = request
    return request
  }, [])

  useEffect(() => {
    mountedRef.current = true
    let cancelled = false
    let timer: number | undefined
    const tick = async () => {
      await load()
      if (!cancelled && mountedRef.current) {
        timer = window.setTimeout(() => { void tick() }, getMapLivePollDelayMs())
      }
    }
    void tick()
    return () => {
      cancelled = true
      mountedRef.current = false
      if (timer !== undefined) window.clearTimeout(timer)
    }
  }, [load])

  const active = snapshot?.data.layers[0]
  const publicPoi = snapshot?.data.layers[1]
  const activeData = active?.data
  const unresolvedCount = useMemo(
    () => activeData?.items.filter(item => item.position.status === 'unresolved').length ?? 0,
    [activeData],
  )

  if (!snapshot && !error) {
    return (
      <div className="flex min-w-0 flex-col gap-4">
        <LiveMapPreviewDisclosure />
        <DataState state="loading" title="Loading cached Deep Desert state…" />
      </div>
    )
  }
  if (!snapshot && error) {
    return (
      <div className="flex min-w-0 flex-col gap-4">
        <LiveMapPreviewDisclosure />
        <DataState state="error" title="Cached Maps API unavailable" message={error} />
      </div>
    )
  }
  if (!snapshot || !active || !activeData || !publicPoi) {
    return (
      <div className="flex min-w-0 flex-col gap-4">
        <LiveMapPreviewDisclosure />
        <DataState state="unavailable" title="Live State data is unavailable" />
      </div>
    )
  }

  const badgeState = refreshing ? 'refreshing' : active.freshness.state
  const summary = activeData.summary
  const source = snapshot.data.health.sources.find(item => item.sourceKey === 'maps.active-spice')

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <LiveMapPreviewDisclosure />
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-text">Deep Desert live state</h2>
          <p className="mt-1 text-sm text-text-muted">
            Cached read-only observations. Refreshing this view never queries the game database.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <FreshnessBadge
            state={badgeState}
            label={refreshing ? 'Reading cache' : freshnessLabel(active.freshness.state, active.freshness.ageSeconds)}
            observedAt={active.freshness.observedAt}
          />
          <button className="btn-secondary min-h-11" onClick={() => { void load() }} disabled={refreshing}>
            <Icon name="RefreshCw" size={14} className={refreshing ? 'animate-spin motion-reduce:animate-none' : undefined} />
            Refresh view
          </button>
        </div>
      </div>

      {error && (
        <DataState
          state="stale"
          title="Showing the last cached snapshot"
          message={`The latest cache read failed: ${error}`}
        />
      )}

      {active.freshness.state === 'unavailable' ? (
        <DataState
          state="unavailable"
          title="Active spice is unavailable"
          message={`No successful cached observation exists${active.error?.code ? ` (${active.error.code})` : ''}.`}
        />
      ) : (
        <>
          {active.freshness.state !== 'fresh' && (
            <DataState
              state={active.freshness.state}
              title={`${active.freshness.state === 'partial' ? 'Partial' : 'Stale'} active-spice snapshot`}
              message={active.error?.code
                ? `The last refresh reported ${active.error.code}; retained cached rows are shown.`
                : active.page.truncated
                  ? 'The source exceeded the bounded row limit; only the returned rows are shown.'
                  : undefined}
            />
          )}

          <dl className="card grid min-w-0 grid-cols-2 gap-x-5 gap-y-4 p-4 lg:grid-cols-4">
            <div className="min-w-0">
              <dt className="text-xs text-text-dim">Active fields</dt>
              <dd className="mt-1 font-semibold text-text">{summary.activeCount}</dd>
            </div>
            <div className="min-w-0">
              <dt className="text-xs text-text-dim">State</dt>
              <dd className="mt-1 break-words text-sm font-semibold text-text">{summary.state}</dd>
            </div>
            <div className="min-w-0">
              <dt className="text-xs text-text-dim">Tier</dt>
              <dd className="mt-1 text-sm font-semibold text-text">{summary.tier ?? 'Not exposed'}</dd>
            </div>
            <div className="min-w-0">
              <dt className="text-xs text-text-dim">Source</dt>
              <dd className="mt-1 break-words text-sm font-semibold text-text">
                {active.source} · {summary.spatialStatus}
              </dd>
            </div>
          </dl>

          {unresolvedCount > 0 && (
            <DataState
              state="partial"
              title="Spatial coordinates are unresolved"
              message={`${unresolvedCount} active field${unresolvedCount === 1 ? '' : 's'} are listed below, but no live marker is drawn because the source does not expose independently verified coordinates.`}
            />
          )}

          <section className="card min-w-0 p-4" aria-labelledby="active-spice-list-title">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h3 id="active-spice-list-title" className="font-semibold text-text">Active spice observations</h3>
                <p className="mt-1 text-xs text-text-dim">
                  Last source success {formatTime(source?.lastSuccessAt ?? active.freshness.observedAt)}
                </p>
              </div>
              {active.page.truncated && <span className="pill border-warning/40 text-warning">Truncated</span>}
            </div>
            {activeData.items.length === 0 ? (
              <p className="mt-4 text-sm text-text-muted">No active spice fields were present in the cached observation.</p>
            ) : (
              <ul className="mt-3 grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2 xl:grid-cols-3">
                {activeData.items.map(item => (
                  <li key={item.fieldId} className="min-w-0 rounded-lg border border-border bg-surface-2 p-3">
                    <div className="flex items-center justify-between gap-2">
                      <span className="truncate font-mono text-sm text-text">{item.fieldId}</span>
                      <span className="pill border-border text-text-muted">{item.state}</span>
                    </div>
                    <p className="mt-2 text-xs leading-relaxed text-text-dim">
                      {item.position.status === 'verified'
                        ? `${item.position.coordinateSystem}: ${item.position.x}, ${item.position.y}`
                        : 'Location unresolved — intentionally not plotted.'}
                    </p>
                    <p className="mt-1 text-xs text-text-dim">Observed {formatTime(item.observedAt)}</p>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <details className="card min-w-0 p-4">
            <summary className="min-h-11 cursor-pointer py-2 font-semibold text-text">
              Observation history ({activeData.history.length})
            </summary>
            <ul className="mt-2 max-h-72 space-y-2 overflow-y-auto">
              {activeData.history.map((item, index) => (
                <li
                  key={`${item.fieldId}-${item.observedAt}-${index}`}
                  className="flex min-w-0 flex-col gap-1 rounded-lg border border-border bg-surface-2 p-3 text-sm sm:flex-row sm:items-center sm:justify-between"
                >
                  <span className="truncate font-mono text-text">{item.fieldId}</span>
                  <span className="text-xs text-text-dim">{item.state} · {formatTime(item.observedAt)}</span>
                </li>
              ))}
            </ul>
          </details>
        </>
      )}

      <DataState
        state="unavailable"
        title="Public POI layer unavailable"
        message={`${publicPoi.error?.message ?? 'Privacy cannot be proven for the current marker schema.'} DST will not query or display this layer until explicit privacy and owner columns are available.`}
      />
    </div>
  )
}
