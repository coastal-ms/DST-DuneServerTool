import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getMapState, startMap, stopMap, type MapState, type MapStopResult } from '../../api/maps'
import { ApiError } from '../../api/client'

interface MapPodCardProps {
  mapKey: string
  label: string
  icon?: string
  bgReady: boolean
}

export function MapPodCard({ mapKey, label, icon = 'Mountain', bgReady }: MapPodCardProps) {
  const [state, setState] = useState<MapState | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    if (!bgReady) { setState(null); setError(null); return }
    setLoading(true); setError(null)
    try {
      const s = await getMapState(mapKey)
      setState(s)
    } catch (e) {
      setState(null)
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [bgReady, mapKey])

  useEffect(() => { void refresh() }, [refresh])

  const start = useCallback(async () => {
    setBusy(true); setMessage(null); setError(null)
    try {
      const r = await startMap(mapKey)
      setMessage(r.message ?? (r.ok ? `${label} is starting.` : 'Start request finished.'))
      setTimeout(() => { void refresh() }, 2000)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }, [mapKey, label, refresh])

  const stop = useCallback(async (force = false) => {
    setBusy(true); setMessage(null); setError(null)
    try {
      const r = await stopMap(mapKey, force)
      setMessage(r.message ?? (r.ok ? `${label} is shutting down.` : 'Stop request finished.'))
      setTimeout(() => { void refresh() }, 2000)
    } catch (e) {
      if (e instanceof ApiError && e.status === 409) {
        const body = e.body as MapStopResult | undefined
        const n = body?.playersOnline ?? 0
        const ok = window.confirm(
          `${n} player${n === 1 ? '' : 's'} currently connected to ${label}.\n\n`
          + `Force shutdown anyway? They will be disconnected.`,
        )
        if (ok) {
          setBusy(false)
          return stop(true)
        }
        setMessage('Shutdown cancelled — players still online.')
      } else {
        setError(e instanceof ApiError ? e.message : String(e))
      }
    } finally {
      setBusy(false)
    }
  }, [mapKey, label, refresh])

  return (
    <div className="card p-5">
      <div className="flex items-center justify-between mb-3 gap-3 flex-wrap">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2 min-w-0">
          <Icon name={icon} size={14} className="text-accent shrink-0" />
          <span className="truncate">{label}</span>
        </h2>
        <div className="flex items-center gap-2 shrink-0">
          {state && (
            <span className={state.running ? 'pill-success' : state.present ? 'pill-muted' : 'pill-warning'}>
              <Icon name={state.running ? 'CheckCircle2' : state.present ? 'CircleDashed' : 'AlertTriangle'} size={10} />
              {state.running ? 'Running' : state.present ? 'Stopped' : 'Not in CRD'}
            </span>
          )}
          <button
            className="btn-secondary"
            onClick={() => { void refresh() }}
            disabled={!bgReady || loading || busy}
            title={!bgReady ? 'Battlegroup must be running' : 'Refresh status'}
          >
            <Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} />
          </button>
          <button
            className="btn-primary whitespace-nowrap"
            onClick={() => { void start() }}
            disabled={!bgReady || busy || loading || (state?.running ?? false)}
            title={
              !bgReady ? 'Battlegroup must be running'
                : state?.running ? `${label} is already running`
                : `Spin up the ${label} map pod`
            }
          >
            <Icon name={busy ? 'Loader2' : 'Play'} size={14} className={busy ? 'animate-spin' : ''} />
            {busy ? 'Working…' : 'Spin up'}
          </button>
          <button
            className="btn-secondary whitespace-nowrap"
            onClick={() => { void stop(false) }}
            disabled={!bgReady || busy || loading || !(state?.running ?? false)}
            title={
              !bgReady ? 'Battlegroup must be running'
                : !state?.running ? `${label} is already stopped`
                : (state?.playersOnline ?? 0) > 0 ? `${state?.playersOnline} player(s) online — will require confirmation`
                : `Gracefully shut down the ${label} map pod`
            }
          >
            <Icon name="Power" size={14} />
            Shut down
          </button>
        </div>
      </div>

      {!bgReady ? (
        <p className="text-sm text-text-dim italic">
          Battlegroup must be running to manage on-demand map pods.
        </p>
      ) : error ? (
        <p className="text-sm text-danger break-words">{error}</p>
      ) : !state ? (
        <p className="text-sm text-text-dim italic">Loading…</p>
      ) : (
        <div className="space-y-2 text-sm">
          <dl className="grid grid-cols-[160px_1fr] gap-y-1">
            <dt className="text-text-dim">Sets in CRD</dt>
            <dd className="font-mono">{state.setCount}</dd>
            <dt className="text-text-dim">Total replicas</dt>
            <dd className="font-mono">{state.totalReplicas}</dd>
            {state.running && (
              <>
                <dt className="text-text-dim">Players online</dt>
                <dd className={(state.playersOnline ?? 0) > 0 ? 'font-mono text-warning' : 'font-mono'}>
                  {state.playersOnline === null || state.playersOnline === undefined
                    ? <span className="text-text-dim italic">unknown</span>
                    : state.playersOnline}
                  {state.playerIds && state.playerIds.length > 0 && (
                    <span className="text-text-dim ml-2">({state.playerIds.join(', ')})</span>
                  )}
                </dd>
              </>
            )}
            {state.hasDisabledPart && (
              <>
                <dt className="text-text-dim">Partitions disabled</dt>
                <dd className="text-warning">Yes — will be re-enabled on spin-up</dd>
              </>
            )}
          </dl>
          {state.sets.length > 0 && (
            <ul className="text-xs text-text-dim font-mono space-y-0.5">
              {state.sets.map(s => (
                <li key={s.idx}>
                  set[{s.idx}] {s.map} · replicas={s.replicas ?? '(unset)'} · partitions={s.partitionCount}
                  {s.dedicatedScaling ? ' · dedicated' : ''}
                </li>
              ))}
            </ul>
          )}
          {message && (
            <p className="text-xs text-text-muted border-l-2 border-accent pl-2 mt-2">{message}</p>
          )}
        </div>
      )}
    </div>
  )
}
