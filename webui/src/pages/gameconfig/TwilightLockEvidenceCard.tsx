import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getTwilightLockExperiment,
  restoreTwilightLockCycle,
  stageTwilightLockCandidate,
  type TwilightLockExperiment,
} from '../../api/gameconfig'

export function TwilightLockEvidenceCard({ vmRunning }: { vmRunning: boolean }) {
  const [experiment, setExperiment] = useState<TwilightLockExperiment | null>(null)
  const [candidate, setCandidate] = useState('')
  const [busy, setBusy] = useState<'stage' | 'restore' | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    void getTwilightLockExperiment()
      .then(result => {
        if (cancelled) return
        setExperiment(result)
        setCandidate(result.candidates[0]?.value ?? '')
      })
      .catch(reason => {
        if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason))
      })
    return () => { cancelled = true }
  }, [])

  async function stage() {
    if (!candidate) return
    const confirmed = window.confirm(
      `Stage candidate ${candidate}?\n\n`
      + 'DST will first verify a server Game.ini backup, then write the candidate m_StartTime and disable the cycle. '
      + 'Nothing takes effect until Apply INIs & restart. DST will not modify client files.',
    )
    if (!confirmed) return
    setBusy('stage')
    setError(null)
    setMessage(null)
    try {
      const result = await stageTwilightLockCandidate(candidate)
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
      const result = await restoreTwilightLockCycle()
      setMessage(`${result.message} Backup: ${result.backup}`)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="card mb-4 p-4" aria-labelledby="twilight-lock-title">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Icon name="Sunset" size={18} className="text-warning" />
            <h2 id="twilight-lock-title" className="font-semibold text-text">Twilight lock field test</h2>
          </div>
          <p className="mt-1 text-sm text-text-muted">
            Tests whether shipped settings can hold twilight lighting without stopping simulation time.
          </p>
        </div>
        <span className="pill border-warning/40 text-warning">Unverified candidates</span>
      </div>

      <div className="mt-4 grid gap-3 lg:grid-cols-2">
        <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
          <h3 className="font-medium text-text">What DST will stage</h3>
          <p className="mt-2 text-text-muted">
            A server backup, one bounded <code>m_StartTime</code> candidate, and
            <code> m_bTimeOfDayEnabled=False</code>. Values 17, 18, and 19 only bracket conventional
            24-hour dusk; none is labeled as the correct Dune twilight phase.
          </p>
          <label className="mt-3 block text-xs font-medium text-text-muted" htmlFor="twilight-candidate">
            Candidate phase value
          </label>
          <select
            id="twilight-candidate"
            className="mt-1 min-h-11 rounded-lg border border-border bg-surface px-3 text-sm text-text"
            value={candidate}
            onChange={event => setCandidate(event.target.value)}
            disabled={!experiment || busy !== null}
          >
            {(experiment?.candidates ?? []).map(option => (
              <option key={option.value} value={option.value}>{option.label}</option>
            ))}
          </select>
        </div>
        <div className="rounded-lg border border-warning/30 bg-warning/5 p-3 text-sm">
          <h3 className="font-medium text-warning">Client and restart behavior</h3>
          <p className="mt-2 text-text-muted">
            DST does not modify client INIs because client behavior for <code>m_StartTime</code> is unverified.
            The first test is server-only. Both stage and restore require <strong>Apply INIs &amp; restart</strong>.
          </p>
          <p className="mt-2 text-text-muted">
            The action does not claim simulation safety. It exists to produce the evidence needed for that decision.
          </p>
        </div>
      </div>

      <div className="mt-3 rounded-lg border border-border bg-surface-2 p-3 text-sm">
        <h3 className="font-medium text-text">
          {experiment?.minimumObservationMinutes ?? 30}-minute checklist
        </h3>
        <ul className="mt-2 grid gap-1.5 text-text-muted sm:grid-cols-2">
          <li>Check whether lighting remains at the selected visual phase.</li>
          <li>Check whether crafting timers continue and complete.</li>
          <li>Check whether scheduled events continue.</li>
          <li>Check whether patrol spawn/despawn timing continues.</li>
          <li>Check whether server timers continue advancing.</li>
          <li>Record whether clients needed a matching override.</li>
        </ul>
      </div>

      {!vmRunning && (
        <p className="mt-3 text-sm text-warning">Start the server VM before staging or restoring this experiment.</p>
      )}
      {error && <p className="mt-3 text-sm text-danger" role="alert">{error}</p>}
      {message && <p className="mt-3 text-sm text-success" role="status">{message}</p>}

      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          className="btn-primary min-h-11"
          disabled={!vmRunning || !experiment?.available || busy !== null}
          onClick={() => { void stage() }}
        >
          <Icon name={busy === 'stage' ? 'Loader2' : 'Sunset'} size={14} className={busy === 'stage' ? 'animate-spin' : undefined} />
          {busy === 'stage' ? 'Staging…' : 'Back up & stage candidate'}
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
