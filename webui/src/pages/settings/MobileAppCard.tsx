import { useState, useEffect } from 'react'
import { QRCodeSVG } from 'qrcode.react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'
import { isLocalViewer } from '../../util/viewer'

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
  pairingId?: string
  remoteToken?: string
  cfAccessClientId?: string
  cfAccessClientSecret?: string
}

export function MobileAppCard() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [data, setData] = useState<MobilePairingData | null>(null)
  const [copied, setCopied] = useState(false)
  const [showLink, setShowLink] = useState(false)
  const localViewer = isLocalViewer()

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
      setBridge(null)
    } finally {
      setBridgeLoading(false)
    }
  }

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
    } catch (e) {
      setError(String(e))
    } finally {
      setLoading(false)
    }
  }

  const bridgePort = data?.port ?? bridge?.port ?? 47900
  const pairUrl = data?.url ?? ''
  // A direct stable URL (Tailscale Funnel / Cloudflare custom domain) — the QR is
  // a clean { url, token } the app uses as-is. The token is the permanent remote
  // token (survives restarts).
  const stableToken = data?.remoteToken || data?.token || ''
  const qrPayload = !data || !pairUrl
    ? ''
    : JSON.stringify({
        url: pairUrl,
        token: stableToken,
        ...(data.cfAccessClientId && data.cfAccessClientSecret ? {
          cfAccessClientId: data.cfAccessClientId,
          cfAccessClientSecret: data.cfAccessClientSecret,
        } : {}),
      })

  return (
    <div className="card">
      <div className="card-header">
        <h2 className="card-title">Mobile App Pairing</h2>
      </div>
      <div className="card-body">

        {/* Secure remote access. The mobile app reaches your server over a stable
            public HTTPS address — Tailscale Funnel (recommended, no domain) or a
            Cloudflare custom domain you set up under Remote Access. */}
        <div className="card p-3" style={{ marginBottom: '1rem' }}>
          <div className="flex items-center gap-2" style={{ fontWeight: 600 }}>
            <Icon name="Globe" size={16} /> Secure remote access
            {data && (
              data.url
                ? <span className="badge safe" style={{ marginLeft: 'auto' }}>{data.source === 'funnel' ? 'Tailscale Funnel' : 'custom domain'}</span>
                : <span className="badge" style={{ marginLeft: 'auto' }}>not set up</span>
            )}
          </div>

          {data?.url ? (
            <div style={{ marginTop: '0.75rem' }}>
              <div className="card p-2 border-success/40 bg-success/10 text-success text-sm flex items-center gap-2">
                <Icon name="CheckCircle2" size={16} /> Reachable at a stable public address
              </div>
              <div style={{ marginTop: '0.5rem', fontSize: '13px', fontFamily: 'monospace', wordBreak: 'break-all' }}>{data.url}</div>
              <div className="help-text" style={{ marginTop: '0.5rem' }}>
                You only scan <strong>once</strong>. The app saves a permanent pairing code and reconnects every time — no re-scanning after a restart.
              </div>
            </div>
          ) : (
            <div className="help-text" style={{ marginTop: '0.75rem' }}>
              No remote address yet. Recommended: install <a href="https://tailscale.com/download" target="_blank" rel="noreferrer">Tailscale</a> on this PC and enable a Funnel on the bridge port (<code>tailscale funnel --bg http://127.0.0.1:{bridgePort}</code>) for a free, no-domain public HTTPS address. Or set up a Cloudflare custom domain under <strong>Settings → Remote Access</strong>. Then generate the QR below.
            </div>
          )}
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
          Set up a remote address above, then scan this code with the DST mobile app to connect.
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
                Set up a Tailscale Funnel or a Cloudflare domain (Remote Access) to generate a QR code.
              </div>
            )}

            <div style={{ flex: 1, minWidth: '300px' }}>
              <div className="form-group">
                <label>Connection Address</label>
                <div className="help-text">The mobile app will use this address to reach your server.</div>
                <div style={{ marginTop: '0.5rem', fontSize: '13px', fontFamily: 'monospace', wordBreak: 'break-all' }}>
                  {pairUrl ? pairUrl : <span className="text-text-muted">No remote address yet — set one up above.</span>}
                </div>
              </div>
              <button className="btn" onClick={() => setData(null)} style={{ marginTop: '1rem' }}>
                Hide QR Code
              </button>

              {localViewer && pairUrl && data.remoteToken && (
                <div className="form-group" style={{ marginTop: '1.25rem' }}>
                  <label>Browser portal link (give this to a co-admin)</label>
                  <div className="help-text">They open it in any browser — no app, no install, no typing. Anyone with this link can manage the server, so only share it with people you trust.</div>
                  {!showLink ? (
                    <button className="btn" style={{ marginTop: '0.5rem' }} onClick={() => setShowLink(true)}>
                      <Icon name="Eye" /> Show portal link
                    </button>
                  ) : (
                    <>
                      <div style={{ marginTop: '0.5rem', fontSize: '12px', fontFamily: 'monospace', wordBreak: 'break-all', background: 'var(--surface-2, #1e293b)', padding: '0.5rem', borderRadius: '6px' }}>
                        {`${pairUrl.replace(/\/+$/, '')}/?key=${data.remoteToken}`}
                      </div>
                      <div className="flex items-center gap-2" style={{ marginTop: '0.5rem' }}>
                        <button
                          className="btn-primary"
                          onClick={() => {
                            const link = `${pairUrl.replace(/\/+$/, '')}/?key=${data.remoteToken}`
                            void navigator.clipboard.writeText(link)
                            setCopied(true)
                            window.setTimeout(() => setCopied(false), 2000)
                          }}
                        >
                          <Icon name={copied ? 'Check' : 'Copy'} /> {copied ? 'Copied!' : 'Copy portal link'}
                        </button>
                        <button className="btn" onClick={() => setShowLink(false)}>
                          <Icon name="EyeOff" /> Hide
                        </button>
                      </div>
                    </>
                  )}
                </div>
              )}

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
