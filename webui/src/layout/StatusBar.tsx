import { Link } from '../router'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import type { BgState, VmStatus, PortStatus } from '../api/types'
import { usePortalAuth } from '../auth/PortalAuthGate'
import { getTestBuildIdentity } from '../util/testBuildIdentity'
import { usePortalAccess } from '../auth/portalAccess'
import { setCommandDeck, useCommandDeck } from '../hooks/useCommandDeck'
import { portResultPresentation } from '../util/portStatusPresentation'

function vmPillClass(vm: VmStatus | undefined | null): string {
  if (!vm || !vm.exists) return 'pill-muted'
  if (vm.running) return 'pill-success'
  return 'pill-warning'
}

function getPortPresentation(ports: PortStatus | null | undefined, port: number, protocol: 'TCP' | 'UDP') {
  const results = Array.isArray(ports?.results) ? ports.results : []
  const r = results.find(x => x.port === port && x.protocol === protocol)
  return { ...portResultPresentation(r), detail: r?.detail }
}

function vmPillText(vm: VmStatus | undefined | null): string {
  if (!vm) return '—'
  if (!vm.exists) return 'Not found'
  // Defensive stringification: if the backend hands back a non-string ip
  // (seen 2026-07-05 when Get-DuneVmStatus returned a wrapping PSObject on a
  // multi-adapter VM), rendering `${ip}` in the pill text yields
  // `[object Object]`. Coerce to string and reject anything that isn't a
  // proper dotted IPv4.
  const rawIp = (vm as unknown as { ip?: unknown }).ip
  const ip = typeof rawIp === 'string' && /^\d{1,3}(\.\d{1,3}){3}$/.test(rawIp) ? rawIp : ''
  if (vm.running) return ip ? `Running · ${ip}` : 'Running'
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
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const { status, loading, forceRefresh } = useStatus()
  const { data: upd } = useUpdateCheck()
  const testBuild = getTestBuildIdentity(upd)
  const vm    = status?.vm ?? null
  const ports = status?.ports ?? null
  const bgKey = (status?.bg?.state ?? 'unknown') as BgState | 'unknown'
  const bg    = BG_STYLES[bgKey] ?? BG_STYLES.unknown
  const serverName = (status?.serverName ?? '').trim()
  const portalAuth = usePortalAuth()
  const commandDeck = useCommandDeck()
  const udpPort = getPortPresentation(ports, 7777, 'UDP')
  const rabbitPort = getPortPresentation(ports, 31982, 'TCP')

  return (
    <header className="h-14 shrink-0 border-b border-border bg-surface/60 backdrop-blur-md px-3 sm:px-5 flex items-center justify-between gap-2 sm:gap-4 overflow-hidden">
      <div className="hidden lg:flex items-center gap-2 text-sm text-text-muted shrink-0">
        <Icon name="Server" size={16} className="text-text-dim" />
        <span>Dune Self Host Server Tool</span>
      </div>
      <div className="flex-1 flex items-center justify-start lg:justify-center min-w-0">
        {serverName && (
          <div className="flex items-center gap-2 min-w-0">
            <Icon name="Server" size={20} className="text-accent shrink-0" />
            <span
              className="text-base sm:text-[22px] leading-none font-semibold tracking-tight text-text truncate"
              title={`Server: ${serverName}`}
            >
              {serverName}
            </span>
          </div>
        )}
      </div>
      <div className="flex items-center gap-1 sm:gap-2 shrink-0">
        <button type="button" className="btn-ghost" aria-pressed={commandDeck}
          onClick={() => setCommandDeck(!commandDeck)}
          title={commandDeck ? 'Return to classic layout' : 'Try the Command Deck preview'}>
          <Icon name="PanelsTopLeft" size={16} />
          <span className="hidden xl:inline">{commandDeck ? 'Classic layout' : 'Try Command Deck'}</span>
          <span className="sr-only xl:hidden">{commandDeck ? 'Return to classic layout' : 'Try Command Deck'}</span>
        </button>
        {portalAuth?.status.account && (
          <button className="btn-ghost" onClick={() => void portalAuth.logout()} title="Sign out of the Browser Portal">
            <Icon name="LogOut" size={14} />
            <span className="hidden xl:inline">{portalAuth.status.account.username}</span>
          </button>
        )}
        {testBuild && canAccessOwnerSurfaces && (
          <Link
            to="/settings"
            className="pill-warning hover:bg-warning/20 transition-colors"
            title={`${testBuild.title}. Click to open Settings, switch to Stable, and install the released build.`}
          >
            <Icon name="FlaskConical" size={11} />
            <span className="hidden sm:inline">{testBuild.label}</span>
            <span className="sr-only sm:hidden">{testBuild.title}</span>
          </Link>
        )}
        {ports?.showUdp && (
          <span className={`${udpPort.pillClass} hidden md:inline-flex`} title="Game server ports (forward on your router/firewall). Shown because you enabled a custom UDP port check.">
            <Icon name="Plug" size={11} /> 7777–7810 UDP · {udpPort.label}
          </span>
        )}
        <span className={`${rabbitPort.pillClass} hidden md:inline-flex`} title={`RabbitMQ port (forward on your router/firewall). ${rabbitPort.label}.${rabbitPort.detail ? ` ${rabbitPort.detail}` : ''}`}>
          <Icon name="Plug" size={11} /> 31982 TCP · {rabbitPort.label}
        </span>
        <span className={`${vmPillClass(vm)} hidden sm:inline-flex`}>
          <Icon name="HardDrive" size={11} /> VM · {vmPillText(vm)}
        </span>
        <span className={bg.cls}>
          <Icon name="Activity" size={11} />
          <span className="hidden min-[360px]:inline">BG · </span>{bg.label}
        </span>
        <button
          className="btn-ghost h-11 w-11 justify-center p-0"
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
