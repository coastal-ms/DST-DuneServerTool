import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import type { BgState, PortResult } from '../api/types'

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

export function Dashboard() {
  const { status, forceRefresh, loading } = useStatus()

  const vm = status?.vm
  const bgState = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg = BG_STYLES[bgState]
  const ports = status?.ports
  const tcp = ports?.results.filter(r => r.protocol === 'TCP') ?? []
  const openTcp = tcp.filter(r => r.status === 'open').length

  const kpis = [
    {
      label: 'Battlegroup',
      value: bg.label,
      icon: 'Activity',
      tone: bg.cls,
      sub: status?.bg?.reason && bgState === 'unknown' ? status.bg.reason : undefined,
    },
    {
      label: 'VM',
      value: !vm ? '—' : !vm.exists ? 'Not found' : vm.running ? 'Running' : (vm.state || 'Stopped'),
      icon: 'HardDrive',
      tone: vm?.running ? 'text-success' : 'text-text-muted',
      sub: vm?.running && vm.uptime > 0 ? `Up ${fmtUptime(vm.uptime)}` : undefined,
    },
    {
      label: 'VM IP',
      value: vm?.ip || '—',
      icon: 'Network',
      tone: vm?.ip ? 'text-text' : 'text-text-muted',
      sub: vm?.name ? `vm: ${vm.name}` : undefined,
    },
    {
      label: ports?.mode === 'disabled' ? 'Port checks' : 'TCP ports open',
      value: ports?.mode === 'disabled'
        ? 'Disabled'
        : tcp.length === 0 ? '—' : `${openTcp}/${tcp.length}`,
      icon: 'Plug',
      tone: tcp.length > 0 && openTcp === tcp.length ? 'text-success'
          : tcp.length > 0 && openTcp === 0 ? 'text-danger'
          : 'text-text-muted',
      sub: ports?.publicIp ? `public ip: ${ports.publicIp}` : undefined,
    },
  ]

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

      <section className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {kpis.map(k => (
          <div key={k.label} className="card card-hover p-4">
            <div className="flex items-center justify-between">
              <span className="text-xs uppercase tracking-wider text-text-dim">{k.label}</span>
              <Icon name={k.icon} size={16} className={k.tone} />
            </div>
            <div className={`mt-2 text-2xl font-semibold ${k.tone} truncate`}>{k.value}</div>
            {k.sub && <div className="mt-1 text-xs text-text-dim truncate">{k.sub}</div>}
          </div>
        ))}
      </section>

      <section className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="card p-5">
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
              <Icon name="HardDrive" size={14} className="text-accent" /> Virtual machine
            </h2>
          </div>
          {!vm ? (
            <p className="text-sm text-text-dim italic">No status yet.</p>
          ) : (
            <dl className="grid grid-cols-[120px,1fr] gap-y-2 text-sm">
              <dt className="text-text-dim">Name</dt>
              <dd className="font-mono">{vm.name}</dd>
              <dt className="text-text-dim">State</dt>
              <dd>{vm.state}</dd>
              <dt className="text-text-dim">IP</dt>
              <dd className="font-mono">{vm.ip || '—'}</dd>
              <dt className="text-text-dim">Uptime</dt>
              <dd>{vm.running ? fmtUptime(vm.uptime) : '—'}</dd>
              {vm.error && (
                <>
                  <dt className="text-text-dim">Error</dt>
                  <dd className="text-warning text-xs break-words">
                    {vm.error}
                    {/required permission|access (?:is )?denied/i.test(vm.error) && (
                      <span className="block mt-1 text-text-muted">
                        Hyper-V cmdlets need administrator rights. Re-launch Dune Server with elevation.
                      </span>
                    )}
                  </dd>
                </>
              )}
            </dl>
          )}
        </div>

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
      </section>
    </>
  )
}
