import { useEffect, useState } from 'react'
import { api } from '../../api/client'

type State = { gameRunning?: boolean; gamePath: string; platform: string; mods: { id: string; enabled: boolean }[] }
export function SoloRegisTanks({ connectionToken }: { connectionToken: string }) {
  const [state, setState] = useState<State | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  useEffect(() => {
    let current = true
    api<State>('/api/solo/mods').then(result => { if (current) setState(result) }).catch(e => { if (current) setError(e instanceof Error ? e.message : String(e)) })
    return () => { current = false }
  }, [connectionToken])
  async function enable(launch: boolean) {
    setBusy(true); setError(''); setMessage('')
    try {
      setState(await api<State>('/api/solo/mods/regis-tanks/enable', { method: 'POST' }))
      if (launch) await api('/api/solo/mods/launch', { method: 'POST', body: JSON.stringify({ withMods: true }) })
      setMessage(launch ? 'Launch requested. In Solo, F8 grants a Dart Tank and F9 grants a Flamethrower Tank.' : 'Tank support enabled. Launch Solo with Tank support to use it.')
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const enabled = state?.mods.some(mod => mod.id === 'dst-regis-tanks' && mod.enabled)
  return <section className="card p-4 mb-4 space-y-3">
    <h3 className="text-sm font-semibold">Regis Tanks</h3>
    <p className="text-xs text-text-muted">Steam Solo: F8 grants the Dart variant; F9 grants the Flamethrower variant. One of each per launch. Keep Tank support enabled when loading saves containing Tanks. Pink effects and unfinished game content are expected.</p>
    <p className="text-xs text-text-muted">{enabled ? 'Tank support is enabled.' : 'Tank support is optional and disabled by default.'} {!state?.gamePath && 'Select the Steam installation folder in the Solo mods tab first.'}</p>
    <div className="flex flex-wrap gap-2">
      <button type="button" className="btn-secondary" disabled={busy || !state?.gamePath || state.platform !== 'steam' || state.gameRunning} onClick={() => void enable(false)}>Enable Tank support</button>
      <button type="button" className="btn-primary" disabled={busy || !state?.gamePath || state.platform !== 'steam' || state.gameRunning} onClick={() => void enable(true)}>Launch Solo with Tank support</button>
    </div>
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
    {message && <p role="status" className="text-sm text-text-muted">{message}</p>}
  </section>
}
