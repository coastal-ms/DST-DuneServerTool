// BgSpiceSummary — compact read-only spice activity readout that
// recreates the old `bg-status` terminal layout. Tabular form: one
// row per (map, field type), sorted by map and then largest-first.
// Lives under the Battlegroup Info card on Server Health.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { getSpicefields } from '../../api/gameconfig'
import type { SpicefieldType } from '../../api/types'

type Props = {
  enabled: boolean   // gate on BG ready
}

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
              <th className="text-right font-medium pb-1"></th>
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
              const off       = !r.isSpawningActive
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
                  <td className="text-right py-0.5">
                    {off && (
                      <span className="text-[10px] uppercase tracking-wider text-danger"
                            title="Spawning disabled for this field type">
                        off
                      </span>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}
    </div>
  )
}
