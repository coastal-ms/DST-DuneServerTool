import { clearSettingsApplyResult, useSettingsApplyOperation } from '../hooks/useSettingsApplyOperation'
import { Link } from '../router'

export function SettingsApplyProgress() {
  const { running, message, error } = useSettingsApplyOperation()
  if (!running && !message && !error) return null
  return <div className={`px-4 py-3 text-sm border-b ${error ? 'border-danger/40 bg-danger/10 text-danger' : 'border-accent/30 bg-accent/10 text-text'}`}>
    <div role={error ? 'alert' : 'status'}>{error || message}</div>
    {running && <p className="mt-1 text-text-muted">You can move between DST pages. Keep DST open until this finishes.</p>}
    <div className="mt-1 flex items-center gap-4">
      <Link to="/" className="underline">Server Overview</Link>
      {!running && <button type="button" className="underline" onClick={clearSettingsApplyResult}>Dismiss</button>}
    </div>
  </div>
}
