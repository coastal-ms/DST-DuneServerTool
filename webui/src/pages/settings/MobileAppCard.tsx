import { useState, useEffect } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'

interface BridgeStatus {
  ready: boolean
  port: number
  elevated: boolean
  canRepair: boolean
  task: boolean
  taskState: string
  listening: boolean
  healthOk: boolean
  issues: string[]
}

interface MobilePairingData {
  token: string
  url?: string | null
  source?: string
  port: number
  bridge?: BridgeStatus | null
}

interface QuickTunnelStatus {
  running: boolean
  url: string
  pid: number
  startedAt?: string
  installed: boolean
  cloudflaredPath?: string
  cloudflaredVersion?: string
  lastUrl?: string
}

export function MobileAppCard() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<MobilePairingData | null>(null)

  const [bridge, setBridge] = useState<BridgeStatus | null>(null)
  const [bridgeLoading, setBridgeLoading] = useState(false)
  const [repairing, setRepairing] = useState(false)
  const [repairError, setRepairError] = useState<string | null>(null)

  const [tunnel, setTunnel] = useState<QuickTunnelStatus | null>(null)
  const [tunnelBusy, setTunnelBusy] = useState(false)
  const [tunnelError, setTunnelError] = useState<string | null>(null)

  const loadBridge = async () => {
    setBridgeLoading(true)
    try {
      const res = await api<BridgeStatus>('/api/mobile/bridge-status')
      setBridge(res)
    } catch {
      setBridge(null)
    } finally {
      setBridgeLoading(false)
    }
  }

  const loadTunnel = async () => {
    try {
      const res = await api<QuickTunnelStatus>('/api/remote-access/quick-tunnel/status')
      setTunnel(res)
    } catch {
      setTunnel(null)
    }
  }

  useEffect(() => { void loadBridge(); void loadTunnel() }, [])

  const repairBridge = async () => {
    setRepairing(true)
    setRepairError(null)
    try {
      const res = await api<{ ok: boolean; status?: BridgeStatus }>('/api/mobile/bridge-repair', { method: 'POST' })
      if (res.status) setBridge(res.status)
      else await loadBridge()
    } catch (e) {
      setRepairError(e instanceof Error ? e.message : String(e))
      await loadBridge()
    } finally {
      setRepairing(false)
    }
  }

  const startTunnel = async () => {
    setTunnelBusy(true)
    setTunnelError(null)
    try {
      const res = await api<{ ok: boolean; url?: string; status?: QuickTunnelStatus }>('/api/remote-access/quick-tunnel/start', { method: 'POST' })
      if (res.status) setTunnel(res.status)
      else await loadTunnel()
      await load()
    } catch (e) {
      setTunnelError(e instanceof Error ? e.message : String(e))
      await loadTunnel()
    } finally {
      setTunnelBusy(false)
    }
  }

  const stopTunnel = async () => {
    setTunnelBusy(true)
    setTunnelError(null)
    try {
      const res = await api<{ ok: boolean; status?: QuickTunnelStatus }>('/api/remote-access/quick-tunnel/stop', { method: 'POST' })
      if (res.status) setTunnel(res.status)
      else await loadTunnel()
      await load()
    } catch (e) {
      setTunnelError(e instanceof Error ? e.message : String(e))
      await loadTunnel()
    } finally {
      setTunnelBusy(false)
    }
  }

  const load = async () => {
    setLoading(true)
    setError(null)
    try {
      const res = await api<MobilePairingData>('/api/mobile/pairing')
      setData(res)
      if (res.bridge) setBridge(res.bridge)
    } catch (e) {
      setError(String(e))
    } finally {
      setLoading(false)
    }
  }

  const bridgePort = data?.port ?? bridge?.port ?? 47900
  const pairUrl = data?.url ?? (tunnel?.running ? tunnel.url : '') ?? ''
  const qrPayload = data && pairUrl ? JSON.stringify({ url: pairUrl, token: data.token }) : ''

  return (
    <div className="card">
      <div className="card-header">
        <h2 className="card-title">Mobile App Pairing</h2>
      </div>
      <div className="card-body">

        {/* Secure remote access (Cloudflare quick tunnel). Free, no account, no
            domain, no router port-forward — cloudflared connects out from this PC
            and hands back an HTTPS URL the phone can reach. */}
        <div className="card p-3" style={{ marginBottom: '1rem' }}>
          <div className="flex items-center gap-2" style={{ fontWeight: 600 }}>
            <Icon name="Globe" size={16} /> Secure remote access
            {tunnel && (
              tunnel.installed
                ? <span className="badge safe" style={{ marginLeft: 'auto' }}>cloudflared installed</span>
                : <span className="badge" style={{ marginLeft: 'auto' }}>cloudflared not found</span>
            )}
          </div>

          {tunnel && !tunnel.installed && (
            <div className="text-text-muted text-sm" style={{ marginTop: '0.5rem' }}>
              cloudflared ships with Dune Server. If this says “not found”, reinstall DST or install it from{' '}
              <a href="https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" target="_blank" rel="noreferrer">Cloudflare</a>.
            </div>
          )}

          {tunnel?.running ? (
            <div style={{ marginTop: '0.75rem' }}>
              <div className="card p-2 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
                <Icon name="CheckCircle2" size={16} /> Tunnel active
              </div>
              <div style={{ marginTop: '0.5rem', fontSize: '13px', fontFamily: 'monospace', wordBreak: 'break-all' }}>{tunnel.url}</div>
              <button className="btn" style={{ marginTop: '0.5rem' }} disabled={tunnelBusy} onClick={() => void stopTunnel()}>
                {tunnelBusy ? <><Icon name="Loader2" className="animate-spin" /> Working…</> : <><Icon name="Square" /> Stop tunnel</>}
              </button>
              <div className="help-text" style={{ marginTop: '0.5rem' }}>
                This address changes each time the tunnel restarts — re-scan the QR code if you stop and start it.
                For a permanent address, add your own domain under <strong>Remote Access</strong>.
              </div>
            </div>
          ) : (
            <div style={{ marginTop: '0.75rem' }}>
              <button className="btn-primary" disabled={tunnelBusy || (tunnel ? !tunnel.installed : false)} onClick={() => void startTunnel()}>
                {tunnelBusy ? <><Icon name="Loader2" className="animate-spin" /> Starting…</> : <><Icon name="Play" /> Start secure tunnel</>}
              </button>
              <div className="help-text" style={{ marginTop: '0.5rem' }}>
                Free and private: no account, no domain, no router setup. Start the tunnel, then scan the QR code with the mobile app.
              </div>
            </div>
          )}
          {tunnelError && <div className="text-danger text-sm" style={{ marginTop: '0.5rem' }}>{tunnelError}</div>}
        </div>

        {/* Local bridge health — the loopback proxy phones reach through the
            tunnel. Binds 127.0.0.1 only, so no admin/firewall is involved. */}
        {bridge && (
          bridge.ready ? (
            <div className="card p-3 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2" style={{ marginBottom: '1rem' }}>
              <Icon name="CheckCircle2" size={16} /> Mobile bridge ready (local port {bridge.port}).
            </div>
          ) : (
            <div className="card p-3 border-warning/40 bg-warning/10 text-sm" style={{ marginBottom: '1rem' }}>
              <div className="flex items-center gap-2 text-warning" style={{ fontWeight: 600 }}>
                <Icon name="AlertTriangle" size={16} /> Mobile bridge not running
              </div>
              <ul style={{ margin: '0.5rem 0 0', paddingLeft: '1.25rem' }} className="text-text-muted">
                {bridge.issues.map((it, i) => <li key={i}>{it}</li>)}
              </ul>
              <button className="btn-primary" style={{ marginTop: '0.75rem' }} disabled={repairing} onClick={() => void repairBridge()}>
                {repairing ? <><Icon name="Loader2" className="animate-spin" /> Repairing…</> : <><Icon name="Wrench" /> Repair Mobile Bridge</>}
              </button>
              {repairError && <div className="text-danger text-sm" style={{ marginTop: '0.5rem' }}>{repairError}</div>}
              <button className="btn" style={{ marginTop: '0.5rem' }} disabled={bridgeLoading || repairing} onClick={() => void loadBridge()}>
                {bridgeLoading ? 'Checking…' : 'Re-check'}
              </button>
            </div>
          )
        )}

        <p className="help-text" style={{ marginBottom: '1rem' }}>
          Start the secure tunnel above, then scan this code with the DST mobile app to connect.
          Your friends need <strong>nothing</strong> installed on their phones — no VPN, no account.
        </p>

        {!data && !loading && (
          <button className="btn-primary" onClick={() => void load()}>
            <Icon name="QrCode" /> Generate QR Code
          </button>
        )}

        {loading && <div className="text-text-dim flex items-center gap-2"><Icon name="Loader2" className="animate-spin" /> Generating...</div>}
        {error && <div className="card p-3 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2"><Icon name="AlertCircle" /> {error}</div>}

        {data && (
          <div style={{ display: 'flex', gap: '2rem', flexWrap: 'wrap', alignItems: 'flex-start' }}>
            {qrPayload ? (
              <div style={{ background: '#fff', padding: '1rem', borderRadius: '8px' }}>
                <QRCodeSVG value={qrPayload} size={200} />
              </div>
            ) : (
              <div className="text-secondary" style={{ width: 200, textAlign: 'center' }}>
                Start the secure tunnel (or add a domain under Remote Access) to generate a QR code.
              </div>
            )}

            <div style={{ flex: 1, minWidth: '300px' }}>
              <div className="form-group">
                <label>Connection Address</label>
                <div className="help-text">The mobile app will use this address to reach your server.</div>
                <div style={{ marginTop: '0.5rem', fontSize: '13px', fontFamily: 'monospace', wordBreak: 'break-all' }}>
                  {pairUrl ? pairUrl : <span className="text-text-muted">No remote address yet — start the tunnel above.</span>}
                </div>
              </div>
              <button className="btn" onClick={() => setData(null)} style={{ marginTop: '1rem' }}>
                Hide QR Code
              </button>

              {pairUrl && (
                <div style={{ marginTop: '2rem', padding: '1rem', backgroundColor: '#f8fafc', borderRadius: '8px', border: '1px solid #e0f2fe' }}>
                  <h4 style={{ margin: '0 0 0.5rem 0', fontSize: '14px', color: '#0369a1' }}>Manual Entry Details</h4>
                  <div style={{ fontSize: '13px', fontFamily: 'monospace', color: '#334155' }}>
                    <div style={{ marginBottom: '4px', wordBreak: 'break-all' }}><strong>URL:</strong> {pairUrl}</div>
                    <div style={{ wordBreak: 'break-all' }}><strong>Token:</strong> {data.token}</div>
                  </div>
                  <div className="help-text" style={{ marginTop: '0.5rem' }}>
                    On the same network you can also use <code>http://&lt;this-pc-lan-ip&gt;:{bridgePort}</code>.
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
