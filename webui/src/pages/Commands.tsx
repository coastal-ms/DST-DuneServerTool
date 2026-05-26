import { useEffect, useMemo, useRef, useState } from 'react'
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
  verticalListSortingStrategy,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import type { Command, CommandsResponse } from '../api/types'

type LaunchResult = {
  ok: boolean
  name: string
  mode: string
  pid: number | null
  started: string
}

const SECTION_ORDER: Command['section'][] = ['VM', 'Battlegroup', 'Tools']
const SECTION_ICONS: Record<Command['section'], string> = {
  VM: 'HardDrive',
  Battlegroup: 'Activity',
  Tools: 'Wrench',
}

function SortableCommandButton({
  cmd, onRun, busy,
}: { cmd: Command; onRun: (c: Command) => void; busy: boolean }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: cmd.name })

  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.55 : undefined,
    zIndex: isDragging ? 10 : undefined,
  }

  const disabled = !cmd.available || busy

  return (
    <div
      ref={setNodeRef}
      style={style}
      className={`group card card-hover p-3 flex items-stretch gap-2 ${
        isDragging ? 'border-accent/60 shadow-lg shadow-accent/20' : ''
      } ${disabled ? 'opacity-60' : ''}`}
    >
      {/* Drag handle — only this triggers a drag, so the rest of the card is still clickable */}
      <button
        type="button"
        aria-label={`Reorder ${cmd.name}`}
        title="Drag to reorder"
        {...attributes}
        {...listeners}
        className="shrink-0 -ml-1 flex items-center justify-center w-6 text-text-dim
                   hover:text-accent cursor-grab active:cursor-grabbing
                   focus:outline-none focus:text-accent touch-none"
      >
        <Icon name="GripVertical" size={14} />
      </button>

      {/* Clickable launch surface */}
      <button
        type="button"
        disabled={disabled}
        onClick={() => onRun(cmd)}
        title={cmd.available ? cmd.desc : (cmd.reason || cmd.desc)}
        className="flex-1 text-left disabled:cursor-not-allowed"
      >
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <kbd className="shrink-0 inline-flex items-center justify-center w-5 h-5 rounded
                            bg-surface-3 border border-border text-[10px] font-mono text-text-dim
                            group-hover:text-text-muted group-hover:border-border-bright">
              {cmd.key}
            </kbd>
            <span className="font-mono text-sm truncate text-text">{cmd.name}</span>
          </div>
          <span className={
            cmd.mode === 'Console' ? 'pill-info shrink-0' : 'pill-muted shrink-0'
          }>
            <Icon name={cmd.mode === 'Console' ? 'SquareTerminal' : 'Zap'} size={10} />
            {cmd.mode}
          </span>
        </div>
        <p className="mt-1.5 text-xs text-text-muted line-clamp-2">{cmd.desc}</p>
        {!cmd.available && cmd.reason && (
          <p className="mt-1 text-[11px] text-warning/80 flex items-center gap-1">
            <Icon name="AlertTriangle" size={10} /> {cmd.reason}
          </p>
        )}
      </button>
    </div>
  )
}

export function Commands() {
  const { forceRefresh } = useStatus()
  const cmdsState = useApi<CommandsResponse>('/api/commands', { intervalMs: 30_000 })

  const [running, setRunning] = useState<Set<string>>(new Set())
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; msg: string } | null>(null)
  // Local order overlay applied on top of server data; lets us reflect drags
  // instantly without round-tripping through useApi's refresh cycle.
  const [localOrder, setLocalOrder] = useState<string[] | null>(null)
  const [savingOrder, setSavingOrder] = useState(false)
  const saveTimer = useRef<number | null>(null)

  // Reset the local overlay whenever the server returns a new authoritative order.
  useEffect(() => {
    setLocalOrder(null)
  }, [cmdsState.data?.order])

  function showToast(kind: 'ok' | 'err', msg: string) {
    setToast({ kind, msg })
    window.setTimeout(() => setToast(t => (t?.msg === msg ? null : t)), 4000)
  }

  async function runCommand(c: Command) {
    setRunning(s => new Set(s).add(c.name))
    try {
      const r = await api<LaunchResult>(`/api/commands/run/${encodeURIComponent(c.name)}`, { method: 'POST' })
      showToast('ok', `Launched '${r.name}'${r.pid ? ` (PID ${r.pid})` : ''} in a new console window.`)
      window.setTimeout(() => { void forceRefresh(); void cmdsState.refresh() }, 1500)
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      showToast('err', `Launch failed: ${msg}`)
    } finally {
      setRunning(s => { const n = new Set(s); n.delete(c.name); return n })
    }
  }

  const ordered = useMemo(() => {
    const commands = cmdsState.data?.commands ?? []
    const effectiveOrder = localOrder ?? cmdsState.data?.order
    if (!Array.isArray(effectiveOrder) || effectiveOrder.length === 0) return commands
    const byName = new Map(commands.map(c => [c.name, c]))
    const result: Command[] = []
    for (const n of effectiveOrder) { const c = byName.get(n); if (c) { result.push(c); byName.delete(n) } }
    return [...result, ...byName.values()]
  }, [cmdsState.data, localOrder])

  const grouped = useMemo(() => {
    const g: Record<Command['section'], Command[]> = { VM: [], Battlegroup: [], Tools: [] }
    for (const c of ordered) {
      if (g[c.section]) g[c.section].push(c)
    }
    return g
  }, [ordered])

  // Debounced PUT to /api/commands/order. Caller passes the new full flat order.
  function persistOrder(newOrder: string[]) {
    if (saveTimer.current) window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(async () => {
      setSavingOrder(true)
      try {
        await api('/api/commands/order', { method: 'PUT', body: JSON.stringify({ order: newOrder }) })
        // Soft refresh so subsequent updates start from server truth.
        void cmdsState.refresh()
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        showToast('err', `Failed to save layout: ${msg}`)
      } finally {
        setSavingOrder(false)
      }
    }, 400)
  }

  function handleDragEnd(section: Command['section'], e: DragEndEvent) {
    const { active, over } = e
    if (!over || active.id === over.id) return
    const items = grouped[section]
    const oldIndex = items.findIndex(c => c.name === active.id)
    const newIndex = items.findIndex(c => c.name === over.id)
    if (oldIndex < 0 || newIndex < 0) return
    const reordered = arrayMove(items, oldIndex, newIndex)
    // Build new full-flat order by replacing this section's slice.
    const next: Command[] = []
    for (const s of SECTION_ORDER) {
      if (s === section) next.push(...reordered)
      else next.push(...grouped[s])
    }
    const names = next.map(c => c.name)
    setLocalOrder(names)
    persistOrder(names)
  }

  async function resetLayout() {
    if (!window.confirm('Reset the Commands page to its default layout?')) return
    setSavingOrder(true)
    try {
      await api('/api/commands/order/reset', { method: 'POST' })
      setLocalOrder(null)
      await cmdsState.refresh()
      showToast('ok', 'Layout reset to default.')
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      showToast('err', `Reset failed: ${msg}`)
    } finally {
      setSavingOrder(false)
    }
  }

  const sensors = useSensors(
    // 6px activation distance — distinguishes a click from a drag so the launch
    // button under the card body doesn't fire when the user grabs the handle.
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  return (
    <>
      <PageHeader
        title="Commands"
        icon="Zap"
        description="Quick actions for the VM, battlegroup, and supporting tools. Drag the grip on any card to reorder within a section."
        actions={
          <div className="flex items-center gap-2">
            {savingOrder && (
              <span className="text-xs text-text-dim flex items-center gap-1">
                <Icon name="Loader2" size={12} className="animate-spin" /> Saving layout…
              </span>
            )}
            <button
              className="btn-secondary"
              onClick={resetLayout}
              disabled={savingOrder}
              title="Reset to default layout"
            >
              <Icon name="RotateCcw" size={14} /> Reset layout
            </button>
            <button
              className="btn-secondary"
              onClick={() => { void cmdsState.refresh(); void forceRefresh() }}
              disabled={cmdsState.loading}
            >
              <Icon name="RefreshCw" size={15} className={cmdsState.loading ? 'animate-spin' : ''} /> Refresh
            </button>
          </div>
        }
      />

      {toast && (
        <div className={`card p-3 mb-4 text-sm flex items-center gap-2 ${
          toast.kind === 'ok'
            ? 'border-success/40 bg-success/10 text-success'
            : 'border-danger/40 bg-danger/10 text-danger'
        }`}>
          <Icon name={toast.kind === 'ok' ? 'CheckCircle2' : 'AlertCircle'} size={14} />
          {toast.msg}
        </div>
      )}

      {cmdsState.error && (
        <div className="card p-3 mb-4 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {cmdsState.error}
        </div>
      )}

      <section className="space-y-5">
        {SECTION_ORDER.map(section => {
          const items = grouped[section]
          if (!items || items.length === 0) return null
          return (
            <div key={section} className="card p-5">
              <div className="flex items-center justify-between mb-4">
                <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
                  <Icon name={SECTION_ICONS[section]} size={14} className="text-accent" />
                  {section}
                </h2>
                <span className="text-xs text-text-dim">{items.length} {items.length === 1 ? 'command' : 'commands'}</span>
              </div>
              <DndContext
                sensors={sensors}
                collisionDetection={closestCenter}
                onDragEnd={(e) => handleDragEnd(section, e)}
              >
                <SortableContext
                  items={items.map(c => c.name)}
                  strategy={verticalListSortingStrategy}
                >
                  <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3">
                    {items.map(c => (
                      <SortableCommandButton key={c.name} cmd={c} onRun={runCommand} busy={running.has(c.name)} />
                    ))}
                  </div>
                </SortableContext>
              </DndContext>
            </div>
          )
        })}

        {cmdsState.loading && !cmdsState.data && (
          <div className="card p-8 text-center text-text-muted">Loading commands…</div>
        )}
      </section>
    </>
  )
}
