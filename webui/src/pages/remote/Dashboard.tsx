import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getRemoteStatus,
  getRemoteBackups,
  RemoteApiError,
  type RemoteStatusResponse,
  type RemoteBackupsResponse,
} from '../../api/remote'

// Mobile-first dashboard: VM state, battlegroup state, public IP,
// port-forward summary, last 3 backups. Read-only — every interaction
// lives on the Maps tab so this view is safe for owner OR admin.

function formatAge(min: number | null): string {
  if (min === null || min === undefined) return '—'
  if (min < 1)   return 'just now'
  if (min < 60)  return `${min}m ago`
  if (min < 1440) {
    const h = Math.floor(min / 60)
    const m = min % 60
    return m === 0 ? `${h}h ago` : `${h}h ${m}m ago`
  }
  const d = Math.floor(min / 1440)
  return `${d}d ago`
}

function formatBytes(n: number): string {
  if (!n || n < 0) return '—'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = n
  let i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return `${v.toFixed(v >= 100 ? 0 : 1)} ${units[i]}`
}

export function RemoteDashboard() {
  const [status, setStatus] = useState<RemoteStatusResponse | null>(null)
  const [backups, setBackups] = useState<RemoteBackupsResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async (showSpinner: boolean) => {
    if (showSpinner) setLoading(true); else setRefreshing(true)
    setError(null)
    try {
      const [s, b] = await Promise.allSettled([getRemoteStatus(), getRemoteBackups()])
      if (s.status === 'fulfilled') setStatus(s.value)
      else if (s.reason instanceof RemoteApiError && s.reason.status === 401) {
        window.location.href = '/remote/login-required'; return
      } else setError(s.reason instanceof Error ? s.reason.message : String(s.reason))
      if (b.status === 'fulfilled') setBackups(b.value)
      // Backups failing is non-fatal — VM may be down. Show what we have.
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false); setRefreshing(false)
    }
  }, [])

  useEffect(() => { void load(true) }, [load])

  // Auto-refresh every 30 s while the page is visible. Cheap because the
  // backend caches port-status results for 5 minutes.
  useEffect(() => {
    const id = window.setInterval(() => {
      if (document.visibilityState === 'visible') void load(false)
    }, 30_000)
    return () => window.clearInterval(id)
  }, [load])

  if (loading && !status) {
    return (
      <div className="flex items-center justify-center py-16 text-text-muted">
        <Icon name="Loader2" size={20} className="animate-spin mr-2" />
        Loading…
      </div>
    )
  }

  const vmRunning = status?.vm?.running === true
  const vmState = status?.vm?.state ?? (status?.vm?.exists ? 'unknown' : 'no VM')

  return (
    <div className="space-y-4">
      {error && (
        <div className="card border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger flex items-start gap-2">
          <Icon name="AlertTriangle" size={16} className="mt-0.5 flex-none" />
          <div>{error}</div>
        </div>
      )}

      <div className="card p-4">
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center gap-2">
            <Icon name="Server" size={18} className="text-text-muted" />
            <h2 className="font-semibold">VM</h2>
          </div>
          {vmRunning
            ? <span className="pill-success">running</span>
            : <span className="pill-danger">{vmState}</span>}
        </div>
        <dl className="grid grid-cols-[8rem,1fr] gap-y-1 text-sm">
          <dt className="text-text-muted">Internal IP</dt>
          <dd className="font-mono">{status?.vm?.ip ?? '—'}</dd>
          <dt className="text-text-muted">Public IP</dt>
          <dd className="font-mono">{status?.publicIp ?? '—'}</dd>
        </dl>
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center gap-2">
            <Icon name="Activity" size={18} className="text-text-muted" />
            <h2 className="font-semibold">Battlegroup</h2>
          </div>
          {status?.bg
            ? <span className="pill-success">available</span>
            : <span className="pill-muted">offline</span>}
        </div>
        {status?.bg
          ? <div className="text-sm text-text-muted">Battlegroup snapshot OK. See desktop portal for full per-set detail.</div>
          : <div className="text-sm text-text-muted">VM is not running or the operator hasn&apos;t reported in yet.</div>}
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center gap-2">
            <Icon name="Globe" size={18} className="text-text-muted" />
            <h2 className="font-semibold">Ports</h2>
          </div>
        </div>
        {status?.ports?.results?.length
          ? (
            <ul className="space-y-1.5 text-sm">
              {status.ports.results.map(p => (
                <li key={`${p.port}-${p.protocol}`} className="flex items-center justify-between">
                  <span className="font-mono">{p.protocol} {p.port}</span>
                  <span className="text-text-muted">{p.label}</span>
                  {p.status === 'open'      && <span className="pill-success">open</span>}
                  {p.status === 'closed'    && <span className="pill-danger">closed</span>}
                  {p.status === 'udp-skip'  && <span className="pill-muted">UDP — skipped</span>}
                  {p.status === 'unknown'   && <span className="pill-muted">unknown</span>}
                  {p.status === 'ratelimit' && <span className="pill-warning">rate-limited</span>}
                </li>
              ))}
            </ul>
          )
          : <div className="text-sm text-text-muted">Port check disabled or unavailable.</div>}
      </div>

      <div className="card p-4">
        <div className="flex items-center justify-between mb-3">
          <div className="flex items-center gap-2">
            <Icon name="HardDrive" size={18} className="text-text-muted" />
            <h2 className="font-semibold">Recent backups</h2>
          </div>
          {backups?.dumpDirSize ? <span className="pill-muted">{backups.dumpDirSize}</span> : null}
        </div>
        {backups?.recent?.length
          ? (
            <ul className="space-y-2 text-sm">
              {backups.recent.map(b => (
                <li key={b.path} className="flex items-center justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="truncate font-mono text-xs">{b.name}</div>
                    <div className="text-text-muted text-xs">{formatBytes(b.sizeBytes)}</div>
                  </div>
                  <div className="text-text-muted text-xs whitespace-nowrap">{formatAge(b.ageMinutes)}</div>
                </li>
              ))}
            </ul>
          )
          : <div className="text-sm text-text-muted">No backups visible (VM offline or none taken yet).</div>}
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

      <div className="text-center text-xs text-text-dim pt-2">
        {status?.email ? <>signed in as <span className="font-mono">{status.email}</span> ({status.role})</> : null}
      </div>
    </div>
  )
}
