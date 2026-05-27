import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import type { BgState, PortStatus, VmStatus } from '../api/types'

function vmPillClass(vm: VmStatus | undefined | null): string {
  if (!vm || !vm.exists) return 'pill-muted'
  if (vm.running) return 'pill-success'
  return 'pill-warning'
}

function vmPillText(vm: VmStatus | undefined | null): string {
  if (!vm) return '—'
  if (!vm.exists) return 'Not found'
  if (vm.running) return vm.ip ? `Running · ${vm.ip}` : 'Running'
  return vm.state || 'Stopped'
}

const BG_STYLES: Record<BgState | 'unknown', { cls: string; label: string }> = {
  running:  { cls: 'pill-success', label: 'Running'  },
  stopped:  { cls: 'pill-muted',   label: 'Stopped'  },
  starting: { cls: 'pill-warning', label: 'Starting' },
  stopping: { cls: 'pill-warning', label: 'Stopping' },
  updating: { cls: 'pill-info',    label: 'Updating' },
  unknown:  { cls: 'pill-muted',   label: 'Unknown'  },
}

function portsSummary(ports: PortStatus | null | undefined): { cls: string; text: string } {
  if (!ports) return { cls: 'pill-muted', text: 'Ports —' }
  if (ports.mode === 'disabled') return { cls: 'pill-muted', text: 'Ports off' }
  const tcp = ports.results.filter(r => r.protocol === 'TCP')
  if (tcp.length === 0) return { cls: 'pill-muted', text: 'Ports —' }
  const open = tcp.filter(r => r.status === 'open').length
  const cls  = open === tcp.length ? 'pill-success' : open === 0 ? 'pill-danger' : 'pill-warning'
  return { cls, text: `Ports ${open}/${tcp.length}` }
}

export function StatusBar() {
  const { status, loading, forceRefresh } = useStatus()
  const vm    = status?.vm ?? null
  const bgKey = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg    = BG_STYLES[bgKey] ?? BG_STYLES.unknown
  const p     = portsSummary(status?.ports)

  return (
    <header className="h-14 shrink-0 border-b border-border bg-surface/60 backdrop-blur-md px-5 flex items-center justify-between">
      <div className="flex items-center gap-2 text-sm text-text-muted">
        <Icon name="Server" size={16} className="text-text-dim" />
        <span>Dune Awakening dedicated server</span>
      </div>
      <div className="flex items-center gap-2">
        <span className={vmPillClass(vm)}>
          <Icon name="HardDrive" size={11} /> VM · {vmPillText(vm)}
        </span>
        <span className={bg.cls}>
          <Icon name="Activity" size={11} /> BG · {bg.label}
        </span>
        <span className={p.cls}>
          <Icon name="Plug" size={11} /> {p.text}
        </span>
        <button
          className="btn-ghost ml-2"
          onClick={() => { void forceRefresh() }}
          title="Refresh status"
          disabled={loading}
        >
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} />
        </button>
      </div>
    </header>
  )
}
