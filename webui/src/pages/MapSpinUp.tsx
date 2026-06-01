import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import { getMapSpinUp, setMapSpinUp, type SpinUpMap } from '../api/mapSpinUp'

export function MapSpinUp() {
  const [maps, setMaps] = useState<SpinUpMap[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getMapSpinUp()
      setMaps(r.maps ?? [])
    } catch (e) {
      setMaps(null)
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void refresh() }, [refresh])

  const onToggle = useCallback(async (m: SpinUpMap, next: boolean) => {
    setBusy(m.map); setMessage(null); setError(null)
    // optimistic
    setMaps(prev => prev?.map(x => x.map === m.map ? { ...x, enabled: next, minServers: next ? 1 : 0 } : x) ?? prev)
    try {
      const r = await setMapSpinUp(m.map, next)
      setMessage(r.message ?? (next ? `${m.label} spin-up enabled.` : `${m.label} spin-up disabled.`))
      if (!r.ok) setError(r.message ?? 'The change may not have applied.')
      await refresh()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
      await refresh()
    } finally {
      setBusy(null)
    }
  }, [refresh])

  const supported = (maps ?? []).filter(m => m.group === 'supported')
  const experimental = (maps ?? []).filter(m => m.group === 'experimental')

  return (
    <>
      <PageHeader
        title="Map SpinUp"
        icon="Power"
        description="Keep at least one server warm for a map (MinServers = 1). Hot-swappable — no restart needed."
        actions={
          <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading || busy !== null}>
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        }
      />

      {error && (
        <div className="card p-4 mb-4 border-danger/40">
          <p className="text-sm text-danger break-words">{error}</p>
        </div>
      )}
      {message && (
        <div className="card p-4 mb-4 border-accent/40">
          <p className="text-sm text-text">{message}</p>
        </div>
      )}

      {!maps ? (
        <div className="card p-6">
          <p className="text-sm text-text-dim italic">{loading ? 'Loading…' : 'No data yet.'}</p>
        </div>
      ) : (
        <>
          <MapGroup
            title="Supported"
            hint="These maps ship with native MinServers support — toggling is reliable."
            maps={supported}
            busy={busy}
            onToggle={onToggle}
          />

          {experimental.length > 0 && (
            <MapGroup
              title="Experimental"
              tone="warning"
              hint="These maps don't ship MinServers natively. Enabling may be ignored by the director, or it may keep an instance warm and consume RAM (~1+ GB each). Use with care."
              maps={experimental}
              busy={busy}
              onToggle={onToggle}
            />
          )}
        </>
      )}
    </>
  )
}

function MapGroup({ title, hint, tone = 'text', maps, busy, onToggle }: {
  title: string
  hint: string
  tone?: 'text' | 'warning'
  maps: SpinUpMap[]
  busy: string | null
  onToggle: (m: SpinUpMap, next: boolean) => void
}) {
  if (maps.length === 0) return null
  const headColor = tone === 'warning' ? 'text-warning' : 'text-text-muted'
  return (
    <section className="mb-6">
      <h2 className={`text-sm font-semibold uppercase tracking-wider mb-1 flex items-center gap-2 ${headColor}`}>
        {tone === 'warning' && <Icon name="AlertTriangle" size={14} className="text-warning" />}
        {title}
      </h2>
      <p className="text-xs text-text-dim mb-3 max-w-3xl">{hint}</p>
      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
        {maps.map(m => (
          <label
            key={m.map}
            className={`card p-4 flex items-center justify-between gap-3 cursor-pointer ${busy === m.map ? 'opacity-60' : ''}`}
          >
            <div className="min-w-0">
              <div className="text-sm font-semibold truncate">{m.label}</div>
              <div className="text-xs text-text-dim font-mono truncate">{m.map}</div>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <span className={m.enabled ? 'pill-success' : 'pill-muted'}>
                {m.enabled ? 'Warm' : 'Off'}
              </span>
              <input
                type="checkbox"
                className="h-4 w-4 accent-accent"
                checked={m.enabled}
                disabled={busy !== null}
                onChange={e => onToggle(m, e.target.checked)}
              />
            </div>
          </label>
        ))}
      </div>
    </section>
  )
}
