// BgSpiceSummary — compact read-only spice activity readout that
// recreates the old `bg-status` terminal layout. Tabular form: one
// row per (map, field type), sorted by map and then largest-first.
// Lives under the Battlegroup Info card on Server Health.
//
// Spawning toggle: legacy servers write the selected DB row live. Retail uses
// the authoritative INI master switch and requires Apply INIs & restart.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { getSpicefields, getSpicefieldState, setSpicefieldSpawning } from '../../api/gameconfig'
import type { SpicefieldStateResponse, SpicefieldType } from '../../api/types'
import { mapLabel } from '../../util/mapLabel'

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
// Keyed on the normalised map id so it matches the Game Servers table.
const MAP_LABEL_CLASS: Record<string, string> = {
  Survival_1: 'text-success',
  DeepDesert_1: 'text-accent-bright',
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

function formatRawInteger(value: string) {
  try {
    return BigInt(value).toLocaleString()
  } catch {
    return value
  }
}

export function BgSpiceSummary({ enabled }: Props) {
  const [rows, setRows] = useState<SpicefieldType[] | null>(null)
  const [unavailableReason, setUnavailableReason] = useState<string | null>(null)
  // False only when the backend could read the battlegroup; a failed read
  // leaves this true so nothing is hidden on a transient error.
  const [gateOk, setGateOk] = useState(false)
  const [err, setErr]   = useState<string | null>(null)
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null)
  const [togglingId, setTogglingId] = useState<number | null>(null)
  const [toggleErr, setToggleErr]   = useState<string | null>(null)
  const [detailsRow, setDetailsRow] = useState<SpicefieldType | null>(null)
  const [details, setDetails] = useState<SpicefieldStateResponse | null>(null)
  const [detailsLoading, setDetailsLoading] = useState(false)
  const [detailsErr, setDetailsErr] = useState<string | null>(null)
  const detailsRequestRef = useRef(0)
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
      setUnavailableReason(data.available ? null : (data.unavailableReason ?? 'Spice field controls are unavailable on this Funcom server build.'))
      setGateOk(data.partitionGate === true)
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

  useEffect(() => () => {
    detailsRequestRef.current += 1
  }, [])

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
      ? prev.map(r => row.globalSpawning || r.spicefieldTypeId === row.spicefieldTypeId
          ? { ...r, isSpawningActive: newActive }
          : r)
      : prev)
    try {
      const resp = await setSpicefieldSpawning(row.spicefieldTypeId, newActive)
      const saved = resp.row
      if (saved.globalSpawning) await load()
      else {
        // Adopt canonical row from server (in case backend normalized).
        setRows(prev => prev
          ? prev.map(r => r.spicefieldTypeId === saved.spicefieldTypeId ? saved : r)
          : prev)
      }
    } catch (e) {
      // Rollback.
      setRows(prev => prev
        ? prev.map(r => row.globalSpawning || r.spicefieldTypeId === row.spicefieldTypeId
            ? { ...r, isSpawningActive: row.isSpawningActive }
            : r)
        : prev)
      setToggleErr(e instanceof Error ? e.message : String(e))
    } finally {
      setTogglingId(null)
    }
  }, [bumpCooldown, cooldownRemaining, load, togglingId])

  const onToggleDetails = useCallback(async (row: SpicefieldType) => {
    if (detailsRow?.spicefieldTypeId === row.spicefieldTypeId) {
      detailsRequestRef.current += 1
      setDetailsRow(null)
      setDetails(null)
      setDetailsErr(null)
      setDetailsLoading(false)
      return
    }

    const requestId = detailsRequestRef.current + 1
    detailsRequestRef.current = requestId
    setDetailsRow(row)
    setDetails(null)
    setDetailsErr(null)
    setDetailsLoading(true)
    try {
      const data = await getSpicefieldState(row.spicefieldTypeId)
      if (detailsRequestRef.current !== requestId) return
      setDetails(data)
    } catch (e) {
      if (detailsRequestRef.current !== requestId) return
      setDetailsErr(e instanceof Error ? e.message : String(e))
    } finally {
      if (detailsRequestRef.current === requestId) setDetailsLoading(false)
    }
  }, [detailsRow])

  // Only partitions that are live or pinned. dune.spicefield_types keeps a row
  // per (map, size, dimension) forever, so a battlegroup that once ran two
  // instances of a map still carries rows for the second one — which rendered as
  // every size listed twice with nothing to distinguish them. When the backend
  // could not read the battlegroup (partitionGate false) nothing is hidden, so a
  // transient failure never silently drops real data.
  const visible = useMemo(() => {
    if (!rows) return []
    if (!gateOk) return rows
    return rows.filter(r => r.partitionActive !== false)
  }, [rows, gateOk])

  useEffect(() => {
    const selectedStillVisible = detailsRow !== null
      && visible.some(row => row.spicefieldTypeId === detailsRow.spicefieldTypeId)
    if (enabled && (detailsRow === null || selectedStillVisible)) return

    detailsRequestRef.current += 1
    setDetailsRow(null)
    setDetails(null)
    setDetailsLoading(false)
    setDetailsErr(null)
  }, [detailsRow, enabled, visible])

  // Group key is map + dimension so two instances of the same map stay apart.
  const groupKey = useCallback(
    (r: SpicefieldType) => `${r.mapId ?? r.mapName}|${r.dimensionIndex ?? 0}`,
    [],
  )

  const sorted = useMemo(() => {
    return [...visible].sort((a, b) => {
      const am = a.mapId ?? a.mapName
      const bm = b.mapId ?? b.mapName
      if (am !== bm) return am.localeCompare(bm)
      const ad = a.dimensionIndex ?? 0
      const bd = b.dimensionIndex ?? 0
      if (ad !== bd) return ad - bd
      const ar = SIZE_RANK[a.fieldType] ?? 99
      const br = SIZE_RANK[b.fieldType] ?? 99
      return ar - br
    })
  }, [visible])

  // Row span data so the Map column collapses repeats, per map+dimension.
  const mapSpan = useMemo(() => {
    const counts: Record<string, number> = {}
    for (const r of sorted) {
      const k = groupKey(r)
      counts[k] = (counts[k] ?? 0) + 1
    }
    return counts
  }, [sorted, groupKey])

  // Only label instances when a map genuinely has more than one, so the common
  // single-instance case stays uncluttered.
  const multiInstanceMaps = useMemo(() => {
    const dims: Record<string, Set<number>> = {}
    for (const r of sorted) {
      const m = r.mapId ?? r.mapName
      ;(dims[m] ??= new Set()).add(r.dimensionIndex ?? 0)
    }
    return new Set(Object.keys(dims).filter(m => dims[m].size > 1))
  }, [sorted])

  const detailsMapDisplay = useMemo(() => {
    if (!detailsRow) return ''
    const mapId = detailsRow.mapId ?? detailsRow.mapName
    return multiInstanceMaps.has(mapId)
      ? `${mapLabel(mapId)} #${(detailsRow.dimensionIndex ?? 0) + 1}`
      : mapLabel(mapId)
  }, [detailsRow, multiInstanceMaps])

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

      {unavailableReason && !err && (
        <p className="text-xs text-warning">{unavailableReason}</p>
      )}

      {rows && rows.length === 0 && !err && !unavailableReason && (
        <p className="text-xs text-text-dim italic">No spicefield types are present.</p>
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
              <th className="text-right font-medium pb-1">Details</th>
            </tr>
          </thead>
          <tbody>
            {sorted.map((r, idx) => {
              const prev      = idx > 0 ? sorted[idx - 1] : null
              const key       = groupKey(r)
              const newMap    = !prev || groupKey(prev) !== key
              const mapId     = r.mapId ?? r.mapName
              const labelCls  = MAP_LABEL_CLASS[mapId] ?? 'text-text'
              const dim       = r.dimensionIndex ?? 0
              const display   = multiInstanceMaps.has(mapId)
                ? `${mapLabel(mapId)} #${dim + 1}`
                : mapLabel(mapId)
              const sizeCls   = SIZE_CLASS[r.fieldType] ?? 'text-text-muted'
              const activeCls = activeFillClass(r.currentActive, r.maxActive)
              const primCls   = r.currentPrimedExact === false ? 'text-text-dim' : primedClass(r.currentPrimed)
              const cooldownMs = cooldownRemaining()
              const onCooldown = cooldownMs > 0
              const isBusy     = togglingId === r.spicefieldTypeId
              const disabled   = isBusy || onCooldown || (togglingId !== null && togglingId !== r.spicefieldTypeId)
              const detailsOpen = detailsRow?.spicefieldTypeId === r.spicefieldTypeId
              const cdSecs     = Math.ceil(cooldownMs / 1000)
              const title      = isBusy ? 'Saving…'
                                 : onCooldown ? `Wait ${cdSecs}s before clicking again`
                                 : r.globalSpawning
                                   ? `${r.isSpawningActive ? 'Spawning ENABLED' : 'Spawning DISABLED'} — Retail master switch; applies after Apply INIs & restart`
                                   : r.isSpawningActive ? 'Spawning ENABLED — click to disable'
                                                         : 'Spawning DISABLED — click to enable'
              return (
                <tr key={r.spicefieldTypeId}
                    className={newMap && idx > 0 ? 'border-t border-border/40' : ''}>
                  {newMap ? (
                    <td className={`align-top font-semibold ${labelCls} pr-3 py-0.5`}
                        rowSpan={mapSpan[key]}>
                      {display}
                    </td>
                  ) : null}
                  <td className={`pr-3 py-0.5 ${sizeCls}`}>{r.fieldType}</td>
                  <td className={`text-right tabular-nums pr-3 py-0.5 ${activeCls}`}>
                    {r.currentActive}<span className="text-text-dim">/{r.maxActive}</span>
                  </td>
                  <td className={`text-right tabular-nums pr-3 py-0.5 ${primCls}`}>
                    {r.currentPrimedExact === false ? '—' : r.currentPrimed}<span className="text-text-dim">/{r.maxPrimed}</span>
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
                  <td className="text-right py-0.5 pl-2">
                    <button
                      type="button"
                      className="inline-flex min-h-9 min-w-16 items-center justify-center rounded-sm px-2 text-[11px] font-sans text-accent hover:bg-bg-dim focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                      aria-expanded={detailsOpen}
                      aria-controls="active-spice-details"
                      aria-label={`${detailsOpen ? 'Hide' : 'Show'} raw field details for ${display} ${r.fieldType}`}
                      onClick={() => void onToggleDetails(r)}
                    >
                      {detailsOpen ? 'Hide' : 'Details'}
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      )}

      {detailsRow && (
        <section
          id="active-spice-details"
          className="mt-2 border border-border bg-bg-dim/40 p-3"
          aria-labelledby="active-spice-details-heading"
          aria-busy={detailsLoading}
        >
          <div className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <h4 id="active-spice-details-heading" className="text-xs font-semibold text-text">
                {detailsMapDisplay} · raw field values
              </h4>
              <p className="mt-1 max-w-[72ch] text-[11px] leading-relaxed text-text-muted">
                Opened from the {detailsRow.fieldType} summary row. The game reports these fields
                for the map instance, but does not identify their Small, Medium, or Large type.
                Values are raw <code>value_remaining</code> data, not a proven conversion to
                harvestable spice.
              </p>
            </div>
            <button
              type="button"
              className="inline-flex min-h-9 shrink-0 items-center px-2 text-[11px] text-text-muted hover:text-text focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              onClick={() => void onToggleDetails(detailsRow)}
            >
              Close
            </button>
          </div>

          {detailsLoading && (
            <p role="status" className="mt-3 text-xs italic text-text-dim">
              Loading raw field values…
            </p>
          )}
          {detailsErr && (
            <p role="alert" className="mt-3 text-xs text-danger">
              Could not load raw field values: {detailsErr}
            </p>
          )}
          {details && (
            <>
              <div className="mt-3 flex flex-wrap items-baseline justify-between gap-2 border-y border-border/60 py-2">
                <span className="text-[11px] text-text-muted">Total raw value remaining</span>
                <strong className="font-mono text-sm tabular-nums text-accent-bright">
                  {formatRawInteger(details.totalRawValueRemaining)}
                </strong>
              </div>
              {details.fields.length === 0 ? (
                <p className="mt-3 text-xs italic text-text-dim">
                  No active field rows reported for this map instance.
                </p>
              ) : (
                <div className="mt-2 max-h-48 overflow-y-auto border border-border/60">
                  <table className="w-full table-fixed font-mono text-xs">
                    <thead className="sticky top-0 bg-bg-dim text-[11px] uppercase tracking-wider text-text-dim">
                      <tr>
                        <th className="w-1/2 px-2 py-1.5 text-left font-medium">Field identifier</th>
                        <th className="w-1/2 px-2 py-1.5 text-right font-medium">Raw remaining</th>
                      </tr>
                    </thead>
                    <tbody>
                      {details.fields.map(field => (
                        <tr key={field.fieldId} className="border-t border-border/40">
                          <td className="truncate px-2 py-1.5 text-text" title={field.fieldId}>
                            {field.fieldId}
                          </td>
                          <td className="px-2 py-1.5 text-right tabular-nums text-text">
                            {formatRawInteger(field.valueRemaining)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {details.truncated && (
                <p className="mt-2 text-[11px] text-text-dim">
                  Showing {details.returned.toLocaleString()} of {details.totalAvailable.toLocaleString()} active fields.
                </p>
              )}
            </>
          )}
        </section>
      )}

      {toggleErr && (
        <p className="mt-1 text-[10px] text-danger font-mono">
          toggle: {toggleErr}
        </p>
      )}
    </div>
  )
}
