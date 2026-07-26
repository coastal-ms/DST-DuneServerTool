import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { BgSpiceSummary } from './dashboard/BgSpiceSummary'
import { ScheduledRestarts } from './dashboard/ScheduledRestarts'
import { VmMemoryPressureBanner } from './dashboard/VmMemoryPressureBanner'
import type { BgState, BgGameServer } from '../api/types'
import { getLinks, type LinksResponse } from '../api/links'
import { api, ApiError } from '../api/client'
import { mapLabel } from '../util/mapLabel'

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

function findSurvivalServer(servers: BgGameServer[]): BgGameServer | undefined {
  return servers.find(s => /survival[_-]?1/i.test(s.map))
}

function GameServerRow({ s }: { s: BgGameServer }) {
  return (
    <tr className="border-t border-border/30">
      <td className="py-1 pr-3 font-medium" title={s.sietchName ? `${s.sietchName} · ${mapLabel(s.map)}` : s.map}>
        {s.sietchName || mapLabel(s.map)}
      </td>
      <td className={`py-1 pr-3 ${healthClass(s.phase)}`}>{s.phase || '—'}</td>
      <td className={`py-1 pr-3 ${healthClass(s.ready)}`}>{s.ready || '—'}</td>
      <td className="py-1 pr-3 font-mono">{s.players || '0'}</td>
      <td className="py-1 font-mono text-text-dim">{s.age || '—'}</td>
    </tr>
  )
}

// Login-readiness heartbeat, driven by the Survival_1 map pod — that's the map
// players actually connect to, so if it isn't Ready you can't log in.
//   ready=True              → green  + "Ready"
//   in a startup phase      → yellow + "Starting"
//   down / missing / failed → red    + "Not Ready"
// Before the first status load (loading, no pods yet) the sensor goes flat.
function survivalHeartbeat(servers: BgGameServer[], loading: boolean): {
  cls: string
  label: string
  beating: boolean
} {
  const sv = findSurvivalServer(servers)
  if (!sv) {
    if (loading) return { cls: 'text-text-dim', label: 'No signal', beating: false }
    return { cls: 'text-danger', label: 'Not Ready', beating: true }
  }
  if (/^(true|ready|yes|ok)$/i.test((sv.ready ?? '').trim())) {
    return { cls: 'text-success', label: 'Ready', beating: true }
  }
  const phase = (sv.phase ?? '').toLowerCase()
  if (/(start|pending|reconcil|creating|init|progress|updating|provision|scaling|waiting)/.test(phase)) {
    return { cls: 'text-warning', label: 'Starting', beating: true }
  }
  return { cls: 'text-danger', label: 'Not Ready', beating: true }
}

function HeartbeatSensor({ servers, loading }: { servers: BgGameServer[]; loading: boolean }) {
  const hb = survivalHeartbeat(servers, loading)
  return (
    <div className="mt-auto pt-2 border-t border-border/30 flex items-center gap-2"
         title="Login readiness — driven by the Survival_1 map's ready/phase. If it isn't Ready you can't log in. Refreshes every 10s.">      <Icon
        name="HeartPulse"
        size={30}
        className={`${hb.cls} ${hb.beating ? 'animate-heartbeat' : ''}`}
      />
      <span className="text-[13px] uppercase tracking-wider text-text-dim">Game Ready State</span>
      <span className={`text-[15px] font-medium ml-auto ${hb.cls}`}>{hb.label}</span>
    </div>
  )
}

export function Dashboard() {
  const { status, forceRefresh, loading } = useStatus()
  const navigate = useNavigate()

  const vm = status?.vm
  const bgState = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg = BG_STYLES[bgState]
  const bgInfo = status?.bg?.info ?? null
  const gameServers = status?.bg?.gameServers ?? []
  const survivalPhase = findSurvivalServer(gameServers)?.phase?.trim() || ''
  const ports = status?.ports
  const portResults = Array.isArray(ports?.results) ? ports.results : []
  const tcp = portResults.filter(r => r.protocol === 'TCP')
  const openTcp = tcp.filter(r => r.status === 'open').length

  // Deep Desert / Arakeen / Harko Village — on-demand map pods.
  const bgReady = bgState === 'running'

  // Per-visit toggle for the raw `battlegroup status` text. Local state only,
  // so it resets to hidden whenever the user navigates away from the page.
  const [showRawBg, setShowRawBg] = useState(false)

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
      />

      <VmMemoryPressureBanner vmRunning={Boolean(vm?.running)} />

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
          <div className="mt-3 pt-3 border-t border-border/40 flex items-center justify-between gap-3">
            <span className="text-xs uppercase tracking-wider text-text-dim flex items-center gap-1.5">
              <Icon name="Plug" size={13} className={portsTone} />
              {ports?.mode === 'disabled' ? 'Port checks' : 'TCP ports open'}
            </span>
            <span className={`text-sm font-semibold ${portsTone} truncate`}>{portsLabel}</span>
          </div>
          <div className="mt-1 text-xs text-text-dim truncate">{portsSub || '—'}</div>
        </div>
        <div className="card card-hover p-4 flex flex-col">
          <div className="flex items-center justify-between">
            <span className="text-xs uppercase tracking-wider text-text-dim">Gameplay Admin</span>
            <Icon name="Gamepad2" size={16} className="text-accent" />
          </div>
          <p className="text-sm text-text-muted mt-2 flex-1">
            Native market, exchange, and bot tools — full gameplay administration, right here in one console.
          </p>
          <button className="btn-primary mt-3 self-start shrink-0" onClick={() => navigate('/gameplay')}>
            <Icon name="ArrowRight" size={15} /> Open Gameplay Admin
          </button>
        </div>
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
        <div className="card p-4">
          <div className="flex items-center justify-between mb-2">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="Activity" size={14} className="text-accent" /> Battlegroup info
            </h2>
            <div className="flex items-center gap-2 min-w-0">
              {status?.funcomUpdate?.available && (
                <span
                  className="inline-flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wider text-warning border border-warning/40 bg-warning/10 rounded px-1.5 py-0.5 shrink-0"
                  title={`Funcom has released a server update (installed build ${status.funcomUpdate.installedBuild || '?'}, latest ${status.funcomUpdate.latestBuild || '?'}). It is applied automatically on the next scheduled restart.`}
                >
                  <Icon name="ArrowUpCircle" size={11} /> Update
                </span>
              )}
              {status?.bg?.name && (
                <span className="text-[10px] font-mono text-text-dim truncate" title={status.bg.name}>
                  {status.bg.name}
                </span>
              )}
            </div>
          </div>
          {!bgReady ? (
            <p className="text-sm text-text-dim italic">
              {status?.bg?.reason || 'Battlegroup is not running.'}
            </p>
          ) : !bgInfo ? (
            <p className="text-sm text-text-dim italic">No battlegroup info yet.</p>
          ) : (
            <dl className="grid grid-cols-[110px_1fr] gap-x-3 gap-y-1 text-sm leading-snug">
              <dt className="text-text-dim" title="Survival_1 game-server phase. This is the login-facing battlegroup status signal.">BG Status</dt>
              <dd className={healthClass(survivalPhase)} title={`Survival_1 phase: ${survivalPhase || 'unknown'}`}>
                {survivalPhase || '—'}
              </dd>
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
          {bgReady && status?.bg?.output && (
            <div className="mt-2 flex justify-end">
              <button
                type="button"
                onClick={() => setShowRawBg(v => !v)}
                className="text-[10px] uppercase tracking-wider text-text-dim hover:text-text border border-border/40 hover:border-border rounded px-2 py-0.5 transition-colors"
                title="Show the raw `battlegroup status` output from the VM. Resets when you leave this page."
              >
                {showRawBg ? 'Hide raw output' : 'Show raw output'}
              </button>
            </div>
          )}
          {showRawBg && status?.bg?.output && (
            <pre className="mt-2 text-[10px] font-mono bg-bg-dim border border-border rounded p-2 max-h-64 overflow-auto whitespace-pre-wrap break-words text-text-dim">{status.bg.output}</pre>
          )}
          <BgSpiceSummary enabled={bgReady} />
        </div>

        <div className="card p-4 flex flex-col">
          <div className="flex items-center justify-between mb-2">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="ServerCog" size={14} className="text-accent" /> Game servers
            </h2>
            <div className="flex items-center gap-2">
              {gameServers.length > 0 && (
                <span className="text-[10px] text-text-dim">{gameServers.length} pod{gameServers.length === 1 ? '' : 's'}</span>
              )}
              <button
                type="button"
                onClick={() => { void forceRefresh() }}
                disabled={loading}
                className="p-1.5 rounded-md border border-border text-text-muted hover:text-text hover:bg-bg-dim transition-colors disabled:opacity-50"
                title="Refresh server status"
              >
                <Icon name="RefreshCw" size={18} className={loading ? 'animate-spin' : ''} />
              </button>
            </div>
          </div>
          {!bgReady ? (
            <p className="text-sm text-text-dim italic">Battlegroup must be running.</p>
          ) : gameServers.length === 0 ? (
            <p className="text-sm text-text-dim italic">No game servers reported.</p>
          ) : (
            <table className="w-full text-sm leading-snug">
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
                {gameServers.map((s, i) => <GameServerRow key={`${s.sietchName || s.map}-${i}`} s={s} />)}
              </tbody>
            </table>
          )}
          <HeartbeatSensor servers={gameServers} loading={loading} />
        </div>
      </section>

      <section className="mb-4">
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

      <section className="mb-4">
        <ScheduledRestarts />
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
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
              Hyper-V cmdlets need administrator rights. Re-launch Dune Server Tool with elevation.
            </span>
          )}
        </section>
      )}
    </>
  )
}
