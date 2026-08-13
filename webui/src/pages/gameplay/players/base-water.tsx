import { useMemo, useState } from 'react'
import { Icon } from '../../../components/Icon'
import { fillBaseWater, type Player } from '../../../api/gameplay'

type Flash = (msg: string, kind?: 'ok' | 'err') => void

export function BaseWaterAdmin({
  players,
  canWrite,
  flash,
}: {
  players: Player[]
  canWrite: boolean
  flash: Flash
}) {
  const [controllerId, setControllerId] = useState('')
  const [busy, setBusy] = useState(false)
  const options = useMemo(
    () => [...players]
      .filter(p => p.controller_id > 0)
      .sort((a, b) => (a.name || '').localeCompare(b.name || '')),
    [players],
  )
  const selected = options.find(p => String(p.controller_id) === controllerId)

  const run = async () => {
    if (!selected) return
    const name = selected.name || `controller ${selected.controller_id}`
    const confirmed = window.confirm(
      `Fill every small, medium, and large cistern on ${name}'s owned bases?\n\n` +
      'DST will create a database backup, stop the battlegroup, disconnect every online player, ' +
      'fill only this player\'s owned cisterns, then start the battlegroup again. ' +
      'Blood-water extractors and windtraps are not changed.\n\nThis can take several minutes.',
    )
    if (!confirmed) return

    setBusy(true)
    try {
      const result = await fillBaseWater(selected.controller_id)
      flash(result.message)
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="card p-4 space-y-3">
      <div className="flex items-center gap-2 text-xs uppercase tracking-wider text-text-dim">
        <Icon name="Droplets" size={13} /> Fill Base Water
      </div>

      <p className="text-xs text-text-dim">
        Fill every supported cistern on one player's owned bases. Small, medium, and large
        cisterns are set to their exact capacities; windtraps and blood-water extractors are excluded.
      </p>

      <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs space-y-1.5">
        <div className="flex items-center gap-2 font-semibold text-warning">
          <Icon name="AlertTriangle" size={14} /> Battlegroup restart required
        </div>
        <p className="text-text-dim">
          Cistern state is cached by the map servers. DST must back up the database, stop the entire
          battlegroup, apply the fill while every map is offline, then start it again. All connected
          players will be disconnected, even though only the selected player's cisterns are changed.
        </p>
      </div>

      <label className="block text-xs">
        <span className="block text-text-dim mb-1">Base owner</span>
        <select
          aria-label="Base owner"
          value={controllerId}
          disabled={busy || !canWrite}
          onChange={e => setControllerId(e.target.value)}
          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm"
        >
          <option value="">Select a player...</option>
          {options.map(p => (
            <option key={p.controller_id} value={String(p.controller_id)}>
              {p.name || `Player ${p.id}`} - controller {p.controller_id}
            </option>
          ))}
        </select>
      </label>

      <button
        type="button"
        className="btn-primary"
        disabled={busy || !canWrite || !selected}
        onClick={() => { void run() }}
      >
        <Icon name={busy ? 'Loader2' : 'Droplets'} size={13} className={busy ? 'animate-spin' : ''} />
        {busy ? 'Backing up, filling, and restarting...' : 'Fill selected player\'s base cisterns'}
      </button>
    </div>
  )
}
