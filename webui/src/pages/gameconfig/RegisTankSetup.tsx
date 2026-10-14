import { useEffect, useState } from 'react'
import { api } from '../../api/client'
export function RegisTankSetup({ vmRunning, stopped }: { vmRunning: boolean; stopped: boolean; onBusyChange?: (busy: boolean) => void }) {
  const [state, setState] = useState<{ enabled: boolean; supported: boolean } | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    let current = true; setState(null); setError('')
    if (vmRunning) api<{ enabled: boolean; supported: boolean }>('/api/gameconfig/regis-tanks')
      .then(result => { if (current) setState(result) })
      .catch(e => { if (current) setError(e instanceof Error ? e.message : String(e)) })
    return () => { current = false }
  }, [vmRunning, stopped])
  return <section className="card mb-4 p-4 space-y-2">
    <h3 className="text-sm font-semibold">Regis Tanks</h3>
    <p className="text-xs text-text-muted">Support is prepared automatically on supported server builds during battlegroup start. Grant either variant from Players → Actions → Vehicle → Regis Tanks.</p>
    <p className="text-xs text-text-muted">{!vmRunning ? 'Start the VM to check Tank support.' : !state ? 'Checking server build…' : !state.supported ? 'Tank support is unavailable for this server build.' : state.enabled ? 'Tank support is ready.' : 'Tank support will be prepared at the next battlegroup start.'}</p>
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
  </section>
}
