import { clearSettingsApplyResult, useSettingsApplyOperation } from '../hooks/useSettingsApplyOperation'
import { Link } from '../router'
import { useStatusSnapshot } from '../hooks/useStatus'

export function SettingsApplyProgress() {
  const { running, message, error, stage, stageStartedAt } = useSettingsApplyOperation()
  const status = useStatusSnapshot()
  const bg = status?.bg
  // Cached status from before this stage cannot advance its progress message.
  const currentObservation = Date.parse(bg?.observedAt ?? '') >= stageStartedAt
  let progress = message
  if (currentObservation && stage === 'stopping') {
    if (bg?.state === 'stopped' && bg.gameServers?.length === 0) {
      progress = 'Battlegroup stopped. Preparing to save the reviewed settings…'
    } else if (bg?.state === 'running') {
      progress = 'Battlegroup running. Checking Apply progress…'
    }
  }
  if (currentObservation && stage === 'starting' && bg?.state === 'running') {
    const ready = !!bg.gameServers?.length && bg.gameServers.every(server => server.ready === 'true')
    progress = ready
      ? 'Reviewed settings applied. Battlegroup ready.'
      : 'Settings saved. Battlegroup starting; waiting for game servers to be ready…'
  }
  if (!running && !message && !error) return null
  return <div className={`px-4 py-3 text-sm border-b ${error ? 'border-danger/40 bg-danger/10 text-danger' : 'border-accent/30 bg-accent/10 text-text'}`}>
    <div role={error ? 'alert' : 'status'}>{error || progress}</div>
    {running && <p className="mt-1 text-text-muted">You can move between DST pages. Keep DST open until this finishes.</p>}
    <div className="mt-1 flex items-center gap-4">
      <Link to="/" className="underline">Server Overview</Link>
      {!running && <button type="button" className="underline" onClick={clearSettingsApplyResult}>Dismiss</button>}
    </div>
  </div>
}
