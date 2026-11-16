import { useEffect, useState } from 'react'
import { api } from '../../api/client'

export function UsageCountCard() {
  const [enabled, setEnabled] = useState(true)
  const [loading, setLoading] = useState(true)
  const [loaded, setLoaded] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let active = true
    api<{ values: Record<string, string> }>('/api/config').then(result => {
      if (active) {
        const value = (result.values.AnonymousUsageEnabled ?? '').trim()
        setEnabled(!value || /^(true|1|yes|on)$/i.test(value))
        setLoaded(true)
      }
    }).catch(() => { if (active) setError('Could not load the installation count setting.') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [])
  async function change(next: boolean) {
    setSaving(true); setError(null)
    try {
      await api('/api/config', { method: 'PUT', body: JSON.stringify({ values: { AnonymousUsageEnabled: String(next) } }) })
      setEnabled(next)
    } catch { setError('Could not save the installation count setting.') }
    finally { setSaving(false) }
  }
  return <section className="card p-5 space-y-3" aria-label="Installation count sharing">
    <h2 className="text-lg font-semibold">Installation count sharing</h2>
    <p className="text-sm text-muted">Help show how many DST installations are in use. Every six hours, DST shares only a random installation ID, its edition, and app version. Your server details, players, accounts, settings, and logs are not shared.</p>
    <label className="flex items-center gap-3">
      <input type="checkbox" checked={loaded && enabled} disabled={!loaded || saving}
        onChange={event => void change(event.target.checked)} />
      Share installation count{loading ? ' — loading…' : !loaded ? ' — unavailable' : saving ? ' — saving…' : enabled ? ' — enabled' : ' — disabled'}
    </label>
    <p className="text-sm text-muted">The count database does not store your IP address, and count requests are configured to stay out of website access logs.</p>
    <p className="text-xs text-muted">Sharing is optional and enabled by default. Turn it off at any time to stop reporting and request removal of this installation’s count.</p>
    {error && <p role="alert" className="text-sm text-red-400">{error}</p>}
  </section>
}
