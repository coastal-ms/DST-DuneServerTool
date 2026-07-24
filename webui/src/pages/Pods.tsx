import { useCallback, useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { ApiError } from '../api/client'
import {
  getPods,
  getPodEvents,
  type PodSummary,
  type PodEventsResponse,
} from '../api/pods'
import { getBackupOpPodInfo, backupOpKindLabel, isFailedPodStatus } from '../podClassification'

function statusTone(status: string): string {
  const s = (status || '').toLowerCase()
  if (/(running|succeeded|completed|ready)/.test(s)) return 'text-success'
  if (/(pending|containercreating|init|terminating|waiting)/.test(s)) return 'text-warning'
  if (/(crash|error|failed|backoff|imagepull|evicted|oomkilled)/.test(s)) return 'text-danger'
  return 'text-text'
}

function eventTone(type: string): string {
  const t = (type || '').toLowerCase()
  if (t === 'warning') return 'text-warning'
  if (t === 'normal') return 'text-text-dim'
  return 'text-text'
}

function fmtTime(t: string): string {
  if (!t) return '—'
  const d = new Date(t)
  if (isNaN(d.getTime())) return t
  return d.toLocaleString()
}

export function Pods() {
  const { status } = useStatus()
  const vmRunning = !!status?.vm?.running

  const [pods, setPods] = useState<PodSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [selected, setSelected] = useState<PodSummary | null>(null)
  const [events, setEvents] = useState<PodEventsResponse | null>(null)
  const [eventsLoading, setEventsLoading] = useState(false)
  const [eventsError, setEventsError] = useState<string | null>(null)

  const loadPods = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await getPods()
      setPods(r.pods ?? [])
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Failed to load pods.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void loadPods() }, [loadPods])

  const openPod = useCallback(async (pod: PodSummary) => {
    setSelected(pod)
    setEvents(null)
    setEventsError(null)
    setEventsLoading(true)
    try {
      const r = await getPodEvents(pod.namespace, pod.name)
      setEvents(r)
    } catch (e) {
      setEventsError(e instanceof ApiError ? e.message : 'Failed to load pod events.')
    } finally {
      setEventsLoading(false)
    }
  }, [])

  const refreshEvents = useCallback(() => {
    if (selected) void openPod(selected)
  }, [selected, openPod])

  // Funcom's battlegroup backup/restore jobs leave a terminal, never-GC'd pod
  // behind on every run (Succeeded, or Failed after a specific attempt's
  // OOM/eviction). They look identical to a live-service crash here unless
  // flagged — see the Database page's "Completed backup & restore pods" for
  // the same identification + cleanup.
  const opPodCount = useMemo(() => pods.filter(p => getBackupOpPodInfo(p.name)).length, [pods])
  const selectedOpInfo = selected ? getBackupOpPodInfo(selected.name) : null

  return (
    <>
      <PageHeader
        title="Pods"
        icon="Boxes"
        description="Every Kubernetes pod in the battlegroup cluster. Click a pod to see its recent events."
      />

      {!vmRunning ? (
        <div className="card p-5">
          <p className="text-sm text-text-dim italic">The VM must be running to inspect pods.</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
          {/* Pod list */}
          <div className="card p-4">
            <div className="flex items-center justify-between mb-3 gap-2">
              <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
                <Icon name="Boxes" size={14} className="text-accent" /> Pods
                {pods.length > 0 && <span className="text-[10px] text-text-dim">({pods.length})</span>}
              </h2>
              <button
                type="button"
                onClick={() => { void loadPods() }}
                disabled={loading}
                className="p-1.5 rounded-md border border-border text-text-muted hover:text-text hover:bg-bg-dim transition-colors disabled:opacity-50"
                title="Refresh pod list"
              >
                <Icon name="RefreshCw" size={16} className={loading ? 'animate-spin' : ''} />
              </button>
            </div>

            {opPodCount > 0 && (
              <div className="mb-3 flex items-start gap-2 rounded-md border border-info/30 bg-info/5 px-3 py-2 text-xs text-text-muted">
                <Icon name="Info" size={14} className="text-info shrink-0 mt-0.5" />
                <span>
                  {opPodCount} pod{opPodCount === 1 ? '' : 's'} below {opPodCount === 1 ? 'is' : 'are'} tagged{' '}
                  <span className="font-mono text-[10px]">Backup</span>/<span className="font-mono text-[10px]">Restore</span> —
                  one-shot completed jobs from Funcom's <span className="font-mono">battlegroup backup</span>/
                  <span className="font-mono">import</span> commands, not live services. A red{' '}
                  <span className="text-danger font-medium">Failed</span> there means that specific backup or restore
                  attempt didn't finish; it does not indicate a current server problem. Manage retention and cleanup on{' '}
                  <Link to="/database" className="text-accent hover:underline">Database → Backup &amp; restore operation pods</Link>.
                </span>
              </div>
            )}

            {loading ? (
              <p className="text-sm text-text-dim italic">Loading…</p>
            ) : error ? (
              <p className="text-sm text-danger break-words">{error}</p>
            ) : pods.length === 0 ? (
              <p className="text-sm text-text-dim italic">No pods reported.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm leading-snug">
                  <thead className="text-[10px] uppercase tracking-wider text-text-dim">
                    <tr>
                      <th className="text-left pb-1 pr-3">Pod</th>
                      <th className="text-left pb-1 pr-3">Ready</th>
                      <th className="text-left pb-1 pr-3">Status</th>
                      <th className="text-left pb-1">Restarts</th>
                    </tr>
                  </thead>
                  <tbody>
                    {pods.map(p => {
                      const isSel = selected?.namespace === p.namespace && selected?.name === p.name
                      const opInfo = getBackupOpPodInfo(p.name)
                      const opFailed = !!opInfo && isFailedPodStatus(p.status)
                      return (
                        <tr
                          key={`${p.namespace}/${p.name}`}
                          onClick={() => { void openPod(p) }}
                          className={`border-t border-border/30 cursor-pointer transition-colors ${isSel ? 'bg-bg-dim' : 'hover:bg-bg-dim/60'}`}
                        >
                          <td className="py-1.5 pr-3">
                            <div className="flex items-center gap-1.5 flex-wrap">
                              <div className="font-medium truncate max-w-[220px]" title={p.name}>{p.name}</div>
                              {opInfo && (
                                <span
                                  className={`shrink-0 text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded border ${opInfo.kind === 'dump' ? 'border-info/40 text-info' : 'border-accent/40 text-accent'}`}
                                  title={`${backupOpKindLabel(opInfo.kind)} operation pod from ${opInfo.timestamp.toLocaleString()} — a one-shot job, not a live service.`}
                                >
                                  {backupOpKindLabel(opInfo.kind)}
                                </span>
                              )}
                            </div>
                            <div className="text-[10px] text-text-dim font-mono">{p.namespace}</div>
                          </td>
                          <td className="py-1.5 pr-3 font-mono">{p.ready || '—'}</td>
                          <td className={`py-1.5 pr-3 ${statusTone(p.status)}`}>
                            {p.status || '—'}
                            {opFailed && (
                              <div className="text-[9px] text-text-dim normal-case font-normal">One-time attempt only</div>
                            )}
                          </td>
                          <td className={`py-1.5 font-mono ${p.restarts > 0 ? 'text-warning' : 'text-text-dim'}`}>{p.restarts}</td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* Pod events / detail */}
          <div className="card p-4">
            <div className="flex items-center justify-between mb-3 gap-2">
              <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2 min-w-0">
                <Icon name="Activity" size={14} className="text-accent" />
                <span className="truncate">{selected ? selected.name : 'Pod events'}</span>
              </h2>
              {selected && (
                <button
                  type="button"
                  onClick={refreshEvents}
                  disabled={eventsLoading}
                  className="p-1.5 rounded-md border border-border text-text-muted hover:text-text hover:bg-bg-dim transition-colors disabled:opacity-50"
                  title="Refresh events"
                >
                  <Icon name="RefreshCw" size={16} className={eventsLoading ? 'animate-spin' : ''} />
                </button>
              )}
            </div>

            {!selected ? (
              <p className="text-sm text-text-dim italic">Select a pod to view its events.</p>
            ) : eventsLoading ? (
              <p className="text-sm text-text-dim italic">Loading events…</p>
            ) : eventsError ? (
              <p className="text-sm text-danger break-words">{eventsError}</p>
            ) : (
              <>
                {selectedOpInfo && (
                  <div className="mb-3 flex items-start gap-2 rounded-md border border-info/30 bg-info/5 px-3 py-2 text-xs text-text-muted">
                    <Icon name="Info" size={14} className="text-info shrink-0 mt-0.5" />
                    <span>
                      This is a completed {selectedOpInfo.kind === 'dump' ? 'backup' : 'restore'} job pod from{' '}
                      <span className="font-mono">{selectedOpInfo.timestamp.toLocaleString()}</span>, not a live
                      service — a failure here reflects only that one attempt, not a current server problem.
                      {isFailedPodStatus(selected.status) && ' See the events below for why it failed.'} Manage and
                      prune these on{' '}
                      <Link to="/database" className="text-accent hover:underline">Database → Backup &amp; restore operation pods</Link>.
                    </span>
                  </div>
                )}
                <dl className="grid grid-cols-[80px_1fr] gap-x-3 gap-y-0.5 text-xs mb-3">
                  <dt className="text-text-dim">Namespace</dt>
                  <dd className="font-mono truncate">{selected.namespace}</dd>
                  <dt className="text-text-dim">Node</dt>
                  <dd className="font-mono truncate">{selected.node || '—'}</dd>
                  <dt className="text-text-dim">Pod IP</dt>
                  <dd className="font-mono truncate">{selected.ip || '—'}</dd>
                  <dt className="text-text-dim">Started</dt>
                  <dd className="font-mono truncate">{fmtTime(selected.startTime)}</dd>
                </dl>

                {!events || events.events.length === 0 ? (
                  <p className="text-sm text-text-dim italic">No recent events for this pod.</p>
                ) : (
                  <ul className="space-y-2">
                    {events.events.map((ev, i) => (
                      <li key={i} className="border border-border/40 rounded-md px-3 py-2">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span className={`text-[10px] font-semibold uppercase tracking-wider ${eventTone(ev.type)}`}>{ev.type || '—'}</span>
                          <span className="text-xs font-medium">{ev.reason || '—'}</span>
                          {ev.count > 1 && <span className="text-[10px] text-text-dim">×{ev.count}</span>}
                          <span className="text-[10px] text-text-dim ml-auto">{fmtTime(ev.time)}</span>
                        </div>
                        <p className="text-xs text-text-muted mt-1 break-words">{ev.message}</p>
                        {ev.source && <p className="text-[10px] text-text-dim mt-0.5 font-mono">{ev.source}</p>}
                      </li>
                    ))}
                  </ul>
                )}

                {events?.describe && (
                  <details className="mt-3">
                    <summary className="text-[10px] uppercase tracking-wider text-text-dim cursor-pointer hover:text-text">Describe tail</summary>
                    <pre className="mt-2 text-[10px] font-mono bg-bg-dim border border-border rounded p-2 max-h-72 overflow-auto whitespace-pre-wrap break-words text-text-dim">{events.describe}</pre>
                  </details>
                )}
              </>
            )}
          </div>
        </div>
      )}
    </>
  )
}
