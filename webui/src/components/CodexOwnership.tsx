import { useMemo, useState } from 'react'
import { useApi } from '../hooks/useApi'
import { api } from '../api/client'
import { CollapsibleCard } from './CollapsibleCard'

export interface CodexFragment {
  id: string
  category: string
  entryId: string
  entry: string
  fragment: string
  owned: boolean
  revealed: boolean
}

export interface CodexOwnershipData {
  ok?: boolean
  source?: 'live' | 'demo'
  liveError?: string
  fragments: CodexFragment[]
  owned: number
  missing: number
  total: number
  profileToken?: string
}

export function CodexOwnership({ path, profileToken, grant }: {
  path: string
  profileToken?: string
  grant?: { path: string; body: Record<string, unknown>; disabled: boolean; reason: string }
}) {
  const state = useApi<CodexOwnershipData>(path)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState('all')
  const [selected, setSelected] = useState<string[]>([])
  const [granting, setGranting] = useState(false)
  const [grantError, setGrantError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const error = state.error ?? state.data?.liveError
  const data = !error && state.data && state.data.ok !== false && state.data.source !== 'demo' && (profileToken === undefined || state.data.profileToken === profileToken)
    ? state.data : null
  const groups = useMemo(() => {
    const found = new Map<string, CodexFragment[]>()
    const search = query.trim().toLowerCase()
    for (const row of data?.fragments ?? []) {
      if (filter === 'owned' && !row.owned || filter === 'missing' && row.owned) continue
      if (filter === 'hidden' && row.revealed) continue
      if (search && !`${row.category} ${row.entry} ${row.fragment}`.toLowerCase().includes(search)) continue
      const key = `${row.category} / ${row.entry}`
      found.set(key, [...(found.get(key) ?? []), row])
    }
    return [...found.entries()]
  }, [data, query, filter])
  const selectedMissing = selected.filter(id => data?.fragments.some(row => row.id === id && (!row.owned || !row.revealed)))
  async function grantSelected() {
    if (!grant || grant.disabled || granting || !selectedMissing.length) return
    if (!window.confirm(`Grant ${selectedMissing.length} selected codex fragment(s)? An automatic backup will be retained. This reveals lore ahead of normal progression; quest objectives and gameplay tags will not be completed.`)) return
    setGrantError(null)
    setMessage(null)
    setGranting(true)
    try {
      await api(grant.path, { method: 'POST', body: JSON.stringify({ ...grant.body, ids: selectedMissing, confirm: 'GRANT CODEX FRAGMENTS' }) })
      setSelected([])
      setMessage('Selected codex fragments updated. Backup retained.')
      await state.refresh()
    } catch (error) { setGrantError(error instanceof Error ? error.message : String(error)) }
    finally { setGranting(false) }
  }
  return <CollapsibleCard id={profileToken === undefined ? 'players.codex' : 'solo.codex'} title="Codex"
    className="mb-0" bodyClassName="px-5 pb-5 space-y-4"
    summary={data ? `${data.owned}/${data.total} owned` : undefined}
    headerRight={
      <button className="btn-secondary" disabled={state.loading || granting} onClick={() => { setSelected([]); void state.refresh() }}>
        {state.loading ? 'Reading…' : 'Refresh'}
      </button>
    }>
    {error && <p role="alert" className="text-sm text-red-400">{error}</p>}
    {grantError && <p role="alert" className="text-sm text-red-400">{grantError}</p>}
    {message && <p role="status" className="text-sm text-emerald-400">{message}</p>}
    {!error && state.data?.source === 'demo' && <p className="text-sm text-text-muted">Connect to live character data to view codex ownership.</p>}
    {data && <>
      <p className="text-sm text-text-muted">{data.owned}/{data.total} fragments owned · {data.missing} missing</p>
      <div className="flex flex-wrap gap-3">
        <input className="input flex-1 min-w-48" aria-label="Search codex" placeholder="Search codex…"
          value={query} onChange={event => setQuery(event.target.value)} />
        <select className="input" aria-label="Codex ownership" value={filter} onChange={event => setFilter(event.target.value)}>
          <option value="all">All fragments</option><option value="owned">Owned</option><option value="missing">Missing</option>
          <option value="hidden">Hidden</option>
        </select>
      </div>
      <div className="max-h-96 overflow-y-auto space-y-4">
        {groups.map(([entry, rows]) => <section key={entry}>
          <h4 className="text-sm font-semibold mb-2">{entry}</h4>
          <ul className="space-y-2">{rows.map(row => <li key={row.id} className="flex items-start justify-between gap-4 text-sm">
            <label className="flex items-start gap-2">
              {grant && (!row.owned || !row.revealed) && <input type="checkbox" aria-label={`Select ${row.fragment}`} checked={selected.includes(row.id)}
                disabled={granting || grant.disabled} onChange={event => setSelected(current => event.target.checked ? [...current, row.id] : current.filter(id => id !== row.id))} />}
              <span>{row.fragment}</span>
            </label>
            <span className={row.owned && row.revealed ? 'text-emerald-400 shrink-0' : 'text-text-muted shrink-0'}>{!row.revealed ? 'Hidden' : row.owned ? 'Owned' : 'Missing'}</span>
          </li>)}</ul>
        </section>)}
        {groups.length === 0 && <p className="text-sm text-text-muted">No matching fragments.</p>}
      </div>
      {grant && <div className="space-y-2">
        <div className="flex flex-wrap gap-2">
          <button className="btn-secondary" disabled={grant.disabled || granting} onClick={() => setSelected(groups.flatMap(([, rows]) => rows.filter(row => !row.owned || !row.revealed).map(row => row.id)))}>Select missing / hidden</button>
          <button className="btn-primary" disabled={grant.disabled || granting || !selectedMissing.length || state.loading} onClick={() => void grantSelected()}>
            {granting ? 'Granting…' : `Grant selected (${selectedMissing.length})`}
          </button>
        </div>
        {grant.disabled && <p className="text-xs text-text-muted">{grant.reason}</p>}
      </div>}
    </>}
  </CollapsibleCard>
}
