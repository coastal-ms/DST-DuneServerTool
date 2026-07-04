import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getFreshStartSnapshotsPath } from '../../api/gameplay'

// Read-only Settings card that exposes where Fresh Start snapshots live on disk,
// so operators can back the folder up before running destructive account resets.
export function FreshStartSnapshotsCard() {
  const [file, setFile] = useState('')
  const [folder, setFolder] = useState('')
  const [exists, setExists] = useState(false)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  const refresh = () => {
    setLoading(true); setErr('')
    getFreshStartSnapshotsPath()
      .then(r => { setFile(r.file || ''); setFolder(r.folder || ''); setExists(!!r.exists) })
      .catch(e => setErr(e instanceof Error ? e.message : String(e)))
      .finally(() => setLoading(false))
  }
  useEffect(() => { refresh() }, [])

  const copy = (s: string) => { if (s) navigator.clipboard?.writeText(s) }

  return (
    <section className="card p-4 md:p-6 space-y-3">
      <div className="flex items-center gap-2">
        <Icon name="Save" size={18} />
        <h2 className="text-lg font-semibold">Fresh Start snapshots</h2>
      </div>
      <p className="text-sm text-text-dim">
        Fresh Start saves each character's purchased CHOAM/MTX sets, pieces, and cosmetics to a single JSON file before wiping the account, so purchases can be restored onto the recreated character. Back this folder up if you want durable copies outside the app data dir.
      </p>
      {loading ? (
        <div className="text-text-dim text-sm flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading…</div>
      ) : err ? (
        <div className="text-danger text-sm">{err}</div>
      ) : (
        <div className="space-y-2 text-sm">
          <div>
            <div className="text-[11px] uppercase tracking-wider text-text-dim mb-1">Folder</div>
            <div className="flex items-center gap-2">
              <code className="flex-1 px-2 py-1 rounded bg-surface-2 border border-border/50 text-text text-xs break-all">{folder}</code>
              <button type="button" className="px-2 py-1 rounded bg-surface-2 border border-border/50 text-xs hover:bg-surface-3" onClick={() => copy(folder)} title="Copy folder path"><Icon name="Copy" size={12} /></button>
            </div>
          </div>
          <div>
            <div className="text-[11px] uppercase tracking-wider text-text-dim mb-1">File {exists ? <span className="text-success">(exists)</span> : <span className="text-text-dim">(not created yet)</span>}</div>
            <div className="flex items-center gap-2">
              <code className="flex-1 px-2 py-1 rounded bg-surface-2 border border-border/50 text-text text-xs break-all">{file}</code>
              <button type="button" className="px-2 py-1 rounded bg-surface-2 border border-border/50 text-xs hover:bg-surface-3" onClick={() => copy(file)} title="Copy file path"><Icon name="Copy" size={12} /></button>
            </div>
          </div>
          <div className="text-xs text-text-dim pt-1">
            Snapshots are keyed by character name. Restoring is a no-op unless the recreated character uses the exact same name.
          </div>
        </div>
      )}
    </section>
  )
}
