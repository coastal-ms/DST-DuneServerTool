import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import {
  getTailscaleStatus,
  openTailscaleConsole,
  type TailscaleStatus,
  type TailscaleNode,
} from '../api/tailscale'

function osIcon(os: string): string {
  const o = (os || '').toLowerCase()
  if (o.includes('windows')) return 'MonitorSmartphone'
  if (o.includes('linux')) return 'Server'
  if (o.includes('android')) return 'Smartphone'
  if (o.includes('ios') || o.includes('macos') || o.includes('mac')) return 'Apple'
  return 'HardDrive'
}

function fmtLastSeen(iso: string, online: boolean): string {
  if (online) return 'now'
  if (!iso || iso.startsWith('0001')) return '—'
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return '—'
  const secs = Math.max(0, Math.round((Date.now() - t) / 1000))
  if (secs < 60) return `${secs}s ago`
  const mins = Math.round(secs / 60)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(mins / 60)
  if (hrs < 24) return `${hrs}h ago`
  const days = Math.round(hrs / 24)
  return `${days}d ago`
}

function IpList({ ips }: { ips: string[] }) {
  const [copied, setCopied] = useState<string | null>(null)
  const copy = async (ip: string) => {
    try {
      await navigator.clipboard.writeText(ip)
      setCopied(ip)
      window.setTimeout(() => setCopied(c => (c === ip ? null : c)), 1500)
    } catch { /* clipboard may be unavailable */ }
  }
  if (!ips.length) return <span className="text-text-dim">—</span>
  return (
    <div className="flex flex-col gap-0.5">
      {ips.map(ip => (
        <button key={ip} type="button" onClick={() => void copy(ip)} title="Copy IP"
          className="font-mono text-xs text-text-muted hover:text-text inline-flex items-center gap-1 w-fit">
          {ip}
          <Icon name={copied === ip ? 'Check' : 'Copy'} size={11} className={copied === ip ? 'text-success' : 'opacity-40'} />
        </button>
      ))}
    </div>
  )
}

function DeviceRow({ node, isSelf }: { node: TailscaleNode; isSelf?: boolean }) {
  return (
    <tr className={`border-b border-border/50 ${isSelf ? 'bg-surface-2/60' : 'hover:bg-surface-2'}`}>
      <td className="px-3 py-2">
        <div className="flex items-center gap-2">
          <Icon name={osIcon(node.os)} size={15} className="text-text-dim shrink-0" />
          <div className="min-w-0">
            <div className="font-medium text-text truncate max-w-[260px] flex items-center gap-1.5">
              {node.name || <span className="text-text-dim italic">unknown</span>}
              {isSelf && <span className="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent-bright">this PC</span>}
              {node.exitNode && <span className="text-[10px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-surface-2 text-text-dim border border-border">exit node</span>}
            </div>
            {node.dnsName && <div className="text-[11px] text-text-dim font-mono truncate max-w-[260px]">{node.dnsName}</div>}
          </div>
        </div>
      </td>
      <td className="px-3 py-2 hidden sm:table-cell text-text-muted text-xs">{node.os || '—'}</td>
      <td className="px-3 py-2"><IpList ips={node.tailscaleIPs} /></td>
      <td className="px-3 py-2 text-center">
        {node.online
          ? <span className="inline-flex items-center gap-1 text-success text-xs"><span className="w-2 h-2 rounded-full bg-success inline-block" /> online</span>
          : <span className="inline-flex items-center gap-1 text-text-dim text-xs"><span className="w-2 h-2 rounded-full bg-text-dim/50 inline-block" /> offline</span>}
      </td>
      <td className="px-3 py-2 text-right hidden md:table-cell text-xs text-text-dim">{fmtLastSeen(node.lastSeen, node.online)}</td>
    </tr>
  )
}

export function Tailscale() {
  const [status, setStatus] = useState<TailscaleStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [opening, setOpening] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      setStatus(await getTailscaleStatus())
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const onOpenConsole = useCallback(async () => {
    setOpening(true)
    try {
      await openTailscaleConsole()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setOpening(false)
    }
  }, [])

  const online = status?.peers.filter(p => p.online).length ?? 0
  const total = status?.peers.length ?? 0

  return (
    <div>
      <PageHeader
        title="Tailscale"
        icon="Share2"
        description="Your tailnet at a glance — the devices and IPs you use to reach this server."
        actions={
          <>
            <button className="btn-secondary" onClick={() => void load()} disabled={loading}>
              <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
            </button>
            <button className="btn-primary" onClick={() => void onOpenConsole()} disabled={opening}
              title="Open the official Tailscale admin console in your browser">
              <Icon name="ExternalLink" size={15} /> Admin console
            </button>
          </>
        }
      />

      {error && <div className="card p-3 mb-4 text-sm text-danger break-words flex items-center gap-2"><Icon name="AlertTriangle" size={15} /> {error}</div>}

      {loading && !status && (
        <div className="card p-8 text-center text-text-dim">
          <Icon name="Loader2" size={18} className="animate-spin inline" /> Reading tailnet status…
        </div>
      )}

      {status && !status.installed && (
        <div className="card p-6">
          <div className="flex items-start gap-3">
            <Icon name="Info" size={20} className="text-accent-bright shrink-0 mt-0.5" />
            <div>
              <h2 className="text-base font-semibold text-text">Tailscale isn’t installed on this PC</h2>
              <p className="text-sm text-text-muted mt-1">
                Install the Tailscale client and sign in to your tailnet, then refresh this page to
                see your devices here. You can still open the web admin console below.
              </p>
              <a className="btn-secondary mt-3 inline-flex" href="https://tailscale.com/download" target="_blank" rel="noopener noreferrer">
                <Icon name="Download" size={14} /> Get Tailscale
              </a>
            </div>
          </div>
        </div>
      )}

      {status && status.installed && (
        <>
          <section className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
            <StatCard label="Connection" value={status.backendState || '—'}
              tone={status.backendState === 'Running' ? 'good' : 'warn'} icon="Wifi" />
            <StatCard label="Tailnet" value={status.tailnetName || '—'} icon="Globe" />
            <StatCard label="This PC" value={status.self?.name || '—'} icon="MonitorSmartphone" />
            <StatCard label="Peers online" value={`${online} / ${total}`} icon="Network" />
          </section>

          {!status.available && status.error && (
            <div className="card p-3 mb-4 text-sm text-warning break-words flex items-center gap-2">
              <Icon name="AlertTriangle" size={15} /> {status.error}
            </div>
          )}

          <div className="card overflow-hidden">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
                  <th className="px-3 py-2 font-medium">Device</th>
                  <th className="px-3 py-2 font-medium hidden sm:table-cell">OS</th>
                  <th className="px-3 py-2 font-medium">Tailnet IPs</th>
                  <th className="px-3 py-2 font-medium text-center">Status</th>
                  <th className="px-3 py-2 font-medium text-right hidden md:table-cell">Last seen</th>
                </tr>
              </thead>
              <tbody>
                {status.self && <DeviceRow node={status.self} isSelf />}
                {status.peers.map(p => <DeviceRow key={p.id || p.name} node={p} />)}
                {!status.self && status.peers.length === 0 && (
                  <tr><td colSpan={5} className="px-3 py-8 text-center text-text-dim">No devices in this tailnet.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          <p className="text-[11px] text-text-dim mt-3 flex items-center gap-1.5">
            <Icon name="Lock" size={12} /> Read-only view. Use the admin console for device management (rename, remove, ACLs, keys).
          </p>
        </>
      )}
    </div>
  )
}

function StatCard({ label, value, icon, tone }: { label: string; value: string; icon: string; tone?: 'good' | 'warn' }) {
  const valueClass = tone === 'good' ? 'text-success' : tone === 'warn' ? 'text-warning' : 'text-text'
  return (
    <div className="card p-3">
      <div className="flex items-center gap-2 text-text-dim text-[11px] uppercase tracking-wider mb-1">
        <Icon name={icon} size={13} /> {label}
      </div>
      <div className={`text-lg font-semibold truncate ${valueClass}`} title={value}>{value}</div>
    </div>
  )
}
