import { useCallback, useEffect, useState } from 'react'
import { api } from '../../../api/client'
import type { Player } from '../../../api/gameplay'
import { mapLabel } from '../../../util/mapLabel'

type Location = { id: string; name: string; map: string }
type State = { enabled: boolean; limit: number; shared: Location[]; private: Location[]; pending: { command: string; name: string; expiresAt: string } | null }

export function TeleportLocations({ player, canWrite }: { player: Player; canWrite: boolean }) {
  const [state, setState] = useState<State | null>(null)
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const account = player.account_id
  const load = useCallback(async () => {
    setError('')
    try { setState(await api<State>(`/api/player-portal/teleports?account_id=${account}`)) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
  }, [account])
  useEffect(() => { setState(null); setName(''); setMessage(''); void load() }, [load])
  const act = async (method: string, body: Record<string, string>) => {
    setBusy(true); setError(''); setMessage('')
    try {
      const result = await api<{ command?: string; message?: string }>('/api/player-portal/teleports', {
        method, body: JSON.stringify({ ...body, account_id: account }),
      })
      setMessage(result.message || (result.command ? 'Capture ready. Enter the code in game, then refresh this tab.' : 'Location updated.'))
      await load()
    } catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const online = player.online_status?.toLowerCase() === 'online'
  const disabled = busy || !canWrite
  return <section className="card p-4 space-y-4" aria-label="Teleport Locations">
    <div className="flex items-center justify-between gap-3">
      <h2 className="font-semibold text-lg">Teleport Locations</h2>
      <button className="btn-secondary" disabled={busy} onClick={() => void load()}>Refresh locations</button>
    </div>
    {error && <p role="alert" className="text-error">{error}</p>}
    {message && <p role="status" className="text-success">{message}</p>}
    {!state && !error && <p>Loading locations…</p>}
    {state && <>
      {!state.enabled && <p className="text-warning">The host must enable !tp in Community tools before locations can be saved or used.</p>}
      {!online && <p className="text-text-muted">The character must be online to save or use a location.</p>}
      <p className="text-sm text-text-muted">Use locations on the matching map. Private locations are five total across all maps, in addition to the shared host list.</p>
      {(['shared', 'private'] as const).map(scope => <div key={scope} className="space-y-2">
        <h3 className="font-semibold">{scope === 'shared' ? 'Shared host locations' : `Private locations (${state.private.length}/5)`}</h3>
        {state[scope].length === 0 && <p className="text-text-muted">No {scope} locations saved.</p>}
        {state[scope].map(location => <div key={location.id} className="flex flex-wrap items-center gap-3 border-b border-border py-2">
          <span className="flex-1 break-words">{location.name} <span className="text-text-muted">· {mapLabel(location.map)}</span></span>
          <button className="btn-primary" disabled={disabled || !online || !state.enabled} onClick={() => {
            if (window.confirm(`Teleport ${player.name} to ${location.name}?`)) void act('POST', { action: 'teleport', scope, id: location.id })
          }}>Teleport</button>
          {scope === 'private' && <button className="btn-secondary" disabled={disabled} onClick={() => {
            if (window.confirm(`Delete private location ${location.name}?`)) void act('DELETE', { id: location.id })
          }}>Delete</button>}
        </div>)}
      </div>)}
      <form className="flex flex-wrap gap-2" onSubmit={event => {
        event.preventDefault()
        if (state.private.some(p => p.name.toLowerCase() === name.trim().toLowerCase()) && !window.confirm(`Replace private location ${name.trim()}?`)) return
        void act('POST', { action: 'capture', name: name.trim() })
      }}>
        <label className="flex-1 min-w-48">Private location name
          <input className="block w-full mt-1 rounded-lg border border-border bg-surface px-3 py-2" maxLength={40} value={name} disabled={disabled} onChange={event => setName(event.target.value)} />
        </label>
        <button className="btn-primary self-end" disabled={disabled || !online || !state.enabled || !name.trim()}>Save current location</button>
      </form>
      <p className="text-sm text-text-muted">Stand at the destination and enter the capture code in game. Use an existing private location name to replace it.</p>
      {state.pending && <div className="space-y-2 border border-border rounded p-3">
        <p>To save <strong>{state.pending.name}</strong>, {player.name} must enter this in game within two minutes:</p>
        <code className="select-all break-all">{state.pending.command}</code>
        <button className="btn-secondary" onClick={() => {
          if (!navigator.clipboard) { setError('Select the capture command and copy it manually.'); return }
          void navigator.clipboard.writeText(state.pending!.command).then(() => setMessage('Capture command copied.'), () => setError('Could not copy. Select the capture command and copy it manually.'))
        }}>Copy command</button>
        <p className="text-sm text-text-muted">After the game confirms it was saved, refresh locations.</p>
        <button className="btn-secondary" disabled={disabled} onClick={() => void act('DELETE', { id: 'pending' })}>Cancel capture</button>
      </div>}
    </>}
  </section>
}
