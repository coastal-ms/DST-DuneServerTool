import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { ConfirmationModal } from '../../components/ConfirmationModal'
import { isLocalViewer } from '../../util/viewer'

export function StartupSettingsSync({ onBusyChange }: { onBusyChange?: (busy: boolean) => void }) {
  const [enabled, setEnabled] = useState(true)
  const [applied, setApplied] = useState(true)
  const [cleanupPending, setCleanupPending] = useState(false)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [confirmDisable, setConfirmDisable] = useState(false)
  useEffect(() => {
    let cancelled = false
    void api<{ enabled: boolean; injectionsApplied?: boolean; cleanupPending?: boolean }>('/api/gameconfig/retail-startup-sync')
      .then(result => { if (!cancelled) { setEnabled(result.enabled); setApplied(result.injectionsApplied ?? result.enabled); setCleanupPending(result.cleanupPending ?? false) } })
      .catch(e => { if (!cancelled) setError(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])
  const save = async (next: boolean) => {
    setSaving(true); setError(''); onBusyChange?.(true)
    try {
      const result = await api<{ enabled: boolean; injectionsApplied?: boolean; cleanupPending?: boolean; cleanupError?: string }>('/api/gameconfig/retail-startup-sync', {
        method: 'PUT', body: JSON.stringify({ enabled: next }),
      })
      setEnabled(result.enabled)
      setApplied(result.injectionsApplied ?? false)
      setCleanupPending(result.cleanupPending ?? false)
      if (result.cleanupError) setError(result.cleanupError)
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setSaving(false); onBusyChange?.(false) }
  }
  return <div className="rounded-lg border border-border bg-surface p-4">
    <label className="flex items-center gap-2 text-sm">
      <input type="checkbox" checked={enabled} disabled={loading || saving || !isLocalViewer()} onChange={e => e.target.checked ? void save(true) : setConfirmDisable(true)} />
      Let DST manage server configuration
    </label>
    <p className="mt-2 text-xs text-text-muted">Applies to the self-hosted battlegroup. Solo profile settings have their own local-file controls in Solo Mode. Turning this off leaves existing INI values untouched and removes DST’s deployment and startup entries from the server configuration. Explicit saves then write files only.</p>
    {!isLocalViewer() && <p className="mt-2 text-xs text-text-muted">Change management mode from DST on the host PC.</p>}
    {!enabled && <p role="note" className="mt-2 text-xs text-warning">You assume responsibility for manual configuration changes and their effects. DST cannot guarantee compatibility or accept responsibility for resulting problems. Configuration-related support may require reproducing the issue with DST management enabled.</p>}
    {cleanupPending && <p role="status" className="mt-2 text-xs text-warning">Server unavailable: YAML cleanup is pending and will run before its next DST start. INIs remain untouched.</p>}
    {enabled && !applied && <p role="status" className="mt-2 text-xs text-text-muted">Use Review & Apply in Server Settings to restore DST injections. Until then, saves write INIs only.</p>}
    {error && <p role="alert" className="mt-2 text-sm text-danger">{error}</p>}
    {confirmDisable && <ConfirmationModal title="Disable DST configuration management?" description="This removes DST settings injections from YAML and leaves all INI blocks and values intact. You assume responsibility for manual changes and resulting problems. Re-enabling requires Review & Apply in Server Settings to restore injections." confirmLabel="Disable management" onCancel={() => setConfirmDisable(false)} onConfirm={() => { setConfirmDisable(false); void save(false) }} />}
  </div>
}
