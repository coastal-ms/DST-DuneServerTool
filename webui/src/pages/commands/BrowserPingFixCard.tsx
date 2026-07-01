// Card for setting HOST_DATACENTER_ID = VM hostname on the BG CR so the
// in-game server browser Ping column actually populates. Not related to P34
// / connection joining — this is *only* about the Ping value shown in the
// server browser bin. Vendor default is "dune-testing" which doesn't match
// the VM hostname, so Ping stays 0. Live-verified fix: patching all 3
// utility pods' HOST_DATACENTER_ID to "duneawakening" (the Alpine VM
// hostname) + BG restart flipped Ping 0 -> 72 on Coastal's server.

import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'

type BrowserPingStatus = {
  vmHostname: string
  currentDatacenterId: string
  currentDatacenterIp: string
  hostnameMatches: boolean
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

// From /api/public-ip/status — same shape the Settings card uses. Only
// `currentPublicIp` is read here so the IP input can prepopulate with DST's
// notion of "the current public IP" as the user asked for.
type PublicIpStatus = {
  currentPublicIp?: string | null
  lastAppliedPublicIp?: string
  manualPublicIp?: string
  lastResolvedPublicIp?: string
}

type ToastFn = (kind: 'ok' | 'err', msg: string) => void

export function BrowserPingFixCard({ vmRunning, showToast }: {
  vmRunning: boolean
  showToast: ToastFn
}) {
  const [status, setStatus]     = useState<BrowserPingStatus | null>(null)
  const [pubIpFromDst, setPubIp] = useState<string>('')
  const [loading, setLoading]   = useState(false)
  const [saving, setSaving]     = useState(false)
  const [err, setErr]           = useState<string | null>(null)
  // Wall-clock elapsed while the save is in flight. Ticks once a second
  // so the button label + progress banner surface real progress instead
  // of a spinner that looks dead for the ~1-3 minutes the BG restart
  // takes. Reset every time saving flips on.
  const [savingElapsed, setSavingElapsed] = useState(0)

  const [draftDatacenterId, setDraftDatacenterId] = useState<string>('duneawakening')
  const [draftPublicIp, setDraftPublicIp]         = useState<string>('')

  const load = useCallback(async () => {
    if (!vmRunning) {
      setStatus(null); setErr('VM is not running.')
      return
    }
    setLoading(true); setErr(null)
    try {
      const [s, pip] = await Promise.all([
        api<BrowserPingStatus>('/api/public-ip/datacenter-id'),
        api<PublicIpStatus>('/api/public-ip/status').catch(() => null),
      ])
      setStatus(s)
      // Prefer the currently-detected public IP; fall back to whatever DST
      // last applied, then to whatever's already in the CR.
      const dstPub = pip?.currentPublicIp || pip?.lastAppliedPublicIp || pip?.manualPublicIp || pip?.lastResolvedPublicIp || ''
      const seedIp = dstPub || (s.currentDatacenterIp && s.currentDatacenterIp !== '(mixed)' ? s.currentDatacenterIp : '')
      setPubIp(dstPub)
      // Seed the datacenter-ID input with the VM hostname when we have one
      // (that's the value that makes browser Ping populate); fall back to
      // the current CR value, then to "duneawakening" as the DST default.
      const seedDcId = s.vmHostname || (s.currentDatacenterId && s.currentDatacenterId !== '(mixed)' ? s.currentDatacenterId : 'duneawakening')
      setDraftDatacenterId(seedDcId)
      setDraftPublicIp(seedIp)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
      setStatus(null)
    } finally {
      setLoading(false)
    }
  }, [vmRunning])

  useEffect(() => { void load() }, [load])

  // Tick a 1s counter while saving. `saving` flips off in the `save()`
  // finally block; the effect's cleanup + reset handles the display.
  useEffect(() => {
    if (!saving) { setSavingElapsed(0); return }
    const start = Date.now()
    setSavingElapsed(0)
    const iv = window.setInterval(() => {
      setSavingElapsed(Math.floor((Date.now() - start) / 1000))
    }, 1000)
    return () => window.clearInterval(iv)
  }, [saving])

  function fmtElapsed(sec: number): string {
    const m = Math.floor(sec / 60)
    const s = sec % 60
    return m > 0 ? `${m}m ${s.toString().padStart(2, '0')}s` : `${s}s`
  }

  async function save() {
    if (!draftDatacenterId) {
      showToast('err', 'Datacenter ID cannot be empty.')
      return
    }
    setSaving(true)
    try {
      const r = await api<ReconcileResult>('/api/public-ip/datacenter-id', {
        method: 'POST',
        body: JSON.stringify({ datacenterId: draftDatacenterId, publicIp: draftPublicIp }),
      })
      showToast('ok', r.message)
    } catch (e) {
      showToast('err', `Save failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setSaving(false)
    }
    // Refresh after save so the "Current" values reflect the patched CR.
    // Fire-and-forget matches the working pattern from the Database card.
    void load()
  }

  const matchIndicator = status && status.currentDatacenterId
    ? (status.hostnameMatches
        ? <span className="text-xs text-success flex items-center gap-1"><Icon name="CheckCircle2" size={12} /> matches VM hostname — Ping should populate</span>
        : <span className="text-xs text-warning flex items-center gap-1"><Icon name="AlertTriangle" size={12} /> does not match VM hostname (<span className="font-mono">{status.vmHostname || '?'}</span>) — Ping will show 0</span>)
    : null

  return (
    <div className="card p-5 flex flex-col mb-6">
      <div className="flex items-center gap-3 mb-3">
        <Icon name="Radar" size={22} className="text-info" />
        <h2 className="text-base font-semibold tracking-tight text-info">Server Browser Ping</h2>
        <span className="ml-auto text-xs text-text-muted">
          Patches <span className="font-mono">HOST_DATACENTER_ID</span> on the BG CR + restarts the battlegroup.
        </span>
      </div>
      <p className="text-sm text-text-muted mb-3">
        The in-game server browser only fills the <strong>Ping</strong> column when the battlegroup's{' '}
        <span className="font-mono">HOST_DATACENTER_ID</span> equals the VM's Linux hostname (DST-shipped VMs: <span className="font-mono">duneawakening</span>).
        The vendor default is <span className="font-mono">dune-testing</span>, which does not match, so Ping shows 0 with empty bars.
        Set the ID to your hostname below and save — DST patches the three utility pods' env vars and restarts the battlegroup cleanly so FLS re-registers on the next matchmaker cycle.
      </p>

      {!vmRunning && (
        <p className="text-xs text-warning mb-3 flex items-center gap-1.5">
          <Icon name="AlertTriangle" size={12} /> VM must be running to read or patch the BG CR.
        </p>
      )}
      {err && (
        <p className="text-xs text-danger mb-3 flex items-center gap-1.5">
          <Icon name="AlertCircle" size={12} /> {err}
        </p>
      )}

      <div className="grid grid-cols-1 md:grid-cols-[1fr_1fr_auto] gap-3 items-end mb-3">
        <label className="flex flex-col gap-1 text-xs">
          <span className="text-text-muted font-medium">Datacenter ID (VM hostname)</span>
          <input
            type="text"
            value={draftDatacenterId}
            onChange={e => setDraftDatacenterId(e.target.value)}
            disabled={!vmRunning || loading || saving}
            spellCheck={false}
            maxLength={64}
            placeholder="duneawakening"
            className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono"
          />
        </label>
        <label className="flex flex-col gap-1 text-xs">
          <span className="text-text-muted font-medium">
            Public IP {pubIpFromDst ? <span className="text-text-dim">(from DST)</span> : null}
          </span>
          <input
            type="text"
            value={draftPublicIp}
            onChange={e => setDraftPublicIp(e.target.value)}
            disabled={!vmRunning || loading || saving}
            spellCheck={false}
            placeholder="e.g. 203.0.113.42"
            className="px-2 py-1.5 rounded bg-surface-2 border border-border text-text text-sm font-mono"
          />
        </label>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => void load()}
            disabled={!vmRunning || loading || saving}
            className="btn-secondary"
          >
            <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <button
            type="button"
            onClick={() => void save()}
            disabled={!vmRunning || loading || saving || !draftDatacenterId}
            className="btn-primary"
            title="Patch HOST_DATACENTER_ID on the 3 utility pods and restart the battlegroup. Runs even when the values are unchanged so a re-apply can repair a bad state."
          >
            <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
            {saving ? `Saving… ${fmtElapsed(savingElapsed)}` : 'Save & restart BG'}
          </button>
        </div>
      </div>

      {/* In-progress banner. The BG restart alone typically takes 1-3
          minutes; without a visible progress cue the spinning button looks
          stuck to anyone who doesn't already know what's happening. */}
      {saving && (
        <div className="rounded border border-info/40 bg-info/5 text-info px-3 py-2 mb-3 flex items-start gap-2">
          <Icon name="Loader2" size={14} className="animate-spin mt-0.5 shrink-0" />
          <div className="text-xs leading-relaxed">
            <div>
              <strong>Reconciling HOST_DATACENTER_ID and restarting the battlegroup…</strong>{' '}
              <span className="font-mono">{fmtElapsed(savingElapsed)}</span> elapsed
            </div>
            <div className="text-text-muted mt-0.5">
              Expected: a few seconds for the CR patch, then <strong>1–3 minutes</strong> for the battlegroup to stop and come back up cleanly. FLS re-registers on the next matchmaker cycle after that.
              Safe to leave this page open — the action runs on the server and finishes on its own.
            </div>
          </div>
        </div>
      )}

      {status && (
        <div className="text-xs text-text-dim border-t border-border pt-2 mt-1">
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
          {matchIndicator && <div className="mt-1">{matchIndicator}</div>}
        </div>
      )}

      <p className="text-xs text-text-dim mt-3 italic">
        Save restarts the battlegroup so the game-server pods pick up the change and FLS re-registers.
        Players connected during the restart will get bounced. This is separate from the Public IP / DDNS apply in Settings.
      </p>
    </div>
  )
}
