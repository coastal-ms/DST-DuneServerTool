// Landsraad Control — set which House holds the Landsraad and which decree is
// in force for the running term.
//
// Normally both are decided by voting at the end of a term: votes write
// elected_decree_id, and the next term promotes that into active_decree_id.
// A term nobody voted in therefore has both columns empty and the in-game board
// shows no holder at all. This card writes the current term row directly so an
// operator can seat a House and a decree without waiting for a vote.
//
// Two behaviours that are easy to get wrong and are deliberately surfaced here:
//   1. A decree is held BY a House — setting the decree alone renders nothing
//      in-game, so the House is always written alongside it.
//   2. The game reads the term row when a map pod starts, not live, so the
//      change only appears after a battlegroup restart.

import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getLandsraadTermControl, setLandsraadTermControl, restartLandsraadBattlegroup,
  type LandsraadTermControlResponse, type DataSource,
} from '../../api/gameplay'
import { SourceBadge } from './shared'

export function LandsraadControlCard() {
  const [data, setData] = useState<LandsraadTermControlResponse | null>(null)
  const [source, setSource] = useState<DataSource>('demo')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [flash, setFlash] = useState<string | null>(null)

  // Pending selection; null means "unchanged from what the server reports".
  const [selFaction, setSelFaction] = useState<number | null>(null)
  const [selDecree, setSelDecree] = useState<number | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [restartOffered, setRestartOffered] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getLandsraadTermControl()
      setData(r); setSource(r.source)
      setSelFaction(null); setSelDecree(null); setConfirming(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const canWrite = source === 'live'
  const holders = useMemo(() => (data?.factions ?? []).filter(f => f.can_hold), [data])

  const currentFaction = data?.reigning_faction_id ?? 0
  const currentDecree = data?.active_decree_id ?? 0

  // Server-disabled decrees can't be made active, so they're hidden rather than
  // shown greyed out. The exception is one that is somehow already in force —
  // then it stays visible so the card still reports the real current state.
  const decrees = useMemo(
    () => (data?.decrees ?? []).filter(d => !d.disabled || d.id === currentDecree),
    [data, currentDecree]
  )
  const pendingFaction = selFaction ?? currentFaction
  const pendingDecree = selDecree ?? currentDecree
  const dirty = pendingFaction !== currentFaction || pendingDecree !== currentDecree

  const holderName = holders.find(f => f.id === currentFaction)?.name
  const activeDecreeName = decrees.find(d => d.id === currentDecree)?.display_name

  const apply = useCallback(async () => {
    if (!data || data.term_id <= 0) return
    setBusy(true); setError(null); setFlash(null)
    try {
      // The House is always sent with the decree: a decree with no holder does
      // not render in-game, and seating one without the other is the exact
      // half-configured state this card exists to prevent.
      const r = await setLandsraadTermControl(pendingFaction || undefined, pendingDecree || undefined)
      setFlash(r.message ?? 'Landsraad term updated.')
      setConfirming(false)
      setRestartOffered(true)
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      setConfirming(false)
    } finally {
      setBusy(false)
    }
  }, [data, pendingFaction, pendingDecree, load])

  const restart = useCallback(async () => {
    setBusy(true); setError(null)
    try {
      const r = await restartLandsraadBattlegroup()
      setFlash(r.message ?? 'Battlegroup restart underway.')
      setRestartOffered(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }, [])

  return (
    <div className="card p-4 mb-4">
      <div className="flex items-center justify-between flex-wrap gap-2 mb-2">
        <div className="flex items-center gap-2">
          <Icon name="Crown" size={18} className="text-accent" />
          <span className="font-semibold text-text">Landsraad Control</span>
          <SourceBadge source={source} />
        </div>
        <button className="btn-secondary" onClick={() => void load()} disabled={loading || busy}>
          <Icon name="RefreshCw" size={14} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
      </div>

      <p className="text-xs text-text-muted leading-relaxed">
        Seat the House that <strong>holds the Landsraad</strong> and the <strong>decree</strong> in force for the
        running term, without waiting for a vote. A decree is held by a House, so both are written together —
        a decree on its own shows nothing in-game. Changes apply on the <strong>next map-pod start</strong>,
        so a battlegroup restart is required.
      </p>

      {data && data.term_id > 0 && (
        <div className="mt-2 text-xs text-text-dim">
          Term <span className="font-mono text-text">{data.term_id}</span>
          {data.end_time && <> • ends <span className="font-mono text-text">{data.end_time}</span></>}
          {' • '}holder <span className="font-mono text-text">{holderName ?? 'none'}</span>
          {' • '}decree <span className="font-mono text-text">{activeDecreeName ?? 'none'}</span>
        </div>
      )}

      {flash && <div className="mt-3 p-3 rounded text-sm text-success flex items-start gap-2 border border-border"><Icon name="CheckCircle2" size={15} className="mt-0.5 shrink-0" /> <span>{flash}</span></div>}
      {error && <div className="mt-3 p-3 rounded text-sm text-danger border border-border">{error}</div>}

      {data && data.term_id <= 0 && (
        <div className="mt-3 text-sm text-text-muted">No active Landsraad term — nothing to set.</div>
      )}

      {data && data.term_id > 0 && (
        <>
          <div className="mt-4">
            <div className="text-xs uppercase tracking-wide text-text-dim mb-2">Holds the Landsraad</div>
            <div className="flex flex-wrap gap-2">
              {holders.map(f => {
                const on = pendingFaction === f.id
                return (
                  <button
                    key={f.id}
                    type="button"
                    disabled={!canWrite || busy}
                    onClick={() => setSelFaction(f.id)}
                    className={`px-3 py-1.5 rounded border text-sm transition-colors ${
                      on ? 'border-accent text-text bg-surface-2' : 'border-border text-text-muted hover:text-text'
                    } ${!canWrite || busy ? 'opacity-50 cursor-not-allowed' : ''}`}
                  >
                    {on && <Icon name="Check" size={13} className="text-accent inline mr-1" />}
                    {f.name}
                    {f.id === currentFaction && <span className="ml-2 text-[10px] text-text-dim">current</span>}
                  </button>
                )
              })}
            </div>
          </div>

          <div className="mt-4">
            <div className="text-xs uppercase tracking-wide text-text-dim mb-2">Decree in force</div>
            <div className="grid gap-1 sm:grid-cols-2">
              {decrees.map(d => {
                const on = pendingDecree === d.id
                const isActive = d.id === currentDecree
                return (
                  <button
                    key={d.id}
                    type="button"
                    disabled={!canWrite || busy || d.disabled}
                    onClick={() => setSelDecree(d.id)}
                    title={d.disabled ? 'Disabled by the game server — cannot be made active.' : d.decree_name}
                    className={`flex items-center gap-2 px-3 py-1.5 rounded border text-left text-sm transition-colors ${
                      on ? 'border-accent text-text bg-surface-2' : 'border-border text-text-muted hover:text-text'
                    } ${(!canWrite || busy || d.disabled) ? 'opacity-50 cursor-not-allowed' : ''}`}
                  >
                    <Icon name={on ? 'CircleDot' : 'Circle'} size={13} className={on ? 'text-accent shrink-0' : 'text-text-dim shrink-0'} />
                    <span className="flex-1 truncate">{d.display_name}</span>
                    {isActive && <span className="text-[10px] text-accent shrink-0">ACTIVE</span>}
                    {d.disabled && <span className="text-[10px] text-text-dim shrink-0">disabled</span>}
                  </button>
                )
              })}
            </div>
          </div>

          {!confirming && (
            <div className="mt-4 flex items-center gap-2 flex-wrap">
              <button
                className="btn-primary"
                disabled={!canWrite || busy || !dirty}
                onClick={() => setConfirming(true)}
              >
                <Icon name="Save" size={14} /> Apply changes
              </button>
              {dirty && (
                <button className="btn-secondary" disabled={busy} onClick={() => { setSelFaction(null); setSelDecree(null) }}>
                  Reset
                </button>
              )}
              {!canWrite && <span className="text-xs text-text-dim">Live server required to change this.</span>}
            </div>
          )}

          {confirming && (
            <div className="mt-4 p-3 rounded border border-border">
              <div className="text-sm text-text mb-2 flex items-center gap-2">
                <Icon name="AlertTriangle" size={15} className="text-warning" /> Confirm Landsraad change
              </div>
              <p className="text-xs text-text-muted mb-3">
                Seats <strong>{holders.find(f => f.id === pendingFaction)?.name ?? 'no House'}</strong> as the holder
                with the decree <strong>{decrees.find(d => d.id === pendingDecree)?.display_name ?? 'none'}</strong> for
                term {data.term_id}. This overrides the result of voting for the rest of the term.
                Back up the database first if you want a way back.
              </p>
              <div className="flex items-center gap-2">
                <button className="btn-primary" disabled={busy} onClick={() => void apply()}>
                  {busy ? 'Applying…' : 'Yes, apply'}
                </button>
                <button className="btn-secondary" disabled={busy} onClick={() => setConfirming(false)}>Cancel</button>
              </div>
            </div>
          )}

          {restartOffered && (
            <div className="mt-4 p-3 rounded border border-border">
              <div className="text-sm text-text mb-2 flex items-center gap-2">
                <Icon name="RotateCcw" size={15} className="text-accent" /> Restart required
              </div>
              <p className="text-xs text-text-muted mb-3">
                The game reads the Landsraad term when a map pod starts, so the change is not live yet.
                A clean battlegroup restart takes a couple of minutes and disconnects players.
              </p>
              <div className="flex items-center gap-2">
                <button className="btn-primary" disabled={busy} onClick={() => void restart()}>
                  {busy ? 'Restarting…' : 'Restart battlegroup now'}
                </button>
                <button className="btn-secondary" disabled={busy} onClick={() => setRestartOffered(false)}>Later</button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}
