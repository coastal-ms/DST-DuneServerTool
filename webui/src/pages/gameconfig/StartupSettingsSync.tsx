import { useEffect, useState } from 'react'
import { api } from '../../api/client'

export function StartupSettingsSync({ onBusyChange }: { onBusyChange?: (busy: boolean) => void }) {
  const [enabled, setEnabled] = useState(true)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    let cancelled = false
    void api<{ enabled: boolean }>('/api/gameconfig/retail-startup-sync')
      .then(result => { if (!cancelled) setEnabled(result.enabled) })
      .catch(e => { if (!cancelled) setError(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [])
  const save = async (next: boolean) => {
    setSaving(true); setError(''); onBusyChange?.(true)
    try {
      const result = await api<{ enabled: boolean }>('/api/gameconfig/retail-startup-sync', {
        method: 'PUT', body: JSON.stringify({ enabled: next }),
      })
      setEnabled(result.enabled)
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setSaving(false); onBusyChange?.(false) }
  }
  return <div className="rounded-lg border border-border bg-surface p-4">
    <label className="flex items-center gap-2 text-sm">
      <input type="checkbox" checked={!enabled} disabled={loading || saving} onChange={e => void save(!e.target.checked)} />
      Disable automatic Server Settings synchronization at startup
    </label>
    <p className="mt-2 text-xs text-text-muted">Manual Server Settings saves still apply. Existing files are kept.</p>
    {error && <p role="alert" className="mt-2 text-sm text-danger">{error}</p>}
  </div>
}
