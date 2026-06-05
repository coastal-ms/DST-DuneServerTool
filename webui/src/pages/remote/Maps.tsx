import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getRemoteMaps,
  spinUpMap,
  spinDownMap,
  fixPartitions,
  RemoteApiError,
  type RemoteMapEntry,
  type RemoteMapsResponse,
} from '../../api/remote'

// Mobile-first map control surface (issue #74).
//
// One card per on-demand map. Each card shows running/ready state and offers
// "Spin up" / "Spin down" buttons. A "Fix partitions" button at the bottom
// re-runs the remote partition cleanup helper (idempotent, safe to retry).
//
// Spin-down without -Force: when players are connected the server returns 409
// with the count; we surface that as a friendly "N players online — try later"
// message. Player-kick is intentionally NOT exposed in v11.1.0 (issue #74's
// deferred list).

interface ActionState {
  busy: 'spin-up' | 'spin-down' | 'fix' | null
  message: string | null
  isError: boolean
}

function statusPill(m: RemoteMapEntry) {
  if (!m.ok) return <span className="pill-muted">offline</span>
  if (m.running) return <span className="pill-success">running</span>
  if (m.hasDisabledPart || m.missingPartitionBinding || m.stuckDedicatedScaling) return <span className="pill-warning">needs fix</span>
  if (m.present) return <span className="pill-muted">stopped</span>
  return <span className="pill-muted">not configured</span>
}

export function RemoteMaps() {
  const [data, setData] = useState<RemoteMapsResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [actions, setActions] = useState<Record<string, ActionState>>({})
  const [globalAction, setGlobalAction] = useState<ActionState>({ busy: null, message: null, isError: false })

  const load = useCallback(async (showSpinner: boolean) => {
    if (showSpinner) setLoading(true); else setRefreshing(true)
    setError(null)
    try {
      const r = await getRemoteMaps()
      setData(r)
    } catch (e) {
      if (e instanceof RemoteApiError && e.status === 401) {
        window.location.href = '/remote/login-required'; return
      }
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false); setRefreshing(false)
    }
  }, [])

  useEffect(() => { void load(true) }, [load])

  // Refresh after every successful write so the user sees the new state.
  const refreshSilently = useCallback(() => { void load(false) }, [load])

  const setMapAction = (key: string, s: ActionState) =>
    setActions(prev => ({ ...prev, [key]: s }))

  const onSpinUp = async (key: string) => {
    setMapAction(key, { busy: 'spin-up', message: null, isError: false })
    try {
      const r = await spinUpMap(key)
      setMapAction(key, { busy: null, message: r.message ?? 'Spin-up scheduled.', isError: !r.ok })
      refreshSilently()
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      setMapAction(key, { busy: null, message: msg, isError: true })
    }
  }

  const onSpinDown = async (key: string) => {
    if (!window.confirm('Spin this map down? Any active session will end.')) return
    setMapAction(key, { busy: 'spin-down', message: null, isError: false })
    try {
      const r = await spinDownMap(key)
      setMapAction(key, { busy: null, message: r.message ?? 'Spin-down complete.', isError: !r.ok })
      refreshSilently()
    } catch (e) {
      if (e instanceof RemoteApiError && e.status === 409) {
        const body = e.body as { playersOnline?: number; message?: string } | undefined
        const count = body?.playersOnline ?? 0
        setMapAction(key, {
          busy: null,
          isError: true,
          message: `${count} player${count === 1 ? '' : 's'} online — try again later (player-kick lives in the desktop portal).`,
        })
        refreshSilently()
        return
      }
      setMapAction(key, { busy: null, message: e instanceof Error ? e.message : String(e), isError: true })
    }
  }

  const onFixPartitions = async () => {
    if (!window.confirm('Re-run the partition-cleanup helper on the VM?\n\nIdempotent — skips any map with a running pod.')) return
    setGlobalAction({ busy: 'fix', message: null, isError: false })
    try {
      const r = await fixPartitions()
      setGlobalAction({ busy: null, message: r.message ?? 'Partition cleanup ran.', isError: !r.ok })
      refreshSilently()
    } catch (e) {
      setGlobalAction({ busy: null, message: e instanceof Error ? e.message : String(e), isError: true })
    }
  }

  if (loading && !data) {
    return (
      <div className="flex items-center justify-center py-16 text-text-muted">
        <Icon name="Loader2" size={20} className="animate-spin mr-2" />
        Loading…
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {error && (
        <div className="card border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger flex items-start gap-2">
          <Icon name="AlertTriangle" size={16} className="mt-0.5 flex-none" />
          <div>{error}</div>
        </div>
      )}

      {data?.maps.map(m => {
        const a = actions[m.key] ?? { busy: null, message: null, isError: false }
        const busy = a.busy !== null
        return (
          <div key={m.key} className="card p-4">
            <div className="flex items-center justify-between mb-3">
              <div className="flex items-center gap-2">
                <Icon name="Map" size={18} className="text-text-muted" />
                <h2 className="font-semibold">{m.label}</h2>
              </div>
              {statusPill(m)}
            </div>

            <dl className="grid grid-cols-[8rem,1fr] gap-y-1 text-sm mb-3">
              <dt className="text-text-muted">Replicas</dt>
              <dd className="font-mono">{m.totalReplicas}</dd>
              <dt className="text-text-muted">Players online</dt>
              <dd className="font-mono">{m.playersOnline ?? '—'}</dd>
            </dl>

            {(m.hasDisabledPart || m.missingPartitionBinding || m.stuckDedicatedScaling) && (
              <div className="text-xs text-warning bg-warning/10 border border-warning/30 rounded-lg px-3 py-2 mb-3">
                Partition state drifted — use &ldquo;Fix partitions&rdquo; below.
              </div>
            )}

            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                onClick={() => { void onSpinUp(m.key) }}
                disabled={busy || !m.ok || m.running}
                className="btn-primary justify-center h-12"
              >
                <Icon name={a.busy === 'spin-up' ? 'Loader2' : 'Power'} size={18} className={a.busy === 'spin-up' ? 'animate-spin' : ''} />
                Spin up
              </button>
              <button
                type="button"
                onClick={() => { void onSpinDown(m.key) }}
                disabled={busy || !m.ok || !m.running}
                className="btn-secondary justify-center h-12"
              >
                <Icon name={a.busy === 'spin-down' ? 'Loader2' : 'PowerOff'} size={18} className={a.busy === 'spin-down' ? 'animate-spin' : ''} />
                Spin down
              </button>
            </div>

            {m.error && (
              <div className="text-xs text-text-muted mt-2">{m.error}</div>
            )}

            {a.message && (
              <div className={'text-xs mt-2 ' + (a.isError ? 'text-danger' : 'text-text-muted')}>
                {a.message}
              </div>
            )}
          </div>
        )
      })}

      <div className="card p-4 border-border-bright">
        <div className="flex items-center gap-2 mb-2">
          <Icon name="Wrench" size={18} className="text-text-muted" />
          <h2 className="font-semibold">Fix partitions</h2>
        </div>
        <p className="text-sm text-text-muted mb-3">
          Re-runs the remote cleanup helper if a map refuses to launch. Idempotent
          and skips any map whose pod is already running, so it&apos;s always safe.
        </p>
        <button
          type="button"
          onClick={() => { void onFixPartitions() }}
          disabled={globalAction.busy === 'fix'}
          className="btn-primary w-full justify-center h-12"
        >
          <Icon
            name={globalAction.busy === 'fix' ? 'Loader2' : 'Wrench'}
            size={18}
            className={globalAction.busy === 'fix' ? 'animate-spin' : ''}
          />
          {globalAction.busy === 'fix' ? 'Running…' : 'Run partition cleanup'}
        </button>
        {globalAction.message && (
          <div className={'text-xs mt-2 ' + (globalAction.isError ? 'text-danger' : 'text-text-muted')}>
            {globalAction.message}
          </div>
        )}
      </div>

      <button
        type="button"
        onClick={() => { void load(false) }}
        disabled={refreshing}
        className="btn-secondary w-full justify-center"
      >
        <Icon name={refreshing ? 'Loader2' : 'RefreshCw'} size={16} className={refreshing ? 'animate-spin' : ''} />
        {refreshing ? 'Refreshing…' : 'Refresh now'}
      </button>
    </div>
  )
}
