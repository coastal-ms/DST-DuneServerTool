// Spice Fields editor backed by current Funcom UserGame.ini settings.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getSpicefields, saveSpicefield, setSpicefieldSpawning } from '../../api/gameconfig'
import type { SpicefieldType } from '../../api/types'

type RowDraft = {
  maxActive: string
  maxPrimed: string
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
  const [unavailableReason, setUnavailableReason] = useState<string | null>(null)
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
      setUnavailableReason(data.available ? null : (data.unavailableReason ?? 'Spice field controls are unavailable on this Funcom server build.'))
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

  // Counts by field size are not exposed by the current Funcom state schema.

  const grouped = useMemo(() => {
    const out: Record<string, SpicefieldType[]> = {}
    for (const r of rows ?? []) (out[r.mapName] ??= []).push(r)
    return out
  }, [rows])

  const groupOrder = useMemo(() => Object.entries(grouped).sort(([an], [bn]) => an.localeCompare(bn)), [grouped])

  function isDirty(r: SpicefieldType) {
    const d = drafts[r.spicefieldTypeId]
    if (!d) return false
    // The spawning switch saves independently; only the two cap values make
    // the numeric row dirty.
    return (
      Number(d.maxActive)   !== r.maxActive   ||
      Number(d.maxPrimed)   !== r.maxPrimed
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
        isSpawningActive: !!d.isSpawningActive,
      })
      if (out.row.globalSpawning) {
        await load()
      } else {
        setRows(prev => (prev ?? []).map(row =>
          row.spicefieldTypeId === r.spicefieldTypeId ? out.row : row,
        ))
        setDrafts(prev => ({
          ...prev,
          [r.spicefieldTypeId]: {
            maxActive:        String(out.row.maxActive),
            maxPrimed:        String(out.row.maxPrimed),
            isSpawningActive: out.row.isSpawningActive,
          },
        }))
      }
      setOk(`${r.mapName} • ${r.fieldType}: saved.`)
      window.setTimeout(() => setOk(null), 3500)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSavingId(null)
    }
  }

  // Save the current Funcom-wide spawning setting. The backend requires an
  // INI apply and restart for it to take effect.
  async function onToggleSpawning(r: SpicefieldType, next: boolean) {
    if (cooldownRemaining('toggle', r.spicefieldTypeId) > 0) return
    if (togglingId === r.spicefieldTypeId) return
    markClick('toggle', r.spicefieldTypeId)
    // Optimistic UI — flip the draft + the row immediately so the checkbox
    // tracks the user's intent while the request is in flight.
    setDrafts(prev => {
      const nextDrafts = { ...prev }
      for (const row of rows ?? []) {
        if (r.globalSpawning || row.spicefieldTypeId === r.spicefieldTypeId) {
          nextDrafts[row.spicefieldTypeId] = {
            ...prev[row.spicefieldTypeId],
            isSpawningActive: next,
          }
        }
      }
      return nextDrafts
    })
    setRows(prev => (prev ?? []).map(row =>
      r.globalSpawning || row.spicefieldTypeId === r.spicefieldTypeId
        ? { ...row, isSpawningActive: next }
        : row,
    ))
    setTogglingId(r.spicefieldTypeId); setErr(null); setOk(null)
    try {
      const out = await setSpicefieldSpawning(r.spicefieldTypeId, next === true)
      if (out.row.globalSpawning) {
        await load()
      } else {
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
      }
      setOk(`${r.mapName} • ${r.fieldType}: spawning ${out.row.isSpawningActive ? 'ON' : 'OFF'}.`)
      window.setTimeout(() => setOk(null), 3500)
    } catch (e) {
      // Roll back the optimistic flip on failure.
      setDrafts(prev => {
        const rolledBack = { ...prev }
        for (const row of rows ?? []) {
          if (r.globalSpawning || row.spicefieldTypeId === r.spicefieldTypeId) {
            rolledBack[row.spicefieldTypeId] = {
              ...prev[row.spicefieldTypeId],
              isSpawningActive: r.isSpawningActive,
            }
          }
        }
        return rolledBack
      })
      setRows(prev => (prev ?? []).map(row =>
        r.globalSpawning || row.spicefieldTypeId === r.spicefieldTypeId
          ? { ...row, isSpawningActive: r.isSpawningActive }
          : row,
      ))
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setTogglingId(null)
    }
  }

  return (
    <CollapsibleCard
      id="gameconfig.spicefields"
      icon="Sparkles"
      iconClassName="text-accent-bright shrink-0"
      title={
        <span className="flex items-center gap-2">
          Spice Fields
          <span className="text-[10px] font-mono normal-case text-text-dim tracking-normal">
            Funcom settings
          </span>
        </span>
      }
      titleClassName="text-sm font-semibold uppercase tracking-wider text-accent-bright"
      className=""
      headerClassName="px-5 pt-5 pb-2"
      bodyClassName="px-5 pb-5"
      headerRight={
        <button
          type="button"
          onClick={() => void load()}
          disabled={!vmRunning || loading}
          className="btn-secondary"
          title="Re-read current Funcom game settings"
        >
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14}
                className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      }
    >

      <p className="text-xs text-text-muted mb-3">
        Set the startup caps per map and field size, plus Funcom's global spice
        spawning switch.
      </p>

      <div className="mb-3 px-3 py-2 rounded border border-info/40 bg-info/10 text-info text-xs flex items-start gap-2">
        <Icon name="Info" size={13} className="mt-0.5 shrink-0" />
        <span>
          DST writes Funcom's <strong>UserGame.ini</strong> settings. Use
          <strong> Apply INIs &amp; restart</strong> after saving. Active field counts
          by size are unavailable because current field state does not identify size.
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
          <Icon name="Loader2" size={13} className="animate-spin" /> Loading current server settings…
        </div>
      )}

      {vmRunning && rows && rows.length === 0 && unavailableReason && (
        <div className="text-xs text-warning flex items-start gap-2">
          <Icon name="AlertTriangle" size={13} className="mt-0.5 shrink-0" /> {unavailableReason}
        </div>
      )}

      {vmRunning && rows && rows.length === 0 && !unavailableReason && (
        <div className="text-xs text-text-muted">
          No current Funcom spice field settings were returned.
        </div>
      )}

      {vmRunning && rows && rows.length > 0 && (
        <div className="space-y-4">
          {groupOrder.map(([mapName, list]) => {
            const totalMaxActive = list.reduce((s, r) => s + r.maxActive, 0)
            const totalMaxPrimed = list.reduce((s, r) => s + r.maxPrimed, 0)
            return (
            <div key={mapName}>
              <div className="flex items-center justify-between mb-2">
                <div className="text-[11px] font-mono uppercase tracking-wider text-text-dim flex items-center gap-2">
                  {mapName}
                </div>
                <div className="text-[11px] text-text-muted">
                  Startup caps: {totalMaxActive} active / {totalMaxPrimed} primed
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
                                ? 'Funcom spice spawning is enabled'
                                : 'Funcom spice spawning is disabled'}>
                          <Icon name={r.isSpawningActive ? 'Sparkles' : 'CircleOff'} size={11} />
                          {r.isSpawningActive ? 'Spawning' : 'Off'}
                        </span>
                      </div>

                      <div className="mb-3">
                        <div className="rounded-md border border-border bg-base/40 px-3 py-2 text-[11px] text-text-dim">
                          Current active count by size is unavailable in the current Funcom field-state data.
                        </div>
                      </div>

                      <div className="grid grid-cols-2 gap-3 items-end md:grid-cols-[1fr_1fr_auto_auto]">
                        <NumField label="Max active" value={d.maxActive}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxActive: v, maxPrimed: v })} />
                        <NumField label="Max primed" value={d.maxPrimed}
                                  onChange={v => setDraft(r.spicefieldTypeId, { maxPrimed: v })} />
                        <label
                          className={
                            'flex items-center gap-2 text-xs select-none pb-2 ' +
                            (toggleDisabled ? 'cursor-not-allowed opacity-70' : 'cursor-pointer')
                          }
                          title={
                            toggleCdMs > 0
                              ? `Rate-limited — wait ${toggleCdSec}s before toggling again`
                              : (d.isSpawningActive
                                  ? 'Disable the Funcom master switch; applies after Apply INIs & restart'
                                  : 'Enable the Funcom master switch; applies after Apply INIs & restart')
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
                      {r.adapter === 'retail-config' && (
                        <div className="mt-2 text-[11px] text-text-dim">
                          {r.configuredOverride === true ? 'Configured override.' : 'Current configuration.'}
                          {r.defaultMaxActive != null && r.defaultMaxPrimed != null && (
                            <>
                              {' '}Funcom default: {r.defaultMaxActive} active / {r.defaultMaxPrimed} primed.
                            </>
                          )}
                          {r.guidanceMax != null && (
                            <> DST guidance: {r.guidanceMax} for both.</>
                          )}
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
            )
          })}
        </div>
      )}
    </CollapsibleCard>
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
