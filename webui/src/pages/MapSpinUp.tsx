import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  DndContext,
  PointerSensor,
  KeyboardSensor,
  useSensor,
  useSensors,
  closestCenter,
  type DragEndEvent,
} from '@dnd-kit/core'
import {
  SortableContext,
  arrayMove,
  sortableKeyboardCoordinates,
  useSortable,
  rectSortingStrategy,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import { getMapSpinUp, setMapSpinUp, type SpinUpMap } from '../api/mapSpinUp'
import { fixOnDemandPartitions, getMapState, restartMapPods, type MapState } from '../api/maps'

// Map SpinUp section names → on-demand map keys that expose a live, schedulable
// pod state via GET /api/maps/{key}. Only these three report whether a pod is
// actually coming up, so only they get the loading counter + failure diagnosis.
// Every other map can only reflect the director.ini MinServers floor.
const ON_DEMAND_KEY: Record<string, string> = {
  DeepDesert_1: 'deepdesert',
  SH_Arrakeen: 'arakeen',
  SH_HarkoVillage: 'harkovillage',
}

// How often to poll the pod state, and how long to wait before declaring the
// spin-up stuck. Cold maps usually settle in ~1-3 min; 5 min is a safe ceiling.
const LOAD_POLL_MS = 5000
const LOAD_TIMEOUT_MS = 300000

// Turn a not-yet-running MapState into a plain-English reason. Mirrors the same
// failure modes Get-DuneOnDemandMapState computes server-side.
function diagnoseStuck(s: MapState): string {
  if (s.missingPartitionBinding || s.hasDisabledPart || s.stuckDedicatedScaling) {
    return 'its on-demand partitions are still pinned/disabled in the battlegroup. Click “Fix partitions”, then try again.'
  }
  if (!s.present) {
    return 'this map set is not in the battlegroup CRD. Add it via the Battlegroup editor first.'
  }
  if (s.totalReplicas < 1) {
    return 'the director never scheduled a pod — usually the Hyper-V VM has no free RAM to start another map. Free memory (spin a map down) and retry.'
  }
  return 'the pod has not reported ready in time. It may still be loading, or the director is reconciling — give it a moment and Refresh.'
}

function fmtElapsed(sec: number): string {
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return `${m}:${s.toString().padStart(2, '0')}`
}

// Most-used maps pinned to the front by default — these fill the first row.
// Everything else keeps the backend's order beneath them. Users can drag any
// card to reorder; the custom order is saved per-browser in localStorage.
const PRIORITY = ['DeepDesert_1', 'SH_Arrakeen', 'SH_HarkoVillage']
const ORDER_KEY = 'dst.mapspinup.order.v1'

function defaultOrder(maps: SpinUpMap[]): string[] {
  const keys = maps.map(m => m.map)
  const pinned = PRIORITY.filter(k => keys.includes(k))
  const rest = keys.filter(k => !PRIORITY.includes(k))
  return [...pinned, ...rest]
}

function loadSavedOrder(): string[] | null {
  try {
    const raw = localStorage.getItem(ORDER_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) && parsed.every(x => typeof x === 'string') ? parsed : null
  } catch {
    return null
  }
}

// Merge a saved order with the live map list: keep saved keys still present (in
// their saved order), then append any new maps in default (priority) order.
function reconcileOrder(saved: string[] | null, maps: SpinUpMap[]): string[] {
  const def = defaultOrder(maps)
  if (!saved) return def
  const present = new Set(maps.map(m => m.map))
  const kept = saved.filter(k => present.has(k))
  const keptSet = new Set(kept)
  const added = def.filter(k => !keptSet.has(k))
  return [...kept, ...added]
}

export function MapSpinUp() {
  const [maps, setMaps] = useState<SpinUpMap[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [fixBusy, setFixBusy] = useState(false)
  const [fixLog, setFixLog] = useState<string | null>(null)
  const [restartBusy, setRestartBusy] = useState<string | null>(null)
  const [order, setOrder] = useState<string[] | null>(null)
  // Live pod-readiness tracking for the on-demand maps. `tracking` holds the
  // spin-up start time per map; `loadElapsed` is the per-second tick the cards
  // render; `loadErrors` carries the diagnosed reason a map failed to come up.
  const [tracking, setTracking] = useState<Record<string, { startedAt: number }>>({})
  const [loadElapsed, setLoadElapsed] = useState<Record<string, number>>({})
  const [loadErrors, setLoadErrors] = useState<Record<string, string>>({})
  const pollMeta = useRef<Record<string, { lastPoll: number; inFlight: boolean }>>({})

  const stopTracking = useCallback((mapName: string) => {
    delete pollMeta.current[mapName]
    setTracking(prev => { const n = { ...prev }; delete n[mapName]; return n })
    setLoadElapsed(prev => { const n = { ...prev }; delete n[mapName]; return n })
  }, [])

  const startTracking = useCallback((mapName: string) => {
    if (!ON_DEMAND_KEY[mapName]) return
    pollMeta.current[mapName] = { lastPoll: 0, inFlight: false }
    setLoadErrors(prev => { const n = { ...prev }; delete n[mapName]; return n })
    setTracking(prev => ({ ...prev, [mapName]: { startedAt: Date.now() } }))
  }, [])

  const dismissLoadError = useCallback((mapName: string) => {
    setLoadErrors(prev => { const n = { ...prev }; delete n[mapName]; return n })
  }, [])

  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getMapSpinUp()
      setMaps(r.maps ?? [])
    } catch (e) {
      setMaps(null)
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void refresh() }, [refresh])

  const onToggle = useCallback(async (m: SpinUpMap, next: boolean) => {
    setBusy(m.map); setMessage(null); setError(null)
    if (!next) { stopTracking(m.map); dismissLoadError(m.map) }
    // optimistic
    setMaps(prev => prev?.map(x => x.map === m.map ? { ...x, enabled: next, minServers: next ? 1 : 0 } : x) ?? prev)
    try {
      const r = await setMapSpinUp(m.map, next)
      setMessage(r.message ?? (next ? `${m.label} spin-up enabled.` : `${m.label} spin-up disabled.`))
      if (!r.ok) setError(r.message ?? 'The change may not have applied.')
      await refresh()
      // Once the floor is set, watch the pod actually come up (on-demand maps only).
      if (next && r.ok && ON_DEMAND_KEY[m.map]) startTracking(m.map)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
      await refresh()
    } finally {
      setBusy(null)
    }
  }, [refresh, startTracking, stopTracking, dismissLoadError])

  // Drive the loading counter + readiness polling for any tracked map. Ticks
  // once a second for the elapsed display and polls the live pod state every
  // LOAD_POLL_MS until it's running, times out, or the read fails.
  useEffect(() => {
    const names = Object.keys(tracking)
    if (names.length === 0) return
    const id = window.setInterval(() => {
      const now = Date.now()
      setLoadElapsed(() => {
        const next: Record<string, number> = {}
        for (const name of Object.keys(tracking)) {
          next[name] = Math.floor((now - tracking[name].startedAt) / 1000)
        }
        return next
      })
      for (const name of Object.keys(tracking)) {
        const key = ON_DEMAND_KEY[name]
        const meta = pollMeta.current[name]
        if (!key || !meta || meta.inFlight || now - meta.lastPoll < LOAD_POLL_MS) continue
        const elapsed = now - tracking[name].startedAt
        meta.lastPoll = now
        meta.inFlight = true
        getMapState(key).then(s => {
          if (pollMeta.current[name]) pollMeta.current[name].inFlight = false
          if (s.running) {
            stopTracking(name)
            setMessage(`${s.label ?? name} pod is up (took ${fmtElapsed(Math.floor(elapsed / 1000))}).`)
            void refresh()
          } else if (elapsed >= LOAD_TIMEOUT_MS) {
            stopTracking(name)
            setLoadErrors(prev => ({ ...prev, [name]: `${s.label ?? name} didn’t come up: ${diagnoseStuck(s)}` }))
          }
        }).catch(e => {
          if (pollMeta.current[name]) pollMeta.current[name].inFlight = false
          stopTracking(name)
          const msg = e instanceof ApiError ? e.message : String(e)
          setLoadErrors(prev => ({ ...prev, [name]: `${name} couldn’t load: ${msg}` }))
        })
      }
    }, 1000)
    return () => window.clearInterval(id)
  }, [tracking, refresh, stopTracking])

  const onFixPartitions = useCallback(async () => {
    const ok = window.confirm(
      'Clear stuck partition pins on the on-demand maps (Deep Desert, Arrakeen, '
      + 'Harko Village) so the director can re-assign partitions and spin them up '
      + 'on demand?\n\n'
      + 'Safety:\n'
      + '• Only those 3 maps are touched. Overmap and Survival_1 are never affected.\n'
      + '• Any map with a running pod is skipped — no live session will be disturbed.\n'
      + '• Partitions are re-assigned by the director on next spawn.\n\n'
      + 'Use this when a map refuses to launch after a reboot or BG restart.',
    )
    if (!ok) return
    setFixBusy(true); setMessage(null); setError(null); setFixLog(null)
    try {
      const r = await fixOnDemandPartitions()
      setMessage(r.message ?? 'Partition cleanup ran.')
      const tail = (r.logTail && r.logTail.trim().length > 0) ? r.logTail : (r.output ?? '')
      setFixLog(tail || null)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setFixBusy(false)
    }
  }, [])

  const onRestartPods = useCallback(async (key: 'survival' | 'deepdesert', label: string) => {
    const ok = window.confirm(
      `Restart the ${label} pod(s)?\n\n`
      + 'This deletes the running Kubernetes pod(s); the operator recreates them '
      + 'fresh in about 60-120 seconds.\n\n'
      + 'Anyone currently on the map will be disconnected. '
      + (key === 'survival'
        ? 'Survival_1 hosts the persistent Hagga overworld, so this affects the main world.'
        : 'Use this when Deep Desert is stuck or misbehaving.'),
    )
    if (!ok) return
    setRestartBusy(key); setMessage(null); setError(null); setFixLog(null)
    try {
      const r = await restartMapPods(key)
      setMessage(r.message ?? `${label} restart requested.`)
      if (!r.ok) setError(r.message ?? 'The restart may not have applied.')
      if (r.raw) setFixLog(r.raw)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setRestartBusy(null)
    }
  }, [])

  // Reconcile the saved drag-order against the live map list whenever maps load.
  useEffect(() => {
    if (!maps) return
    setOrder(reconcileOrder(loadSavedOrder(), maps))
  }, [maps])

  const orderedMaps = useMemo<SpinUpMap[]>(() => {
    if (!maps) return []
    const byKey = new Map(maps.map(m => [m.map, m]))
    const seq = order ?? defaultOrder(maps)
    const out = seq.map(k => byKey.get(k)).filter((m): m is SpinUpMap => Boolean(m))
    // Defensive: append any map missing from the order sequence.
    for (const m of maps) if (!seq.includes(m.map)) out.push(m)
    return out
  }, [maps, order])

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  const onDragEnd = useCallback((e: DragEndEvent) => {
    const { active, over } = e
    if (!over || active.id === over.id) return
    setOrder(prev => {
      const base = prev ?? (maps ? defaultOrder(maps) : [])
      const oldIdx = base.indexOf(String(active.id))
      const newIdx = base.indexOf(String(over.id))
      if (oldIdx < 0 || newIdx < 0) return prev
      const next = arrayMove(base, oldIdx, newIdx)
      try { localStorage.setItem(ORDER_KEY, JSON.stringify(next)) } catch { /* ignore */ }
      return next
    })
  }, [maps])

  const resetOrder = useCallback(() => {
    try { localStorage.removeItem(ORDER_KEY) } catch { /* ignore */ }
    setOrder(maps ? defaultOrder(maps) : null)
  }, [maps])

  const isCustomOrder = useMemo(() => {
    if (!maps || !order) return false
    const def = defaultOrder(maps)
    return order.length !== def.length || order.some((k, i) => k !== def[i])
  }, [maps, order])

  return (
    <>
      <PageHeader
        title="Map SpinUp"
        icon="Power"
        description="Keep at least one server warm for a map (MinServers = 1). Hot-swappable — no restart needed. Drag the grip on any card to reorder; your layout is saved in this browser."
        actions={
          <>
            {isCustomOrder && (
              <button
                className="btn-secondary"
                onClick={resetOrder}
                disabled={loading || busy !== null || fixBusy}
                title="Restore the default card order (Deep Desert, Arrakeen, Harko Village first)."
              >
                <Icon name="RotateCcw" size={14} /> Reset order
              </button>
            )}
            <button
              className="btn-secondary"
              onClick={() => { void onFixPartitions() }}
              disabled={loading || busy !== null || fixBusy}
              title="Clear stuck igwsss.spec.partitions pins on Deep Desert / Arrakeen / Harko Village. Safe — only touches those 3 maps, skips any with a running pod, and never touches Overmap or Survival_1."
            >
              <Icon name={fixBusy ? 'Loader2' : 'Wrench'} size={15} className={fixBusy ? 'animate-spin' : ''} />
              {fixBusy ? 'Fixing…' : 'Fix partitions'}
            </button>
            <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading || busy !== null || fixBusy}>
              <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
            </button>
          </>
        }
      />

      <div className="mb-4 flex flex-wrap items-center justify-center gap-3">
        <button
          className="btn-secondary"
          onClick={() => { void onRestartPods('survival', 'Hagga (Survival_1)') }}
          disabled={loading || busy !== null || fixBusy || restartBusy !== null}
          title="Delete and recreate the Survival_1 (Hagga overworld) pod(s). Disconnects anyone on the main world; the operator brings them back in ~60-120s."
        >
          <Icon name={restartBusy === 'survival' ? 'Loader2' : 'RotateCcw'} size={15} className={restartBusy === 'survival' ? 'animate-spin' : ''} />
          {restartBusy === 'survival' ? 'Restarting…' : 'Restart Hagga'}
        </button>
        <button
          className="btn-secondary"
          onClick={() => { void onRestartPods('deepdesert', 'Deep Desert') }}
          disabled={loading || busy !== null || fixBusy || restartBusy !== null}
          title="Delete and recreate the DeepDesert_1 pod(s). Disconnects anyone in Deep Desert; the operator brings them back in ~60-120s."
        >
          <Icon name={restartBusy === 'deepdesert' ? 'Loader2' : 'RotateCcw'} size={15} className={restartBusy === 'deepdesert' ? 'animate-spin' : ''} />
          {restartBusy === 'deepdesert' ? 'Restarting…' : 'Restart Deep Desert'}
        </button>
      </div>

      <div className="mb-4 rounded-lg border border-warning/60 bg-warning/15 px-4 py-3 flex items-start gap-3">
        <Icon name="AlertTriangle" size={20} className="shrink-0 mt-0.5 text-warning" />
        <div className="text-sm text-warning">
          <div className="font-bold uppercase tracking-wide mb-1">RAM requirement</div>
          <span className="text-warning/90">
            Because the RAM allocated to each map can be customized, some maps may not spin up if the
            Hyper-V VM doesn't have enough memory to support all of them at once. OverMap, Hagga, and
            DeepDesert alone can consume <strong>31–35 GB</strong> at the default level — adjust
            accordingly. Maps will <strong>not</strong> spin down while a player is present, and they
            also scale on demand when a player tries to enter (though that player may see a longer
            load while the map spins up). On-demand is the recommended approach; this Map SpinUp page
            simply lets you start the spawn process ahead of time, before you arrive, if desired.
          </span>
        </div>
      </div>

      {error && (
        <div className="card p-4 mb-4 border-danger/40">
          <p className="text-sm text-danger break-words">{error}</p>
        </div>
      )}
      {message && (
        <div className="card p-4 mb-4 border-accent/40">
          <p className="text-sm text-text">{message}</p>
          {fixLog && (
            <pre className="mt-3 text-[11px] leading-snug text-text-dim font-mono whitespace-pre-wrap break-words max-h-60 overflow-auto border-t border-border/40 pt-2">
              {fixLog}
            </pre>
          )}
        </div>
      )}

      {!maps ? (
        <div className="card p-6">
          <p className="text-sm text-text-dim italic">{loading ? 'Loading…' : 'No data yet.'}</p>
        </div>
      ) : (
        <>
          <MapGroup
            title="Maps"
            hint="These keep at least one server warm (MinServers = 1). Some maps don't ship MinServers natively — enabling those may be ignored by the director, or may keep an instance warm and consume RAM. Use with care."
            maps={orderedMaps}
            busy={busy}
            onToggle={onToggle}
            loadElapsed={loadElapsed}
            loadErrors={loadErrors}
            onDismissError={dismissLoadError}
            sensors={sensors}
            onDragEnd={onDragEnd}
          />
        </>
      )}
    </>
  )
}

function MapGroup({ title, hint, tone = 'text', maps, busy, onToggle, loadElapsed, loadErrors, onDismissError, sensors, onDragEnd }: {
  title: string
  hint: string
  tone?: 'text' | 'warning'
  maps: SpinUpMap[]
  busy: string | null
  onToggle: (m: SpinUpMap, next: boolean) => void
  loadElapsed: Record<string, number>
  loadErrors: Record<string, string>
  onDismissError: (mapName: string) => void
  sensors: ReturnType<typeof useSensors>
  onDragEnd: (e: DragEndEvent) => void
}) {
  if (maps.length === 0) return null
  const headColor = tone === 'warning' ? 'text-warning' : 'text-text-muted'
  return (
    <section className="mb-6">
      <h2 className={`text-sm font-semibold uppercase tracking-wider mb-1 flex items-center gap-2 ${headColor}`}>
        {tone === 'warning' && <Icon name="AlertTriangle" size={14} className="text-warning" />}
        {title}
      </h2>
      <p className="text-xs text-text-dim mb-3 max-w-3xl">{hint}</p>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <SortableContext items={maps.map(m => m.map)} strategy={rectSortingStrategy}>
          <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
            {maps.map(m => (
              <SortableMapCard
                key={m.map}
                map={m}
                busy={busy}
                onToggle={onToggle}
                elapsed={loadElapsed[m.map]}
                loadError={loadErrors[m.map]}
                onDismissError={onDismissError}
              />
            ))}
          </div>
        </SortableContext>
      </DndContext>
    </section>
  )
}

function SortableMapCard({ map: m, busy, onToggle, elapsed, loadError, onDismissError }: {
  map: SpinUpMap
  busy: string | null
  onToggle: (m: SpinUpMap, next: boolean) => void
  elapsed?: number
  loadError?: string
  onDismissError: (mapName: string) => void
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: m.map })
  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.4 : busy === m.map ? 0.6 : undefined,
  }
  const loading = elapsed !== undefined
  return (
    <div
      ref={setNodeRef}
      style={style}
      className="card p-4 flex flex-col gap-2"
    >
      <div className="flex items-center gap-3">
        <button
          type="button"
          className="shrink-0 -ml-1 p-1 text-text-dim hover:text-text cursor-grab active:cursor-grabbing touch-none"
          title="Drag to reorder"
          {...attributes}
          {...listeners}
        >
          <Icon name="GripVertical" size={16} />
        </button>
        <label className="flex items-center justify-between gap-3 flex-1 min-w-0 cursor-pointer">
          <div className="min-w-0">
            <div className="text-sm font-semibold truncate">{m.label}</div>
            <div className="text-xs text-text-dim font-mono truncate">{m.map}</div>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            {loading ? (
              <span className="pill-warning" title="Waiting for the map pod to come up">
                <Icon name="Loader2" size={10} className="animate-spin" /> Loading… {fmtElapsed(elapsed)}
              </span>
            ) : (
              <span className={m.enabled ? 'pill-success' : 'pill-muted'}>
                {m.enabled ? 'Warm' : 'Off'}
              </span>
            )}
            <input
              type="checkbox"
              className="h-4 w-4 accent-accent"
              checked={m.enabled}
              disabled={busy !== null || loading}
              onChange={e => onToggle(m, e.target.checked)}
            />
          </div>
        </label>
      </div>
      {loadError && (
        <div className="flex items-start gap-2 rounded-md border border-danger/40 bg-danger/10 px-2.5 py-1.5 text-xs text-danger">
          <Icon name="AlertTriangle" size={13} className="shrink-0 mt-0.5" />
          <span className="flex-1 break-words">{loadError}</span>
          <button
            type="button"
            className="shrink-0 text-danger/70 hover:text-danger"
            title="Dismiss"
            onClick={() => onDismissError(m.map)}
          >
            <Icon name="X" size={13} />
          </button>
        </div>
      )}
    </div>
  )
}
