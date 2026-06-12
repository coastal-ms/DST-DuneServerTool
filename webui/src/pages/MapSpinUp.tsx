import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import { getMapSpinUp, setMapSpinUp, type SpinUpMap } from '../api/mapSpinUp'
import { fixOnDemandPartitions } from '../api/maps'

export function MapSpinUp() {
  const [maps, setMaps] = useState<SpinUpMap[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [fixBusy, setFixBusy] = useState(false)
  const [fixLog, setFixLog] = useState<string | null>(null)

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

  const onFixPartitions = useCallback(async () => {
    const ok = window.confirm(
      'Clear stuck partition pins on the on-demand maps (Deep Desert, Arrakeen, '
      + 'Harko Village) so the director can re-assign partitions and spin them up '
      + 'on demand?\n\n'
      + 'Safety:\n'
      + '• Only those 3 maps are touched. Overmap and Survival_1 are never affected.\n'
      + '• Any map with a running pod is skipped — no live session will be disturbed.\n'
      + '• Partitions are re-assigned by the director on next spawn.\n\n'
      + 'Use this when a map refuses to launch after a reboot or BG restart.',
    )
    if (!ok) return
    setFixBusy(true); setMessage(null); setError(null); setFixLog(null)
    try {
      const r = await fixOnDemandPartitions()
      setMessage(r.message ?? 'Partition cleanup ran.')
      const tail = (r.logTail && r.logTail.trim().length > 0) ? r.logTail : (r.output ?? '')
      setFixLog(tail || null)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setFixBusy(false)
    }
  }, [])

  const allMaps = maps ?? []

  return (
    <>
      <PageHeader
        title="Map SpinUp"
        icon="Power"
        description="Keep at least one server warm for a map (MinServers = 1). Hot-swappable — no restart needed."
        actions={
          <>
            <button
              className="btn-secondary"
              onClick={() => { void onFixPartitions() }}
              disabled={loading || busy !== null || fixBusy}
              title="Clear stuck igwsss.spec.partitions pins on Deep Desert / Arrakeen / Harko Village. Safe — only touches those 3 maps, skips any with a running pod, and never touches Overmap or Survival_1."
            >
              <Icon name={fixBusy ? 'Loader2' : 'Wrench'} size={15} className={fixBusy ? 'animate-spin' : ''} />
              {fixBusy ? 'Fixing…' : 'Fix partitions'}
            </button>
            <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading || busy !== null || fixBusy}>
              <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
            </button>
          </>
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
          {fixLog && (
            <pre className="mt-3 text-[11px] leading-snug text-text-dim font-mono whitespace-pre-wrap break-words max-h-60 overflow-auto border-t border-border/40 pt-2">
              {fixLog}
            </pre>
          )}
        </div>
      )}

      {!maps ? (
        <div className="card p-6">
          <p className="text-sm text-text-dim italic">{loading ? 'Loading…' : 'No data yet.'}</p>
        </div>
      ) : (
        <>
          <MapGroup
            title="Maps"
            hint="These keep at least one server warm (MinServers = 1). Some maps don't ship MinServers natively — enabling those may be ignored by the director, or may keep an instance warm and consume RAM (~1+ GB each). Use with care."
            maps={allMaps}
            busy={busy}
            onToggle={onToggle}
          />
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
