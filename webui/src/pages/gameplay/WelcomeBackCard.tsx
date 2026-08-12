import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getWelcomeBack, saveWelcomeBack } from '../../api/gameplay'
import type { WelcomeBackState } from '../../api/types'

// Welcome Back - give a returning player an item package when they come back.
//
// Replaces the three returning-player console variables that were removed, which
// a Funcom developer confirmed do nothing on a self-hosted server. This does the
// same job with the admin's own item packages.
//
// The wording here is deliberate about WHEN it fires. The absence is measured
// between a player's previous login and the one that just happened, so it pays
// out once per absence and enabling it cannot hand packages to a whole existing
// player base at once. An admin who does not know that would reasonably fear
// turning it on.

function formatWhen(iso?: string): string {
  if (!iso) return 'never'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return 'never'
  return d.toLocaleString()
}

export function WelcomeBackCard() {
  const [state, setState] = useState<WelcomeBackState | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [days, setDays] = useState('7')

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      const s = await getWelcomeBack()
      setState(s)
      setDays(String(s.daysAway ?? 7))
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  async function patch(body: Parameters<typeof saveWelcomeBack>[0], note?: string) {
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await saveWelcomeBack(body)
      // The PUT returns settings but not the package list or history, so merge
      // rather than replace and keep those from the last GET.
      setState(prev => (prev ? { ...prev, ...res, packages: prev.packages, recent: prev.recent } : prev))
      if (typeof res.daysAway === 'number') setDays(String(res.daysAway))
      if (note) setOk(note)
      // Enabling runs a seeding pass, so the tracked count changes - refresh to
      // show it rather than leaving a stale number on screen.
      if (body.enabled === true) { void load() }
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  const enabled = state?.enabled === true
  const packages = state?.packages ?? []
  const recent = state?.recent ?? []
  const chosen = packages.find(p => p.id === state?.packageId)

  return (
    <CollapsibleCard
      id="gameplay.welcomeBack"
      icon="Gift"
      iconClassName="text-ibad shrink-0"
      title="Welcome back"
      titleClassName="text-sm font-semibold uppercase tracking-wider text-ibad"
      subtitle={
        <span className="text-xs text-text-muted">
          Give a package to players returning after time away. Off by default.
        </span>
      }
      headerClassName="px-5 pt-5 pb-2"
      bodyClassName="px-5 pb-5"
      headerRight={
        <button type="button" className="btn-secondary" disabled={loading || saving}
                onClick={() => void load()}>
          <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14}
                className={loading ? 'animate-spin' : ''} />
          Refresh
        </button>
      }
    >
      {err && <div className="mb-3 px-3 py-2 rounded border border-danger/40 bg-danger/10 text-danger text-xs">{err}</div>}
      {ok && <div className="mb-3 px-3 py-2 rounded border border-success/40 bg-success/10 text-success text-xs">{ok}</div>}

      <p className="text-xs text-text-muted mb-3">
        When a player logs in after being away, DST gives them one of your item
        packages. The gap is measured between their previous login and this one, so
        each player is given the package once per absence — turning this on will not
        hand anything to your existing players until they next return.
      </p>
      <div className="mb-3 px-3 py-2 rounded border border-warning/35 bg-warning/10 text-xs text-text-muted">
        Still seeing the game&apos;s older returning-player popup? That is separate from
        this DST package feature. Set <b className="text-text">Legacy Returning Player Popup</b> to
        Disabled under Experimental Lab, then use Apply INIs &amp; restart.
      </div>

      <label className="flex items-center gap-2 text-sm cursor-pointer">
        <input type="checkbox" checked={enabled} disabled={saving || loading}
               onChange={e => void patch({ enabled: e.target.checked },
                 e.target.checked ? 'Watching for returning players.' : 'Stopped.')}
               className="accent-ibad" />
        <span className="font-medium text-text">Give a package to returning players</span>
      </label>

      {enabled && state?.readyMessage && (
        <div className="mt-2 px-3 py-2 rounded border border-warning/40 bg-warning/10 text-warning text-xs">
          {state.readyMessage}
        </div>
      )}

      <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Package to give</label>
          <select
            value={state?.packageId ?? ''}
            disabled={saving || loading}
            onChange={e => {
              setState(prev => (prev ? { ...prev, packageId: e.target.value } : prev))
              void patch({ packageId: e.target.value })
            }}
            className="w-full px-2 py-1.5 rounded bg-surface border border-border text-text text-sm"
          >
            <option value="">— none chosen —</option>
            {packages.map(p => (
              <option key={p.id} value={p.id}>
                {p.name} ({p.itemCount} item{p.itemCount === 1 ? '' : 's'})
              </option>
            ))}
          </select>
          {packages.length === 0 && (
            <div className="mt-1 text-[11px] text-warning">
              No item packages exist yet. Create one under Players &rsaquo; Give Package.
            </div>
          )}
        </div>

        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Days away before it counts</label>
          <div className="flex items-center gap-2">
            <input
              type="text" inputMode="numeric"
              value={days}
              disabled={saving || loading}
              onChange={e => setDays(e.target.value.replace(/[^\d]/g, ''))}
              onBlur={() => {
                const n = Number(days)
                // >= 0: zero is a real setting, not an error. See the note in
                // lib/WelcomeBack.ps1 - it means every login qualifies.
                if (days !== '' && Number.isFinite(n) && n >= 0 && n !== state?.daysAway) void patch({ daysAway: n })
                else setDays(String(state?.daysAway ?? 7))
              }}
              className="w-24 px-2 py-1.5 rounded bg-surface border border-border text-text font-mono text-sm"
            />
            <span className="text-xs text-text-dim">days</span>
          </div>
          {state?.daysAway === 0 && (
            <div className="mt-1 text-[11px] text-warning">
              0 means every login qualifies — they get the package each time they come back.
            </div>
          )}
        </div>
      </div>

      <label className="mt-3 flex items-center gap-2 text-xs cursor-pointer">
        <input type="checkbox" checked={state?.announce === true} disabled={saving || loading}
               onChange={e => {
                 setState(prev => (prev ? { ...prev, announce: e.target.checked } : prev))
                 void patch({ announce: e.target.checked })
               }}
               className="accent-ibad" />
        <span className="text-text">Announce it to the server when someone gets one</span>
      </label>

      <div className="mt-4 pt-3 border-t border-border flex flex-wrap gap-x-6 gap-y-1 text-[11px] text-text-dim">
        <span>Players tracked: <span className="text-text-muted">{state?.tracked ?? 0}</span></span>
        <span>Last checked: <span className="text-text-muted">{formatWhen(state?.lastRunAt)}</span></span>
        {chosen && <span>Giving: <span className="text-text-muted">{chosen.name}</span></span>}
      </div>

      {recent.length > 0 && (
        <div className="mt-3">
          <div className="text-[11px] uppercase tracking-wider text-text-dim mb-1.5">Recently given</div>
          <ul className="space-y-1">
            {recent.slice(0, 8).map((g, i) => (
              <li key={`${g.at}-${i}`} className="flex items-center gap-2 text-xs">
                <Icon name={g.ok ? 'Check' : 'X'} size={12}
                      className={g.ok ? 'text-success shrink-0' : 'text-danger shrink-0'} />
                <span className="text-text">{g.name || 'Unknown'}</span>
                <span className="text-text-dim">away {Math.round(g.daysAway)}d</span>
                <span className="text-text-muted">{g.package}</span>
                <span className="text-text-dim ml-auto">{formatWhen(g.at)}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      <p className="mt-4 text-[11px] text-text-dim">
        DST checks every few minutes, so a package can arrive a little after they
        log in rather than the instant they do.
      </p>
    </CollapsibleCard>
  )
}
