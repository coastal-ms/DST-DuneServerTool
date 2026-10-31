import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from '../router'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { getPods, getPodEvents, pruneTerminalDirectorPods, type PodSummary, type PodEventsResponse } from '../api/pods'
import { isHistoricalDirectorPod } from '../podClassification'
import { podPresentation } from '../podPresentation'

type View = 'active' | 'maps' | 'services' | 'history'
const views: [View, string][] = [['active', 'All live services'], ['maps', 'Game maps'], ['services', 'Server services'], ['history', 'History']]
const fmtTime = (value: string) => !value ? '—' : isNaN(Date.parse(value)) ? value : new Date(value).toLocaleString()

export function Pods() {
  const { status } = useStatus()
  const vmRunning = !!status?.vm?.running
  const [pods, setPods] = useState<PodSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [view, setView] = useState<View>('active')
  const [search, setSearch] = useState('')
  const [attentionOnly, setAttentionOnly] = useState(false)
  const [pruning, setPruning] = useState(false)
  const [selected, setSelected] = useState<PodSummary | null>(null)
  const [events, setEvents] = useState<PodEventsResponse | null>(null)
  const [eventsLoading, setEventsLoading] = useState(false)
  const [eventsError, setEventsError] = useState<string | null>(null)
  const [copyMessage, setCopyMessage] = useState('')
  const eventRequest = useRef(0)
  const loadPods = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const result = await getPods()
      const next = result.pods ?? []
      setPods(next)
      setSelected(previous => previous ? next.find(p => p.namespace === previous.namespace && p.name === previous.name) ?? null : null)
    } catch (e) { setError(e instanceof Error ? e.message : 'Failed to load pods.') }
    finally { setLoading(false) }
  }, [])
  useEffect(() => { if (vmRunning) void loadPods() }, [vmRunning, loadPods])
  const openPod = useCallback(async (pod: PodSummary) => {
    const request = ++eventRequest.current
    setSelected(pod); setCopyMessage(''); setEvents(null); setEventsError(null); setEventsLoading(true)
    try { const result = await getPodEvents(pod.namespace, pod.name); if (request === eventRequest.current) setEvents(result) }
    catch (e) { if (request === eventRequest.current) setEventsError(e instanceof Error ? e.message : 'Failed to load pod events.') }
    finally { if (request === eventRequest.current) setEventsLoading(false) }
  }, [])
  const entries = useMemo(() => pods.map(pod => ({ pod, ...podPresentation(pod) })), [pods])
  const counts = { active: entries.filter(p => !p.terminal).length, maps: entries.filter(p => p.group === 'maps').length, services: entries.filter(p => p.group === 'services').length, history: entries.filter(p => p.group === 'history').length }
  const attentionCount = entries.filter(p => p.needsAttention).length
  const visible = useMemo(() => entries.filter(entry => {
    if (view === 'active' ? entry.terminal : entry.group !== view) return false
    if (attentionOnly && !entry.needsAttention) return false
    return [entry.label, entry.description, entry.pod.name, entry.pod.namespace, entry.state, entry.pod.status].join(' ').toLowerCase().includes(search.trim().toLowerCase())
  }).sort((a, b) => {
    const order = { maps: 0, services: 1, history: 2 }
    return order[a.group] - order[b.group] || Number(b.needsAttention) - Number(a.needsAttention) || a.label.localeCompare(b.label) || a.pod.name.localeCompare(b.pod.name)
  }), [entries, view, attentionOnly, search])
  const detail = selected ? podPresentation(selected) : null
  const historicalDirectorCount = pods.filter(p => isHistoricalDirectorPod(p.name, p.phase)).length
  const copyDetails = async (nameOnly: boolean) => {
    if (!selected || !detail) return
    const text = nameOnly ? selected.name : [detail.label, `Pod: ${selected.name}`, `Namespace: ${selected.namespace}`, `Health: ${detail.state}`, `Ready containers: ${selected.ready}`, `Status: ${selected.status}`, `Phase: ${selected.phase}`, `Lifetime restarts: ${selected.restarts}`, `Node: ${selected.node}`, `Started: ${fmtTime(selected.startTime)}`].join('\n')
    try { await navigator.clipboard.writeText(text); setCopyMessage(nameOnly ? 'Pod name copied.' : 'Support details copied.') }
    catch { setCopyMessage('Copy is unavailable in this browser. Select the full name or details below to copy them.') }
  }
  const pruneDirectorHistory = async () => {
    setPruning(true); setError(null)
    try { await pruneTerminalDirectorPods(); await loadPods() }
    catch (e) { setError(e instanceof Error ? e.message : 'Failed to clean stale director pod history.') }
    finally { setPruning(false) }
  }
  return <>
    <PageHeader title="Pods" icon="Boxes" description="Find game maps and server services, check readiness, and copy details for support." />
    {!vmRunning ? <div className="card p-5"><p className="text-sm text-text-dim">The VM must be running to inspect services.</p></div> : <>
      <div className="flex items-center justify-between gap-3 flex-wrap mb-4">
        <div className="flex gap-2 flex-wrap" role="group" aria-label="Service groups">{views.map(([key, label]) => <button type="button" key={key} aria-pressed={view === key} className={view === key ? 'btn-primary' : 'btn-secondary'} onClick={() => { setView(key); setAttentionOnly(false) }}>{label} ({counts[key]})</button>)}</div>
        <button type="button" className="btn-secondary" disabled={loading} onClick={() => void loadPods()}><Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} /> Refresh services</button>
      </div>
      <p className={`text-sm mb-4 ${attentionCount ? 'text-warning' : 'text-text-muted'}`}>{loading && pods.length === 0 ? 'Checking services…' : error ? 'Service readiness could not be refreshed.' : pods.length === 0 ? 'No service readiness reported.' : attentionCount ? `${attentionCount} live service${attentionCount === 1 ? '' : 's'} not ready. Select an entry for its status and recent events.` : 'All reported live services are ready.'}</p>
      <div className="grid grid-cols-1 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,1fr)] gap-4 items-start">
        <section className="card p-4 min-w-0" aria-label="Service list">
          <div className="flex items-center gap-3 flex-wrap mb-4"><input className="flex-1 min-w-0 rounded-lg border border-border bg-surface-2 px-3 py-2 text-text" aria-label="Search services" placeholder="Search Hagga, database, status, or full pod name…" value={search} onChange={e => setSearch(e.target.value)} />{view !== 'history' && <label className="text-xs flex items-center gap-2 text-text-muted"><input type="checkbox" checked={attentionOnly} onChange={e => setAttentionOnly(e.target.checked)} /> Needs attention</label>}</div>
          {view === 'history' && <div className="text-sm text-text-muted mb-4 space-y-2"><p>Completed and failed jobs are past attempts, not live server health.</p><p><Link to="/database" className="text-accent hover:underline">Manage backup and restore history in Database</Link>.</p>{historicalDirectorCount > 0 && <button type="button" className="btn-secondary" disabled={pruning} onClick={() => void pruneDirectorHistory()}>{pruning ? 'Cleaning…' : `Clean director history (${historicalDirectorCount})`}</button>}</div>}
          {error && <p role="alert" className="text-sm text-danger break-words mb-3">{error}</p>}
          {loading && pods.length === 0 ? <p className="text-text-dim text-sm">Loading services…</p> : visible.length === 0 ? <p className="text-text-dim text-sm">{pods.length === 0 ? 'No pods reported.' : 'No services match this view and search.'}</p> : <div className="overflow-x-auto"><table className="w-full text-sm leading-snug">
            <thead className="text-xs text-text-dim"><tr><th className="text-left pb-2 pr-3">Map / service</th><th className="text-left pb-2 pr-3">Health</th><th className="text-left pb-2">Containers</th></tr></thead>
            <tbody>{visible.map((entry, index) => <PodRows key={`${entry.pod.namespace}/${entry.pod.name}`} heading={view === 'active' && (index === 0 || visible[index - 1]?.group !== entry.group) ? entry.group === 'maps' ? 'Game maps' : 'Server services' : null} selected={selected?.name === entry.pod.name && selected.namespace === entry.pod.namespace} pod={entry.pod} onSelect={() => void openPod(entry.pod)} />)}</tbody>
          </table></div>}
        </section>
        <section className="card p-4 min-w-0" aria-label="Service details">
          {!selected || !detail ? <><h2 className="text-lg font-semibold mb-2">Service details</h2><p className="text-sm text-text-dim">Select a map or service to see its full name, health and recent events.</p></> : <>
            <div className="flex items-start justify-between gap-3 mb-3"><div className="min-w-0"><h2 className="text-lg font-semibold break-words">{detail.label}</h2><p className="text-sm text-text-dim mt-1">{detail.description}</p></div><button type="button" className="btn-secondary shrink-0" disabled={eventsLoading} onClick={() => void openPod(selected)} aria-label="Refresh selected service events"><Icon name="RefreshCw" size={14} /></button></div>
            <p className={`font-semibold mb-3 ${detail.tone}`}>{detail.state} <span className="text-text-muted text-sm font-normal">· {selected.ready} containers ready</span></p>
            {detail.terminal && <p className="text-sm text-text-muted mb-3">This is a past attempt, not a live service. Its result does not describe the server’s current health.</p>}
            <div className="bg-bg-dim border border-border rounded-md p-3 mb-3"><p className="text-xs text-text-dim mb-1">Full pod name</p><code className="block text-xs break-all select-text">{selected.name}</code><div className="flex flex-wrap gap-2 mt-3"><button type="button" className="btn-secondary" onClick={() => void copyDetails(true)}>Copy pod name</button><button type="button" className="btn-secondary" onClick={() => void copyDetails(false)}>Copy support details</button></div>{copyMessage && <p role="status" className="text-xs text-text-muted mt-2">{copyMessage}</p>}</div>
            <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-2 text-xs mb-4">{[['Namespace', selected.namespace], ['Status', selected.status || '—'], ['Phase', selected.phase || '—'], ['Node', selected.node || '—'], ['Pod IP', selected.ip || '—'], ['Started', fmtTime(selected.startTime)], ['Lifetime restarts', String(selected.restarts)]].map(([label, value]) => <DetailRow key={label} label={label!} value={value!} />)}</dl>
            <p className="text-xs text-text-dim mb-4">Lifetime restarts include past incidents and VM reboots. Current readiness is shown above.</p>
            <h3 className="text-sm font-semibold mb-2">Recent events</h3>
            {eventsLoading ? <p className="text-sm text-text-dim">Loading events…</p> : eventsError ? <p role="alert" className="text-sm text-danger break-words">{eventsError}</p> : !events?.events.length ? <p className="text-sm text-text-dim">No recent events recorded. See readiness above for current health.</p> : <ul className="space-y-2">{events.events.map((event, index) => <li key={index} className="border border-border rounded-md p-3"><div className="flex gap-2 flex-wrap text-xs"><span className={event.type.toLowerCase() === 'warning' ? 'text-warning' : 'text-text-muted'}>{event.type} · {event.reason}</span><span className="text-text-dim">{fmtTime(event.time)}{event.count > 1 ? ` · ${event.count} occurrences` : ''}</span></div><p className="text-sm break-words mt-1">{event.message}</p></li>)}</ul>}
            {events?.describe && <details className="mt-4"><summary className="text-sm text-text-muted cursor-pointer">Technical diagnostics</summary><pre className="mt-2 text-xs font-mono bg-bg-dim border border-border rounded p-2 max-h-72 overflow-auto whitespace-pre-wrap break-words">{events.describe}</pre></details>}
          </>}
        </section>
      </div>
    </>}
  </>
}

function DetailRow({ label, value }: { label: string; value: string }) { return <><dt className="text-text-dim">{label}</dt><dd className="font-mono break-all select-text">{value}</dd></> }
function PodRows({ heading, pod, selected, onSelect }: { heading: string | null; pod: PodSummary; selected: boolean; onSelect: () => void }) {
  const info = podPresentation(pod)
  return <>{heading && <tr><th colSpan={3} className="pt-4 pb-2 text-left text-xs uppercase tracking-wider text-text-muted">{heading}</th></tr>}<tr className={`border-t border-border/40 ${selected ? 'bg-bg-dim' : 'hover:bg-bg-dim/60'}`}>
    <td className="py-2 pr-3 min-w-0"><button type="button" className="text-left w-full rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent" aria-pressed={selected} aria-label={`${info.label} — ${info.description}`} onClick={onSelect}><span className="block font-semibold break-all">{info.label}</span><span className="block text-xs text-text-dim mt-1">{info.description}</span></button></td><td className={`py-2 pr-3 ${info.tone}`}>{info.state}</td><td className="py-2 text-text-muted font-mono">{pod.ready || '—'}</td>
  </tr></>
}
