import { useEffect, useMemo, useRef, useState } from 'react'
import {
  DndContext,
  DragOverlay,
  PointerSensor,
  KeyboardSensor,
  useSensor,
  useSensors,
  closestCorners,
  useDroppable,
  type DragEndEvent,
  type DragStartEvent,
  type DragOverEvent,
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

type SectionIndex = 0 | 1 | 2
const SECTION_INDICES: SectionIndex[] = [0, 1, 2]
const SECTION_ICONS = ['HardDrive', 'Activity', 'Wrench'] as const
const MAX_SECTION_NAME = 40

const COMMAND_BUTTON_CLASS =
  'group relative flex items-stretch gap-2 p-3 rounded-lg ' +
  'bg-gradient-to-b from-surface-2 to-surface ' +
  'border border-border-bright border-b-2 ' +
  'shadow-[0_2px_0_rgba(0,0,0,0.35),0_4px_10px_-4px_rgba(0,0,0,0.55),inset_0_1px_0_rgba(255,255,255,0.04)] ' +
  'transition-[transform,box-shadow,background-color,border-color] ' +
  'hover:from-surface-3 hover:to-surface-2 hover:border-accent/40 ' +
  'hover:shadow-[0_3px_0_rgba(0,0,0,0.4),0_8px_18px_-6px_rgba(0,0,0,0.6),inset_0_1px_0_rgba(255,255,255,0.05)] ' +
  'hover:-translate-y-px ' +
  'active:translate-y-0 active:border-b ' +
  'active:shadow-[0_1px_0_rgba(0,0,0,0.3),0_2px_6px_-2px_rgba(0,0,0,0.5),inset_0_1px_0_rgba(255,255,255,0.03)]'

// ---------- Atomic UI pieces -----------------------------------------------

function CommandButtonInner({
  cmd,
  busy,
  dragHandleAttributes,
  dragHandleListeners,
  onLaunch,
}: {
  cmd: Command
  busy: boolean
  dragHandleAttributes?: Record<string, unknown>
  dragHandleListeners?: Record<string, unknown>
  onLaunch?: () => void
}) {
  const disabled = !cmd.available || busy
  return (
    <>
      <button
        type="button"
        aria-label={`Reorder ${cmd.name}`}
        title="Drag to move (across sections too)"
        {...dragHandleAttributes}
        {...dragHandleListeners}
        className="shrink-0 -ml-1 flex items-center justify-center w-6 text-text-dim
                   hover:text-accent cursor-grab active:cursor-grabbing
                   focus:outline-none focus:text-accent touch-none"
      >
        <Icon name="GripVertical" size={14} />
      </button>
      <button
        type="button"
        disabled={disabled}
        onClick={onLaunch}
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
            <span className="font-medium text-sm truncate text-text">{cmd.label || cmd.name}</span>
          </div>
          <span className={cmd.mode === 'Console' ? 'pill-info shrink-0' : 'pill-muted shrink-0'}>
            <Icon name={cmd.mode === 'Console' ? 'SquareTerminal' : 'Zap'} size={10} />
            {cmd.mode}
          </span>
        </div>
        <p className={`mt-1.5 text-xs text-text-muted line-clamp-2 ${cmd.name === 'dune-admin' ? 'pr-28' : ''}`}>{cmd.desc}</p>
        {!cmd.available && cmd.reason && (
          <p className="mt-1 text-[11px] text-warning/80 flex items-center gap-1">
            <Icon name="AlertTriangle" size={10} /> {cmd.reason}
          </p>
        )}
      </button>
      {cmd.name === 'dune-admin' && (
        <a
          href="https://github.com/Icehunter"
          target="_blank"
          rel="noopener noreferrer"
          onClick={(e) => e.stopPropagation()}
          title="dune-admin is built by Icehunter — visit GitHub profile"
          className="absolute bottom-1 right-2 z-10 flex items-center gap-1
                     text-[10px] font-mono text-text-dim hover:text-accent
                     px-1.5 py-0.5 rounded bg-surface-3/60 border border-border/40
                     hover:border-accent/40 transition-colors"
        >
          <Icon name="Github" size={10} />
          <span>by Icehunter</span>
        </a>
      )}
    </>
  )
}

function SortableCommandButton({
  cmd, onRun, busy, sectionIdx,
}: {
  cmd: Command
  onRun: (c: Command) => void
  busy: boolean
  sectionIdx: SectionIndex
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } =
    useSortable({ id: cmd.name, data: { containerId: sectionIdx, type: 'command' } })

  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.35 : undefined,
  }

  const disabled = !cmd.available || busy
  return (
    <div
      ref={setNodeRef}
      style={style}
      className={`${COMMAND_BUTTON_CLASS} ${disabled ? 'opacity-60' : ''}`}
    >
      <CommandButtonInner
        cmd={cmd}
        busy={busy}
        dragHandleAttributes={attributes as unknown as Record<string, unknown>}
        dragHandleListeners={listeners as unknown as Record<string, unknown>}
        onLaunch={() => onRun(cmd)}
      />
    </div>
  )
}

// Drop zone for the section's grid. Always droppable (including when empty)
// so the user can move a single remaining command back into an empty section.
function SectionDropZone({
  sectionIdx, children, count, isOver,
}: {
  sectionIdx: SectionIndex
  children: React.ReactNode
  count: number
  isOver: boolean
}) {
  const { setNodeRef } = useDroppable({
    id: `section:${sectionIdx}`,
    data: { containerId: sectionIdx, type: 'section' },
  })
  return (
    <div
      ref={setNodeRef}
      className={`grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3 rounded-lg transition-colors
                  ${isOver ? 'ring-2 ring-accent/40 bg-accent/5 p-2 -m-2' : ''}
                  ${count === 0 ? 'min-h-[6rem] border-2 border-dashed border-border rounded-lg items-center justify-center' : ''}`}
    >
      {count === 0 ? (
        <div className="col-span-full flex items-center justify-center text-xs text-text-dim py-6">
          Drop commands here to move them into this section.
        </div>
      ) : children}
    </div>
  )
}

// Inline-editable section name. Click the pencil (or the label) to edit;
// Enter / blur saves, Escape cancels. Empty input snaps back to the server-side
// default ('Section N') after save.
function SectionTitle({
  name, sectionIdx, onRename, disabled,
}: {
  name: string
  sectionIdx: SectionIndex
  onRename: (next: string) => void
  disabled: boolean
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(name)
  const inputRef = useRef<HTMLInputElement | null>(null)

  useEffect(() => { if (!editing) setDraft(name) }, [name, editing])
  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus()
      inputRef.current.select()
    }
  }, [editing])

  function commit() {
    setEditing(false)
    const trimmed = draft.trim().slice(0, MAX_SECTION_NAME)
    if (trimmed !== name) onRename(trimmed)
  }

  function cancel() {
    setDraft(name)
    setEditing(false)
  }

  if (editing) {
    return (
      <div className="flex items-center gap-2 min-w-0 flex-1">
        <Icon name={SECTION_ICONS[sectionIdx]} size={14} className="text-accent shrink-0" />
        <input
          ref={inputRef}
          value={draft}
          maxLength={MAX_SECTION_NAME}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit() }
            else if (e.key === 'Escape') { e.preventDefault(); cancel() }
          }}
          className="flex-1 min-w-0 bg-surface-2 border border-border-bright rounded px-2 py-1
                     text-sm font-semibold uppercase tracking-wider text-text
                     focus:outline-none focus:border-accent"
        />
      </div>
    )
  }

  return (
    <button
      type="button"
      disabled={disabled}
      onClick={() => setEditing(true)}
      title="Click to rename this section"
      className="flex items-center gap-2 min-w-0 text-sm font-semibold uppercase tracking-wider
                 text-text-muted hover:text-text disabled:cursor-not-allowed disabled:opacity-60
                 group/title"
    >
      <Icon name={SECTION_ICONS[sectionIdx]} size={14} className="text-accent shrink-0" />
      <span className="truncate">{name}</span>
      <Icon
        name="Pencil"
        size={11}
        className="text-text-dim opacity-0 group-hover/title:opacity-100 transition-opacity shrink-0"
      />
    </button>
  )
}

// ---------- Page -----------------------------------------------------------

export function Commands() {
  const { forceRefresh } = useStatus()
  const cmdsState = useApi<CommandsResponse>('/api/commands', { intervalMs: 30_000 })

  const [running, setRunning] = useState<Set<string>>(new Set())
  const [toast, setToast] = useState<{ kind: 'ok' | 'err'; msg: string } | null>(null)

  // Local optimistic copy of the layout. When non-null, this overrides the
  // server data — that way drags and renames are reflected instantly and don't
  // snap back during the brief window between PUT and the next GET refresh.
  const [localNames, setLocalNames]       = useState<[string, string, string] | null>(null)
  const [localSections, setLocalSections] = useState<[string[], string[], string[]] | null>(null)
  // Bumped after every successful PUT — used to invalidate localNames /
  // localSections only once we've seen the server reflect our save back.
  const lastSavedRef = useRef<number>(0)
  const [serverSeenAt, setServerSeenAt] = useState<number>(0)
  const [savingLayout, setSavingLayout] = useState(false)
  const saveTimer = useRef<number | null>(null)

  const [activeDrag, setActiveDrag] = useState<{ id: string; cmd: Command } | null>(null)
  const [overSection, setOverSection] = useState<SectionIndex | null>(null)

  // Track when the server payload changes — clear locals only if the most
  // recent save has already been observed (otherwise we'd flicker back to old
  // server state for a single refresh tick).
  useEffect(() => {
    if (cmdsState.data) setServerSeenAt(Date.now())
  }, [cmdsState.data])

  useEffect(() => {
    if (serverSeenAt >= lastSavedRef.current) {
      setLocalNames(null)
      setLocalSections(null)
    }
  }, [serverSeenAt])

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

  // Effective layout = local optimistic overlay if present, otherwise server.
  const effective = useMemo<{ names: [string, string, string]; sections: [string[], string[], string[]] }>(() => {
    const fallbackNames: [string, string, string] = ['VM', 'Battlegroup', 'Tools']
    const fallbackSections: [string[], string[], string[]] = [[], [], []]
    const serverNames    = (cmdsState.data?.sectionNames ?? fallbackNames) as [string, string, string]
    const serverSections = (cmdsState.data?.sections     ?? fallbackSections) as [string[], string[], string[]]
    return {
      names:    localNames    ?? serverNames,
      sections: localSections ?? serverSections,
    }
  }, [cmdsState.data, localNames, localSections])

  const commandsByName = useMemo(() => {
    const m = new Map<string, Command>()
    for (const c of cmdsState.data?.commands ?? []) m.set(c.name, c)
    return m
  }, [cmdsState.data?.commands])

  // Resolve each section's command-name array into Command objects, dropping
  // any unknown names defensively.
  const grouped = useMemo(() => {
    return effective.sections.map(arr =>
      arr.map(n => commandsByName.get(n)).filter((c): c is Command => Boolean(c))
    ) as [Command[], Command[], Command[]]
  }, [effective.sections, commandsByName])

  // ---- Persistence -------------------------------------------------------

  function persistLayout(names: [string, string, string], sections: [string[], string[], string[]]) {
    if (saveTimer.current) window.clearTimeout(saveTimer.current)
    saveTimer.current = window.setTimeout(async () => {
      setSavingLayout(true)
      try {
        await api('/api/commands/layout', {
          method: 'PUT',
          body: JSON.stringify({ sectionNames: names, sections }),
        })
        lastSavedRef.current = Date.now()
        void cmdsState.refresh()
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        showToast('err', `Failed to save layout: ${msg}`)
      } finally {
        setSavingLayout(false)
      }
    }, 400)
  }

  function updateLayout(
    next: { names?: [string, string, string]; sections?: [string[], string[], string[]] }
  ) {
    const nextNames    = (next.names    ?? effective.names)    as [string, string, string]
    const nextSections = (next.sections ?? effective.sections) as [string[], string[], string[]]
    setLocalNames(nextNames)
    setLocalSections(nextSections)
    persistLayout(nextNames, nextSections)
  }

  function renameSection(idx: SectionIndex, name: string) {
    const cleaned = name.trim().slice(0, MAX_SECTION_NAME)
    const fallback = ['VM', 'Battlegroup', 'Tools'][idx]
    const finalName = cleaned.length === 0 ? fallback : cleaned
    const nextNames: [string, string, string] = [...effective.names] as [string, string, string]
    nextNames[idx] = finalName
    updateLayout({ names: nextNames })
  }

  // ---- DnD ---------------------------------------------------------------

  function containerOf(id: string | null): SectionIndex | null {
    if (!id) return null
    if (id.startsWith('section:')) {
      const i = Number(id.slice('section:'.length))
      return (i === 0 || i === 1 || i === 2) ? (i as SectionIndex) : null
    }
    // Command id — find which section currently holds it.
    for (const i of SECTION_INDICES) {
      if (grouped[i].some(c => c.name === id)) return i
    }
    return null
  }

  function handleDragStart(e: DragStartEvent) {
    const cmd = commandsByName.get(String(e.active.id))
    if (cmd) setActiveDrag({ id: cmd.name, cmd })
  }

  function handleDragOver(e: DragOverEvent) {
    setOverSection(containerOf(e.over?.id?.toString() ?? null))
  }

  function handleDragEnd(e: DragEndEvent) {
    setActiveDrag(null)
    setOverSection(null)
    const { active, over } = e
    if (!over) return

    const source = containerOf(active.id.toString())
    const dest   = containerOf(over.id.toString())
    if (source === null || dest === null) return

    const activeName = active.id.toString()
    const overName   = over.id.toString()

    const next: [string[], string[], string[]] = [
      [...effective.sections[0]],
      [...effective.sections[1]],
      [...effective.sections[2]],
    ]

    if (source === dest) {
      if (activeName === overName) return
      const arr = next[source]
      const oldIdx = arr.indexOf(activeName)
      const newIdx = overName.startsWith('section:')
        ? arr.length - 1
        : arr.indexOf(overName)
      if (oldIdx < 0 || newIdx < 0) return
      next[source] = arrayMove(arr, oldIdx, newIdx)
    } else {
      const srcArr = next[source]
      const dstArr = next[dest]
      const srcIdx = srcArr.indexOf(activeName)
      if (srcIdx < 0) return
      const [moved] = srcArr.splice(srcIdx, 1)
      const dstIdx = overName.startsWith('section:')
        ? dstArr.length
        : dstArr.indexOf(overName)
      if (dstIdx < 0) dstArr.push(moved)
      else            dstArr.splice(dstIdx, 0, moved)
    }

    updateLayout({ sections: next })
  }

  async function resetLayout() {
    if (!window.confirm('Reset the Commands page to its default layout (section names, order, and assignments)?')) return
    if (saveTimer.current) window.clearTimeout(saveTimer.current)
    setSavingLayout(true)
    try {
      await api('/api/commands/layout/reset', { method: 'POST' })
      lastSavedRef.current = Date.now()
      setLocalNames(null)
      setLocalSections(null)
      await cmdsState.refresh()
      showToast('ok', 'Layout reset to default.')
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      showToast('err', `Reset failed: ${msg}`)
    } finally {
      setSavingLayout(false)
    }
  }

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  return (
    <>
      <PageHeader
        title="Commands"
        icon="Zap"
        description="Quick actions for the VM, battlegroup, and supporting tools. Click a section title to rename it. Drag the grip on any card to reorder within a section or move it to another — sections grow and shrink as you go."
        actions={
          <div className="flex items-center gap-2">
            {savingLayout && (
              <span className="text-xs text-text-dim flex items-center gap-1">
                <Icon name="Loader2" size={12} className="animate-spin" /> Saving layout…
              </span>
            )}
            <button
              className="btn-secondary"
              onClick={resetLayout}
              disabled={savingLayout}
              title="Reset section names + assignments to default"
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

      <DndContext
        sensors={sensors}
        collisionDetection={closestCorners}
        onDragStart={handleDragStart}
        onDragOver={handleDragOver}
        onDragEnd={handleDragEnd}
        onDragCancel={() => { setActiveDrag(null); setOverSection(null) }}
      >
        <section className="space-y-5">
          {SECTION_INDICES.map(idx => {
            const items = grouped[idx]
            return (
              <div key={idx} className="card p-5">
                <div className="flex items-center justify-between gap-3 mb-4">
                  <SectionTitle
                    name={effective.names[idx]}
                    sectionIdx={idx}
                    onRename={(n) => renameSection(idx, n)}
                    disabled={savingLayout}
                  />
                  <span className="text-xs text-text-dim shrink-0">
                    {items.length} {items.length === 1 ? 'command' : 'commands'}
                  </span>
                </div>
                <SortableContext
                  items={items.map(c => c.name)}
                  strategy={rectSortingStrategy}
                >
                  <SectionDropZone sectionIdx={idx} count={items.length} isOver={overSection === idx}>
                    {items.map(c => (
                      <SortableCommandButton
                        key={c.name}
                        cmd={c}
                        sectionIdx={idx}
                        onRun={runCommand}
                        busy={running.has(c.name)}
                      />
                    ))}
                  </SectionDropZone>
                </SortableContext>
              </div>
            )
          })}

          {cmdsState.loading && !cmdsState.data && (
            <div className="card p-8 text-center text-text-muted">Loading commands…</div>
          )}
        </section>

        <DragOverlay>
          {activeDrag ? (
            <div className={`${COMMAND_BUTTON_CLASS} shadow-[0_8px_24px_-4px_rgba(0,0,0,0.7),0_0_0_2px_rgba(217,119,6,0.4)]`}>
              <CommandButtonInner cmd={activeDrag.cmd} busy={false} />
            </div>
          ) : null}
        </DragOverlay>
      </DndContext>
    </>
  )
}
