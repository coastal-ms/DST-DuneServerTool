import { useCallback, useEffect, useState } from 'react'
import { ApiError } from '../../api/client'
import {
  getHyperVLifecycle,
  reconcileHyperVLifecycle,
  removeHyperVLifecycle,
  type HyperVLifecycleStatus,
} from '../../api/setup'
import { Icon } from '../../components/Icon'
import { useCardCollapse } from '../../components/CollapsibleCard'

function resultText(result?: string, phase?: string, at?: string) {
  if (!result) return 'No result recorded'
  return [result, phase, at].filter(Boolean).join(' · ')
}

export function HyperVLifecycleCard() {
  const { open, setOpen } = useCardCollapse('settings.hyperVLifecycle', false)
  const [status, setStatus] = useState<HyperVLifecycleStatus | null>(null)
  const [loading, setLoading] = useState(false)
  const [working, setWorking] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setStatus(await getHyperVLifecycle())
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { if (open) void load() }, [open, load])

  const reconcile = useCallback(async () => {
    setWorking(true)
    setMessage(null)
    setError(null)
    try {
      const next = await reconcileHyperVLifecycle()
      setStatus(next)
      setMessage('Hyper-V shutdown and Alpine boot lifecycle reconciled.')
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setWorking(false)
    }
  }, [])

  const remove = useCallback(async () => {
    setWorking(true)
    setMessage(null)
    setError(null)
    try {
      const next = await removeHyperVLifecycle()
      setStatus(next)
      setConfirmRemove(false)
      setMessage('Lifecycle integration removed and recorded Hyper-V values restored.')
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setWorking(false)
    }
  }, [])

  const configured = status?.configured === true
  const guestReady = status?.guest.reachable && status.guest.supported

  return (
    <div className="card mb-4" data-section-nav-id="settings.hyperVLifecycle" data-section-nav-label="Hyper-V VM lifecycle">
      <button
        type="button"
        onClick={() => setOpen(value => !value)}
        aria-expanded={open}
        data-section-nav-toggle
        className="w-full flex items-center justify-between gap-3 p-6 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Power" size={18} className="text-text-muted shrink-0" />
          <div className="min-w-0">
            <div className="font-medium">Hyper-V VM lifecycle</div>
            <div className="text-sm text-text-muted truncate">
              {configured
                ? 'Graceful host shutdown and Alpine battlegroup boot recovery are configured.'
                : 'Protect the Funcom stack when Windows stops or restarts its Hyper-V host.'}
            </div>
          </div>
        </div>
        <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={18} className="text-text-muted shrink-0" />
      </button>

      {open && (
        <div className="px-6 pb-6 space-y-4">
          <p className="text-sm text-text-dim">
            Reconcile enables only Hyper-V Operating System Shutdown and sets this VM&apos;s Automatic Stop Action
            to <span className="font-mono">ShutDown</span>. The Alpine hook stops the battlegroup before k3s,
            has a fixed timeout, and restarts only a battlegroup that was running before shutdown.
          </p>

          {error && (
            <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger flex items-start gap-2">
              <Icon name="CircleX" size={16} className="mt-0.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}
          {message && (
            <div className="rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success flex items-start gap-2">
              <Icon name="CircleCheck" size={16} className="mt-0.5 shrink-0" />
              <span>{message}</span>
            </div>
          )}

          {loading && !status ? (
            <p className="text-sm text-text-dim italic">Loading…</p>
          ) : status && (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
              <div className="rounded-lg border border-border bg-surface-2 p-3 space-y-1">
                <div className="font-medium">Windows host</div>
                <div className="text-text-dim">Target <span className="font-mono text-text">{status.host.identity}</span></div>
                <div className="text-text-dim">VM <span className="font-mono text-text">{status.host.vmName}</span> · {status.host.vmState}</div>
                <div className={status.host.shutdownEnabled ? 'text-success' : 'text-warning'}>
                  Operating System Shutdown: {status.host.shutdownEnabled ? 'enabled' : 'disabled'}
                </div>
                <div className={status.host.automaticStopAction === 'ShutDown' ? 'text-success' : 'text-warning'}>
                  Automatic Stop Action: {status.host.automaticStopAction || 'unknown'}
                </div>
              </div>

              <div className="rounded-lg border border-border bg-surface-2 p-3 space-y-1">
                <div className="font-medium">Alpine guest</div>
                <div className={guestReady ? 'text-success' : 'text-warning'}>
                  hv_utils shutdown support: {guestReady ? 'ready' : 'not verified'}
                </div>
                <div className={status.guest.installed && status.guest.runlevel && status.guest.serviceStarted ? 'text-success' : 'text-warning'}>
                  OpenRC lifecycle: {status.guest.installed ? 'installed' : 'not installed'}
                </div>
                {status.guest.reason && <div className="text-xs text-warning break-words">{status.guest.reason}</div>}
                <div className="text-xs text-text-dim">
                  Last shutdown: {resultText(status.guest.lastShutdownResult, status.guest.lastShutdownPhase, status.guest.lastShutdownAt)}
                </div>
                <div className="text-xs text-text-dim">
                  Last start: {resultText(status.guest.lastStartResult, status.guest.lastStartPhase, status.guest.lastStartAt)}
                </div>
              </div>
            </div>
          )}

          {status?.rollbackStateError && (
            <div className="text-sm text-danger">{status.rollbackStateError}</div>
          )}
          {status?.rollbackStatePresent && !status.rollbackStateMatches && (
            <div className="text-sm text-danger">
              Saved rollback state belongs to a different Hyper-V host or VM. DST will not change either system.
            </div>
          )}

          <div className="flex flex-wrap gap-2">
            <button type="button" className="btn-secondary" onClick={() => void load()} disabled={loading || working}>
              <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
              Refresh
            </button>
            <button
              type="button"
              className="btn-primary"
              onClick={() => void reconcile()}
              disabled={loading || working || !status?.guest.reachable || !status.guest.supported || (status.rollbackStatePresent && !status.rollbackStateMatches)}
            >
              <Icon name={working ? 'Loader2' : 'ShieldCheck'} size={14} className={working ? 'animate-spin' : ''} />
              {working ? 'Working…' : 'Reconcile'}
            </button>
            {status?.rollbackStatePresent && (
              !confirmRemove ? (
                <button type="button" className="btn-secondary" onClick={() => setConfirmRemove(true)} disabled={working}>
                  Remove lifecycle integration
                </button>
              ) : (
                <>
                  <button type="button" className="btn-secondary text-danger" onClick={() => void remove()} disabled={working}>
                    Confirm remove
                  </button>
                  <button type="button" className="btn-secondary" onClick={() => setConfirmRemove(false)} disabled={working}>
                    Cancel
                  </button>
                </>
              )
            )}
          </div>
        </div>
      )}
    </div>
  )
}
