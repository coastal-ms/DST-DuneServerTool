import { useState } from 'react'
import { api } from '../../api/client'

type Backup = { path: string; name: string; folder: string; size: number; modified: number; sha256: string }

export function ServerIniBackups({ vmRunning }: { vmRunning: boolean }) {
  const [open, setOpen] = useState(false)
  const [files, setFiles] = useState<Backup[]>([])
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [downloaded, setDownloaded] = useState<Set<string>>(new Set())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const chosen = files.filter(file => selected.has(file.path))

  async function refresh() {
    setOpen(true); setBusy(true); setError(''); setSelected(new Set())
    try { setFiles((await api<{ backups: Backup[] }>('/api/gameconfig/ini-backups')).backups) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }

  async function download() {
    setBusy(true); setError(''); setMessage('')
    try {
      const result = await api<{ filename: string; base64: string }>('/api/gameconfig/ini-backups/download', { method: 'POST', body: JSON.stringify({ files: chosen }) })
      const bytes = Uint8Array.from(atob(result.base64), char => char.charCodeAt(0))
      const url = URL.createObjectURL(new Blob([bytes], { type: 'application/zip' }))
      const anchor = document.createElement('a')
      anchor.href = url; anchor.download = result.filename; document.body.append(anchor); anchor.click(); anchor.remove()
      window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
      setDownloaded(prev => new Set([...prev, ...chosen.map(file => `${file.path}:${file.sha256}`)]))
      setMessage('Download started. Check that the ZIP is saved before deleting the selected backups.')
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }

  async function remove() {
    if (!window.confirm(`Delete ${chosen.length} selected INI backup(s) from the server? Check that your downloaded ZIP is saved first.`)) return
    setBusy(true); setError(''); setMessage('')
    try {
      const result = await api<{ deleted: number; results: { path: string; ok: boolean }[] }>('/api/gameconfig/ini-backups/delete', { method: 'POST', body: JSON.stringify({ files: chosen }) })
      const removed = new Set(result.results.filter(file => file.ok).map(file => file.path))
      setFiles(prev => prev.filter(file => !removed.has(file.path))); setSelected(new Set())
      setMessage(`Deleted ${result.deleted} backup(s).`)
      if (result.results.some(file => !file.ok)) setError('Some backups changed or could not be deleted. Refresh the list.')
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }

  return <section className="card mb-4 p-4">
    <button type="button" className="btn-secondary" disabled={!vmRunning || busy} onClick={() => open ? setOpen(false) : void refresh()}>Server INI Backup File Download and Delete</button>
    {open && <div className="mt-3 space-y-3">
      <p className="text-xs text-text-muted">Download backups as a ZIP, then remove them from the server folders. Active settings files are excluded. No server restart is needed.</p>
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn-secondary" disabled={busy || !vmRunning} onClick={() => void refresh()}>Refresh backups</button>
        <button type="button" className="btn-secondary" disabled={busy || !files.length} onClick={() => setSelected(selected.size === files.length ? new Set() : new Set(files.map(file => file.path)))}>Select all / Clear</button>
      </div>
      <div className="max-h-64 overflow-auto space-y-2">
        {files.map(file => <label key={file.path} className="flex items-center gap-2 text-sm">
          <input type="checkbox" disabled={busy} checked={selected.has(file.path)} onChange={() => setSelected(prev => { const next = new Set(prev); if (next.has(file.path)) next.delete(file.path); else next.add(file.path); return next })} />
          <span className="break-all">{file.folder}/{file.name} <span className="text-text-muted">({file.size} bytes)</span></span>
        </label>)}
        {!busy && !files.length && !error && <p className="text-sm text-text-muted">No INI backups found.</p>}
      </div>
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn-primary" disabled={busy || !vmRunning || !chosen.length} onClick={() => void download()}>Download selected ZIP</button>
        <button type="button" className="btn-secondary" disabled={busy || !vmRunning || !chosen.length || chosen.some(file => !downloaded.has(`${file.path}:${file.sha256}`))} onClick={() => void remove()}>Delete downloaded backups</button>
      </div>
    </div>}
    {error && <p role="alert" className="mt-2 text-sm text-danger">{error}</p>}
    {message && <p role="status" className="mt-2 text-sm text-text-muted">{message}</p>}
  </section>
}
