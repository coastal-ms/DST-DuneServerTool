import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import type { BgState, VmStatus, PortStatus } from '../api/types'

function vmPillClass(vm: VmStatus | undefined | null): string {
  if (!vm || !vm.exists) return 'pill-muted'
  if (vm.running) return 'pill-success'
  return 'pill-warning'
}

function portPillClass(ports: PortStatus | null | undefined, port: number, protocol: 'TCP' | 'UDP'): string {
  const r = ports?.results?.find(x => x.port === port && x.protocol === protocol)
  return r?.status === 'open' ? 'pill-success' : 'pill-muted'
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

export function StatusBar() {
  const { status, loading, forceRefresh } = useStatus()
  const vm    = status?.vm ?? null
  const ports = status?.ports ?? null
  const bgKey = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg    = BG_STYLES[bgKey] ?? BG_STYLES.unknown

  return (
    <header className="h-14 shrink-0 border-b border-border bg-surface/60 backdrop-blur-md px-5 flex items-center justify-between">
      <div className="flex items-center gap-2 text-sm text-text-muted">
        <Icon name="Server" size={16} className="text-text-dim" />
        <span>Dune Awakening dedicated server</span>
      </div>
      <div className="flex items-center gap-2">
        <span className={portPillClass(ports, 7777, 'UDP')} title="Game server ports (forward on your router/firewall)">
          <Icon name="Plug" size={11} /> 7777–7810 UDP
        </span>
        <span className={portPillClass(ports, 31982, 'TCP')} title="RabbitMQ port (forward on your router/firewall)">
          <Icon name="Plug" size={11} /> 31982 TCP
        </span>
        <span className={vmPillClass(vm)}>
          <Icon name="HardDrive" size={11} /> VM · {vmPillText(vm)}
        </span>
        <span className={bg.cls}>
          <Icon name="Activity" size={11} /> BG · {bg.label}
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
