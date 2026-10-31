import { useEffect, useState } from 'react'
import { useApi } from '../../hooks/useApi'
import { api } from '../../api/client'
import { pickLocalFolder } from '../../util/pathPicker'
import { Icon } from '../Icon'

interface BackupPolicy { ok: boolean; root: string; policy: { managed?: boolean; directory: string; archiveRoot?: string; archiveRoots?: string[]; maximumBackups: number } }
export function SoloBackupSettings({ profileToken, disabled, onSaved }: { profileToken: string; disabled: boolean; onSaved: () => Promise<void> }) {
  const state = useApi<BackupPolicy>('/api/solo/backup-policy', { enabled: !!profileToken })
  const [managed, setManaged] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  useEffect(() => { setManaged(state.data?.policy.managed === true) }, [state.data])
  const configure = async (enable: boolean, changeFolder = false) => {
    setBusy(true); setMessage('')
    try {
      let directory = state.data?.policy.directory ?? ''
      if (enable || changeFolder) {
        const chosen = await pickLocalFolder({ initialPath: directory || undefined, description: 'Choose a folder to preserve Solo backup archives' })
        if (!chosen) return
        directory = chosen
        setMessage('Preserving existing backups in the archive…')
      }
      const result = await api<BackupPolicy>('/api/solo/backup-policy', { method: 'PUT', body: JSON.stringify({ managed: enable, directory, expectedProfileToken: profileToken }) })
      setManaged(result.policy.managed === true)
      await Promise.all([state.refresh(), onSaved()])
      setMessage(enable ? 'Backup management enabled. Existing backups are preserved in the archive.' : 'Backup management disabled. Existing local and archived backups are kept.')
    } catch (error) { setMessage(error instanceof Error ? error.message : String(error)) }
    finally { setBusy(false) }
  }
  return <section className="card p-5 space-y-3" aria-label="Solo backup preferences">
    <h2 className="font-semibold">Backup storage</h2>
    <label className="flex items-center gap-3 font-medium cursor-pointer">
      <input type="checkbox" checked={managed} disabled={disabled || busy || !state.data} onChange={event => void configure(event.target.checked)} />
      Let DST manage backups
    </label>
    <p className="text-sm text-text-muted">Keep the newest 50 backups locally and preserve the existing set plus future overflow in your chosen archive. Archived backups are never automatically pruned or overwritten.</p>
    {!managed && <p className="text-sm text-text-dim">Off by default. When off, DST does not limit or offload your backups.</p>}
    {managed && <button type="button" className="btn-secondary" disabled={disabled || busy} onClick={() => void configure(true, true)}><Icon name="FolderOpen" size={14} /> Change archive folder…</button>}
    {busy && <p role="status" className="text-sm text-text-muted">{message || 'Choosing archive folder…'}</p>}
    {!busy && message && <p role="status" className="text-sm text-text-muted">{message}</p>}
    {state.error && <p role="alert" className="text-sm text-danger">{state.error}</p>}
    {state.data?.policy.archiveRoot && <details className="text-xs text-text-dim"><summary className="cursor-pointer">Archive folder</summary><p className="mt-1 break-all select-text">{state.data.policy.archiveRoot}</p></details>}
  </section>
}
