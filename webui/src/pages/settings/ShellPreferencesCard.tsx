import { useEffect, useState } from 'react'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { Icon } from '../../components/Icon'
import {
  getShellPreferences,
  restartShell,
  setShellPreferences,
  type ShellPreferencesState,
} from '../../util/shellBridge'

export function ShellPreferencesCard() {
  const [state, setState] = useState<ShellPreferencesState | null>(null)
  const [softwareRendering, setSoftwareRendering] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let live = true
    getShellPreferences()
      .then(next => {
        if (!live) return
        setState(next)
        setSoftwareRendering(next.preferences.softwareRendering)
      })
      .catch(err => {
        if (live) setError(err instanceof Error ? err.message : String(err))
      })
    return () => { live = false }
  }, [])

  const dirty = state !== null &&
    softwareRendering !== state.preferences.softwareRendering

  async function saveAndRestart() {
    setBusy(true)
    setError(null)
    try {
      const next = dirty
        ? await setShellPreferences({ softwareRendering })
        : state
      if (!next) return
      setState(next)
      if (next.restartRequired) await restartShell()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <CollapsibleCard
      id="settings.desktopShell"
      icon="MonitorCog"
      title="Desktop shell"
      titleClassName="text-lg font-semibold"
      headerClassName="px-6 pt-6 pb-2"
      bodyClassName="px-6 pb-6"
    >
      <div className="space-y-4">
        <p className="text-sm text-text-dim">
          These preferences apply only to this Windows desktop shell. Browser and Remote Access sessions are unaffected.
        </p>

        <label className="flex items-start gap-3 rounded-lg border border-border bg-surface-2/30 p-4">
          <input
            type="checkbox"
            checked={softwareRendering}
            disabled={!state || busy}
            onChange={event => setSoftwareRendering(event.target.checked)}
            className="mt-1 h-4 w-4 accent-accent"
          />
          <span>
            <span className="block font-medium">Use software rendering</span>
            <span className="block text-sm text-text-dim mt-1">
              Disables WebView2 GPU acceleration. Enable this only to work around graphics-driver rendering problems.
              The default is hardware acceleration.
            </span>
          </span>
        </label>

        {state && (
          <p className="text-xs text-text-dim">
            Active now: {state.active.softwareRendering ? 'software rendering' : 'hardware acceleration'}.
            {state.restartRequired && ' A shell restart is required to apply the saved preference.'}
          </p>
        )}

        {error && (
          <div className="text-sm text-danger flex items-center gap-2" role="alert">
            <Icon name="AlertCircle" size={14} />
            {error}
          </div>
        )}

        <div className="flex items-center gap-3">
          <button
            type="button"
            className="btn-primary"
            disabled={(!dirty && !state?.restartRequired) || busy}
            onClick={saveAndRestart}
          >
            <Icon name="RefreshCw" size={14} />
            {busy ? 'Applying...' : dirty ? 'Save and restart shell' : 'Restart shell'}
          </button>
          <span className="text-xs text-text-dim">
            Restarts only the desktop window; the DST backend and game server keep running.
          </span>
        </div>
      </div>
    </CollapsibleCard>
  )
}
