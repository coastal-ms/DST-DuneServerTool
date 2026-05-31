import { useEffect, useRef, useState } from 'react'
import { Icon } from './Icon'
import {
  installDependency,
  dependencyInstallStatus,
  type SystemDependency,
  type DependencyInstallStatus,
} from '../api/dependencies'

type DepUiState = {
  status: 'idle' | 'running' | 'success' | 'failed'
  error?: string
  logTail?: string
}

export interface DependencyInstallModalProps {
  /** The missing dependencies to offer to install. */
  deps: SystemDependency[]
  /** Whether winget is available on the machine (drives the manual-fallback note). */
  wingetAvailable: boolean
  /** One-line context, e.g. "The patched dune-admin build needs these tools." */
  context?: string
  /** Called when the user cancels / dismisses without resolving everything. */
  onCancel: () => void
  /** Called once every offered dependency is present (installed or already there). */
  onAllResolved: () => void
}

/**
 * Reusable "DST needs <X> — install it?" dialog.
 *
 * Given a set of missing dependencies, it offers a one-click winget install for
 * each (run detached on the backend), polls until each is present, and fires
 * onAllResolved when nothing is missing anymore. Generalised so any feature can
 * reuse it — not just the dune-admin patch build.
 */
export function DependencyInstallModal({
  deps,
  wingetAvailable,
  context,
  onCancel,
  onAllResolved,
}: DependencyInstallModalProps) {
  // Per-dependency UI state keyed by name. Seed from the incoming list.
  const [state, setState] = useState<Record<string, DepUiState>>(() =>
    Object.fromEntries(deps.map(d => [d.name, { status: 'idle' as const }])),
  )
  // Names confirmed present (resolved) this session.
  const [resolved, setResolved] = useState<Record<string, boolean>>({})
  const pollers = useRef<Record<string, number>>({})

  // When every offered dep is resolved, notify the parent.
  useEffect(() => {
    if (deps.length > 0 && deps.every(d => resolved[d.name])) {
      onAllResolved()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [resolved])

  // Clean up any polling intervals on unmount.
  useEffect(() => {
    return () => {
      Object.values(pollers.current).forEach(id => window.clearInterval(id))
    }
  }, [])

  function applyStatus(name: string, s: DependencyInstallStatus) {
    setState(prev => ({
      ...prev,
      [name]: { status: s.status === 'idle' ? 'idle' : s.status, error: s.error, logTail: s.logTail },
    }))
    if (s.found || s.status === 'success') {
      window.clearInterval(pollers.current[name])
      delete pollers.current[name]
      setResolved(prev => ({ ...prev, [name]: true }))
      setState(prev => ({ ...prev, [name]: { status: 'success' } }))
    } else if (s.status === 'failed') {
      window.clearInterval(pollers.current[name])
      delete pollers.current[name]
    }
  }

  async function onInstall(dep: SystemDependency) {
    setState(prev => ({ ...prev, [dep.name]: { status: 'running' } }))
    try {
      const start = await installDependency(dep.name)
      if (start.alreadyInstalled || start.status === 'success') {
        setResolved(prev => ({ ...prev, [dep.name]: true }))
        setState(prev => ({ ...prev, [dep.name]: { status: 'success' } }))
        return
      }
      if (start.status === 'failed') {
        setState(prev => ({ ...prev, [dep.name]: { status: 'failed', error: start.error } }))
        return
      }
      // Poll until terminal.
      window.clearInterval(pollers.current[dep.name])
      pollers.current[dep.name] = window.setInterval(async () => {
        try {
          const s = await dependencyInstallStatus(dep.name)
          applyStatus(dep.name, s)
        } catch {
          /* transient; keep polling */
        }
      }, 2000)
    } catch (e) {
      setState(prev => ({
        ...prev,
        [dep.name]: { status: 'failed', error: e instanceof Error ? e.message : String(e) },
      }))
    }
  }

  const anyRunning = Object.values(state).some(s => s.status === 'running')
  const allDone = deps.length > 0 && deps.every(d => resolved[d.name])

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={() => { if (!anyRunning) onCancel() }}
    >
      <div className="card p-0 max-w-lg w-full" onClick={e => e.stopPropagation()}>
        <div className="px-5 py-4 border-b border-border flex items-center justify-between">
          <h3 className="font-semibold text-text flex items-center gap-2">
            <Icon name="PackagePlus" size={16} className="text-accent" />
            DST needs {deps.length === 1 ? 'a tool' : 'some tools'}
          </h3>
          <button
            type="button"
            className="btn-ghost px-2 py-1 disabled:opacity-40"
            disabled={anyRunning}
            onClick={onCancel}
          >
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-3 text-sm text-text leading-relaxed">
          <div className="text-text-muted">
            {context ?? 'This action needs the following tool(s) that are not installed yet.'}{' '}
            DST can install them for you{wingetAvailable ? ' via winget' : ''}.
          </div>

          {!wingetAvailable && (
            <div className="rounded border border-warning/40 bg-warning/5 px-3 py-2 text-xs text-warning">
              winget (Windows Package Manager) was not found, so automatic install is unavailable.
              Install each tool manually using the command shown, then retry.
            </div>
          )}

          <ul className="space-y-2">
            {deps.map(dep => {
              const st = state[dep.name] ?? { status: 'idle' }
              const done = resolved[dep.name] || st.status === 'success'
              return (
                <li key={dep.name} className="rounded-lg border border-border bg-bg-dim p-3">
                  <div className="flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <div className="font-medium text-text flex items-center gap-2">
                        {dep.display}
                        {done && <Icon name="CheckCircle2" size={14} className="text-success" />}
                      </div>
                      <div className="text-xs text-text-dim">{dep.reason}</div>
                      <div className="text-[11px] font-mono text-text-muted mt-0.5">
                        winget install --id {dep.wingetId}
                      </div>
                    </div>
                    <div className="shrink-0">
                      {done ? (
                        <span className="text-xs text-success font-medium flex items-center gap-1">
                          <Icon name="Check" size={14} /> installed
                        </span>
                      ) : st.status === 'running' ? (
                        <span className="text-xs text-text-muted flex items-center gap-1">
                          <Icon name="Loader2" size={14} className="animate-spin" /> installing…
                        </span>
                      ) : (
                        <button
                          type="button"
                          className="btn-primary text-xs px-3 py-1.5 disabled:opacity-40"
                          disabled={!wingetAvailable}
                          onClick={() => onInstall(dep)}
                        >
                          <Icon name="Download" size={14} />
                          {st.status === 'failed' ? 'Retry' : 'Install'}
                        </button>
                      )}
                    </div>
                  </div>
                  {st.status === 'failed' && st.error && (
                    <div className="mt-2 text-xs text-danger break-words">{st.error}</div>
                  )}
                  {st.status === 'running' && st.logTail && (
                    <pre className="mt-2 text-[10px] font-mono bg-bg border border-border rounded p-2 max-h-24 overflow-auto whitespace-pre-wrap">
                      {st.logTail}
                    </pre>
                  )}
                </li>
              )
            })}
          </ul>
        </div>

        <div className="px-5 py-4 border-t border-border flex items-center justify-end gap-2">
          <button type="button" className="btn-ghost disabled:opacity-40" disabled={anyRunning} onClick={onCancel}>
            {allDone ? 'Close' : 'Cancel'}
          </button>
          {allDone && (
            <button type="button" className="btn-primary" onClick={onAllResolved}>
              <Icon name="ArrowRight" size={15} />
              Continue
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
