import { useState, useEffect } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'

interface BridgeStatus {
  ready: boolean
  port: number
  elevated: boolean
  canRepair: boolean
  tailscaleUp: boolean
  tailscaleIp?: string | null
  firewallRule: boolean
  task: boolean
  taskState: string
  listening: boolean
  healthOk: boolean
  issues: string[]
}

interface MobilePairingData {
  token: string
  port: number
  publicIp?: string
  tailscaleIp?: string
  hostname?: string
  bridge?: BridgeStatus | null
}

export function MobileAppCard() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<MobilePairingData | null>(null)
  const [selectedIp, setSelectedIp] = useState<string>('')

  const [bridge, setBridge] = useState<BridgeStatus | null>(null)
  const [bridgeLoading, setBridgeLoading] = useState(false)
  const [repairing, setRepairing] = useState(false)
  const [repairError, setRepairError] = useState<string | null>(null)

  const loadBridge = async () => {
    setBridgeLoading(true)
    try {
      const res = await api<BridgeStatus>('/api/mobile/bridge-status')
      setBridge(res)
    } catch {
      // Older server or unavailable — leave the banner hidden rather than alarm.
      setBridge(null)
    } finally {
      setBridgeLoading(false)
    }
  }

  // Probe bridge health on mount so the connectivity banner is visible without
  // first generating a QR code.
  useEffect(() => { void loadBridge() }, [])

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

  const load = async () => {
    setLoading(true)
    setError(null)
    try {
      const res = await api<MobilePairingData>('/api/mobile/pairing')
      setData(res)
      if (res.bridge) setBridge(res.bridge)
      // Pick best default
      if (res.tailscaleIp) setSelectedIp(res.tailscaleIp)
      else setSelectedIp('')
    } catch (e) {
      setError(String(e))
    } finally {
      setLoading(false)
    }
  }

  // Single source of truth for the port: the server reports the bridge port.
  const bridgePort = data?.port ?? bridge?.port ?? 47900

  const qrPayload = data && data.tailscaleIp && selectedIp === data.tailscaleIp ? JSON.stringify({
    ip: data.tailscaleIp,
    port: bridgePort,
    token: data.token
  }) : ''

  return (
    <div className="card">
      <div className="card-header">
        <h2 className="card-title">Mobile App Pairing</h2>
      </div>
      <div className="card-body">

        {/* Bridge connectivity banner — surfaces the firewall/Tailscale/bridge
            health that determines whether phones can actually reach the server. */}
        {bridge && (
          bridge.ready ? (
            <div className="card p-3 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2" style={{ marginBottom: '1rem' }}>
              <Icon name="CheckCircle2" size={16} /> Mobile bridge ready — phones on your Tailnet can reach this server (port {bridge.port}).
            </div>
          ) : (
            <div className="card p-3 border-warning/40 bg-warning/10 text-sm" style={{ marginBottom: '1rem' }}>
              <div className="flex items-center gap-2 text-warning" style={{ fontWeight: 600 }}>
                <Icon name="AlertTriangle" size={16} /> Mobile bridge not reachable
              </div>
              <ul style={{ margin: '0.5rem 0 0', paddingLeft: '1.25rem' }} className="text-text-muted">
                {bridge.issues.map((it, i) => <li key={i}>{it}</li>)}
              </ul>
              {bridge.canRepair ? (
                <button className="btn-primary" style={{ marginTop: '0.75rem' }} disabled={repairing} onClick={() => void repairBridge()}>
                  {repairing ? <><Icon name="Loader2" className="animate-spin" /> Repairing…</> : <><Icon name="Wrench" /> Repair Mobile Bridge</>}
                </button>
              ) : !bridge.elevated ? (
                <div className="text-text-muted" style={{ marginTop: '0.75rem', fontSize: '13px' }}>
                  <span style={{ verticalAlign: 'text-bottom', marginRight: 4, display: 'inline-block' }}><Icon name="Info" size={13} /></span>
                  Restart Dune Server Tool <strong>as administrator</strong> to let it fix the firewall automatically.
                </div>
              ) : null}
              {repairError && <div className="text-danger text-sm" style={{ marginTop: '0.5rem' }}>{repairError}</div>}
              <button className="btn" style={{ marginTop: '0.5rem' }} disabled={bridgeLoading || repairing} onClick={() => void loadBridge()}>
                {bridgeLoading ? 'Checking…' : 'Re-check'}
              </button>
            </div>
          )
        )}

        <p className="help-text" style={{ marginBottom: '1rem' }}>
          Scan this code with the DST mobile app to securely connect to your server.
          <br /><br />
          <strong>Important for your users:</strong> Anyone using the mobile app to connect to your server <strong>must</strong> have <a href="https://tailscale.com/download" target="_blank" rel="noreferrer" style={{color: '#0066cc'}}>Tailscale</a> installed on their phone and be authenticated to your Tailnet. You do not need to port forward your router.
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
              <div className="text-secondary" style={{ width: 200, textAlign: 'center' }}>No IP selected</div>
            )}
            
            <div style={{ flex: 1, minWidth: '300px' }}>
              <div className="form-group">
                <label>Connection Address</label>
                <div className="help-text">Which address should the mobile app use to reach this server?</div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', marginTop: '0.5rem' }}>
                  {data.tailscaleIp ? (
                    <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', cursor: 'pointer' }}>
                      <input type="radio" name="mobile_ip" checked={selectedIp === data.tailscaleIp} onChange={() => setSelectedIp(data.tailscaleIp!)} />
                      Tailscale IP ({data.tailscaleIp}) <span className="badge safe">Recommended</span>
                    </label>
                  ) : (
                    <div className="text-danger text-sm" style={{ padding: '0.5rem', backgroundColor: '#fee2e2', borderRadius: '4px' }}>
                      <span style={{ display: 'inline-flex', alignItems: 'center', gap: '4px', verticalAlign: 'text-bottom' }}>
                        <Icon name="AlertTriangle" size={16} />
                        Tailscale is required for secure mobile access. Please install Tailscale on this PC and your mobile device.
                      </span>
                    </div>
                  )}
                </div>
              </div>
              <button className="btn" onClick={() => setData(null)} style={{ marginTop: '1rem' }}>
                Hide QR Code
              </button>
              
              {data.tailscaleIp && (
                <div style={{ marginTop: '2rem', padding: '1rem', backgroundColor: '#f8fafc', borderRadius: '8px', border: '1px solid #e0f2fe' }}>
                  <h4 style={{ margin: '0 0 0.5rem 0', fontSize: '14px', color: '#0369a1' }}>Manual Entry Details</h4>
                  <div style={{ fontSize: '13px', fontFamily: 'monospace', color: '#334155' }}>
                    <div style={{ marginBottom: '4px' }}><strong>IP:</strong> {data.tailscaleIp}</div>
                    <div style={{ marginBottom: '4px' }}><strong>Port:</strong> {bridgePort}</div>
                    <div style={{ wordBreak: 'break-all' }}><strong>Token:</strong> {data.token}</div>
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
