// Settings card: fix the in-game server-browser Ping column.
//
// The Ping column only populates when the battlegroup CR's HOST_DATACENTER_ID
// env (on the 3 utility pods: director / serverGateway / textRouter) is the
// literal "dune-awakening". The vendor default is "dune-testing", which never
// registers, so out of the box Ping shows 0 with empty bars. Live-verified
// 2026-07-11: setting HOST_DATACENTER_ID = "dune-awakening" (+
// HOST_DATACENTER_IP_ADDRESS = the public IP) flipped Ping 0 -> 46 with full
// green bars.
//
// This patches the battlegroup CR (the operator's desired state -- the same
// object "Edit Director" / kubectl edit battlegroup opens), so the change
// PERSISTS across pod/BG restarts. It never touches the running pods directly,
// and it only ever runs when the user clicks Save -- nothing is auto-applied.

import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { api, ApiError } from '../../api/client'

const RECOMMENDED_ID = 'dune-awakening'

type BrowserPingStatus = {
  vmHostname: string
  currentDatacenterId: string
  currentDatacenterIp: string
  hostnameMatches: boolean
  recommendedDatacenterId: string
  datacenterIdIsRecommended: boolean
  bgNamespace: string
  bgName: string
}

type ReconcileResult = {
  ok: boolean
  message: string
  datacenterId: string
  publicIp: string
  output: string
}

// From /api/public-ip/status -- only the current public IP is read here so the
// IP input can prepopulate with DST's notion of "the current public IP".
type PublicIpStatus = {
  currentPublicIp?: string | null
  lastAppliedPublicIp?: string
  manualPublicIp?: string
  lastResolvedPublicIp?: string
}

function fmtElapsed(sec: number): string {
  const m = Math.floor(sec / 60)
  const s = sec % 60
  return m > 0 ? `${m}m ${s.toString().padStart(2, '0')}s` : `${s}s`
}

export function ServerBrowserPingCard() {
  const [open, setOpen] = useState(false)
  const [status, setStatus] = useState<BrowserPingStatus | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [savingElapsed, setSavingElapsed] = useState(0)
  const [err, setErr] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  // Defaults per request: hostname box -> "dune-awakening", IP box -> the
  // user's detected public IP (filled in once the status/IP loads).
  const [draftDatacenterId, setDraftDatacenterId] = useState<string>(RECOMMENDED_ID)
  const [draftPublicIp, setDraftPublicIp] = useState<string>('')
  const [pubIpFromDst, setPubIpFromDst] = useState<string>('')

  const load = useCallback(async () => {
    setLoading(true)
    setErr(null)
    try {
      const [s, pip] = await Promise.all([
        api<BrowserPingStatus>('/api/public-ip/datacenter-id'),
        api<PublicIpStatus>('/api/public-ip/status').catch(() => null),
      ])
      setStatus(s)
      // IP box default: the detected public IP, falling back to whatever DST
      // last applied, then to whatever's already pinned in the CR.
      const dstPub =
        pip?.currentPublicIp ||
        pip?.lastAppliedPublicIp ||
        pip?.manualPublicIp ||
        pip?.lastResolvedPublicIp ||
        ''
      setPubIpFromDst(dstPub)
      const seedIp =
        dstPub ||
        (s.currentDatacenterIp && s.currentDatacenterIp !== '(mixed)' ? s.currentDatacenterIp : '')
      setDraftPublicIp(seedIp)
      // Hostname box default: always the recommended "dune-awakening" (the
      // known-good literal), regardless of the VM's Linux hostname.
      setDraftDatacenterId(RECOMMENDED_ID)
    } catch (e) {
      const msg =
        e instanceof ApiError && e.status === 503
          ? 'VM must be running to read or patch the battlegroup.'
          : e instanceof Error
            ? e.message
            : String(e)
      setErr(msg)
      setStatus(null)
    } finally {
      setLoading(false)
    }
  }, [])

  // Read status only when the card is expanded. Read-only -- never applies.
  useEffect(() => {
    if (!open) return
    void load()
  }, [open, load])

  // Tick a 1s counter while saving so the BG restart (1-3 min) shows progress.
  useEffect(() => {
    if (!saving) {
      setSavingElapsed(0)
      return
    }
    const start = Date.now()
    setSavingElapsed(0)
    const iv = window.setInterval(() => {
      setSavingElapsed(Math.floor((Date.now() - start) / 1000))
    }, 1000)
    return () => window.clearInterval(iv)
  }, [saving])

  async function save() {
    if (!draftDatacenterId.trim()) {
      setErr('Hostname / Datacenter ID cannot be empty.')
      return
    }
    setSaving(true)
    setErr(null)
    setMessage(null)
    try {
      const r = await api<ReconcileResult>('/api/public-ip/datacenter-id', {
        method: 'POST',
        body: JSON.stringify({
          datacenterId: draftDatacenterId.trim(),
          publicIp: draftPublicIp.trim(),
        }),
      })
      setMessage(r.message)
    } catch (e) {
      setErr(`Save failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setSaving(false)
    }
    // Refresh so the "Currently on CR" line reflects the patched values.
    void load()
  }

  const currentMatches = status?.datacenterIdIsRecommended

  return (
    <div className="card mb-4">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between gap-3 p-6 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Radar" size={18} className="text-text-muted shrink-0" />
          <div className="min-w-0">
            <div className="font-medium">Server browser Ping (Datacenter ID)</div>
            <div className="text-sm text-text-muted truncate">
              Fix a server that shows Ping 0 / empty bars in the in-game server browser.
            </div>
          </div>
        </div>
        <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={18} className="text-text-muted shrink-0" />
      </button>

      {open && (
        <div className="px-6 pb-6 space-y-4">
          <div className="rounded-lg border border-info/40 bg-info/10 p-3 text-sm text-text space-y-2">
            <div className="flex items-center gap-2 font-medium text-info">
              <Icon name="Info" size={16} />
              What this does
            </div>
            <p className="text-text-muted">
              The in-game server browser only fills the <span className="font-mono">Ping</span> column when
              your battlegroup advertises a recognised Datacenter ID. The vendor default{' '}
              <span className="font-mono">dune-testing</span> never registers, so the server shows{' '}
              <span className="font-mono">0</span> with empty bars. Setting the ID to{' '}
              <span className="font-mono">dune-awakening</span> (and pinning your public IP) makes the Ping
              populate — live-verified on a real server.
            </p>
            <p className="text-text-dim text-xs">
              This patches the battlegroup CR — the same object “Edit Director” edits — so it{' '}
              <strong>persists</strong> across restarts. It only runs when you click Save; nothing is applied
              automatically. Saving restarts the battlegroup, so anyone online is briefly disconnected.
            </p>
          </div>

          {err && (
            <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger flex items-start gap-2">
              <Icon name="CircleX" size={16} className="mt-0.5 shrink-0" />
              <span>{err}</span>
            </div>
          )}

          <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">Hostname / Datacenter ID</span>
              <input
                type="text"
                value={draftDatacenterId}
                onChange={e => setDraftDatacenterId(e.target.value)}
                disabled={loading || saving}
                spellCheck={false}
                maxLength={64}
                placeholder={RECOMMENDED_ID}
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              />
              <span className="text-xs text-text-dim">
                Recommended: <span className="font-mono">{RECOMMENDED_ID}</span>
              </span>
            </label>
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">
                Public IP {pubIpFromDst ? <span className="text-text-dim font-normal">(from DST)</span> : null}
              </span>
              <input
                type="text"
                value={draftPublicIp}
                onChange={e => setDraftPublicIp(e.target.value)}
                disabled={loading || saving}
                spellCheck={false}
                placeholder="e.g. 203.0.113.42"
                className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
              />
              <span className="text-xs text-text-dim">
                Advertised to players as <span className="font-mono">HOST_DATACENTER_IP_ADDRESS</span>.
              </span>
            </label>
          </div>

          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => void load()}
              disabled={loading || saving}
              className="btn-secondary"
            >
              <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
              Refresh
            </button>
            <button
              type="button"
              onClick={() => void save()}
              disabled={loading || saving || !draftDatacenterId.trim()}
              className="btn-primary"
              title="Patch HOST_DATACENTER_ID (+ IP) on the battlegroup CR and restart the battlegroup. Runs even when values are unchanged, so you can re-apply to repair a bad state."
            >
              <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
              {saving ? `Saving… ${fmtElapsed(savingElapsed)}` : 'Save & restart battlegroup'}
            </button>
          </div>

          {saving && (
            <div className="rounded-lg border border-info/40 bg-info/10 p-3 text-sm text-info flex items-start gap-2">
              <Icon name="Loader2" size={14} className="animate-spin mt-0.5 shrink-0" />
              <div className="leading-relaxed">
                <div>
                  <strong>Patching the battlegroup CR and restarting…</strong>{' '}
                  <span className="font-mono">{fmtElapsed(savingElapsed)}</span> elapsed
                </div>
                <div className="text-text-muted mt-0.5 text-xs">
                  A few seconds for the CR patch, then <strong>1–3 minutes</strong> for the battlegroup to come
                  back up. Safe to leave this page open — it finishes on the server.
                </div>
              </div>
            </div>
          )}

          {message && (
            <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success flex items-start gap-2">
              <Icon name="CircleCheck" size={16} className="mt-0.5 shrink-0" />
              <span>{message}</span>
            </div>
          )}

          {status && (
            <div className="text-xs text-text-dim border-t border-border pt-3">
              <div>
                Currently on CR:{' '}
                <span className="font-mono text-text">{status.currentDatacenterId || '(empty)'}</span>
                {status.currentDatacenterIp && (
                  <> · IP <span className="font-mono text-text">{status.currentDatacenterIp}</span></>
                )}
                {status.vmHostname && (
                  <> · VM hostname <span className="font-mono text-text">{status.vmHostname}</span></>
                )}
              </div>
              <div className="mt-1">
                {currentMatches ? (
                  <span className="text-success flex items-center gap-1">
                    <Icon name="CheckCircle2" size={12} /> ID is set to the recommended{' '}
                    <span className="font-mono">{RECOMMENDED_ID}</span>
                  </span>
                ) : (
                  <span className="text-warning flex items-center gap-1">
                    <Icon name="AlertTriangle" size={12} /> ID is not{' '}
                    <span className="font-mono">{RECOMMENDED_ID}</span> — Ping may show 0 until you apply
                  </span>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
