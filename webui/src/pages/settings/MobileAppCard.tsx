import { useState } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'

interface MobilePairingData {
  token: string
  port: number
  publicIp?: string
  tailscaleIp?: string
  hostname?: string
}

export function MobileAppCard() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<MobilePairingData | null>(null)
  const [selectedIp, setSelectedIp] = useState<string>('')

  const load = async () => {
    setLoading(true)
    setError(null)
    try {
      const res = await api<MobilePairingData>('/api/mobile/pairing')
      setData(res)
      // Pick best default
      if (res.tailscaleIp) setSelectedIp(res.tailscaleIp)
      else setSelectedIp('')
    } catch (e) {
      setError(String(e))
    } finally {
      setLoading(false)
    }
  }

  const qrPayload = data && data.tailscaleIp && selectedIp === data.tailscaleIp ? JSON.stringify({
    ip: data.tailscaleIp,
    port: 47900,
    token: data.token
  }) : ''

  return (
    <div className="card">
      <div className="card-header">
        <h2 className="card-title">Mobile App Pairing</h2>
      </div>
      <div className="card-body">
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
                    <div style={{ marginBottom: '4px' }}><strong>Port:</strong> 47900</div>
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
