import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getTimeOfDayLockConfig,
  restoreTimeOfDayCycle,
  stageTimeOfDayPhase,
  type TimeOfDayLockConfig,
} from '../../api/gameconfig'

export function TimeOfDayLockPanel({ vmRunning }: { vmRunning: boolean }) {
  const [config, setConfig] = useState<TimeOfDayLockConfig | null>(null)
  const [candidate, setCandidate] = useState('')
  const [busy, setBusy] = useState<'stage' | 'restore' | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const missingEntries = config !== null && (
    config.current.startTime === null || config.current.timeOfDayEnabled === null
  )

  useEffect(() => {
    let cancelled = false
    void getTimeOfDayLockConfig()
      .then(result => {
        if (cancelled) return
        setConfig(result)
        setCandidate(result.current.candidate ?? '')
      })
      .catch(reason => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => { cancelled = true }
  }, [])

  async function stage() {
    if (!candidate) return
    const confirmed = window.confirm(
      `Set phase ${candidate}?\n\n`
      + 'DST will first verify a server Game.ini backup, then write the selected m_StartTime and disable the cycle. '
      + 'Nothing takes effect until Apply server settings. DST will not modify client files.',
    )
    if (!confirmed) return
    setBusy('stage')
    setError(null)
    setMessage(null)
    try {
      const result = await stageTimeOfDayPhase(candidate)
      setConfig(previous => previous ? {
        ...previous,
        current: { startTime: candidate, timeOfDayEnabled: 'False', candidate },
      } : previous)
      setMessage(`${result.message} Backup: ${result.backup}`)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy(null)
    }
  }

  async function restore() {
    const confirmed = window.confirm(
      'Restore normal cycle?\n\nDST will verify a fresh server Game.ini backup, remove both DST-managed twilight overrides, '
      + 'and restore shipped default semantics. Apply server settings is still required.',
    )
    if (!confirmed) return
    setBusy('restore')
    setError(null)
    setMessage(null)
    try {
      const result = await restoreTimeOfDayCycle()
      setConfig(previous => previous ? {
        ...previous,
        current: { startTime: null, timeOfDayEnabled: null, candidate: null },
      } : previous)
      setMessage(`${result.message} Backup: ${result.backup}`)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="mt-5 rounded-lg border border-border bg-surface p-4" aria-labelledby="time-of-day-title">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Icon name="Sunset" size={18} className="text-warning" />
            <h3 id="time-of-day-title" className="font-semibold text-text">Time of day</h3>
          </div>
          <p className="mt-1 text-sm text-text-muted">
            Hold the server at the selected time of day.
          </p>
        </div>
      </div>

      <div className="mt-4 grid gap-3 lg:grid-cols-2">
        <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
          <h3 className="font-medium text-text">Time of day setting</h3>
          <p className="mt-2 text-text-muted">
            Select Sunset, Twilight, Dark night, Full night, or Dew harvest. Apply server settings after saving.
          </p>
          <label className="mt-3 block text-xs font-medium text-text-muted" htmlFor="twilight-candidate">
            Time of day phase
          </label>
          {config && (
            <p className="mt-2 text-xs text-text-muted">
              Server UserGame.ini: m_StartTime={config.current.startTime ?? 'not set'}; m_bTimeOfDayEnabled={config.current.timeOfDayEnabled ?? 'not set'}.
            </p>
          )}
          <select
            id="twilight-candidate"
            className="mt-1 min-h-11 rounded-lg border border-border bg-surface px-3 text-sm text-text"
            value={candidate}
            onChange={event => setCandidate(event.target.value)}
            disabled={!config || busy !== null}
          >
            <option value="" disabled>Select a phase</option>
            {(config?.candidates ?? []).map(option => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
          {missingEntries && (
            <p className="mt-2 text-sm text-text-muted">
              Select a phase, then use Add time of day settings to add the required entries to the server INI here.
              DST backs up the file first and preserves other settings.
            </p>
          )}
        </div>
        <div className="rounded-lg border border-warning/30 bg-warning/5 p-3 text-sm">
          <h3 className="font-medium text-warning">Client and restart behavior</h3>
          <p className="mt-2 text-text-muted">
            Changes apply to the server INI. Use <strong>Apply server settings</strong> after setting a phase or restoring the cycle.
          </p>
        </div>
      </div>

      {!vmRunning && (
        <p className="mt-3 text-sm text-warning">Start the server VM before setting a phase or restoring the cycle.</p>
      )}
      {error && <p className="mt-3 text-sm text-danger" role="alert">{error}</p>}
      {message && <p className="mt-3 text-sm text-success" role="status">{message}</p>}

      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          className="btn-primary min-h-11"
          disabled={!vmRunning || !config?.available || !candidate || busy !== null}
          onClick={() => { void stage() }}
        >
          <Icon name={busy === 'stage' ? 'Loader2' : 'Sunset'} size={14} className={busy === 'stage' ? 'animate-spin' : undefined} />
          {busy === 'stage' ? 'Saving…' : missingEntries ? 'Add time of day settings' : 'Set time of day'}
        </button>
        <button
          type="button"
          className="btn-secondary min-h-11"
          disabled={!vmRunning || busy !== null}
          onClick={() => { void restore() }}
        >
          <Icon name={busy === 'restore' ? 'Loader2' : 'RotateCcw'} size={14} className={busy === 'restore' ? 'animate-spin' : undefined} />
          {busy === 'restore' ? 'Restoring…' : 'Restore normal cycle'}
        </button>
      </div>
    </section>
  )
}
