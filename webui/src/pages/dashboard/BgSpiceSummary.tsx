// BgSpiceSummary — compact read-only spice activity readout that
// recreates the old `bg-status` terminal layout. Tabular form: one
// row per (map, field type), sorted by map and then largest-first.
// Lives under the Battlegroup Info card on Server Health.
//
// Per-row spawning toggle: clicking the checkbox to the right of
// Primed flips `is_spawning_active` in dune.spicefield_types live,
// via the guard-railed PUT /api/gameconfig/spicefields/{id}/spawning
// endpoint (only ever writes TRUE/FALSE to that one column). Each
// checkbox has an independent 5-second click cooldown.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { getSpicefields, setSpicefieldSpawning } from '../../api/gameconfig'
import type { SpicefieldType } from '../../api/types'

type Props = {
  enabled: boolean   // gate on BG ready
}

// 5-second click cooldown per checkbox (defense against accidental
// rapid clicks hammering the DB). Mirrors the GameConfig SpicefieldsCard.
const CLICK_COOLDOWN_MS = 5000

// Large fields are operationally most interesting — sort reverse so they're on top.
const SIZE_RANK: Record<string, number> = { Large: 0, Medium: 1, Small: 2 }

// Size tier color — large=amber, medium=blue, small=muted. Matches the
// "scale of importance" cue used elsewhere in the dashboard.
const SIZE_CLASS: Record<string, string> = {
  Large:  'text-accent-bright',
  Medium: 'text-ibad',
  Small:  'text-text-muted',
}

// Map labels mirror the colors from the original bg-status terminal output.
const MAP_LABEL_CLASS: Record<string, string> = {
  HaggaBasin: 'text-success',
  DeepDesert: 'text-accent-bright',
}

const MAP_DISPLAY: Record<string, string> = {
  HaggaBasin: 'Hagga Basin',
  DeepDesert: 'Deep Desert',
}

// Color the Active count by fill ratio so the eye is drawn to busy fields.
function activeFillClass(cur: number, max: number): string {
  if (max <= 0) return 'text-text-dim'
  const pct = cur / max
  if (pct >= 1)    return 'text-warning font-semibold'  // at cap
  if (pct >= 0.75) return 'text-accent-bright font-semibold'
  if (pct >= 0.25) return 'text-ibad'
  if (cur === 0)   return 'text-text-dim'
  return 'text-text'
}

function primedClass(cur: number): string {
  return cur > 0 ? 'text-accent' : 'text-text-dim'
}

function formatTime(d: Date) {
  return d.toLocaleTimeString([], { hour12: false })
}

export function BgSpiceSummary({ enabled }: Props) {
  const [rows, setRows] = useState<SpicefieldType[] | null>(null)
  const [err, setErr]   = useState<string | null>(null)
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null)
  const [togglingId, setTogglingId] = useState<number | null>(null)
  const [toggleErr, setToggleErr]   = useState<string | null>(null)
  // SHARED cooldown: one click anywhere on this card locks every
  // checkbox for 5 seconds. Ref (not state) so the cooldown check
  // doesn't depend on re-render timing.
  const lastClickAtRef = useRef<number>(0)
  // bumpCooldown forces a re-render when the shared cooldown lapses
  // so all checkboxes visually re-enable at once.
  const [, setCooldownTick] = useState(0)
  const bumpCooldown = useCallback(() => setCooldownTick(t => t + 1), [])

  const cooldownRemaining = useCallback(() => {
    const remaining = CLICK_COOLDOWN_MS - (Date.now() - lastClickAtRef.current)
    return remaining > 0 ? remaining : 0
  }, [])

  const load = useCallback(async () => {
    if (!enabled) return
    try {
      const data = await getSpicefields()
      setRows(data.rows)
      setUpdatedAt(new Date())
      setErr(null)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }, [enabled])

  useEffect(() => { void load() }, [load])

  // Poll every 10s — counts change as the game spawns / consumes fields.
  useEffect(() => {
    if (!enabled) return
    const id = window.setInterval(() => { void load() }, 10000)
    return () => window.clearInterval(id)
  }, [enabled, load])

  // Live-commit toggle: optimistically flip the row in state, send to
  // the guard-railed PUT endpoint, and roll back on failure. ONE shared
  // 5s cooldown across all checkboxes — clicking any of them locks all
  // of them. Cooldown enforced inside the handler too (defense-in-depth
  // against stale React state allowing a second click through).
  const onToggleSpawning = useCallback(async (row: SpicefieldType) => {
    if (cooldownRemaining() > 0) return
    if (togglingId !== null) return
    lastClickAtRef.current = Date.now()
    window.setTimeout(bumpCooldown, CLICK_COOLDOWN_MS + 50)

    const newActive = !row.isSpawningActive
    setTogglingId(row.spicefieldTypeId)
    setToggleErr(null)
    // Optimistic update.
    setRows(prev => prev
      ? prev.map(r => r.spicefieldTypeId === row.spicefieldTypeId
          ? { ...r, isSpawningActive: newActive }
          : r)
      : prev)
    try {
      const resp = await setSpicefieldSpawning(row.spicefieldTypeId, newActive)
      const saved = resp.row
      // Adopt canonical row from server (in case backend normalized).
      setRows(prev => prev
        ? prev.map(r => r.spicefieldTypeId === saved.spicefieldTypeId ? saved : r)
        : prev)
    } catch (e) {
      // Rollback.
      setRows(prev => prev
        ? prev.map(r => r.spicefieldTypeId === row.spicefieldTypeId
            ? { ...r, isSpawningActive: row.isSpawningActive }
            : r)
        : prev)
      setToggleErr(e instanceof Error ? e.message : String(e))
    } finally {
      setTogglingId(null)
    }
  }, [bumpCooldown, cooldownRemaining, togglingId])

  const sorted = useMemo(() => {
    if (!rows) return []
    return [...rows].sort((a, b) => {
      if (a.mapName !== b.mapName) return a.mapName.localeCompare(b.mapName)
      const ar = SIZE_RANK[a.fieldType] ?? 99
      const br = SIZE_RANK[b.fieldType] ?? 99
      return ar - br
    })
  }, [rows])

  // Row span data so the Map column collapses repeats.
  const mapSpan = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const r of sorted) counts[r.mapName] = (counts[r.mapName] ?? 0) + 1
    return counts
  }, [sorted])

  if (!enabled) return null

  return (
    <div className="mt-4 pt-3 border-t border-border">
      <div className="flex items-baseline justify-between mb-1">
        <h3 className="text-[11px] font-semibold uppercase tracking-wider text-text-dim">
          Active spice
        </h3>
        {updatedAt && (
          <span className="text-[10px] text-text-dim font-mono">updated {formatTime(updatedAt)}</span>
        )}
      </div>

      {!rows && !err && (
        <p className="text-xs text-text-dim italic">Loading spice activity…</p>
      )}

      {err && (
        <p className="text-xs text-danger font-mono">spice: {err}</p>
      )}

      {rows && rows.length === 0 && !err && (
        <p className="text-xs text-text-dim italic">No spicefield types configured.</p>
      )}

      {rows && rows.length > 0 && (
        <table className="w-full font-mono text-xs leading-snug">
          <thead className="text-[10px] uppercase tracking-wider text-text-dim">
            <tr>
              <th className="text-left font-medium pb-1">Map</th>
              <th className="text-left font-medium pb-1">Size</th>
              <th className="text-right font-medium pb-1">Active</th>
              <th className="text-right font-medium pb-1">Primed</th>
              <th className="text-center font-medium pb-1" title="Spawning enabled — click to toggle">Active</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((r, idx) => {
              const prev      = idx > 0 ? sorted[idx - 1] : null
              const newMap    = !prev || prev.mapName !== r.mapName
              const labelCls  = MAP_LABEL_CLASS[r.mapName] ?? 'text-text'
              const display   = MAP_DISPLAY[r.mapName] ?? r.mapName
              const sizeCls   = SIZE_CLASS[r.fieldType] ?? 'text-text-muted'
              const activeCls = activeFillClass(r.currentActive, r.maxActive)
              const primCls   = primedClass(r.currentPrimed)
              const cooldownMs = cooldownRemaining()
              const onCooldown = cooldownMs > 0
              const isBusy     = togglingId === r.spicefieldTypeId
              const disabled   = isBusy || onCooldown || (togglingId !== null && togglingId !== r.spicefieldTypeId)
              const cdSecs     = Math.ceil(cooldownMs / 1000)
              const title      = isBusy ? 'Saving…'
                                 : onCooldown ? `Wait ${cdSecs}s before clicking again`
                                 : r.isSpawningActive ? 'Spawning ENABLED — click to disable'
                                                       : 'Spawning DISABLED — click to enable'
              return (
                <tr key={r.spicefieldTypeId}
                    className={newMap && idx > 0 ? 'border-t border-border/40' : ''}>
                  {newMap ? (
                    <td className={`align-top font-semibold ${labelCls} pr-3 py-0.5`}
                        rowSpan={mapSpan[r.mapName]}>
                      {display}
                    </td>
                  ) : null}
                  <td className={`pr-3 py-0.5 ${sizeCls}`}>{r.fieldType}</td>
                  <td className={`text-right tabular-nums pr-3 py-0.5 ${activeCls}`}>
                    {r.currentActive}<span className="text-text-dim">/{r.maxActive}</span>
                  </td>
                  <td className={`text-right tabular-nums pr-3 py-0.5 ${primCls}`}>
                    {r.currentPrimed}<span className="text-text-dim">/{r.maxPrimed}</span>
                  </td>
                  <td className="text-center py-0.5 whitespace-nowrap">
                    <label className={`inline-flex items-center gap-1 ${disabled ? 'cursor-wait opacity-70' : 'cursor-pointer'}`}
                           title={title}>
                      <input
                        type="checkbox"
                        checked={r.isSpawningActive}
                        disabled={disabled}
                        onChange={() => void onToggleSpawning(r)}
                        className="h-3 w-3 accent-accent-bright cursor-[inherit]"
                      />
                      {onCooldown && (
                        <span className="text-[10px] text-text-dim font-mono tabular-nums">
                          {cdSecs}s
                        </span>
                      )}
                      {isBusy && !onCooldown && (
                        <span className="text-[10px] text-text-dim font-mono">…</span>
                      )}
                    </label>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

      {toggleErr && (
        <p className="mt-1 text-[10px] text-danger font-mono">
          toggle: {toggleErr}
        </p>
      )}
    </div>
  )
}
