import { useEffect, useState } from 'react'
import { api } from '../../api/client'

export function RegisTankSetup({ vmRunning, stopped, onBusyChange }: { vmRunning: boolean; stopped: boolean; onBusyChange?: (busy: boolean) => void }) {
  const [state, setState] = useState<{ enabled: boolean; supported: boolean } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  useEffect(() => {
    let current = true
    setState(null)
    if (vmRunning) api<{ enabled: boolean; supported: boolean }>('/api/gameconfig/regis-tanks')
      .then(result => { if (current) setState(result) })
      .catch(e => { if (current) setError(e instanceof Error ? e.message : String(e)) })
    return () => { current = false }
  }, [vmRunning, stopped])
  async function change(enabled: boolean) {
    if (!enabled && !window.confirm('Saved Tanks require compatibility to remain enabled. Disabling it may remove them when the server starts. Restore the official server image?')) return
    setBusy(true); onBusyChange?.(true); setError(''); setMessage('')
    try {
      const result = await api<{ enabled: boolean; message: string }>('/api/gameconfig/regis-tanks', { method: 'PUT', body: JSON.stringify({ enabled, acknowledgeStoredTanks: !enabled }) })
      setState({ enabled: result.enabled, supported: true }); setMessage(result.message)
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false); onBusyChange?.(false) }
  }
  return <section className="card mb-4 p-4 space-y-3">
    <h3 className="text-sm font-semibold">Regis Tanks</h3>
    <p className="text-xs text-text-muted">Enable Tank compatibility, then grant either variant from Players → Actions → Vehicle → Regis Tanks. Existing Tanks need compatibility on every start. Disable it before updating the server.</p>
    <p className="text-xs text-text-muted">{!vmRunning ? 'Start the VM to configure Tank compatibility.' : !state ? 'Checking server build…' : !state.supported ? 'Tank compatibility is unavailable for this server build.' : state.enabled ? 'Tank compatibility is enabled.' : 'Tank compatibility is disabled.'}</p>
    <div className="flex flex-wrap gap-2">
      <button type="button" className="btn-primary" disabled={busy || !vmRunning || !stopped || !state?.supported || state.enabled} onClick={() => void change(true)}>{busy ? 'Preparing compatibility…' : 'Enable Tank compatibility'}</button>
      <button type="button" className="btn-secondary" disabled={busy || !vmRunning || !stopped || !state?.enabled} onClick={() => void change(false)}>Disable Tank compatibility</button>
    </div>
    {vmRunning && !stopped && <p className="text-xs text-text-muted">Stop the battlegroup before changing compatibility.</p>}
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
    {message && <p role="status" className="text-sm text-text-muted">{message}</p>}
  </section>
}
