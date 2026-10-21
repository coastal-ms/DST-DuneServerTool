import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { isLocalViewer } from '../../util/viewer'

export function IniBackupsCard() {
  const [path, setPath] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const local = isLocalViewer()
  useEffect(() => {
    if (local) void api<{ path: string }>('/api/gameconfig/backup-folder').then(result => setPath(result.path)).catch(error => setError(String(error)))
  }, [local])
  async function open() {
    setBusy(true); setError('')
    try { await api('/api/gameconfig/backup-folder/open', { method: 'POST' }) }
    catch (error) { setError(String(error)) }
    finally { setBusy(false) }
  }
  return <section className="card mb-4 p-4 space-y-3" aria-label="INI backups">
    <h2 className="font-semibold">INI backups</h2>
    <p className="text-sm text-text-muted">This PC’s INI recovery copies are kept separately from the game files. Unchanged files do not create another backup.</p>
    {local ? <><div className="text-sm font-mono break-all">{path || (error ? 'Backup location unavailable' : 'Reading backup location…')}</div>
      <button type="button" className="btn-secondary" disabled={!path || busy} onClick={() => void open()}>{busy ? 'Opening…' : 'Open folder'}</button></>
      : <p className="text-sm text-text-muted">Open DST on the host PC to view this folder.</p>}
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
  </section>
}
