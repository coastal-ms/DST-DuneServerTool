import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getDeepDesertPvp, saveDeepDesertPvp } from '../../api/gameconfig'
import type { DeepDesertPvpState } from '../../api/types'

type Props = { vmRunning: boolean }

export function DeepDesertPvpCard({ vmRunning }: Props) {
  const [state, setState] = useState<DeepDesertPvpState | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [dirty, setDirty] = useState(false)
  const dirtyRef = useRef(false)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const seed = useCallback((next: DeepDesertPvpState) => {
    setState(next)
    setEnabled(next.enabled)
    setSelected(new Set(next.instances.filter(x => x.pvpEnabled).map(x => x.partitionId)))
    setDirty(false)
    dirtyRef.current = false
  }, [])

  const load = useCallback(async (silent = false) => {
    if (!vmRunning) return
    if (!silent) { setLoading(true); setErr(null) }
    try {
      const next = await getDeepDesertPvp()
      if (!silent || !dirtyRef.current) seed(next)
    } catch (e) {
      if (!silent) setErr(e instanceof Error ? e.message : String(e))
    } finally {
      if (!silent) setLoading(false)
    }
  }, [vmRunning, seed])

  useEffect(() => { void load() }, [load])
  useEffect(() => {
    if (!vmRunning) return
    const timer = window.setInterval(() => { void load(true) }, 15000)
    return () => window.clearInterval(timer)
  }, [vmRunning, load])

  const sorted = useMemo(
    () => [...(state?.instances ?? [])].sort((a, b) => a.partitionId - b.partitionId),
    [state],
  )

  function toggleMaster(next: boolean) {
    setEnabled(next)
    if (!next) setSelected(new Set())
    setDirty(true)
    dirtyRef.current = true
    setOk(null)
  }

  function togglePartition(id: number, next: boolean) {
    setSelected(prev => {
      const out = new Set(prev)
      if (next) out.add(id)
      else out.delete(id)
      return out
    })
    setDirty(true)
    dirtyRef.current = true
    setOk(null)
  }

  async function apply() {
    if (enabled && selected.size === 0) {
      setErr('Select at least one running Deep Desert partition for PvP.')
      return
    }
    setSaving(true); setErr(null); setOk(null)
    try {
      const next = await saveDeepDesertPvp(enabled, [...selected])
      seed(next)
      if (next.restart && !next.restart.ok) {
        setErr(`PvP settings saved, but the Deep Desert restart failed: ${next.restart.message ?? 'unknown restart error'}`)
      } else {
        setOk(next.message ?? 'Deep Desert PvP saved. Running instances are restarting.')
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card p-5">
      <div className="flex items-center justify-between gap-3 mb-3">
        <div>
          <h2 className="text-sm font-semibold uppercase tracking-wider text-danger flex items-center gap-2">
            <Icon name="Swords" size={14} /> Deep Desert PvP
          </h2>
          <p className="text-xs text-text-muted mt-1">
            Enable PvP only for currently running <code>DeepDesert_1</code> partitions.
          </p>
        </div>
        <button type="button" className="btn-secondary" disabled={!vmRunning || loading || saving}
                onClick={() => void load()}>
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14}
                className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      {err && <div className="mb-3 px-3 py-2 rounded border border-danger/40 bg-danger/10 text-danger text-xs">{err}</div>}
      {ok && <div className="mb-3 px-3 py-2 rounded border border-success/40 bg-success/10 text-success text-xs">{ok}</div>}
      {state?.forceAll && (
        <div className="mb-3 px-3 py-2 rounded border border-warning/40 bg-warning/10 text-warning text-xs">
          Global “PvP on all partitions” is currently enabled. Applying this card disables that global override and uses only selected Deep Desert partitions.
        </div>
      )}

      {!vmRunning ? (
        <div className="text-xs text-warning">Start the VM and spin up Deep Desert to configure partition PvP.</div>
      ) : loading && !state ? (
        <div className="text-xs text-text-muted flex items-center gap-2">
          <Icon name="Loader2" size={13} className="animate-spin" /> Loading running instances…
        </div>
      ) : sorted.length === 0 ? (
        <div className="text-xs text-text-muted">
          No running Deep Desert instances found. Spin up <code>DeepDesert_1</code>, then refresh.
        </div>
      ) : (
        <>
          <label className="flex items-center gap-2 text-sm mb-3 cursor-pointer">
            <input type="checkbox" checked={enabled} disabled={saving}
                   onChange={e => toggleMaster(e.target.checked)} className="accent-ibad" />
            <span className="font-medium text-text">Configure PvP by running partition</span>
          </label>

          {enabled && (
            <div className="space-y-2 mb-4">
              {sorted.map(row => (
                <label key={row.partitionId}
                       className="flex items-center justify-between gap-3 rounded-lg border border-border bg-surface-2/40 px-3 py-2 cursor-pointer">
                  <div className="min-w-0">
                    <div className="text-sm text-text truncate">{row.serverDisplayName}</div>
                    <div className="text-[11px] font-mono text-text-dim">
                      {row.map} • partition {row.partitionId} • dimension {row.dimension}
                      {row.gamePort > 0 ? ` • UDP ${row.gamePort}` : ''} • {row.ready ? 'Ready' : row.phase}
                    </div>
                  </div>
                  <span className="flex items-center gap-2 text-xs">
                    <input type="checkbox" checked={selected.has(row.partitionId)} disabled={saving}
                           onChange={e => togglePartition(row.partitionId, e.target.checked)}
                           className="accent-ibad" />
                    PvP
                  </span>
                </label>
              ))}
            </div>
          )}

          {state && state.inactiveSelectedPartitionIds.length > 0 && (
            <div className="mb-3 text-[11px] text-text-dim">
              Previously selected spun-down partition(s) {state.inactiveSelectedPartitionIds.join(', ')} are preserved.
            </div>
          )}
          {state && state.staleSelectedPartitionIds.length > 0 && (
            <div className="mb-3 text-[11px] text-warning">
              Stale non-Deep-Desert partition selection(s) {state.staleSelectedPartitionIds.join(', ')} will be removed on Apply.
            </div>
          )}

          <div className="flex justify-end">
            <button type="button" className="btn-primary" disabled={!dirty || saving}
                    onClick={() => void apply()}>
              <Icon name={saving ? 'Loader2' : 'Save'} size={14}
                    className={saving ? 'animate-spin' : ''} />
              {saving ? 'Applying…' : 'Apply & restart Deep Desert'}
            </button>
          </div>
        </>
      )}
    </div>
  )
}
