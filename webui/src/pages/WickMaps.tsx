// Wick Maps — per-seed Deep Desert POI maps.
//
// The Deep Desert regenerates on the Coriolis cycle and there are 12 fixed
// preset layouts (world seeds 0-11). This page draws the POI layout for a
// chosen seed and, on load, jumps to whichever seed the server is actually
// running.
//
// The map is drawn client-side from src/data/wickmaps.json rather than shipping
// twelve rendered PNGs — it keeps the payload at ~70 KB instead of ~12 MB and
// lets the legend double as a type filter.
//
// Named for Wick (@.arturiuss), who brute-forced the 12 layouts. The seed-0
// spice pool that started the work came from DrkShrk (@drkshrk). Attribution
// stays in-app only — keep both names out of release notes and Discord embeds.

import { useEffect, useMemo, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { getCoriolisSeeds } from '../api/gameplay'
import data from '../data/wickmaps.json'

type Poi = { sector: string; subx: number; suby: number; type: string }
type LegendEntry = { type: string; label: string; count: number }
type SeedEntry = {
  seed: number
  confidence: string
  reliability: 'high' | 'medium' | 'low'
  note: string | null
  capturedUtc: string
  largeSpiceSectors: string[]
  poiCount: number
  legend: LegendEntry[]
  pois: Poi[]
}
type Payload = {
  schemaVersion: number
  generated: string
  disclaimer: string
  availableSeeds: number[]
  seeds: SeedEntry[]
}

const PAYLOAD = data as unknown as Payload

// I..A top to bottom, 1..9 left to right, each sector split into a 4x4 sub-grid
// (subx 1-4, suby 0-3) — matches how the source data is tagged.
const ROWS = ['I', 'H', 'G', 'F', 'E', 'D', 'C', 'B', 'A']
const COLS = ['1', '2', '3', '4', '5', '6', '7', '8', '9']

const GRID = 900          // px, the playable square
const PAD = 34            // gutter holding the row/column labels
const CELL = GRID / 9
const SIZE = GRID + PAD * 2

// Icon set. All markers are flat SVGs so the map reads uniformly at any zoom.
// Titanium and stravidium are built locally: their source art carries a dark
// backdrop that only works against a near-black UI, so the ore is lifted out
// and set on a diamond plate matching the spice marker. Taxi has no SVG
// equivalent in that set and keeps its PNG.
const SVG_TYPES = new Set([
  'cave', 'wreck', 'large-spice-field', 'testing-station', 'titanium', 'stravidium',
])
const ICON = (t: string) => `/wickmaps/${t}.${SVG_TYPES.has(t) ? 'svg' : 'png'}`

/** Row A is the densest row on every seed, so its icons are halved to stop
 *  neighbouring pairs from overlapping. Mirrors the PNG renderer. */
const iconSize = (row: string) => (row === 'A' ? CELL * 0.31 : CELL * 0.62)

function fmtCaptured(ts: string): string {
  if (!ts || ts.length < 8) return ts || 'unknown'
  return `${ts.slice(0, 4)}-${ts.slice(4, 6)}-${ts.slice(6, 8)}`
}

const RELIABILITY: Record<SeedEntry['reliability'], { label: string; cls: string; icon: string }> = {
  high: { label: 'High confidence', cls: 'text-ok border-ok/40', icon: 'CheckCircle2' },
  medium: { label: 'Medium confidence', cls: 'text-text-dim border-border', icon: 'CircleDashed' },
  low: { label: 'Low confidence', cls: 'text-warning border-warning/50', icon: 'AlertTriangle' },
}

export function WickMaps() {
  const [seed, setSeed] = useState<number>(PAYLOAD.availableSeeds[0] ?? 0)
  const [liveSeed, setLiveSeed] = useState<number | null>(null)
  const [liveErr, setLiveErr] = useState<string | null>(null)
  const [hidden, setHidden] = useState<Set<string>>(new Set())
  const [hover, setHover] = useState<{ x: number; y: number; text: string } | null>(null)

  // Read the seed the server is actually running. world_map_reset_seed carries
  // two naming schemes: partition names (Survival_1 / DeepDesert_1) are what an
  // admin requested, friendly names (DeepDesert) are what the game wrote back
  // after loading the map. The friendly row is the truth, so prefer it.
  useEffect(() => {
    let alive = true
    getCoriolisSeeds()
      .then(r => {
        if (!alive) return
        const maps = r.maps || []
        const friendly = maps.find(m => m.map === 'DeepDesert')
        const fallback = maps.find(m => m.map.startsWith('DeepDesert'))
        const live = friendly?.seed ?? fallback?.seed ?? null
        if (live !== null && live >= 0 && live <= 11) {
          setLiveSeed(live)
          if (PAYLOAD.availableSeeds.includes(live)) setSeed(live)
        }
      })
      .catch(e => { if (alive) setLiveErr(e instanceof Error ? e.message : String(e)) })
    return () => { alive = false }
  }, [])

  const entry = useMemo(
    () => PAYLOAD.seeds.find(s => s.seed === seed) ?? PAYLOAD.seeds[0],
    [seed],
  )

  const toggleType = (t: string) =>
    setHidden(prev => {
      const next = new Set(prev)
      if (next.has(t)) next.delete(t)
      else next.add(t)
      return next
    })

  const visible = useMemo(
    () => entry.pois.filter(p => !hidden.has(p.type)),
    [entry, hidden],
  )

  const labelFor = (t: string) =>
    entry.legend.find(l => l.type === t)?.label ?? t

  const rel = RELIABILITY[entry.reliability] ?? RELIABILITY.medium

  return (
    <div className="flex flex-col gap-4">
      <PageHeader
        title="Wick Maps"
        icon="Map"
        description="Deep Desert point-of-interest layouts for each of the 12 Coriolis world seeds."
      />

      <div className="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_340px] gap-4 items-start">
        {/* ---------------------------------------------------------------- */}
        {/* Map                                                              */}
        {/* ---------------------------------------------------------------- */}
        <div className="card p-4 overflow-hidden">
          <div className="flex items-center justify-between gap-2 mb-3 flex-wrap">
            <div className="flex items-baseline gap-3">
              <h2 className="text-sm font-semibold text-text">World Seed {entry.seed}</h2>
              <span className="text-xs text-text-dim">
                {visible.length} of {entry.poiCount} POIs
              </span>
            </div>
            <span
              className={`inline-flex items-center gap-1.5 text-[11px] px-2 py-0.5 rounded-full border ${rel.cls}`}
              title={entry.note ?? entry.confidence}
            >
              <Icon name={rel.icon} size={11} /> {rel.label}
            </span>
          </div>

          <div className="relative w-full">
            <svg
              viewBox={`0 0 ${SIZE} ${SIZE}`}
              className="w-full h-auto rounded-lg select-none"
              style={{ background: '#4a3220' }}
              role="img"
              aria-label={`Deep Desert point-of-interest map for world seed ${entry.seed}`}
              onMouseLeave={() => setHover(null)}
            >
              <defs>
                {/* Procedural sand. Two turbulence layers: a coarse one for the
                    blotchy stucco mottling, a fine one for grain. Cheaper and
                    sharper at any zoom than shipping a tiled texture. */}
                <filter id="wm-mottle" x="0" y="0" width="100%" height="100%">
                  <feTurbulence
                    type="fractalNoise" baseFrequency="0.011" numOctaves={4}
                    seed={11} result="t"
                  />
                  <feColorMatrix in="t" type="saturate" values="0" result="g" />
                  <feComponentTransfer in="g">
                    <feFuncA type="linear" slope="0.5" intercept="0" />
                  </feComponentTransfer>
                </filter>
                <filter id="wm-grain" x="0" y="0" width="100%" height="100%">
                  <feTurbulence
                    type="fractalNoise" baseFrequency="0.75" numOctaves={3}
                    seed={5} result="t"
                  />
                  <feColorMatrix in="t" type="saturate" values="0" result="g" />
                  <feComponentTransfer in="g">
                    <feFuncA type="linear" slope="0.32" intercept="0" />
                  </feComponentTransfer>
                </filter>
                <clipPath id="wm-field">
                  <rect x={PAD} y={PAD} width={GRID} height={GRID} />
                </clipPath>
              </defs>

              <rect x={0} y={0} width={SIZE} height={SIZE} fill="#4a3220" />
              <rect x={PAD} y={PAD} width={GRID} height={GRID} fill="#d5ab76" />
              <g clipPath="url(#wm-field)" style={{ mixBlendMode: 'multiply' }}>
                <rect x={PAD} y={PAD} width={GRID} height={GRID} filter="url(#wm-mottle)" />
                <rect x={PAD} y={PAD} width={GRID} height={GRID} filter="url(#wm-grain)" />
              </g>

              {/* grid lines */}
              {Array.from({ length: 10 }, (_, i) => (
                <g key={`g${i}`} stroke="#7a5433" strokeWidth={1.5} opacity={0.85}>
                  <line x1={PAD + i * CELL} y1={PAD} x2={PAD + i * CELL} y2={PAD + GRID} />
                  <line x1={PAD} y1={PAD + i * CELL} x2={PAD + GRID} y2={PAD + i * CELL} />
                </g>
              ))}
              <rect
                x={PAD} y={PAD} width={GRID} height={GRID}
                fill="none" stroke="#3d2717" strokeWidth={3}
              />

              {/* edge labels, mirrored on both sides like the in-game map */}
              {COLS.map((c, i) => (
                <g key={`c${c}`} fill="#f2e4c9" fontSize={19} fontWeight={700} textAnchor="middle">
                  <text x={PAD + (i + 0.5) * CELL} y={PAD / 2 + 7}>{c}</text>
                  <text x={PAD + (i + 0.5) * CELL} y={PAD + GRID + PAD / 2 + 7}>{c}</text>
                </g>
              ))}
              {ROWS.map((r, i) => (
                <g key={`r${r}`} fill="#f2e4c9" fontSize={19} fontWeight={700} textAnchor="middle">
                  <text x={PAD / 2} y={PAD + (i + 0.5) * CELL + 7}>{r}</text>
                  <text x={PAD + GRID + PAD / 2} y={PAD + (i + 0.5) * CELL + 7}>{r}</text>
                </g>
              ))}

              {/* POIs */}
              {visible.map((p, i) => {
                const row = p.sector[0]
                const col = Number(p.sector.slice(1))
                const ri = ROWS.indexOf(row)
                if (ri < 0 || !col) return null
                const sx = Math.min(4, Math.max(1, p.subx))
                const sy = Math.min(3, Math.max(0, p.suby))
                const cx = PAD + (col - 1) * CELL + (sx - 0.5) * (CELL / 4)
                const cy = PAD + ri * CELL + (sy + 0.5) * (CELL / 4)
                const s = iconSize(row)
                return (
                  <image
                    key={`${p.sector}-${p.type}-${i}`}
                    href={ICON(p.type)}
                    x={cx - s / 2}
                    y={cy - s / 2}
                    width={s}
                    height={s}
                    style={{ cursor: 'help' }}
                    onMouseEnter={() =>
                      setHover({ x: cx, y: cy, text: `${labelFor(p.type)} — ${p.sector}` })
                    }
                    onMouseLeave={() => setHover(null)}
                  />
                )
              })}

              {hover && (
                <g pointerEvents="none">
                  <rect
                    x={Math.min(Math.max(hover.x - 92, 4), SIZE - 188)}
                    y={Math.max(hover.y - 42, 4)}
                    width={184}
                    height={28}
                    rx={6}
                    fill="#1d130a"
                    opacity={0.94}
                  />
                  <text
                    x={Math.min(Math.max(hover.x - 92, 4), SIZE - 188) + 92}
                    y={Math.max(hover.y - 42, 4) + 19}
                    fill="#f4e9d4"
                    fontSize={14}
                    textAnchor="middle"
                  >
                    {hover.text}
                  </text>
                </g>
              )}
            </svg>
          </div>
        </div>

        {/* ---------------------------------------------------------------- */}
        {/* Side rail                                                        */}
        {/* ---------------------------------------------------------------- */}
        <div className="flex flex-col gap-4">
          {/* Seed selector */}
          <div className="card p-4">
            <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-3">
              World Seed
            </div>
            <div className="grid grid-cols-6 gap-1.5">
              {PAYLOAD.availableSeeds.map(s => {
                const active = s === seed
                const isLive = s === liveSeed
                return (
                  <button
                    key={s}
                    onClick={() => setSeed(s)}
                    title={isLive ? `Seed ${s} — currently live on this server` : `Seed ${s}`}
                    className={`relative py-2 rounded-lg text-sm font-mono border transition-colors ${
                      active
                        ? 'bg-ibad/20 border-ibad text-text'
                        : 'bg-surface-2 border-border text-text-dim hover:text-text hover:border-border-strong'
                    }`}
                  >
                    {s}
                    {isLive && (
                      <span className="absolute top-0.5 right-0.5 w-1.5 h-1.5 rounded-full bg-ok" />
                    )}
                  </button>
                )
              })}
            </div>

            <div className="mt-3 pt-3 border-t border-border/60 text-xs text-text-dim">
              {liveSeed !== null ? (
                <span className="flex items-center gap-1.5">
                  <span className="w-1.5 h-1.5 rounded-full bg-ok inline-block" />
                  Seed <strong className="text-text font-mono">{liveSeed}</strong> is live on this
                  server.
                  {liveSeed !== seed && (
                    <button className="underline hover:text-text" onClick={() => setSeed(liveSeed)}>
                      Show it
                    </button>
                  )}
                </span>
              ) : liveErr ? (
                <span className="flex items-center gap-1.5 text-warning">
                  <Icon name="AlertTriangle" size={12} /> Couldn't read the live seed.
                </span>
              ) : (
                <span>Reading the live seed…</span>
              )}
            </div>
          </div>

          {/* Legend / filter */}
          <div className="card p-4">
            <div className="flex items-center justify-between mb-3">
              <div className="text-xs font-semibold uppercase tracking-widest text-accent">
                Legend
              </div>
              {hidden.size > 0 && (
                <button
                  className="text-[11px] text-text-dim underline hover:text-text"
                  onClick={() => setHidden(new Set())}
                >
                  Show all
                </button>
              )}
            </div>
            <div className="flex flex-col gap-1">
              {entry.legend.map(l => {
                const off = hidden.has(l.type)
                return (
                  <button
                    key={l.type}
                    onClick={() => toggleType(l.type)}
                    title={off ? `Show ${l.label}` : `Hide ${l.label}`}
                    className={`flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-sm transition-colors ${
                      off
                        ? 'opacity-40 hover:opacity-70'
                        : 'hover:bg-surface-2'
                    }`}
                  >
                    <img src={ICON(l.type)} alt="" className="w-5 h-5 shrink-0" />
                    <span className="flex-1 text-left text-text">{l.label}</span>
                    <span className="font-mono text-xs text-text-dim">{l.count}</span>
                  </button>
                )
              })}
            </div>
            <p className="mt-3 pt-3 border-t border-border/60 text-[11px] text-text-dim">
              Click a row to hide or show that type on the map.
            </p>
          </div>

          {/* Per-seed detail */}
          <div className="card p-4 text-xs text-text-dim flex flex-col gap-2">
            <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-1">
              Seed {entry.seed} detail
            </div>
            <div className="flex justify-between gap-3">
              <span>Large spice fields</span>
              <span className="font-mono text-text text-right">
                {entry.largeSpiceSectors.join(', ') || '—'}
              </span>
            </div>
            <div className="flex justify-between gap-3">
              <span>Total POIs</span>
              <span className="font-mono text-text">{entry.poiCount}</span>
            </div>
            <div className="flex justify-between gap-3">
              <span>Captured</span>
              <span className="font-mono text-text">{fmtCaptured(entry.capturedUtc)}</span>
            </div>
            {entry.note && (
              <p className="mt-1 pt-2 border-t border-border/60 leading-relaxed">
                <Icon name="Info" size={11} className="inline mr-1 -mt-0.5" />
                {entry.note}
              </p>
            )}
          </div>
        </div>
      </div>

      {/* ------------------------------------------------------------------ */}
      {/* Static cards                                                       */}
      {/* ------------------------------------------------------------------ */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-stretch">
        <div className="card p-4 border-warning/30">
          <div className="text-xs font-semibold uppercase tracking-widest text-warning mb-2 flex items-center gap-1.5">
            <Icon name="AlertTriangle" size={13} /> About this data
          </div>
          <p className="text-sm text-text-dim leading-relaxed">{PAYLOAD.disclaimer}</p>
          <p className="text-xs text-text-dim leading-relaxed mt-2">
            Sub-cell positions within a sector are approximate, and the underlying spawn tables are
            probabilistic — treat sectors as reliable and exact placement as a guide.
          </p>
        </div>

        <div className="card p-4">
          <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-2">
            Source
          </div>
          <p className="text-sm text-text-dim leading-relaxed">
            Seed table by <strong className="text-text">Wick</strong>{' '}
            (<span className="font-mono">@.arturiuss</span>), who brute-forced the 12 layouts.
            Seed-0 spice pool by <strong className="text-text">DrkShrk</strong>{' '}
            (<span className="font-mono">@drkshrk</span>).
          </p>
        </div>
      </div>
    </div>
  )
}
