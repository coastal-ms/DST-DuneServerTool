import { useEffect, useState } from 'react'
import { api, PlayerGuardCancelledError, withOnlinePlayerGuard } from '../../api/client'

export function RegisTankSetup({ vmRunning, stopped, onBusyChange }: { vmRunning: boolean; stopped: boolean; onBusyChange?: (busy: boolean) => void }) {
  const [state, setState] = useState<{ enabled: boolean; supported: boolean; legacyPending?: boolean } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  useEffect(() => {
    let current = true; setState(null); setError('')
    if (vmRunning) api<{ enabled: boolean; supported: boolean; legacyPending?: boolean }>('/api/gameconfig/regis-tanks')
      .then(result => { if (current) setState(result) })
      .catch(e => { if (current) setError(e instanceof Error ? e.message : String(e)) })
    return () => { current = false }
  }, [vmRunning, stopped])

  async function toggle() {
    if (!state || busy || !stopped) return
    const enabled = !state.enabled
    if (!enabled && !window.confirm('Disable Tank support? Saved Tanks may be affected when the official server starts.')) return
    setBusy(true); onBusyChange?.(true); setError('')
    try {
      await api('/api/gameconfig/regis-tanks', { method: 'PUT', body: JSON.stringify({ enabled, acknowledgeStoredTanks: !enabled }) })
      setState(await api<{ enabled: boolean; supported: boolean; legacyPending?: boolean }>('/api/gameconfig/regis-tanks'))
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false); onBusyChange?.(false) }
  }

  async function updateWithTanks() {
    if (busy || !state?.supported) return
    if (!window.confirm('Update the server with Tank support? DST will stop the battlegroup, disable Tank support, update, and restore support before restarting. If the new build is unsupported, it will stay stopped.')) return
    setBusy(true); onBusyChange?.(true); setError(''); setMessage('')
    try {
      await withOnlinePlayerGuard(force => api(`/api/commands/run/update-with-tanks${force ? '?force=true' : ''}`, { method: 'POST' }))
      setMessage('Tank update launched. Follow its progress in the command window. The battlegroup stays stopped if Tank support cannot be restored.')
    } catch (e) {
      if (!(e instanceof PlayerGuardCancelledError)) setError(e instanceof Error ? e.message : String(e))
    } finally { setBusy(false); onBusyChange?.(false) }
  }

  return <section className="card mb-4 p-4 space-y-2">
    <div className="flex items-center justify-between gap-3">
      <h3 className="text-sm font-semibold">Regis Tanks</h3>
      {state && <span className="text-xs text-text-muted">{state.enabled ? 'Enabled' : 'Disabled'}</span>}
    </div>
    <p className="text-xs text-text-muted">Optional Tank support. Normal server starts and updates do not enable it.</p>
    <p className="text-xs text-text-muted">Tanks use a custom server image outside Funcom’s normal update path. Disable support before a normal update, or use Update with Tank support to handle the steps together. The new build must be supported by DST.</p>
    {state?.legacyPending && <p role="alert" className="text-sm text-warning">Previous automatic Tank support is now off. The existing image will be removed at the next server start or update. To keep saved Tanks, stop the battlegroup and enable Tank support before then.</p>}
    <p className="text-xs text-text-muted">Starting the official server with Tank support disabled can remove saved Tanks.</p>
    <p className="text-xs text-text-muted">{!vmRunning ? 'Start the VM to check Tank support.' : !state ? (error ? 'Tank status unavailable.' : 'Checking server build…') : !state.supported ? 'Tank support is unavailable for this server build.' : state.enabled ? 'Grant Tanks from Players → Actions → Vehicle → Regis Tanks.' : 'Enable only if you want to use Regis Tanks.'}</p>
    {state && <button className="btn btn-secondary" disabled={busy || !stopped || (!state.enabled && !state.supported)} onClick={() => void toggle()}>
      {busy ? 'Applying…' : state.enabled ? 'Disable Tank support' : 'Enable Tank support'}
    </button>}
    {state && !stopped && <p className="text-xs text-text-muted">Stop the battlegroup before changing Tank support.</p>}
    {state && <button className="btn btn-secondary" disabled={busy || !state.supported} onClick={() => void updateWithTanks()}>Update with Tank support</button>}
    {message && <p role="status" className="text-sm text-text-muted">{message}</p>}
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
  </section>
}
