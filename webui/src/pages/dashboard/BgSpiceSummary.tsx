// BgSpiceSummary — compact read-only spice activity readout that
// recreates the old `bg-status` terminal layout: one line per map,
// each field type shown as "Name cur/max (N primed)". Lives under
// the Battlegroup Info card on Server Health.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { getSpicefields } from '../../api/gameconfig'
import type { SpicefieldType } from '../../api/types'

type Props = {
  enabled: boolean   // gate on BG ready
}

// Stable display order — Large fields are operationally most interesting.
const SIZE_ORDER = ['Large', 'Medium', 'Small']

// Map labels mirror the colors from the original bg-status terminal output.
const MAP_LABEL_CLASS: Record<string, string> = {
  HaggaBasin: 'text-success',
  DeepDesert: 'text-accent-bright',
}

const MAP_DISPLAY: Record<string, string> = {
  HaggaBasin: 'Hagga Basin',
  DeepDesert: 'Deep Desert',
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

  const grouped = useMemo(() => {
    const out: Record<string, SpicefieldType[]> = {}
    for (const r of rows ?? []) (out[r.mapName] ??= []).push(r)
    for (const k of Object.keys(out)) {
      out[k].sort((a, b) => {
        const ai = SIZE_ORDER.indexOf(a.fieldType)
        const bi = SIZE_ORDER.indexOf(b.fieldType)
        return (ai < 0 ? 99 : ai) - (bi < 0 ? 99 : bi)
      })
    }
    return out
  }, [rows])

  if (!enabled) return null

  return (
    <div className="mt-4 pt-3 border-t border-border font-mono text-xs leading-relaxed">
      {!rows && !err && (
        <p className="text-text-dim italic">Loading spice activity…</p>
      )}

      {err && (
        <p className="text-danger">spice: {err}</p>
      )}

      {rows && rows.length === 0 && !err && (
        <p className="text-text-dim italic">No spicefield types configured.</p>
      )}

      {rows && rows.length > 0 && (
        <ul className="space-y-1">
          {Object.entries(grouped).map(([mapName, list]) => {
            const labelClass = MAP_LABEL_CLASS[mapName] ?? 'text-text'
            const display    = MAP_DISPLAY[mapName] ?? mapName
            return (
              <li key={mapName} className="flex flex-wrap items-baseline gap-x-4 gap-y-0.5">
                <span className={`font-semibold ${labelClass}`}>{display}:</span>
                {list.map(r => {
                  const atCap = r.maxActive > 0 && r.currentActive >= r.maxActive
                  const off   = !r.isSpawningActive
                  return (
                    <span key={r.spicefieldTypeId} className="whitespace-nowrap">
                      <span className="text-text-muted">{r.fieldType}</span>
                      {' '}
                      <span className={atCap ? 'text-warning font-semibold' : 'text-text'}>
                        {r.currentActive}/{r.maxActive}
                      </span>
                      <span className="text-text-dim"> ({r.currentPrimed} primed)</span>
                      {off && (
                        <span className="ml-1 text-[10px] uppercase tracking-wider text-danger"
                              title="Spawning disabled for this field type">
                          off
                        </span>
                      )}
                    </span>
                  )
                })}
                {updatedAt && (
                  <span className="ml-auto text-text-dim">updated {formatTime(updatedAt)}</span>
                )}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
