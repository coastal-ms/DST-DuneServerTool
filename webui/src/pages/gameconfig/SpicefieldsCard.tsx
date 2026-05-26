// SpicefieldsCard — editor for dune.spicefield_types.
// Live read/write directly against the live BG Postgres pod over SSH.
// Disabled when the VM is not running.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getSpicefields, saveSpicefield } from '../../api/gameconfig'
import type { SpicefieldType } from '../../api/types'

type RowDraft = {
  maxActive: string
  maxPrimed: string
  spawnWeight: string
  isSpawningActive: boolean
}

type Props = {
  vmRunning: boolean
}

export function SpicefieldsCard({ vmRunning }: Props) {
  const [rows, setRows] = useState<SpicefieldType[] | null>(null)
  const [drafts, setDrafts] = useState<Record<number, RowDraft>>({})
  const [loading, setLoading] = useState(false)
  const [savingId, setSavingId] = useState<number | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const seed = useCallback((list: SpicefieldType[]) => {
    const next: Record<number, RowDraft> = {}
    for (const r of list) {
      next[r.spicefieldTypeId] = {
        maxActive:        String(r.maxActive),
        maxPrimed:        String(r.maxPrimed),
        spawnWeight:      String(r.spawnWeight),
        isSpawningActive: r.isSpawningActive,
      }
    }
    setDrafts(next)
  }, [])

  const load = useCallback(async () => {
    if (!vmRunning) return
    setLoading(true); setErr(null)
    try {
      const data = await getSpicefields()
      const sorted = [...data.rows].sort((a, b) =>
        a.mapName.localeCompare(b.mapName) ||
        a.spicefieldTypeId - b.spicefieldTypeId,
      )
      setRows(sorted)
      seed(sorted)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [vmRunning, seed])

  useEffect(() => { void load() }, [load])

  const grouped = useMemo(() => {
    const out: Record<string, SpicefieldType[]> = {}
    for (const r of rows ?? []) (out[r.mapName] ??= []).push(r)
    return out
  }, [rows])

  function isDirty(r: SpicefieldType) {
    const d = drafts[r.spicefieldTypeId]
    if (!d) return false
    return (
      Number(d.maxActive)   !== r.maxActive   ||
      Number(d.maxPrimed)   !== r.maxPrimed   ||
      Number(d.spawnWeight) !== r.spawnWeight ||
      d.isSpawningActive    !== r.isSpawningActive
    )
  }

  function setDraft(id: number, patch: Partial<RowDraft>) {
    setDrafts(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }))
  }

  async function onSave(r: SpicefieldType) {
    const d = drafts[r.spicefieldTypeId]
    if (!d) return
    setSavingId(r.spicefieldTypeId); setErr(null); setOk(null)
    try {
      const out = await saveSpicefield(r.spicefieldTypeId, {
        maxActive:        Math.max(0, Math.floor(Number(d.maxActive)   || 0)),
        maxPrimed:        Math.max(0, Math.floor(Number(d.maxPrimed)   || 0)),
        spawnWeight:      Math.max(0, Number(d.spawnWeight) || 0),
        isSpawningActive: !!d.isSpawningActive,
      })
      setRows(prev => (prev ?? []).map(row =>
        row.spicefieldTypeId === r.spicefieldTypeId ? out.row : row,
      ))
      setDrafts(prev => ({
        ...prev,
        [r.spicefieldTypeId]: {
          maxActive:        String(out.row.maxActive),
          maxPrimed:        String(out.row.maxPrimed),
          spawnWeight:      String(out.row.spawnWeight),
          isSpawningActive: out.row.isSpawningActive,
        },
      }))
      setOk(`${r.mapName} • ${r.fieldType}: saved.`)
      window.setTimeout(() => setOk(null), 3500)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSavingId(null)
    }
  }

  return (
    <div className="card p-5">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-sm font-semibold uppercase tracking-wider text-accent-bright flex items-center gap-2">
          <Icon name="Sparkles" size={14} /> Spice Fields
          <span className="ml-2 text-[10px] font-mono normal-case text-text-dim tracking-normal">
            dune.spicefield_types
          </span>
        </h2>
        <button
          type="button"
          onClick={() => void load()}
          disabled={!vmRunning || loading}
          className="btn-secondary"
          title="Re-fetch from the live BG Postgres"
        >
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14}
                className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      <p className="text-xs text-text-muted mb-3">
        How many spice fields can be active &amp; primed per map/size, the per-type
        spawn weight, and whether spawning is enabled. <em>Current</em> counts are
        read-only and reflect what is on the map right now.
      </p>

      {err && (
        <div className="mb-3 px-3 py-2 rounded border border-danger/40 bg-danger/10 text-danger text-xs flex items-center gap-2">
          <Icon name="AlertCircle" size={13} /> {err}
        </div>
      )}
      {ok && (
        <div className="mb-3 px-3 py-2 rounded border border-success/40 bg-success/10 text-success text-xs flex items-center gap-2">
          <Icon name="CheckCircle2" size={13} /> {ok}
        </div>
      )}

      {!vmRunning && (
        <div className="text-xs text-warning flex items-center gap-2">
          <Icon name="AlertTriangle" size={13} /> Start the battlegroup to load and edit spicefield types.
        </div>
      )}

      {vmRunning && loading && !rows && (
        <div className="text-xs text-text-muted flex items-center gap-2">
          <Icon name="Loader2" size={13} className="animate-spin" /> Loading from Postgres…
        </div>
      )}

      {vmRunning && rows && rows.length === 0 && (
        <div className="text-xs text-text-muted">
          No rows in <code>dune.spicefield_types</code>.
        </div>
      )}

      {vmRunning && rows && rows.length > 0 && (
        <div className="space-y-4">
          {Object.entries(grouped).map(([mapName, list]) => (
            <div key={mapName}>
              <div className="text-[11px] font-mono uppercase tracking-wider text-text-dim mb-2">
                {mapName}
              </div>
              <div className="space-y-2">
                {list.map(r => {
                  const d = drafts[r.spicefieldTypeId]
                  if (!d) return null
                  const dirty = isDirty(r)
                  const saving = savingId === r.spicefieldTypeId
                  return (
                    <div key={r.spicefieldTypeId}
                         className="border border-border rounded-lg p-3 bg-surface-2/40">
                      <div className="flex items-center justify-between mb-3">
                        <div className="flex items-center gap-2">
                          <span className="font-medium text-text">{r.fieldType}</span>
                          <span className="text-[10px] font-mono text-text-dim">
                            id {r.spicefieldTypeId}
                          </span>
                          {dirty && (
                            <span className="w-1.5 h-1.5 rounded-full bg-ibad"
                                  title="Unsaved changes" />
                          )}
                        </div>
                        <div className="flex items-center gap-3 text-[11px] text-text-muted">
                          <span title="Currently active on the map / max allowed">
                            <span className="text-text">{r.currentActive}</span>
                            <span className="text-text-dim"> / {r.maxActive}</span>
                            <span className="ml-1">active</span>
                          </span>
                          <span className="text-border">|</span>
                          <span title="Currently primed (about to spawn) / max allowed">
                            <span className="text-text">{r.currentPrimed}</span>
                            <span className="text-text-dim"> / {r.maxPrimed}</span>
                            <span className="ml-1">primed</span>
                          </span>
                        </div>
                      </div>

                      <div className="grid grid-cols-2 md:grid-cols-[1fr_1fr_1fr_auto_auto] gap-3 items-end">
                        <NumField label="Max active" value={d.maxActive}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxActive: v })} />
                        <NumField label="Max primed" value={d.maxPrimed}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxPrimed: v })} />
                        <NumField label="Spawn weight" value={d.spawnWeight} step="0.1"
                                  onChange={v => setDraft(r.spicefieldTypeId, { spawnWeight: v })} />
                        <label className="flex items-center gap-2 text-xs select-none cursor-pointer pb-2">
                          <input
                            type="checkbox"
                            checked={d.isSpawningActive}
                            onChange={e => setDraft(r.spicefieldTypeId,
                                                   { isSpawningActive: e.target.checked })}
                            className="accent-ibad"
                          />
                          <span className={d.isSpawningActive ? 'text-success' : 'text-text-dim'}>
                            {d.isSpawningActive ? 'Spawning' : 'Off'}
                          </span>
                        </label>
                        <button
                          type="button"
                          className="btn-primary py-2"
                          disabled={!dirty || saving}
                          onClick={() => void onSave(r)}
                        >
                          <Icon name={saving ? 'Loader2' : 'Save'} size={14}
                                className={saving ? 'animate-spin' : ''} />
                          Save
                        </button>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function NumField({ label, value, step, onChange }: {
  label: string
  value: string
  step?: string
  onChange: (v: string) => void
}) {
  return (
    <div>
      <label className="block text-[11px] text-text-muted mb-1">{label}</label>
      <input
        type="number"
        min={0}
        step={step ?? 1}
        value={value}
        onChange={e => onChange(e.target.value)}
        className="w-full px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
      />
    </div>
  )
}
