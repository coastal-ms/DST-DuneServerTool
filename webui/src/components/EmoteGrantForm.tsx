import { useEffect, useRef, useState } from 'react'
import catalog from '../data/emotes.json'

/** Item delivery only. Inventory and wheel slots do not prove learned ownership. */
export function EmoteGrantForm({ busy, onGrant }: {
  busy: boolean
  onGrant: (template: string) => Promise<boolean>
}) {
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState<string[]>([])
  const [submitted, setSubmitted] = useState<string[]>([])
  const [failed, setFailed] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [running, setRunning] = useState(false)
  const mounted = useRef(true)
  useEffect(() => { mounted.current = true; return () => { mounted.current = false } }, [])
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const matches = catalog.entries.filter(entry => words.every(word => `${entry.name} ${entry.template}`.toLowerCase().includes(word)))
  const visible = new Set(matches.map(entry => entry.template))
  const chosen = catalog.entries.filter(entry => selected.includes(entry.template))
  const remaining = chosen.filter(entry => !submitted.includes(entry.template))
  const locked = busy || running

  async function grant() {
    if (locked || !remaining.length) return
    setRunning(true); setFailed(null); setError('')
    try {
      for (const entry of remaining) {
        if (!mounted.current) break
        let accepted: boolean
        try { accepted = await onGrant(entry.template) }
        catch (reason) {
          if (mounted.current) { setFailed(entry.template); setError(reason instanceof Error ? reason.message : 'Request failed.') }
          break
        }
        if (!mounted.current) break
        if (!accepted) { setFailed(entry.template); break }
        setSubmitted(previous => [...previous, entry.template])
      }
    } finally { if (mounted.current) setRunning(false) }
  }

  return <div className="space-y-3">
    <p className="text-xs text-text-muted">Choose which emote items to grant. Learned emotes are not checked; you can grant duplicates. Requests deliver items to this private server’s character and do not grant account ownership. Check inventory and the emote list in game after delivery.</p>
    <input className="input w-full" aria-label="Search emotes" placeholder="Search emote name or template" value={query} disabled={locked} onChange={event => setQuery(event.target.value)} />
    <p className="text-xs text-text-muted">Ctrl-click to select several emotes; Shift-click to select a range. Selections stay selected while searching.</p>
    <select multiple size={8} aria-label="Emotes to grant" className="w-full rounded-lg border border-border bg-surface-2 p-3 text-text text-sm" style={{ colorScheme: 'inherit' }} value={selected} disabled={locked}
      onChange={event => {
        const ids = [...selected.filter(id => !visible.has(id)), ...Array.from(event.currentTarget.selectedOptions, option => option.value)]
        setSelected(ids); setSubmitted(previous => previous.filter(id => ids.includes(id))); setFailed(null); setError('')
      }}>
      {matches.map(entry => <option key={entry.template} value={entry.template}>{entry.name}</option>)}
    </select>
    <div className="flex items-center justify-between gap-3"><span className="text-sm">{chosen.length} selected · {matches.length} matching</span><button type="button" className="btn-secondary" disabled={locked || !selected.length} onClick={() => { setSelected([]); setSubmitted([]); setFailed(null); setError('') }}>Clear selection</button></div>
    {!!chosen.length && <ul className="max-h-48 overflow-y-auto space-y-2 text-xs" aria-label="Selected emote grants">{chosen.map(entry => <li key={entry.template} className="flex justify-between gap-2"><span>{entry.name}</span><span role="status">{submitted.includes(entry.template) ? 'Request submitted' : failed === entry.template ? 'Request failed — see action result.' : 'Not submitted'}</span></li>)}</ul>}
    {error && <p role="alert" className="text-xs text-danger">{error}</p>}
    <button type="button" className="btn-primary w-full" disabled={locked || !remaining.length} onClick={() => void grant()}>{running ? 'Granting…' : `Grant selected (${remaining.length})`}</button>
  </div>
}
