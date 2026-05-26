import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import type { BgState, PortResult, BgGameServer } from '../api/types'
import { getMapState, startMap, type MapState } from '../api/maps'
import { getLinks, type LinksResponse } from '../api/links'
import { api, ApiError } from '../api/client'

const BG_STYLES: Record<BgState | 'unknown', { cls: string; label: string }> = {
  running:  { cls: 'text-success', label: 'Running'  },
  stopped:  { cls: 'text-text-muted', label: 'Stopped'  },
  starting: { cls: 'text-warning', label: 'Starting' },
  stopping: { cls: 'text-warning', label: 'Stopping' },
  updating: { cls: 'text-info',    label: 'Updating' },
  unknown:  { cls: 'text-text-muted', label: 'Unknown'  },
}

function fmtUptime(seconds: number): string {
  if (!seconds || seconds <= 0) return '—'
  const d = Math.floor(seconds / 86400)
  const h = Math.floor((seconds % 86400) / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

function portPill(r: PortResult): string {
  switch (r.status) {
    case 'open':     return 'pill-success'
    case 'closed':   return 'pill-danger'
    case 'udp-skip': return 'pill-muted'
    default:         return 'pill-warning'
  }
}

function portStatusText(r: PortResult): string {
  if (r.status === 'udp-skip') return 'UDP (skipped)'
  return r.status
}

// Map a health/phase string to a tone class. Used for Battlegroup Info
// (Healthy/Ready/...) and Game Servers (Running/Starting/...).
function healthClass(v: string | undefined): string {
  if (!v) return 'text-text-dim'
  const s = v.toLowerCase()
  if (/(healthy|ready|running|true)/.test(s)) return 'text-success'
  if (/(starting|reconciling|pending|updating|warning)/.test(s)) return 'text-warning'
  if (/(stopped|stopping|failed|error|unhealthy|crash|false)/.test(s)) return 'text-danger'
  return 'text-text'
}

function GameServerRow({ s }: { s: BgGameServer }) {
  return (
    <tr className="border-t border-border/30">
      <td className="py-1.5 pr-3 font-medium">{s.map}</td>
      <td className={`py-1.5 pr-3 ${healthClass(s.phase)}`}>{s.phase || '—'}</td>
      <td className={`py-1.5 pr-3 ${healthClass(s.ready)}`}>{s.ready || '—'}</td>
      <td className="py-1.5 pr-3 font-mono">{s.players || '0'}</td>
      <td className="py-1.5 font-mono text-text-dim">{s.age || '—'}</td>
    </tr>
  )
}

export function Dashboard() {
  const { status, forceRefresh, loading } = useStatus()

  const vm = status?.vm
  const bgState = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg = BG_STYLES[bgState]
  const bgInfo = status?.bg?.info ?? null
  const gameServers = status?.bg?.gameServers ?? []
  const ports = status?.ports
  const tcp = ports?.results.filter(r => r.protocol === 'TCP') ?? []
  const openTcp = tcp.filter(r => r.status === 'open').length

  // Deep Desert (on-demand map pod) — only fetch when BG is running.
  const bgReady = bgState === 'running'
  const [ddState, setDdState] = useState<MapState | null>(null)
  const [ddLoading, setDdLoading] = useState(false)
  const [ddError, setDdError] = useState<string | null>(null)
  const [ddBusy, setDdBusy] = useState(false)
  const [ddMessage, setDdMessage] = useState<string | null>(null)

  const refreshDd = useCallback(async () => {
    if (!bgReady) { setDdState(null); setDdError(null); return }
    setDdLoading(true); setDdError(null)
    try {
      const s = await getMapState('deepdesert')
      setDdState(s)
    } catch (e) {
      setDdState(null)
      setDdError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setDdLoading(false)
    }
  }, [bgReady])

  useEffect(() => { void refreshDd() }, [refreshDd])

  const startDd = useCallback(async () => {
    setDdBusy(true); setDdMessage(null); setDdError(null)
    try {
      const r = await startMap('deepdesert')
      setDdMessage(r.message ?? (r.ok ? 'Deep Desert is starting.' : 'Start request finished.'))
      setTimeout(() => { void refreshDd() }, 2000)
    } catch (e) {
      setDdError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setDdBusy(false)
    }
  }, [refreshDd])

  // Web Interfaces (File Browser + Director URLs)
  const [links, setLinks] = useState<LinksResponse | null>(null)
  const [linksLoading, setLinksLoading] = useState(false)
  const [linksError, setLinksError] = useState<string | null>(null)

  const refreshLinks = useCallback(async (force = false) => {
    setLinksLoading(true); setLinksError(null)
    try {
      const r = await getLinks({ force })
      setLinks(r)
    } catch (e) {
      setLinks(null)
      setLinksError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLinksLoading(false)
    }
  }, [])

  useEffect(() => { void refreshLinks() }, [refreshLinks, bgReady])

  // Log exports — run-command wrappers
  const [exportBusy, setExportBusy] = useState<string | null>(null)
  const [exportMsg,  setExportMsg]  = useState<string | null>(null)
  const [exportErr,  setExportErr]  = useState<string | null>(null)

  const runExport = useCallback(async (name: string, label: string) => {
    setExportBusy(name); setExportErr(null); setExportMsg(null)
    try {
      await api(`/api/commands/run/${encodeURIComponent(name)}`, { method: 'POST' })
      setExportMsg(`${label} launched in a console window.`)
    } catch (e) {
      setExportErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setExportBusy(null)
    }
  }, [])

  const copyToClipboard = useCallback((url: string) => {
    void navigator.clipboard?.writeText(url).catch(() => { /* ignore */ })
  }, [])

  // KPI summary — 2 combined cards: Battlegroup+VM, TCP ports+VM IP.
  const vmSubLine = !vm
    ? 'No VM data'
    : !vm.exists
      ? 'VM not found'
      : vm.running
        ? `VM ${vm.state.toLowerCase()} · up ${fmtUptime(vm.uptime)}`
        : `VM ${vm.state.toLowerCase()}`
  const portsLabel = ports?.mode === 'disabled' ? 'Disabled'
                  : tcp.length === 0 ? '—'
                  : `${openTcp}/${tcp.length}`
  const portsTone = tcp.length > 0 && openTcp === tcp.length ? 'text-success'
                : tcp.length > 0 && openTcp === 0 ? 'text-danger'
                : 'text-text-muted'
  const portsSub = [
    vm?.ip ? `VM ip: ${vm.ip}` : 'No VM ip',
    ports?.publicIp ? `public: ${ports.publicIp}` : null,
  ].filter(Boolean).join(' · ')

  return (
    <>
      <PageHeader
        title="Server Health"
        icon="LayoutDashboard"
        description="Live VM, battlegroup, and port status."
        actions={
          <button
            className="btn-secondary"
            onClick={() => { void forceRefresh() }}
            disabled={loading}
          >
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        }
      />

      <section className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
        <div className="card card-hover p-4">
          <div className="flex items-center justify-between">
            <span className="text-xs uppercase tracking-wider text-text-dim">Battlegroup + VM</span>
            <Icon name="Activity" size={16} className={bg.cls} />
          </div>
          <div className={`mt-2 text-2xl font-semibold ${bg.cls} truncate`}>{bg.label}</div>
          <div className="mt-1 text-xs text-text-dim truncate">{vmSubLine}</div>
          {status?.bg?.reason && bgState === 'unknown' && (
            <div className="mt-1 text-xs text-warning break-words">{status.bg.reason}</div>
          )}
        </div>
        <div className="card card-hover p-4">
          <div className="flex items-center justify-between">
            <span className="text-xs uppercase tracking-wider text-text-dim">
              {ports?.mode === 'disabled' ? 'Port checks' : 'TCP ports open'}
            </span>
            <Icon name="Plug" size={16} className={portsTone} />
          </div>
          <div className={`mt-2 text-2xl font-semibold ${portsTone} truncate`}>{portsLabel}</div>
          <div className="mt-1 text-xs text-text-dim truncate">{portsSub || '—'}</div>
        </div>
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
        <div className="card p-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="Activity" size={14} className="text-accent" /> Battlegroup info
            </h2>
            {status?.bg?.name && (
              <span className="text-[10px] font-mono text-text-dim truncate ml-2" title={status.bg.name}>
                {status.bg.name}
              </span>
            )}
          </div>
          {!bgReady ? (
            <p className="text-sm text-text-dim italic">
              {status?.bg?.reason || 'Battlegroup is not running.'}
            </p>
          ) : !bgInfo ? (
            <p className="text-sm text-text-dim italic">No battlegroup info yet.</p>
          ) : (
            <dl className="grid grid-cols-[110px,1fr] gap-y-2 text-sm">
              <dt className="text-text-dim">Status</dt>
              <dd className={healthClass(bgInfo.status)}>{bgInfo.status || '—'}</dd>
              <dt className="text-text-dim">Database</dt>
              <dd className={healthClass(bgInfo.database)}>{bgInfo.database || '—'}</dd>
              <dt className="text-text-dim">Gateway</dt>
              <dd className={healthClass(bgInfo.gateway)}>{bgInfo.gateway || '—'}</dd>
              <dt className="text-text-dim">Director</dt>
              <dd className={healthClass(bgInfo.director)}>{bgInfo.director || '—'}</dd>
              <dt className="text-text-dim">Uptime</dt>
              <dd className="font-mono">{bgInfo.uptime || '—'}</dd>
            </dl>
          )}
        </div>

        <div className="card p-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="ServerCog" size={14} className="text-accent" /> Game servers
            </h2>
            {gameServers.length > 0 && (
              <span className="text-[10px] text-text-dim">{gameServers.length} pod{gameServers.length === 1 ? '' : 's'}</span>
            )}
          </div>
          {!bgReady ? (
            <p className="text-sm text-text-dim italic">Battlegroup must be running.</p>
          ) : gameServers.length === 0 ? (
            <p className="text-sm text-text-dim italic">No game servers reported.</p>
          ) : (
            <table className="w-full text-sm">
              <thead className="text-[10px] uppercase tracking-wider text-text-dim">
                <tr>
                  <th className="text-left pb-1">Map</th>
                  <th className="text-left pb-1">Phase</th>
                  <th className="text-left pb-1">Ready</th>
                  <th className="text-left pb-1">Players</th>
                  <th className="text-left pb-1">Age</th>
                </tr>
              </thead>
              <tbody>
                {gameServers.map(s => <GameServerRow key={s.map} s={s} />)}
              </tbody>
            </table>
          )}
        </div>
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
        <div className="card p-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="Plug" size={14} className="text-accent" /> Public port status
            </h2>
            {ports?.cached && (
              <span className="text-[10px] text-text-dim">cached · {ports.ageSecs}s ago</span>
            )}
          </div>
          {!ports || ports.results.length === 0 ? (
            <p className="text-sm text-text-dim italic">
              {ports?.mode === 'disabled' ? 'Port checks disabled in Settings.' : 'No status yet.'}
            </p>
          ) : (
            <ul className="space-y-2">
              {ports.results.map(r => (
                <li key={`${r.protocol}-${r.port}`} className="flex items-center justify-between gap-2 text-sm">
                  <div className="min-w-0">
                    <div className="truncate">{r.label}</div>
                    <div className="text-xs text-text-dim font-mono">{r.protocol} · {r.port}</div>
                  </div>
                  <span className={portPill(r)}>
                    <Icon name={
                      r.status === 'open' ? 'CheckCircle2'
                        : r.status === 'closed' ? 'XCircle'
                        : 'CircleDashed'
                    } size={10} />
                    {portStatusText(r)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="card p-5">
          <div className="flex items-center justify-between mb-3 gap-3 flex-wrap">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="Link2" size={14} className="text-accent" /> Web interfaces
            </h2>
            <button
              className="btn-secondary"
              onClick={() => { void refreshLinks(true) }}
              disabled={linksLoading}
              title="Re-resolve Director port via SSH"
            >
              <Icon name="RefreshCw" size={14} className={linksLoading ? 'animate-spin' : ''} />
            </button>
          </div>
          {linksError ? (
            <p className="text-sm text-danger break-words">{linksError}</p>
          ) : !links ? (
            <p className="text-sm text-text-dim italic">Loading…</p>
          ) : (
            <ul className="space-y-2 text-sm">
              {([
                { key: 'fb',  label: 'File Browser',         link: links.fileBrowser, icon: 'FolderOpen' },
                { key: 'dir', label: 'Battlegroup Director', link: links.director,    icon: 'Compass' },
              ] as const).map(row => (
                <li key={row.key} className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <Icon name={row.icon} size={14} className={row.link.available ? 'text-success' : 'text-text-dim'} />
                      <span className="font-medium">{row.label}</span>
                    </div>
                    {row.link.url ? (
                      <a
                        href={row.link.url}
                        target="_blank"
                        rel="noreferrer"
                        className="text-xs text-text-dim font-mono hover:text-accent truncate block"
                      >
                        {row.link.url}
                      </a>
                    ) : (
                      <div className="text-xs text-text-dim italic">{row.link.reason ?? 'Unavailable'}</div>
                    )}
                  </div>
                  <div className="flex gap-1 shrink-0">
                    <button
                      className="btn-secondary"
                      disabled={!row.link.url}
                      onClick={() => row.link.url && copyToClipboard(row.link.url)}
                      title="Copy URL"
                    >
                      <Icon name="Copy" size={14} />
                    </button>
                    <a
                      className={`btn-primary ${!row.link.url ? 'opacity-50 pointer-events-none' : ''}`}
                      href={row.link.url ?? '#'}
                      target="_blank"
                      rel="noreferrer"
                    >
                      <Icon name="ExternalLink" size={14} /> Open
                    </a>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
        <div className="card p-5">
          <div className="flex items-center justify-between mb-3 gap-3 flex-wrap">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="Mountain" size={14} className="text-accent" /> Deep Desert
            </h2>
            <div className="flex items-center gap-2">
              {ddState && (
                <span className={ddState.running ? 'pill-success' : ddState.present ? 'pill-muted' : 'pill-warning'}>
                  <Icon name={ddState.running ? 'CheckCircle2' : ddState.present ? 'CircleDashed' : 'AlertTriangle'} size={10} />
                  {ddState.running ? 'Running' : ddState.present ? 'Stopped' : 'Not in CRD'}
                </span>
              )}
              <button
                className="btn-secondary"
                onClick={() => { void refreshDd() }}
                disabled={!bgReady || ddLoading || ddBusy}
                title={!bgReady ? 'Battlegroup must be running' : 'Refresh status'}
              >
                <Icon name="RefreshCw" size={14} className={ddLoading ? 'animate-spin' : ''} />
              </button>
              <button
                className="btn-primary"
                onClick={() => { void startDd() }}
                disabled={!bgReady || ddBusy || ddLoading || (ddState?.running ?? false)}
                title={
                  !bgReady ? 'Battlegroup must be running'
                    : ddState?.running ? 'Deep Desert is already running'
                    : 'Spin up the Deep Desert map pod'
                }
              >
                <Icon name={ddBusy ? 'Loader2' : 'Play'} size={14} className={ddBusy ? 'animate-spin' : ''} />
                {ddBusy ? 'Starting…' : 'Spin up Deep Desert'}
              </button>
            </div>
          </div>

          {!bgReady ? (
            <p className="text-sm text-text-dim italic">
              Battlegroup must be running to manage on-demand map pods.
            </p>
          ) : ddError ? (
            <p className="text-sm text-danger break-words">{ddError}</p>
          ) : !ddState ? (
            <p className="text-sm text-text-dim italic">Loading…</p>
          ) : (
            <div className="space-y-2 text-sm">
              <dl className="grid grid-cols-[160px,1fr] gap-y-1">
                <dt className="text-text-dim">Sets in CRD</dt>
                <dd className="font-mono">{ddState.setCount}</dd>
                <dt className="text-text-dim">Total replicas</dt>
                <dd className="font-mono">{ddState.totalReplicas}</dd>
                {ddState.hasDisabledPart && (
                  <>
                    <dt className="text-text-dim">Partitions disabled</dt>
                    <dd className="text-warning">Yes — will be re-enabled on spin-up</dd>
                  </>
                )}
              </dl>
              {ddState.sets.length > 0 && (
                <ul className="text-xs text-text-dim font-mono space-y-0.5">
                  {ddState.sets.map(s => (
                    <li key={s.idx}>
                      set[{s.idx}] {s.map} · replicas={s.replicas ?? '(unset)'} · partitions={s.partitionCount}
                      {s.dedicatedScaling ? ' · dedicated' : ''}
                    </li>
                  ))}
                </ul>
              )}
              {ddMessage && (
                <p className="text-xs text-text-muted border-l-2 border-accent pl-2 mt-2">{ddMessage}</p>
              )}
            </div>
          )}
        </div>

        <div className="card p-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="FileText" size={14} className="text-accent" /> Log exports
            </h2>
          </div>
          <p className="text-xs text-text-dim mb-3">
            Collects logs from every pod and writes them to your desktop. Each export opens a console window.
          </p>
          <div className="flex flex-wrap gap-2">
            <button
              className="btn-primary"
              disabled={!bgReady || exportBusy !== null}
              onClick={() => { void runExport('logs-export', 'Battlegroup log export') }}
              title={!bgReady ? 'Battlegroup must be running' : 'Export battlegroup pod logs'}
            >
              <Icon name={exportBusy === 'logs-export' ? 'Loader2' : 'Download'} size={14} className={exportBusy === 'logs-export' ? 'animate-spin' : ''} />
              Battlegroup logs
            </button>
            <button
              className="btn-primary"
              disabled={!bgReady || exportBusy !== null}
              onClick={() => { void runExport('operator-logs-export', 'Operator log export') }}
              title={!bgReady ? 'Battlegroup must be running' : 'Export operator pod logs'}
            >
              <Icon name={exportBusy === 'operator-logs-export' ? 'Loader2' : 'Download'} size={14} className={exportBusy === 'operator-logs-export' ? 'animate-spin' : ''} />
              Operator logs
            </button>
          </div>
          {exportMsg && <p className="mt-3 text-xs text-text-muted border-l-2 border-accent pl-2">{exportMsg}</p>}
          {exportErr && <p className="mt-3 text-xs text-danger break-words">{exportErr}</p>}
        </div>
      </section>

      {vm?.error && (
        <section className="card p-4 text-xs text-warning break-words">
          <span className="font-semibold">VM error:</span> {vm.error}
          {/required permission|access (?:is )?denied/i.test(vm.error) && (
            <span className="block mt-1 text-text-muted">
              Hyper-V cmdlets need administrator rights. Re-launch Dune Server with elevation.
            </span>
          )}
        </section>
      )}
    </>
  )
}
