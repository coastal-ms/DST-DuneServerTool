import { useEffect, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { DndContext, DragOverlay, PointerSensor, KeyboardSensor, useSensor, useSensors, closestCorners, type DragEndEvent } from '@dnd-kit/core'
import { SortableContext, arrayMove, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { Icon } from '../Icon'
import { api } from '../../api/client'
import { ConfirmationModal } from '../ConfirmationModal'
import { CollapsibleCard } from '../CollapsibleCard'
import { pickLocalFolder } from '../../util/pathPicker'

interface Mod { folder: string; id: string; name: string; version: string; enabled: boolean; warnings?: string[]; errors: string[] }
interface State { gameRunning?: boolean; mods: Mod[]; folder: string; gamePath: string; skipIntro: boolean; soloArguments?: string; runtimeReady: boolean; session: unknown; launchError?: string; runtimeLog?: string }

function SortableMod({ mod, disabled, children }: { mod: Mod; disabled: boolean; children: ReactNode }) {
  const { attributes, listeners, setNodeRef, setActivatorNodeRef, transform, transition, isDragging } = useSortable({ id: mod.folder, disabled })
  return <div ref={setNodeRef} style={{ transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.35 : undefined }} className="border border-border rounded p-3 flex items-start gap-3">
    <button ref={setActivatorNodeRef} type="button" aria-label={`Reorder ${mod.name}`} title="Drag to reorder"
      {...attributes} {...listeners} disabled={disabled}
      className="shrink-0 -ml-1 flex items-center justify-center w-6 text-text-dim hover:text-accent cursor-grab active:cursor-grabbing focus:outline-none focus:text-accent touch-none disabled:opacity-40 disabled:cursor-default">
      <Icon name="GripVertical" size={14} />
    </button>
    <div className="flex-1 min-w-0">{children}</div>
  </div>
}

export function SoloMods({ connectionToken = '' }: { connectionToken?: string }) {
  const [state, setState] = useState<State | null>(null)
  const [gamePath, setGamePath] = useState('')
  const [platform, setPlatform] = useState('steam')
  const [soloArguments, setSoloArguments] = useState('')
  const [dragged, setDragged] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [deleting, setDeleting] = useState<Mod | null>(null)
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )
  const refresh = async () => {
    const result = await api<State>('/api/solo/mods')
    setState(result)
    setGamePath(result.gamePath)
    setPlatform((result as State & { platform?: string }).platform ?? 'steam')
    setSoloArguments(result.soloArguments ?? '')
  }
  useEffect(() => { void refresh().catch(e => setError(String(e))) }, [connectionToken])
  const run = async (action: string, body: unknown = {}) => {
    setBusy(true); setError(''); setNotice('')
    try {
      await api(`/api/solo/mods/${action}`, { method: 'POST', body: JSON.stringify(body) })
      await refresh()
      if (action === 'shortcut') setNotice('Desktop shortcut created.')
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const save = (mods = state?.mods ?? [], path = gamePath) => run('selection', { mods, gamePath: path, platform })
  const saveArguments = async () => {
    setBusy(true); setError('')
    try {
      await api('/api/game/launch-preferences', { method: 'POST', body: JSON.stringify({ soloArguments }) })
      await refresh()
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const move = (index: number, direction: number) => {
    if (!state || index + direction < 0 || index + direction >= state.mods.length) return
    const mods = [...state.mods]
    ;[mods[index], mods[index + direction]] = [mods[index + direction], mods[index]]
    void save(mods)
  }
  const dropMod = ({ active, over }: DragEndEvent) => {
    setDragged(null)
    if (!state || busy || state.gameRunning || !over || active.id === over.id) return
    const from = state.mods.findIndex(mod => mod.folder === active.id)
    const to = state.mods.findIndex(mod => mod.folder === over.id)
    if (from < 0 || to < 0) return
    const mods = arrayMove(state.mods, from, to)
    setState({ ...state, mods })
    void save(mods)
  }
  const pickGame = async () => {
    const path = await pickLocalFolder({ initialPath: gamePath, description: 'Select Dune Awakening installation' })
    if (path) await save(state?.mods, path)
  }
  const install = async () => {
    try {
      const pick = await api<{ cancelled: boolean; path: string }>('/api/browse-path', {
        method: 'POST', body: JSON.stringify({ mode: 'file', title: 'Install mod ZIP', filter: 'Mod ZIP (*.zip)|*.zip' }),
      })
      if (!pick.cancelled && pick.path) await run('import', { path: pick.path })
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
  }
  return <CollapsibleCard id="solo-mods" title="Solo mods" icon="Package" defaultOpen={false} subtitle="Download mods from Nexus Mods or another source, then install your downloaded ZIP. Mod settings stay in their INI files." headerClassName="px-5 py-4 flex-wrap [&>div]:w-full" headerRight={
    <div className="flex flex-wrap gap-2 w-full">
      <label className="block w-full rounded border border-accent/40 bg-accent/5 p-3 text-sm">Dune installation folder
        <select aria-label="Mod installation platform" className="input mt-2" value={platform} disabled={busy || state?.gameRunning} onChange={e => void run('selection', { mods: state?.mods ?? [], platform: e.target.value, gamePath: '' })}>
          <option value="steam">Steam</option><option value="xbox">Xbox PC</option>
        </select>
        <div className="flex flex-wrap gap-2 mt-1">
          <input className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" value={gamePath} onChange={e => setGamePath(e.target.value)} placeholder="Select your Dune Awakening installation folder" />
          <button className="btn-secondary" disabled={busy} onClick={() => void pickGame()}>Browse</button>
          <button className="btn-secondary" disabled={busy} onClick={() => void save()}>Save</button>
        </div>
        <span className="block text-xs text-text-muted mt-2">Xbox PC detects the installed game automatically. Browse saves a manual folder; if you type it, click Save.</span>
      </label>
      <label className="block w-full text-sm">Launch Arguments
        <div className="flex flex-wrap gap-2 mt-1">
          <input className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" value={soloArguments} maxLength={8192} onChange={e => setSoloArguments(e.target.value)} placeholder="Optional command line arguments" />
          <button className="btn-secondary" disabled={busy} onClick={() => void saveArguments()}>Save arguments</button>
        </div>
        <span className="block text-xs text-text-muted mt-2">Type your arguments in the box, then click Save arguments. Used by both Solo launch buttons in DST.</span>
      </label>
      {notice && <p role="status" className="text-sm w-full">{notice}</p>}
      {(error || state?.launchError) && <p role="alert" className="text-danger whitespace-pre-wrap text-sm w-full">{error || state?.launchError}</p>}
      <button className="btn-primary" disabled={busy} onClick={() => void run('launch', { withMods: true })}>Launch with Mods</button>
      <button className="btn-secondary" disabled={busy} onClick={() => void run('launch', { withMods: false })}>Launch Normally</button>
      <button className="btn-secondary" disabled={busy} onClick={() => void run('shortcut')}>Create desktop shortcut</button>
    </div>
  }>
    <div className="space-y-3">
      <p className="text-sm text-text-muted">Launching with mods, including through the desktop shortcut, disables BattlEye for that game session.</p>
      {deleting && <ConfirmationModal title={`Delete ${deleting.name}?`} description="This permanently removes the mod folder and its INI settings. You can reinstall the mod from its ZIP." confirmLabel="Delete mod" onCancel={() => setDeleting(null)} onConfirm={() => { const folder = deleting.folder; setDeleting(null); void run('delete', { folder }) }} />}
      <a className="text-sm text-accent-bright underline" href="https://www.nexusmods.com/duneawakening" target="_blank" rel="noopener noreferrer">Browse Dune: Awakening mods on Nexus Mods</a>
      <div className="flex flex-wrap gap-2">
        <button className="btn-secondary" disabled={busy} onClick={() => void install()}>Install mod ZIP</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void run('open')}>Open Mods Folder</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void refresh().catch(e => setError(String(e)))}>Refresh</button>
        {!state?.runtimeReady && <button className="btn-secondary" disabled={busy} onClick={() => void run('runtime')}>Install mod runtime</button>}
      </div>
      {state && state.mods.length > 1 && <p className="text-sm text-text-muted">Mods load from top to bottom. Follow the mod author's load order instructions.</p>}
      <DndContext sensors={sensors} collisionDetection={closestCorners}
        onDragStart={({ active }) => setDragged(String(active.id))} onDragEnd={dropMod} onDragCancel={() => setDragged(null)}>
      <SortableContext items={state?.mods.map(mod => mod.folder) ?? []} strategy={verticalListSortingStrategy}>
      {state?.mods.map((mod, index) => <SortableMod key={mod.folder} mod={mod} disabled={busy || !!state.gameRunning}>
        <div className="flex items-center justify-between gap-3">
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={mod.enabled} disabled={busy} onChange={e => void save(state.mods.map(m => m.folder === mod.folder ? { ...m, enabled: e.target.checked } : m))} />
          <span>{mod.name} {mod.version && <span className="text-text-muted">{mod.version}</span>}</span>
        </label>
        <button className="btn-secondary" aria-label={`Delete ${mod.name}`} disabled={busy || state.gameRunning} onClick={() => setDeleting(mod)}>Delete</button>
        </div>
        <div className="flex gap-2 mt-2">
          <button className="btn-secondary" aria-label={`Move ${mod.name} up`} disabled={busy || index === 0} onClick={() => move(index, -1)}>Move Up</button>
          <button className="btn-secondary" aria-label={`Move ${mod.name} down`} disabled={busy || index === state.mods.length - 1} onClick={() => move(index, 1)}>Move Down</button>
        </div>
        {mod.errors.map((message, i) => <p className="text-danger text-sm mt-1" key={i}>{message}</p>)}
      </SortableMod>)}
      </SortableContext>
      {createPortal(<DragOverlay>{dragged && <div className="border border-border rounded p-3 bg-surface shadow-lg flex items-center gap-3"><Icon name="GripVertical" size={14} />{state?.mods.find(mod => mod.folder === dragged)?.name}</div>}</DragOverlay>, document.body)}
      </DndContext>
      {state && !state.mods.length && <p className="text-sm text-text-muted">No mods installed.</p>}
      {state?.session != null && <button className="btn-secondary" disabled={busy} onClick={() => void run('restore')}>Restore normal launch</button>}
      <p className="text-xs text-text-muted">Solo only. Normal launch bypasses the mod runtime. DST supports its mod-loading framework only. We make no guarantees that any individual mod will or will not work, and DST does not provide individual mod troubleshooting. Contact the mod author or discuss issues with the community.</p>
      <a className="text-xs text-accent-bright underline" href="https://discord.com/channels/1517599283757453333/1558246888967245957" target="_blank" rel="noopener noreferrer">Solo mod discussion</a>
      {state?.runtimeLog && <details><summary className="cursor-pointer text-sm">Loader log</summary><pre className="text-xs whitespace-pre-wrap max-h-64 overflow-auto mt-2">{state.runtimeLog}</pre></details>}
    </div>
  </CollapsibleCard>
}
