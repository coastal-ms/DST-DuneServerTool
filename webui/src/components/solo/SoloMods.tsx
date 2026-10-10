import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { ConfirmationModal } from '../ConfirmationModal'
import { CollapsibleCard } from '../CollapsibleCard'
import { pickLocalFolder } from '../../util/pathPicker'

interface Mod { folder: string; id: string; name: string; version: string; enabled: boolean; warnings?: string[]; errors: string[] }
interface State { gameRunning?: boolean; mods: Mod[]; folder: string; gamePath: string; skipIntro: boolean; soloArguments?: string; runtimeReady: boolean; session: unknown; launchError?: string; runtimeLog?: string }

export function SoloMods() {
  const [state, setState] = useState<State | null>(null)
  const [gamePath, setGamePath] = useState('')
  const [soloArguments, setSoloArguments] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [deleting, setDeleting] = useState<Mod | null>(null)
  const refresh = async () => {
    const result = await api<State>('/api/solo/mods')
    setState(result)
    setGamePath(result.gamePath)
    setSoloArguments(result.soloArguments ?? '')
  }
  useEffect(() => { void refresh().catch(e => setError(String(e))) }, [])
  const run = async (action: string, body: unknown = {}) => {
    setBusy(true); setError('')
    try {
      await api(`/api/solo/mods/${action}`, { method: 'POST', body: JSON.stringify(body) })
      await refresh()
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const save = (mods = state?.mods ?? [], path = gamePath) => run('selection', { mods, gamePath: path })
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
        <div className="flex flex-wrap gap-2 mt-1">
          <input className="input flex-1 min-w-0" value={gamePath} onChange={e => setGamePath(e.target.value)} placeholder="Select your Dune Awakening installation folder" />
          <button className="btn-secondary" disabled={busy} onClick={() => void pickGame()}>Browse</button>
          <button className="btn-secondary" disabled={busy} onClick={() => void save()}>Save</button>
        </div>
        <span className="block text-xs text-text-muted mt-2">Required for both launch options. Browse saves the folder; if you type it, click Save.</span>
      </label>
      <label className="block w-full text-sm">Launch Arguments
        <div className="flex flex-wrap gap-2 mt-1">
          <input className="input flex-1 min-w-0" value={soloArguments} maxLength={8192} onChange={e => setSoloArguments(e.target.value)} placeholder="Optional command line arguments" />
          <button className="btn-secondary" disabled={busy} onClick={() => void saveArguments()}>Save arguments</button>
        </div>
        <span className="block text-xs text-text-muted mt-2">Used by both Solo launch buttons in DST. Click Save arguments after editing.</span>
      </label>
      {(error || state?.launchError) && <p role="alert" className="text-danger whitespace-pre-wrap text-sm w-full">{error || state?.launchError}</p>}
      <button className="btn-primary" disabled={busy} onClick={() => void run('launch', { withMods: true })}>Launch with Mods</button>
      <button className="btn-secondary" disabled={busy} onClick={() => void run('launch', { withMods: false })}>Launch Normally</button>
    </div>
  }>
    <div className="space-y-3">
      {deleting && <ConfirmationModal title={`Delete ${deleting.name}?`} description="This permanently removes the mod folder and its INI settings. You can reinstall the mod from its ZIP." confirmLabel="Delete mod" onCancel={() => setDeleting(null)} onConfirm={() => { const folder = deleting.folder; setDeleting(null); void run('delete', { folder }) }} />}
      <a className="text-sm text-accent-bright underline" href="https://www.nexusmods.com/duneawakening" target="_blank" rel="noopener noreferrer">Browse Dune: Awakening mods on Nexus Mods</a>
      <div className="flex flex-wrap gap-2">
        <button className="btn-secondary" disabled={busy} onClick={() => void install()}>Install mod ZIP</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void run('open')}>Open Mods Folder</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void refresh().catch(e => setError(String(e)))}>Refresh</button>
        {!state?.runtimeReady && <button className="btn-secondary" disabled={busy} onClick={() => void run('runtime')}>Install mod runtime</button>}
      </div>
      {state && state.mods.length > 1 && <p className="text-sm text-text-muted">Mods load from top to bottom. Follow the mod author's load order instructions.</p>}
      {state?.mods.map((mod, index) => <div key={mod.folder} className="border border-border rounded p-3">
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
      </div>)}
      {state && !state.mods.length && <p className="text-sm text-text-muted">No mods installed.</p>}
      {state?.session != null && <button className="btn-secondary" disabled={busy} onClick={() => void run('restore')}>Restore normal launch</button>}
      <p className="text-xs text-text-muted">Solo only. Normal launch bypasses the mod runtime. DST supports its mod-loading framework only. We make no guarantees that any individual mod will or will not work, and DST does not provide individual mod troubleshooting. Contact the mod author or discuss issues with the community.</p>
      <a className="text-xs text-accent-bright underline" href="https://discord.com/channels/1517599283757453333/1558246888967245957" target="_blank" rel="noopener noreferrer">Solo mod discussion</a>
      {state?.runtimeLog && <details><summary className="cursor-pointer text-sm">Loader log</summary><pre className="text-xs whitespace-pre-wrap max-h-64 overflow-auto mt-2">{state.runtimeLog}</pre></details>}
    </div>
  </CollapsibleCard>
}
