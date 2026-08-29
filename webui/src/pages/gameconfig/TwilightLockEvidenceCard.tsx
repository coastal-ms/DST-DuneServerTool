import { Icon } from '../../components/Icon'

export function TwilightLockEvidenceCard() {
  return (
    <section className="card mb-4 p-4" aria-labelledby="twilight-lock-title">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Icon name="Sunset" size={18} className="text-warning" />
            <h2 id="twilight-lock-title" className="font-semibold text-text">
              Twilight lock
            </h2>
          </div>
          <p className="mt-1 text-sm text-text-muted">
            Experimental evidence gate for a visual-only fixed sun phase.
          </p>
        </div>
        <span className="pill border-warning/40 text-warning">Phase lock unavailable</span>
      </div>

      <div className="mt-4 grid gap-3 lg:grid-cols-2">
        <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
          <h3 className="font-medium text-text">What is known</h3>
          <ul className="mt-2 space-y-1.5 text-text-muted">
            <li><code>m_StartTime=12.0</code> exists in the shipped TimeOfDaySettings defaults.</li>
            <li><code>m_bTimeOfDayEnabled</code> controls whether the day/night cycle advances.</li>
            <li>DST does not expose or write <code>m_StartTime</code> because its effect, range, and apply behavior are unverified.</li>
          </ul>
        </div>
        <div className="rounded-lg border border-warning/30 bg-warning/5 p-3 text-sm">
          <h3 className="font-medium text-warning">What is not proven</h3>
          <p className="mt-2 text-text-muted">
            No recovered key or command selects twilight while independently freezing only the visual sun.
            Disabling the cycle may also stop time-of-day-driven simulation or schedules, so DST will not
            automate that pairing in this test.
          </p>
        </div>
      </div>

      <div className="mt-3 rounded-lg border border-border bg-surface-2 p-3 text-sm">
        <h3 className="font-medium text-text">Field experiment required to unlock this feature</h3>
        <p className="mt-1 text-text-muted">
          On a disposable test battlegroup, manually compare the shipped default against one candidate
          <code> m_StartTime</code> override, restart map processes, and determine its units, scope, and whether
          clients need a matching value. Only after that is verified, disable the cycle and observe for at
          least 30 minutes while checking crafting, scheduled events, patrol timing, and server timers.
          Record whether lighting stays fixed and every non-visual timer continues.
        </p>
      </div>

      <div className="mt-3 text-xs text-text-dim">
        <p>
          Restore normal cycle: remove the experimental <code>m_StartTime</code> override from every modified
          server and client INI, enable <strong className="text-text-muted">Time of Day Cycle</strong>, save,
          then use Apply INIs &amp; restart.
        </p>
        <p className="mt-1 font-medium text-text-muted">This card does not change any setting.</p>
      </div>
    </section>
  )
}
