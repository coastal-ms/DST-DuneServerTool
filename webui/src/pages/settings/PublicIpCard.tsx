import { useEffect, useMemo, useState } from 'react'
import { ApiError, api } from '../../api/client'
import { Icon } from '../../components/Icon'

type PublicIpMode = 'ddns' | 'manual'

type PublicIpStatus = {
  mode?: PublicIpMode
  hostname?: string
  manualPublicIp?: string
  lastResolvedPublicIp?: string
  lastAppliedPublicIp?: string
  currentPublicIp?: string | null
  vmIp?: string | null
  k3sExternalIp?: string
}

type PublicIpStep = {
  id: string
  label: string
  status: 'running' | 'done' | 'failed'
  detail?: string
  raw?: string
}

type ResolveResponse = {
  ok: boolean
  hostname: string
  publicIp: string
  candidates?: string[]
}

type ValidateResponse = {
  ok: boolean
  publicIp: string
}

type ApplyResponse = {
  ok: boolean
  publicIp: string
  error?: string
  steps?: PublicIpStep[]
}

function stepClass(status: PublicIpStep['status']): string {
  if (status === 'done') return 'text-success'
  if (status === 'failed') return 'text-danger'
  return 'text-warning'
}

export function PublicIpCard() {
  const [loading, setLoading] = useState(false)
  const [status, setStatus] = useState<PublicIpStatus | null>(null)
  const [mode, setMode] = useState<PublicIpMode>('ddns')
  const [hostname, setHostname] = useState('')
  const [manualIp, setManualIp] = useState('')
  const [targetIp, setTargetIp] = useState('')
  const [validatedInput, setValidatedInput] = useState('')
  const [working, setWorking] = useState<'resolve' | 'validate' | 'apply' | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [steps, setSteps] = useState<PublicIpStep[]>([])

  async function loadStatus() {
    setLoading(true)
    try {
      const r = await api<PublicIpStatus>('/api/public-ip/status')
      setStatus(r)
      setMode(r.mode === 'manual' ? 'manual' : 'ddns')
      setHostname(r.hostname ?? '')
      setManualIp(r.manualPublicIp ?? '')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { void loadStatus() }, [])

  const currentInput = useMemo(() => (
    mode === 'ddns' ? hostname.trim().toLowerCase() : manualIp.trim()
  ), [mode, hostname, manualIp])

  const canApply = Boolean(targetIp && validatedInput === currentInput && working !== 'apply')

  function clearValidation() {
    setTargetIp('')
    setValidatedInput('')
    setMessage(null)
    setSteps([])
  }

  async function resolveHostname() {
    setWorking('resolve')
    setError(null)
    setMessage(null)
    setSteps([])
    try {
      const r = await api<ResolveResponse>('/api/public-ip/resolve', {
        method: 'POST',
        body: JSON.stringify({ hostname }),
      })
      setHostname(r.hostname)
      setTargetIp(r.publicIp)
      setValidatedInput(r.hostname)
      setMessage(`${r.hostname} resolves to ${r.publicIp}.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setWorking(null)
    }
  }

  async function validateManualIp() {
    setWorking('validate')
    setError(null)
    setMessage(null)
    setSteps([])
    try {
      const r = await api<ValidateResponse>('/api/public-ip/validate', {
        method: 'POST',
        body: JSON.stringify({ publicIp: manualIp }),
      })
      setManualIp(r.publicIp)
      setTargetIp(r.publicIp)
      setValidatedInput(r.publicIp)
      setMessage(`${r.publicIp} is a usable public IPv4 address.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setWorking(null)
    }
  }

  async function applyPublicIp() {
    if (!targetIp) return
    const label = mode === 'ddns' ? `${hostname.trim()} -> ${targetIp}` : targetIp
    if (!window.confirm(
      `Apply public IP change?\n\nTarget: ${label}\n\n`
      + 'This updates the Windows route, VM public IP alias, Dune settings.conf, K3s ExternalIP, NAT, and restarts affected game pods.',
    )) return

    setWorking('apply')
    setError(null)
    setMessage(null)
    setSteps([{ id: 'client', label: 'Apply request sent', status: 'running', detail: 'Waiting for the backend to finish.' }])
    try {
      const body = mode === 'ddns'
        ? { mode, hostname, resolvedIp: targetIp, confirmed: true }
        : { mode, publicIp: targetIp, confirmed: true }
      const r = await api<ApplyResponse>('/api/public-ip/apply', {
        method: 'POST',
        body: JSON.stringify(body),
      })
      setSteps(r.steps ?? [])
      setMessage(`Applied public IP ${r.publicIp}.`)
      await loadStatus()
    } catch (e) {
      if (e instanceof ApiError) {
        const body = e.body as Partial<ApplyResponse> | undefined
        if (body?.steps) setSteps(body.steps)
        setError(body?.error ?? e.message)
      } else {
        setError(e instanceof Error ? e.message : String(e))
      }
    } finally {
      setWorking(null)
    }
  }

  return (
    <div className="card mb-4 p-6">
      <div className="flex items-start justify-between gap-3 mb-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <Icon name="Globe2" size={18} className="text-text-muted" />
            <h2 className="text-lg font-semibold">Public IP / DDNS</h2>
          </div>
          <p className="text-sm text-text-dim">
            Use this after your ISP changes your public IP. DST still applies a numeric IPv4 address to Dune, but it can resolve a DDNS hostname first.
          </p>
          <div className="mt-2 flex flex-wrap gap-2 text-xs">
            {status?.currentPublicIp && <span className="pill-muted">internet · {status.currentPublicIp}</span>}
            {status?.vmIp && <span className="pill-muted">VM · {status.vmIp}</span>}
            {status?.k3sExternalIp && <span className="pill-muted">K3s ExternalIP · {status.k3sExternalIp}</span>}
            {status?.lastAppliedPublicIp && <span className="pill-success">last applied · {status.lastAppliedPublicIp}</span>}
          </div>
        </div>
        <button type="button" onClick={() => void loadStatus()} disabled={loading || working !== null} className="btn-secondary shrink-0">
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={15} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </div>

      <div className="flex flex-wrap gap-2 mb-4">
        <button
          type="button"
          onClick={() => { setMode('ddns'); clearValidation() }}
          className={mode === 'ddns' ? 'btn-primary' : 'btn-secondary'}
        >
          Use DDNS hostname
        </button>
        <button
          type="button"
          onClick={() => { setMode('manual'); clearValidation() }}
          className={mode === 'manual' ? 'btn-primary' : 'btn-secondary'}
        >
          Enter public IP manually
        </button>
      </div>

      {mode === 'ddns' ? (
        <div className="space-y-2">
          <label className="block text-sm font-medium">DDNS hostname</label>
          <div className="flex items-stretch gap-2">
            <input
              type="text"
              value={hostname}
              placeholder="dunecoastal.myvnc.com"
              onChange={e => { setHostname(e.target.value); clearValidation() }}
              className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
            <button type="button" onClick={() => void resolveHostname()} disabled={working !== null || !hostname.trim()} className="btn-secondary shrink-0">
              <Icon name={working === 'resolve' ? 'Loader2' : 'Search'} size={15} className={working === 'resolve' ? 'animate-spin' : ''} />
              Resolve hostname
            </button>
          </div>
        </div>
      ) : (
        <div className="space-y-2">
          <label className="block text-sm font-medium">Public IPv4 address</label>
          <div className="flex items-stretch gap-2">
            <input
              type="text"
              value={manualIp}
              placeholder="50.123.76.96"
              onChange={e => { setManualIp(e.target.value); clearValidation() }}
              className="flex-1 min-w-0 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm placeholder:text-text-dim focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
            <button type="button" onClick={() => void validateManualIp()} disabled={working !== null || !manualIp.trim()} className="btn-secondary shrink-0">
              <Icon name={working === 'validate' ? 'Loader2' : 'CheckCircle2'} size={15} className={working === 'validate' ? 'animate-spin' : ''} />
              Validate IP
            </button>
          </div>
        </div>
      )}

      {targetIp && (
        <div className="mt-4 rounded-lg border border-success/40 bg-success/10 p-3 text-sm">
          <div className="flex items-center gap-2 text-success">
            <Icon name="CheckCircle2" size={15} />
            Target numeric IP: <span className="font-mono">{targetIp}</span>
          </div>
        </div>
      )}

      {message && (
        <p className="mt-3 text-sm text-success flex items-center gap-1.5">
          <Icon name="CheckCircle2" size={14} /> {message}
        </p>
      )}
      {error && (
        <p className="mt-3 text-sm text-danger flex items-center gap-1.5">
          <Icon name="AlertCircle" size={14} /> {error}
        </p>
      )}

      {steps.length > 0 && (
        <div className="mt-4 border border-border rounded-lg overflow-hidden">
          {steps.map(s => (
            <div key={s.id} className="px-3 py-2 border-b border-border last:border-b-0 text-sm">
              <div className="flex items-center gap-2">
                <Icon name={s.status === 'running' ? 'Loader2' : s.status === 'done' ? 'CheckCircle2' : 'AlertCircle'} size={14} className={s.status === 'running' ? 'animate-spin text-warning' : stepClass(s.status)} />
                <span className="font-medium">{s.label}</span>
                <span className={`text-xs uppercase ${stepClass(s.status)}`}>{s.status}</span>
              </div>
              {s.detail && <div className="mt-1 text-xs text-text-dim">{s.detail}</div>}
            </div>
          ))}
        </div>
      )}

      <div className="mt-4 pt-4 border-t border-border flex items-center justify-between gap-3">
        <p className="text-xs text-text-dim">
          Apply is enabled only after the current input has been resolved or validated.
        </p>
        <button type="button" onClick={() => void applyPublicIp()} disabled={!canApply} className="btn-danger shrink-0">
          <Icon name={working === 'apply' ? 'Loader2' : 'Network'} size={15} className={working === 'apply' ? 'animate-spin' : ''} />
          {working === 'apply' ? 'Applying…' : 'Apply public IP'}
        </button>
      </div>
    </div>
  )
}
