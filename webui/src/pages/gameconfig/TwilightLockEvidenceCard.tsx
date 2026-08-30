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

  useEffect(() => {
    let cancelled = false
    void getTimeOfDayLockConfig()
      .then(result => {
        if (cancelled) return
        setConfig(result)
        setCandidate(result.currentCandidate ?? result.candidates[0]?.value ?? '')
      })
      .catch(reason => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => { cancelled = true }
  }, [])

  async function stage() {
    if (!candidate) return
    const confirmed = window.confirm(
      `Lock Time of Day at ${candidate}?\n\n`
      + 'DST will first verify a server Game.ini backup, then write the selected m_StartTime and disable the cycle. '
      + 'Nothing takes effect until Apply INIs & restart. DST will not modify client files.',
    )
    if (!confirmed) return
    setBusy('stage')
    setError(null)
    setMessage(null)
    try {
      const result = await stageTimeOfDayPhase(candidate)
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
      + 'and restore shipped default semantics. Apply INIs & restart is still required.',
    )
    if (!confirmed) return
    setBusy('restore')
    setError(null)
    setMessage(null)
    try {
      const result = await restoreTimeOfDayCycle()
      setMessage(`${result.message} Backup: ${result.backup}`)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="mt-5 rounded-lg border border-border bg-surface p-4" aria-labelledby="time-of-day-title">
      <div className="flex items-center gap-2">
        <Icon name="Sunset" size={18} className="text-warning" />
        <div>
          <h3 id="time-of-day-title" className="font-semibold text-text">Time of Day</h3>
          <p className="text-sm text-text-muted">
            Lock the server at sunset, twilight, night, or the dew harvest window.
          </p>
        </div>
      </div>

      <p className="mt-3 text-sm text-text-muted">
        Ordinary resources continue to respawn while the clock is frozen. The server never advances
        to other hours, so game behavior tied to those hours will not occur until the lock changes
        or the normal cycle is restored. The dew preset is only for the 04:00 lock time; during the
        normal unlocked cycle, dew remains available across its natural time span. The normal daily
        battlegroup restart replenishes harvested dew.
      </p>

      {!vmRunning && (
        <p className="mt-3 text-sm text-warning">Start the server VM before locking or restoring Time of Day.</p>
      )}
      {error && <p className="mt-3 text-sm text-danger" role="alert">{error}</p>}
      {message && <p className="mt-3 text-sm text-success" role="status">{message}</p>}

      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-xs font-medium text-text-muted" htmlFor="twilight-candidate">
          Locked phase
          <select
            id="twilight-candidate"
            className="mt-1 block min-h-11 rounded-lg border border-border bg-surface-2 px-3 text-sm text-text"
            value={candidate}
            onChange={event => setCandidate(event.target.value)}
            disabled={!config || busy !== null}
          >
            {(config?.candidates ?? []).map(option => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </label>
        <button
          type="button"
          className="btn-primary min-h-11"
          disabled={!vmRunning || !config?.available || busy !== null}
          onClick={() => { void stage() }}
        >
          <Icon name={busy === 'stage' ? 'Loader2' : 'Sunset'} size={14} className={busy === 'stage' ? 'animate-spin' : undefined} />
          {busy === 'stage' ? 'Locking…' : 'Back up & lock phase'}
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
