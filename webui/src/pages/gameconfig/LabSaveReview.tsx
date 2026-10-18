import { useEffect, useState } from 'react'
import { getGameConfigClient, saveLabLocal } from '../../api/gameconfig'
import type { GameConfigClientInfo, GameConfigRawUpdate } from '../../api/types'
import { isLocalViewer } from '../../util/viewer'

export function LabSaveReview({ updates, serverPaths, serverAvailable = true, serverOnly = false, onServerSave, onDone, onCancel }: {
  serverOnly?: boolean
  updates: GameConfigRawUpdate[]
  serverPaths?: { game: string; engine: string }
  serverAvailable?: boolean
  onServerSave: () => Promise<unknown>
  onDone: (message: string) => void
  onCancel: () => void
}) {
  const localViewer = isLocalViewer()
  const [client, setClient] = useState<GameConfigClientInfo | null>(null)
  const [localError, setLocalError] = useState('')
  const [local, setLocal] = useState(localViewer && !serverOnly)
  const [server, setServer] = useState(serverAvailable)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [serverSaved, setServerSaved] = useState(false)
  const [localSaved, setLocalSaved] = useState(false)
  useEffect(() => {
    if (!localViewer) return
    let active = true
    void getGameConfigClient().then(info => {
      if (active) setClient(info)
    }).catch(e => { if (active) setLocalError(String(e)) })
    return () => { active = false }
  }, [localViewer])

  async function save() {
    setBusy(true); setError('')
    let staged = serverSaved
    let written = localSaved
    try {
      // Do the local write first: a running game must not leave a surprise
      // server-only save. Each completed destination remains visible on retry.
      if (local && !written) {
        await saveLabLocal(updates)
        written = true; setLocalSaved(true)
      }
      if (server && !staged) {
        await onServerSave()
        staged = true; setServerSaved(true)
      }
      onDone([
        written ? 'Local Solo/player INIs saved and verified; existing files backed up. Restart the game to test.' : '',
        staged ? 'Server INIs saved. Use Apply server settings to deploy them to the self-hosted server.' : '',
      ].filter(Boolean).join(' '))
    } catch (e) {
      setError(`${written ? 'Local files saved. ' : ''}${staged ? 'Server files saved. ' : ''}${e instanceof Error ? e.message : String(e)} Pending destinations have not been saved.`)
    } finally { setBusy(false) }
  }

  return <div className="fixed inset-0 z-[100] bg-black/60 flex items-center justify-center p-4">
    <section role="dialog" aria-modal="true" aria-labelledby="lab-save-title" className="card p-5 w-full max-w-2xl max-h-[85vh] overflow-y-auto space-y-4">
      <h2 id="lab-save-title" className="text-lg font-semibold">Review Lab save destinations</h2>
      <p className="text-sm text-text-muted">Choose where to save these exact changes. Local files affect Solo and this PC’s player. Server files affect the self-hosted server after Apply server settings. A verified file write does not prove an in-game effect.</p>
      <label className="flex gap-2"><input type="checkbox" checked={local} disabled={serverOnly || !localViewer || busy || localSaved} onChange={e => setLocal(e.target.checked)} />
        Save to this PC’s local Solo/player files {localSaved && '(saved)'}</label>
      {localViewer ? <div className="text-xs text-text-muted break-all">
        {client ? [...new Set(updates.map(u => u.file))].map(file => <div key={file}>{file === 'engine' ? client.engine.path : (client.game ?? client).path}</div>) : localError || 'Reading local file locations…'}
        <p>Approval applies only to the listed edits. Existing files are backed up; unrelated values stay intact. Close Dune: Awakening before saving local files.</p>
      </div> : <p className="text-xs text-text-muted">Local file changes require opening DST on the host PC. You can still save the server copy here.</p>}
      <label className="flex gap-2"><input type="checkbox" checked={server} disabled={busy || serverSaved || !serverAvailable} onChange={e => setServer(e.target.checked)} />Save to self-hosted server INIs {serverSaved && '(saved)'}</label>
      {!serverAvailable && <p className="text-xs text-text-muted">Server unavailable. Local saves remain available; reconnect to save the server copy.</p>}
      <p className="text-xs text-text-muted">Game → server UserGame.ini · Engine → server UserEngine.ini. Save stages these changes without restarting the battlegroup.</p>
      {serverPaths && <div className="text-xs text-text-muted break-all">{[...new Set(updates.map(u => u.file))].map(file => <div key={file}>{serverPaths[file]}</div>)}</div>}
      <ul className="space-y-2 text-xs font-mono max-h-60 overflow-y-auto">
        {updates.map(u => <li key={`${u.file}||${u.section}||${u.key}`} className="border border-border p-2 rounded break-all">
          <div>{u.file === 'game' ? 'Game.ini / UserGame.ini' : 'Engine.ini / UserEngine.ini'} [{u.section}]</div>
          <div>{u.key} → {u.arrayLines ? u.arrayLines.join('\n') || 'Remove array entries' : u.value?.trim() ? u.value : 'Remove override; use inherited default'}</div>
          {client && <div className="text-text-muted">Local now: {(u.file === 'engine' ? client.engine : client.game ?? client).effective[`${u.section}||${u.key}`] ?? 'No override'}</div>}
        </li>)}
      </ul>
      {error && <p role="alert" className="text-danger text-sm">{error}</p>}
      <div className="flex justify-end gap-2">
        <button type="button" className="btn-secondary" disabled={busy} onClick={onCancel}>Cancel</button>
        <button type="button" className="btn-primary" disabled={busy || (!local && !server) || (local && !client)} onClick={() => void save()}>{busy ? 'Saving…' : local ? 'Approve local changes & Save' : 'Save server files'}</button>
      </div>
    </section>
  </div>
}
