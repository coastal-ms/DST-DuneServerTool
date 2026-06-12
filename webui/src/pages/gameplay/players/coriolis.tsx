// CoriolisAdmin — v11.5.7 storm seed inspector + editor.
//
// Lives in the Server Overview pane (Players tab, no player selected) so admins
// can see + override the world-reset seed at three scopes:
//   - farm   (cascades to every map + partition)
//   - map    (cascades to that map's partitions)
//   - partition (single partition only)
//
// Backed by /api/gameplay/coriolis/* which wraps Postgres dune.debug_set_*
// functions. Read endpoint returns 'source: demo' when the live DB is offline
// or the debug_get_coriolis_seeds() routine isn't available.

import { useEffect, useState } from 'react'
import { Icon } from '../../../components/Icon'
import {
  getCoriolisSeeds, setCoriolisFarmSeed, setCoriolisMapSeed, setCoriolisPartitionSeed,
  type CoriolisMap, type CoriolisPartition, type DataSource,
} from '../../../api/gameplay'

type Flash = (msg: string, kind?: 'ok' | 'err') => void

export function CoriolisAdmin({ flash }: { flash: Flash }) {
  const [loading, setLoading]   = useState(true)
  const [err, setErr]           = useState<string | null>(null)
  const [source, setSource]     = useState<DataSource>('demo')
  const [farmSeed, setFarmSeed] = useState(0)
  const [maps, setMaps]         = useState<CoriolisMap[]>([])
  const [parts, setParts]       = useState<CoriolisPartition[]>([])
  const [busy, setBusy]         = useState(false)
  const [tick, setTick]         = useState(0)

  // Per-scope draft inputs.
  const [farmDraft, setFarmDraft]               = useState('')
  const [mapDrafts, setMapDrafts]               = useState<Record<string, string>>({})
  const [partDrafts, setPartDrafts]             = useState<Record<number, string>>({})

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getCoriolisSeeds()
      .then(r => {
        if (!alive) return
        setSource(r.source)
        setFarmSeed(r.farm_seed)
        setMaps(r.maps || [])
        setParts(r.partitions || [])
        setFarmDraft(String(r.farm_seed))
        const md: Record<string, string> = {}
        for (const m of r.maps || []) md[m.map] = String(m.seed)
        setMapDrafts(md)
        const pd: Record<number, string> = {}
        for (const p of r.partitions || []) pd[p.partition_id] = String(p.seed)
        setPartDrafts(pd)
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [tick])

  const run = async (fn: () => Promise<{ message: string }>, label: string) => {
    setBusy(true)
    try {
      const r = await fn()
      flash(r.message || `${label} done.`, 'ok')
      setTick(t => t + 1)
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  const applyFarm = () => {
    const seed = Number(farmDraft)
    if (!Number.isFinite(seed) || seed < 0) return flash('Farm seed must be a non-negative integer.', 'err')
    if (!confirm(`Set FARM coriolis seed to ${seed}?\n\nThis cascades to every map + partition and (when changed) cleans up corpses / coriolis-affected loose state.`)) return
    run(() => setCoriolisFarmSeed(seed), 'Set farm seed')
  }
  const applyMap = (map: string) => {
    const seed = Number(mapDrafts[map])
    if (!Number.isFinite(seed) || seed < 0) return flash(`Map seed for ${map} must be a non-negative integer.`, 'err')
    if (!confirm(`Set MAP "${map}" coriolis seed to ${seed}?\n\nCascades to that map's partitions.`)) return
    run(() => setCoriolisMapSeed(map, seed), `Set ${map} seed`)
  }
  const applyPart = (p: CoriolisPartition) => {
    const seed = Number(partDrafts[p.partition_id])
    if (!Number.isFinite(seed) || seed < 0) return flash(`Partition seed must be a non-negative integer.`, 'err')
    if (!confirm(`Set PARTITION ${p.partition_id} (${p.map}) coriolis seed to ${seed}?`)) return
    run(() => setCoriolisPartitionSeed(p.partition_id, seed), `Set partition ${p.partition_id} seed`)
  }
  const reroll = () => {
    const seed = Math.floor(Math.random() * 2_000_000_000) + 1
    setFarmDraft(String(seed))
  }
  const stay = () => setFarmDraft(String(farmSeed))

  if (loading) {
    return (
      <div className="card p-4 text-sm text-text-dim flex items-center gap-2">
        <Icon name="Loader2" size={13} className="animate-spin" /> Loading coriolis storm seeds…
      </div>
    )
  }
  if (err) {
    return <div className="card p-3 text-sm text-danger">Coriolis: {err}</div>
  }

  return (
    <div className="card p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2 text-xs uppercase tracking-wider text-text-dim">
          <Icon name="Wind" size={13} /> Coriolis Storm Seeds
          {source === 'demo' && (
            <span className="ml-2 px-1.5 py-0.5 rounded bg-warning/10 text-warning text-[10px] uppercase">demo</span>
          )}
        </div>
        <button className="btn-secondary text-[11px]" disabled={busy} onClick={() => setTick(t => t + 1)}>
          <Icon name="RefreshCw" size={11} /> Refresh
        </button>
      </div>

      <p className="text-xs text-text-dim">
        World-reset seeds drive Coriolis storm layout (spawns, dunes, loot scatter). Changing a seed
        triggers cleanup (corpses, loose loot) on next storm tick. Use <em>Stay on current</em> to
        lock the layout across resets, or <em>Reroll</em> to pick a fresh random one.
      </p>

      {/* Farm scope */}
      <div className="rounded-lg border border-border bg-surface-2/40 p-3 space-y-2">
        <div className="flex items-center justify-between">
          <div className="text-sm font-medium text-text">Farm (all maps)</div>
          <div className="font-mono text-xs text-text-dim">current: {farmSeed}</div>
        </div>
        <div className="flex items-center gap-2">
          <input
            type="number"
            min={0}
            value={farmDraft}
            onChange={e => setFarmDraft(e.target.value)}
            disabled={busy}
            className="flex-1 px-3 py-2 rounded-lg bg-surface-1 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            placeholder="seed"
          />
          <button className="btn-secondary text-xs" disabled={busy} onClick={reroll} title="Pick a fresh random seed">
            <Icon name="Shuffle" size={12} /> Reroll
          </button>
          <button className="btn-secondary text-xs" disabled={busy} onClick={stay} title="Reset draft to current seed (no change on apply)">
            <Icon name="Lock" size={12} /> Stay
          </button>
          <button className="btn-primary text-xs" disabled={busy || farmDraft === ''} onClick={applyFarm}>
            <Icon name="Check" size={12} /> Apply
          </button>
        </div>
      </div>

      {/* Per-map scope */}
      {maps.length > 0 && (
        <div className="rounded-lg border border-border bg-surface-2/40 p-3 space-y-2">
          <div className="text-sm font-medium text-text">Per map</div>
          <div className="space-y-2">
            {maps.map(m => (
              <div key={m.map} className="flex items-center gap-2">
                <div className="w-32 text-xs text-text truncate" title={m.map}>{m.map}</div>
                <span className="font-mono text-[11px] text-text-dim w-24">cur: {m.seed}</span>
                <input
                  type="number"
                  min={0}
                  value={mapDrafts[m.map] ?? ''}
                  onChange={e => setMapDrafts(d => ({ ...d, [m.map]: e.target.value }))}
                  disabled={busy}
                  className="flex-1 px-3 py-1.5 rounded-lg bg-surface-1 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
                />
                <button className="btn-secondary text-xs" disabled={busy} onClick={() => applyMap(m.map)}>
                  <Icon name="Check" size={11} /> Apply
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Per-partition scope */}
      {parts.length > 0 && (
        <details className="rounded-lg border border-border bg-surface-2/40 p-3">
          <summary className="text-sm font-medium text-text cursor-pointer select-none">
            Per partition ({parts.length})
          </summary>
          <div className="mt-2 space-y-2 max-h-72 overflow-y-auto pr-1">
            {parts.map(p => (
              <div key={p.partition_id} className="flex items-center gap-2">
                <div className="w-12 text-xs text-text-dim font-mono">#{p.partition_id}</div>
                <div className="w-28 text-xs text-text truncate" title={p.map}>{p.map}</div>
                <span className="font-mono text-[11px] text-text-dim w-24">cur: {p.seed}</span>
                <input
                  type="number"
                  min={0}
                  value={partDrafts[p.partition_id] ?? ''}
                  onChange={e => setPartDrafts(d => ({ ...d, [p.partition_id]: e.target.value }))}
                  disabled={busy}
                  className="flex-1 px-3 py-1.5 rounded-lg bg-surface-1 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
                />
                <button className="btn-secondary text-xs" disabled={busy} onClick={() => applyPart(p)}>
                  <Icon name="Check" size={11} /> Apply
                </button>
              </div>
            ))}
          </div>
        </details>
      )}
    </div>
  )
}
