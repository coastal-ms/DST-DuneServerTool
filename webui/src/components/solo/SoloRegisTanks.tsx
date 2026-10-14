import { useState } from 'react'
import { api } from '../../api/client'

export function SoloRegisTanks(_props: { connectionToken: string }) {
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const grant = async (preset: 'T6_CombatDart' | 'T6_CombatFire') => {
    setBusy(true); setMessage(''); setError('')
    try {
      const result = await api<{ message: string }>('/api/solo/mods/regis-tanks', { method: 'POST', body: JSON.stringify({ preset }) })
      setMessage(result.message)
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  return <section className="card p-4 space-y-2">
    <h3 className="text-sm font-semibold">Grant Regis Tanks</h3>
    <p className="text-xs text-text-muted">Tank support is included automatically when you launch Steam or Xbox PC Solo from DST. No separate Tank launch or enable switch is needed.</p>
    <p className="text-sm">Enter your Solo world and stand on foot in open ground before granting. One of each per launch.</p>
    <div className="flex flex-wrap gap-2">
      <button type="button" className="btn-primary" disabled={busy} onClick={() => void grant('T6_CombatDart')}>Grant Dart Tank</button>
      <button type="button" className="btn-primary" disabled={busy} onClick={() => void grant('T6_CombatFire')}>Grant Flamethrower Tank</button>
    </div>
    {message && <p role="status" className="text-sm">{message}</p>}
    {error && <p role="alert" className="text-sm text-danger">{error}</p>}
    <p className="text-xs text-text-muted">Known limitations: pink weapon effects, missing audio and misleading tread/PSU labels.</p>
  </section>
}
