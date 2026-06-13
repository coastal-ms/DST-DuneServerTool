// SpicefieldsCard — editor for dune.spicefield_types.
// Live read/write directly against the live BG Postgres pod over SSH.
// Disabled when the VM is not running.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getSpicefields, saveSpicefield, setSpicefieldSpawning } from '../../api/gameconfig'
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

// Per-button rate limit (ms). Each button (toggle + Save) records the time
// of its last click; another click within this window is dropped.
const CLICK_COOLDOWN_MS = 5000

export function SpicefieldsCard({ vmRunning }: Props) {
  const [rows, setRows] = useState<SpicefieldType[] | null>(null)
  const [drafts, setDrafts] = useState<Record<number, RowDraft>>({})
  const [loading, setLoading] = useState(false)
  const [savingId, setSavingId] = useState<number | null>(null)
  const [togglingId, setTogglingId] = useState<number | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  // Cooldowns are stored as ref maps so a tick doesn't re-render every row.
  // Key: `${kind}:${spicefieldTypeId}` -> last click ms timestamp.
  const lastClickRef = useRef<Record<string, number>>({})
  // Force a re-render when a cooldown expires so disabled buttons re-enable.
  const [, bumpCooldown] = useState(0)

  function cooldownRemaining(kind: 'toggle' | 'save', id: number): number {
    const k = `${kind}:${id}`
    const t = lastClickRef.current[k] ?? 0
    const remaining = (t + CLICK_COOLDOWN_MS) - Date.now()
    return remaining > 0 ? remaining : 0
  }
  function markClick(kind: 'toggle' | 'save', id: number) {
    lastClickRef.current[`${kind}:${id}`] = Date.now()
    // Re-render once when the cooldown lapses so the button re-enables.
    window.setTimeout(() => bumpCooldown(x => x + 1), CLICK_COOLDOWN_MS + 50)
  }

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

  const load = useCallback(async (opts?: { silent?: boolean }) => {
    if (!vmRunning) return
    if (!opts?.silent) { setLoading(true); setErr(null) }
    try {
      const data = await getSpicefields()
      const sorted = [...data.rows].sort((a, b) =>
        a.mapName.localeCompare(b.mapName) ||
        a.spicefieldTypeId - b.spicefieldTypeId,
      )
      setRows(sorted)
      if (opts?.silent) {
        // Background poll: refresh stats but never overwrite an in-progress edit.
        setDrafts(prev => {
          const next = { ...prev }
          for (const r of sorted) {
            const d = prev[r.spicefieldTypeId]
            if (!d) {
              next[r.spicefieldTypeId] = {
                maxActive:        String(r.maxActive),
                maxPrimed:        String(r.maxPrimed),
                spawnWeight:      String(r.spawnWeight),
                isSpawningActive: r.isSpawningActive,
              }
            }
          }
          return next
        })
      } else {
        seed(sorted)
      }
    } catch (e) {
      if (!opts?.silent) setErr(e instanceof Error ? e.message : String(e))
    } finally {
      if (!opts?.silent) setLoading(false)
    }
  }, [vmRunning, seed])

  useEffect(() => { void load() }, [load])

  // Light polling so the read-only "current active / primed" counters track
  // what's actually on the map without the operator hitting Refresh — and
  // without clobbering any unsaved edits in the form.
  useEffect(() => {
    if (!vmRunning) return
    const id = window.setInterval(() => { void load({ silent: true }) }, 15000)
    return () => window.clearInterval(id)
  }, [vmRunning, load])

  const grouped = useMemo(() => {
    const out: Record<string, SpicefieldType[]> = {}
    for (const r of rows ?? []) (out[r.mapName] ??= []).push(r)
    return out
  }, [rows])

  function isDirty(r: SpicefieldType) {
    const d = drafts[r.spicefieldTypeId]
    if (!d) return false
    // Only numeric fields gate the Save button. isSpawningActive is
    // committed live via its own endpoint, so it never makes the row "dirty".
    return (
      Number(d.maxActive)   !== r.maxActive   ||
      Number(d.maxPrimed)   !== r.maxPrimed   ||
      Number(d.spawnWeight) !== r.spawnWeight
    )
  }

  function setDraft(id: number, patch: Partial<RowDraft>) {
    setDrafts(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }))
  }

  async function onSave(r: SpicefieldType) {
    const d = drafts[r.spicefieldTypeId]
    if (!d) return
    if (cooldownRemaining('save', r.spicefieldTypeId) > 0) return
    markClick('save', r.spicefieldTypeId)
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

  // Live-commit toggle for is_spawning_active. Each click hits the dedicated
  // /spawning endpoint that only ever writes TRUE or FALSE to that single
  // column. Rate-limited to one click every CLICK_COOLDOWN_MS per row to
  // prevent a stuck user from hammering the DB.
  async function onToggleSpawning(r: SpicefieldType, next: boolean) {
    if (cooldownRemaining('toggle', r.spicefieldTypeId) > 0) return
    if (togglingId === r.spicefieldTypeId) return
    markClick('toggle', r.spicefieldTypeId)
    // Optimistic UI — flip the draft + the row immediately so the checkbox
    // tracks the user's intent while the request is in flight.
    setDrafts(prev => ({
      ...prev,
      [r.spicefieldTypeId]: { ...prev[r.spicefieldTypeId], isSpawningActive: next },
    }))
    setRows(prev => (prev ?? []).map(row =>
      row.spicefieldTypeId === r.spicefieldTypeId
        ? { ...row, isSpawningActive: next }
        : row,
    ))
    setTogglingId(r.spicefieldTypeId); setErr(null); setOk(null)
    try {
      const out = await setSpicefieldSpawning(r.spicefieldTypeId, next === true)
      setRows(prev => (prev ?? []).map(row =>
        row.spicefieldTypeId === r.spicefieldTypeId ? out.row : row,
      ))
      setDrafts(prev => ({
        ...prev,
        [r.spicefieldTypeId]: {
          ...prev[r.spicefieldTypeId],
          isSpawningActive: out.row.isSpawningActive,
        },
      }))
      setOk(`${r.mapName} • ${r.fieldType}: spawning ${out.row.isSpawningActive ? 'ON' : 'OFF'}.`)
      window.setTimeout(() => setOk(null), 3500)
    } catch (e) {
      // Roll back the optimistic flip on failure.
      setDrafts(prev => ({
        ...prev,
        [r.spicefieldTypeId]: { ...prev[r.spicefieldTypeId], isSpawningActive: r.isSpawningActive },
      }))
      setRows(prev => (prev ?? []).map(row =>
        row.spicefieldTypeId === r.spicefieldTypeId
          ? { ...row, isSpawningActive: r.isSpawningActive }
          : row,
      ))
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setTogglingId(null)
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

      <div className="mb-3 px-3 py-2 rounded border border-info/40 bg-info/10 text-info text-xs flex items-start gap-2">
        <Icon name="Info" size={13} className="mt-0.5 shrink-0" />
        <span>
          These Spice adjustments take effect immediately and do not persist across BG
          restarts. They are based on the last BG start of the SpiceField settings in the
          ini files below.
        </span>
      </div>

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
          {Object.entries(grouped).map(([mapName, list]) => {
            const totalActive = list.reduce((s, r) => s + r.currentActive, 0)
            const totalMaxActive = list.reduce((s, r) => s + r.maxActive, 0)
            const totalPrimed = list.reduce((s, r) => s + r.currentPrimed, 0)
            const totalMaxPrimed = list.reduce((s, r) => s + r.maxPrimed, 0)
            return (
            <div key={mapName}>
              <div className="flex items-center justify-between mb-2">
                <div className="text-[11px] font-mono uppercase tracking-wider text-text-dim">
                  {mapName}
                </div>
                <div className="text-[11px] text-text-muted flex items-center gap-3">
                  <span title={`Total currently active across all ${mapName} field sizes`}>
                    <Icon name="Sparkles" size={11} className="inline mr-1 text-accent-bright" />
                    <span className="text-text font-medium">{totalActive}</span>
                    <span className="text-text-dim"> / {totalMaxActive}</span>
                    <span className="ml-1">active</span>
                  </span>
                  <span className="text-border">·</span>
                  <span title={`Total currently primed across all ${mapName} field sizes`}>
                    <span className="text-text font-medium">{totalPrimed}</span>
                    <span className="text-text-dim"> / {totalMaxPrimed}</span>
                    <span className="ml-1">primed</span>
                  </span>
                </div>
              </div>
              <div className="space-y-2">
                {list.map(r => {
                  const d = drafts[r.spicefieldTypeId]
                  if (!d) return null
                  const dirty = isDirty(r)
                  const saving = savingId === r.spicefieldTypeId
                  const toggling = togglingId === r.spicefieldTypeId
                  const toggleCdMs = cooldownRemaining('toggle', r.spicefieldTypeId)
                  const saveCdMs   = cooldownRemaining('save',   r.spicefieldTypeId)
                  const toggleCdSec = Math.ceil(toggleCdMs / 1000)
                  const saveCdSec   = Math.ceil(saveCdMs   / 1000)
                  const toggleDisabled = !vmRunning || toggling || toggleCdMs > 0
                  const saveDisabled   = !vmRunning || !dirty || saving || saveCdMs > 0
                  const activeAtCap = r.maxActive > 0 && r.currentActive >= r.maxActive
                  const primedAtCap = r.maxPrimed > 0 && r.currentPrimed >= r.maxPrimed
                  return (
                    <div key={r.spicefieldTypeId}
                         className="border border-border rounded-lg p-3 bg-surface-2/40">
                      <div className="flex items-center justify-between mb-3 gap-3 flex-wrap">
                        <div className="flex items-center gap-2">
                          <span className="font-medium text-text">{r.fieldType}</span>
                          <span className="text-[10px] font-mono text-text-dim">
                            id {r.spicefieldTypeId}
                          </span>
                          {dirty && (
                            <span className="w-1.5 h-1.5 rounded-full bg-ibad"
                                  title="Unsaved changes (numeric fields)" />
                          )}
                        </div>
                        <span className={r.isSpawningActive ? 'pill-success' : 'pill-muted'}
                              title={r.isSpawningActive
                                ? 'Game is spawning this field type'
                                : 'Spawning disabled for this field type'}>
                          <Icon name={r.isSpawningActive ? 'Sparkles' : 'CircleOff'} size={11} />
                          {r.isSpawningActive ? 'Spawning' : 'Off'}
                        </span>
                      </div>

                      <div className="grid grid-cols-2 gap-2 mb-3">
                        <StatTile
                          label="Active on map"
                          current={r.currentActive}
                          max={r.maxActive}
                          atCap={activeAtCap}
                        />
                        <StatTile
                          label="Primed to spawn"
                          current={r.currentPrimed}
                          max={r.maxPrimed}
                          atCap={primedAtCap}
                        />
                      </div>

                      <div className="grid grid-cols-2 md:grid-cols-[1fr_1fr_1fr_auto_auto] gap-3 items-end">
                        <NumField label="Max active" value={d.maxActive}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxActive: v, maxPrimed: v })} />
                        <NumField label="Max primed" value={d.maxPrimed}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxPrimed: v })} />
                        <NumField label="Spawn weight" value={d.spawnWeight} step="0.1"
                                  onChange={v => setDraft(r.spicefieldTypeId, { spawnWeight: v })} />
                        <label
                          className={
                            'flex items-center gap-2 text-xs select-none pb-2 ' +
                            (toggleDisabled ? 'cursor-not-allowed opacity-70' : 'cursor-pointer')
                          }
                          title={
                            toggleCdMs > 0
                              ? `Rate-limited — wait ${toggleCdSec}s before toggling again`
                              : (d.isSpawningActive
                                  ? 'Click to disable spawning for this field (live DB write)'
                                  : 'Click to enable spawning for this field (live DB write)')
                          }
                        >
                          <input
                            type="checkbox"
                            checked={d.isSpawningActive}
                            disabled={toggleDisabled}
                            onChange={e => void onToggleSpawning(r, e.target.checked)}
                            className="accent-ibad"
                          />
                          <span className={d.isSpawningActive ? 'text-success' : 'text-text-dim'}>
                            {toggling ? '…' : (d.isSpawningActive ? 'Spawning' : 'Off')}
                            {toggleCdMs > 0 && !toggling && (
                              <span className="ml-1 text-[10px] font-mono text-text-dim">
                                ({toggleCdSec}s)
                              </span>
                            )}
                          </span>
                        </label>
                        <button
                          type="button"
                          className="btn-primary py-2"
                          disabled={saveDisabled}
                          onClick={() => void onSave(r)}
                          title={
                            saveCdMs > 0
                              ? `Rate-limited — wait ${saveCdSec}s before saving again`
                              : 'Save numeric fields'
                          }
                        >
                          <Icon name={saving ? 'Loader2' : 'Save'} size={14}
                                className={saving ? 'animate-spin' : ''} />
                          {saveCdMs > 0 && !saving ? `Save (${saveCdSec}s)` : 'Save'}
                        </button>
                      </div>
                    </div>
                  )
                })}
              </div>
            </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

function StatTile({ label, current, max, atCap }: {
  label: string
  current: number
  max: number
  atCap: boolean
}) {
  const pct = max > 0 ? Math.min(100, Math.round((current / max) * 100)) : 0
  const barColor = atCap
    ? 'bg-warning'
    : pct >= 75 ? 'bg-accent-bright'
    : 'bg-ibad'
  return (
    <div className={
      'rounded-md border px-3 py-2 ' +
      (atCap
        ? 'border-warning/40 bg-warning/5'
        : 'border-border bg-base/40')
    }>
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-[10px] uppercase tracking-wider text-text-dim">{label}</span>
        {atCap && (
          <span className="text-[10px] uppercase tracking-wider text-warning font-semibold">
            at cap
          </span>
        )}
      </div>
      <div className="flex items-baseline gap-1 mt-0.5">
        <span className={'font-mono text-lg leading-none ' + (atCap ? 'text-warning' : 'text-text')}>
          {current}
        </span>
        <span className="font-mono text-sm text-text-dim">/ {max}</span>
      </div>
      <div className="mt-1.5 h-1 rounded-full bg-surface-3 overflow-hidden">
        <div className={'h-full ' + barColor} style={{ width: pct + '%' }} />
      </div>
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
