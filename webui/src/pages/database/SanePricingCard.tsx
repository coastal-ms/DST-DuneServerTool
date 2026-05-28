import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getPricingPatchStatus,
  applyPricingPatch,
  restorePricingPatch,
  type PricingPatchStatus,
} from '../../api/duneAdminPricing'
import { ApiError } from '../../api/client'

interface SanePricingCardProps {
  onToast?: (kind: 'ok' | 'err', msg: string) => void
}

export function SanePricingCard({ onToast }: SanePricingCardProps) {
  const [status, setStatus] = useState<PricingPatchStatus | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<'apply' | 'restore' | null>(null)
  const [lastLog, setLastLog] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      setStatus(await getPricingPatchStatus())
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void refresh() }, [refresh])

  const handleApply = useCallback(async () => {
    if (!status?.canApply) return
    const ok = window.confirm(
      'Apply Coastal\'s sane-pricing patch to dune-admin?\n\n' +
      'This will:\n' +
      '  - stage the patch + build script into your dune-admin source repo\n' +
      '  - stop dune-admin (if running)\n' +
      '  - rebuild dune-admin.exe in place\n' +
      '  - relaunch dune-admin in a fresh console window\n\n' +
      'Original upstream dune-admin.exe will be backed up to dune-admin.exe.upstream.'
    )
    if (!ok) return
    setBusy('apply'); setError(null); setLastLog(null)
    try {
      const r = await applyPricingPatch()
      setLastLog(r.log)
      if (r.ok) {
        onToast?.('ok', 'Sane-pricing patch applied. dune-admin restarted.')
      } else {
        onToast?.('err', `Patch apply finished with exit code ${r.exitCode}. See log below.`)
      }
      await refresh()
    } catch (e) {
      const msg = e instanceof ApiError ? e.message : String(e)
      setError(msg)
      onToast?.('err', `Apply failed: ${msg}`)
    } finally {
      setBusy(null)
    }
  }, [status, onToast, refresh])

  const handleRestore = useCallback(async () => {
    if (!status?.canRestore) return
    const ok = window.confirm(
      'Restore the original upstream dune-admin.exe?\n\n' +
      'This swaps dune-admin.exe.upstream back over the patched binary. ' +
      'You\'ll need to relaunch dune-admin afterwards.'
    )
    if (!ok) return
    setBusy('restore'); setError(null)
    try {
      const r = await restorePricingPatch()
      onToast?.('ok', r.message)
      await refresh()
    } catch (e) {
      const msg = e instanceof ApiError ? e.message : String(e)
      setError(msg)
      onToast?.('err', `Restore failed: ${msg}`)
    } finally {
      setBusy(null)
    }
  }, [status, onToast, refresh])

  const copyCmd = useCallback((cmd: string) => {
    void navigator.clipboard.writeText(cmd)
    onToast?.('ok', 'Copied to clipboard')
  }, [onToast])

  return (
    <section className="card p-5 mb-4">
      <header className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          <Icon name="Coins" size={18} className="text-accent" />
          <h2 className="text-lg font-semibold">dune-admin Sane-Pricing Patch (Coastal)</h2>
        </div>
        <button
          type="button"
          className="btn btn-ghost text-sm"
          onClick={() => void refresh()}
          disabled={loading}
        >
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      </header>

      <p className="text-sm text-text-muted mb-4">
        Replaces dune-admin's upstream rarity-weighted market-bot pricing
        (which produces multi-million-solari T6 listings) with a tier-driven
        model calibrated for small private servers. Hard 100k cap on every
        listing. Patches your dune-admin source repo and rebuilds in place.
      </p>

      {status?.patchApplied && status.marker && (
        <div className="rounded border border-accent/30 bg-accent/10 px-3 py-2 mb-4 text-sm">
          <div className="flex items-center gap-2 font-medium text-accent">
            <Icon name="CheckCircle2" size={14} /> Patch is currently applied
          </div>
          <div className="text-text-muted mt-1">
            Applied {new Date(status.marker.appliedAt).toLocaleString()} by Dune Server Tool v{status.marker.appliedByVersion}.
            Upstream backup at <span className="font-mono text-xs">{status.marker.upstreamBackup}</span>.
          </div>
        </div>
      )}

      {error && (
        <div className="rounded border border-red-500/40 bg-red-500/10 px-3 py-2 mb-4 text-sm text-red-400">
          {error}
        </div>
      )}

      {/* Preconditions checklist with inline directions next to each row. */}
      <div className="mb-4">
        <h3 className="text-sm font-semibold text-text-muted uppercase tracking-wide mb-2">Prerequisites</h3>
        <ul className="space-y-2">
          {(status?.preconditions ?? []).map(p => (
            <li key={p.key} className="rounded border border-border bg-surface-secondary/40 px-3 py-2">
              <div className="flex items-start gap-2">
                <Icon
                  name={p.ok ? 'CheckCircle2' : 'AlertCircle'}
                  size={16}
                  className={p.ok ? 'text-accent flex-shrink-0 mt-0.5' : 'text-amber-400 flex-shrink-0 mt-0.5'}
                />
                <div className="flex-1 min-w-0">
                  <div className="text-sm font-medium">{p.label}</div>
                  <div className={`text-xs mt-0.5 ${p.ok ? 'text-text-muted' : 'text-amber-300/80'}`}>
                    {p.detail}
                  </div>
                  {!p.ok && (
                    <div className="mt-2 text-xs">
                      <div className="text-text-muted mb-1">
                        <span className="font-semibold text-amber-400">Fix:</span> {p.fix}
                      </div>
                      {p.installCommand && (
                        <div className="flex items-center gap-2 mt-1">
                          <code className="flex-1 font-mono text-xs bg-background border border-border rounded px-2 py-1 overflow-x-auto whitespace-nowrap">
                            {p.installCommand}
                          </code>
                          <button
                            type="button"
                            className="btn btn-ghost text-xs flex-shrink-0"
                            onClick={() => copyCmd(p.installCommand!)}
                          >
                            <Icon name="Copy" size={12} /> Copy
                          </button>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      </div>

      {/* Action buttons + a tight reminder of what they do, kept inline. */}
      <div className="flex flex-wrap items-center gap-3 pt-2 border-t border-border">
        <button
          type="button"
          className="btn btn-primary"
          disabled={!status?.canApply || busy !== null}
          onClick={() => void handleApply()}
          title={status?.canApply ? 'All prerequisites met' : 'Resolve every prerequisite above first'}
        >
          <Icon name={busy === 'apply' ? 'Loader2' : 'Wrench'} size={15} className={busy === 'apply' ? 'animate-spin' : ''} />
          {busy === 'apply' ? 'Applying…' : 'Apply Sane-Pricing Patch'}
        </button>

        <button
          type="button"
          className="btn btn-ghost"
          disabled={!status?.canRestore || busy !== null}
          onClick={() => void handleRestore()}
          title={status?.canRestore ? 'Restore upstream dune-admin.exe from .upstream backup' : 'Nothing to restore (patch not currently applied)'}
        >
          <Icon name={busy === 'restore' ? 'Loader2' : 'Undo2'} size={15} className={busy === 'restore' ? 'animate-spin' : ''} />
          {busy === 'restore' ? 'Restoring…' : 'Restore Upstream'}
        </button>

        <div className="text-xs text-text-muted ml-auto max-w-md">
          <span className="font-semibold">Heads up:</span> Apply runs <span className="font-mono">build-patched.ps1 -Restart</span> in your dune-admin
          source repo. It will stop, rebuild, and relaunch dune-admin in a new console window.
        </div>
      </div>

      {lastLog && (
        <details className="mt-4 text-xs">
          <summary className="cursor-pointer text-text-muted hover:text-foreground">
            Last apply log (click to expand)
          </summary>
          <pre className="mt-2 max-h-64 overflow-auto rounded border border-border bg-background p-2 font-mono text-[11px] whitespace-pre-wrap">
            {lastLog}
          </pre>
        </details>
      )}
    </section>
  )
}
