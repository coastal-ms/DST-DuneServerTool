import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { CollapsibleCard } from '../CollapsibleCard'
import { pickLocalFolder } from '../../util/pathPicker'

interface Mod { folder: string; id: string; name: string; version: string; enabled: boolean; warnings?: string[]; errors: string[] }
interface State { mods: Mod[]; folder: string; gamePath: string; skipIntro: boolean; runtimeReady: boolean; session: unknown; launchError?: string; runtimeLog?: string }

export function SoloMods() {
  const [state, setState] = useState<State | null>(null)
  const [gamePath, setGamePath] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const refresh = async () => {
    const result = await api<State>('/api/solo/mods')
    setState(result)
    setGamePath(result.gamePath)
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
  return <CollapsibleCard id="solo-mods" title="Solo mods" icon="Package" subtitle="Install your downloaded mods. Dependencies and mod errors are shown here; mod settings stay in their INI files." headerClassName="px-5 py-4 flex-wrap" headerRight={
    <div className="flex flex-wrap gap-2">
      <button className="btn-primary" disabled={busy} onClick={() => void run('launch', { withMods: true })}>Launch with Mods</button>
      <button className="btn-secondary" disabled={busy} onClick={() => void run('launch', { withMods: false })}>Launch Normally</button>
    </div>
  }>
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2">
        <button className="btn-secondary" disabled={busy} onClick={() => void install()}>Install mod ZIP</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void run('open')}>Open Mods Folder</button>
        <button className="btn-secondary" disabled={busy} onClick={() => void refresh().catch(e => setError(String(e)))}>Refresh</button>
        {!state?.runtimeReady && <button className="btn-secondary" disabled={busy} onClick={() => void run('runtime')}>Install mod runtime</button>}
      </div>
      <label className="block text-sm">Dune installation
        <div className="flex gap-2 mt-1">
          <input className="input flex-1" value={gamePath} onChange={e => setGamePath(e.target.value)} placeholder="Dune Awakening folder" />
          <button className="btn-secondary" disabled={busy} onClick={() => void pickGame()}>Browse</button>
          <button className="btn-secondary" disabled={busy} onClick={() => void save()}>Save</button>
        </div>
      </label>
      {state?.mods.map(mod => <div key={mod.folder} className="border border-border rounded p-3">
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={mod.enabled} disabled={busy} onChange={e => void save(state.mods.map(m => m.folder === mod.folder ? { ...m, enabled: e.target.checked } : m))} />
          <span>{mod.name} {mod.version && <span className="text-text-muted">{mod.version}</span>}</span>
        </label>
        {mod.errors.map((message, i) => <p className="text-danger text-sm mt-1" key={i}>{message}</p>)}
      </div>)}
      {state && !state.mods.length && <p className="text-sm text-text-muted">No mods installed.</p>}
      {state?.session != null && <button className="btn-secondary" disabled={busy} onClick={() => void run('restore')}>Restore normal launch</button>}
      <p className="text-xs text-text-muted">Solo only. Normal launch bypasses the mod runtime. DST supports its mod-loading framework only. We make no guarantees that any individual mod will or will not work, and DST does not provide individual mod troubleshooting. Contact the mod author or discuss issues with the community.</p>
      <a className="text-xs text-accent-bright underline" href="https://discord.com/channels/1517599283757453333/1558246888967245957" target="_blank" rel="noopener noreferrer">Solo mod discussion</a>
      {(error || state?.launchError) && <p role="alert" className="text-danger whitespace-pre-wrap text-sm">{error || state?.launchError}</p>}
      {state?.runtimeLog && <details><summary className="cursor-pointer text-sm">Loader log</summary><pre className="text-xs whitespace-pre-wrap max-h-64 overflow-auto mt-2">{state.runtimeLog}</pre></details>}
    </div>
  </CollapsibleCard>
}
