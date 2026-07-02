// LandclaimTimerCard — collapse the game's staking-unit (land claim) extension
// schedule down to a single custom duration.
//
// The game ships a doubling schedule (60..30720s) for how long a land-claim
// staking-unit extension takes. Enabling this writes one admin-chosen "seconds"
// value into [/Script/DuneSandbox.BuildingSettings] as the two *DefaultTimes
// scalars, and strips every built-in schedule entry via array-remove (-) lines —
// into BOTH the server UserGame.ini and the local client Game.ini. Disabling
// removes DST's lines so the game defaults return.
import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { IniShareModal } from '../../components/IniShareModal'
import { ApiError } from '../../api/client'
import { getLandclaimTimer, saveLandclaimTimer } from '../../api/gameconfig'
import type { LandclaimTimerState } from '../../api/types'

type Props = {
  vmRunning: boolean
}

export function LandclaimTimerCard({ vmRunning }: Props) {
  const [state, setState] = useState<LandclaimTimerState | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [seconds, setSeconds] = useState('')
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [showBlock, setShowBlock] = useState(false)

  const seed = useCallback((s: LandclaimTimerState) => {
    // Prefer the server's live view; fall back to the local client file when the
    // VM is down so the form still reflects what's on disk.
    const src = s.server.available ? s.server : s.client
    setEnabled(src.enabled)
    setSeconds(src.enabled ? src.seconds : '')
  }, [])

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      const s = await getLandclaimTimer()
      setState(s)
      seed(s)
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [seed])

  useEffect(() => { void load() }, [load])

  const trimmed = seconds.trim()
  const num = Number(trimmed)
  const validSeconds = trimmed !== '' && Number.isFinite(num) && num > 0
  const server = state?.server

  // Dirty vs the server's current state (what actually governs the server).
  const curEnabled = server?.available ? server.enabled : false
  const curSeconds = server?.available ? server.seconds : ''
  const dirty = enabled !== curEnabled || (enabled && trimmed !== curSeconds.trim())
  const canApply = vmRunning && !saving && dirty && (!enabled || validSeconds)

  async function apply() {
    if (!canApply) return
    setSaving(true); setErr(null); setOk(null)
    try {
      const r = await saveLandclaimTimer(enabled, enabled ? trimmed : '')
      setState({ server: r.server, client: r.client, clientBlock: r.clientBlock })
      seed({ server: r.server, client: r.client, clientBlock: r.clientBlock })
      const clientNote = r.result.client.applied
        ? 'client Game.ini updated'
        : `client Game.ini skipped (${r.result.client.reason ?? 'no client folder'})`
      setOk(enabled
        ? `Land-claim timer set to ${trimmed}s — server UserGame.ini updated, ${clientNote}.`
        : `Land-claim timer cleared — game defaults restored. ${clientNote}.`)
      // Client-side setting: surface the exact block so the admin can hand it to
      // connecting players (it only takes effect on their end if THEIR Game.ini
      // carries the same block).
      if (enabled && r.clientBlock) setShowBlock(true)
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card p-4 mb-4 border-border">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Timer" size={16} className="shrink-0 text-accent" />
          <div className="min-w-0">
            <div className="text-sm font-semibold text-text">Land Claim Timer</div>
            <div className="text-xs text-text-muted">
              Override how long a land-claim staking-unit extension takes (seconds).
            </div>
          </div>
        </div>
        <button
          type="button"
          className="btn-secondary shrink-0"
          onClick={() => void load()}
          disabled={loading || saving}
          title="Reload current values"
        >
          <Icon name={loading ? 'Loader2' : 'RotateCcw'} size={14} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
      </div>

      <label className="mt-3 flex items-center gap-2 cursor-pointer select-none">
        <input
          type="checkbox"
          checked={enabled}
          onChange={e => { setEnabled(e.target.checked); setOk(null); setErr(null) }}
          disabled={!vmRunning || saving}
          className="h-4 w-4 accent-accent"
        />
        <span className="text-sm text-text">Use a custom land-claim timer</span>
      </label>

      {enabled && (
        <div className="mt-3">
          <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Timer (seconds)</label>
          <input
            type="number"
            min={1}
            step={1}
            value={seconds}
            onChange={e => { setSeconds(e.target.value); setOk(null); setErr(null) }}
            disabled={!vmRunning || saving}
            className="w-40 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-accent focus:border-accent/50"
            placeholder="1"
          />
          {trimmed !== '' && !validSeconds && (
            <div className="mt-1 text-xs text-danger">Enter a positive number of seconds.</div>
          )}
        </div>
      )}

      <div className="card p-3 mt-3 border-border bg-surface-2/40 text-xs text-text-muted flex items-start gap-2">
        <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-accent-bright" />
        <div className="leading-relaxed">
          Applies to both the server <span className="font-mono">UserGame.ini</span> and this PC&apos;s client
          <span className="font-mono"> Game.ini</span> (when the client config folder is set). Connecting players
          need the same client value for the change to take effect on their end — share your DST-managed
          <span className="font-mono"> Game.ini</span> block. Disabling restores the game&apos;s default schedule.
        </div>
      </div>

      {state && (
        <div className="mt-3 text-xs text-text-muted space-y-1">
          <div>
            Server:{' '}
            {!server?.available
              ? <span className="text-text-dim italic">unavailable{server?.reason ? ` (${server.reason})` : ''}</span>
              : server.enabled
                ? <span className="text-success">custom {server.seconds}s{server.formattedOk ? '' : ' (needs re-apply)'}</span>
                : <span className="text-text-dim">game default</span>}
          </div>
          <div>
            Client Game.ini:{' '}
            {!state.client.exists
              ? <span className="text-text-dim italic">not found{state.client.dir ? ` at ${state.client.dir}` : ''}</span>
              : state.client.enabled
                ? <span className="text-success">custom {state.client.seconds}s</span>
                : <span className="text-text-dim">game default</span>}
          </div>
        </div>
      )}

      <div className="mt-3 flex items-center gap-2">
        <button type="button" className="btn-primary" onClick={() => void apply()} disabled={!canApply}>
          <Icon name={saving ? 'Loader2' : 'Check'} size={14} className={saving ? 'animate-spin' : ''} />
          {saving ? 'Applying…' : enabled ? 'Apply' : 'Clear & restore default'}
        </button>
        {state?.clientBlock && (
          <button type="button" className="btn-secondary" onClick={() => setShowBlock(true)}>
            <Icon name="Share2" size={14} /> Players&apos; Game.ini snippet
          </button>
        )}
      </div>

      {!vmRunning && (
        <div className="mt-2 text-xs text-text-dim">Start the VM to change the server value.</div>
      )}
      {err && (
        <div className="mt-3 text-sm text-danger flex items-center gap-2">
          <Icon name="AlertCircle" size={14} /> {err}
        </div>
      )}
      {ok && (
        <div className="mt-3 text-sm text-success flex items-start gap-2">
          <Icon name="ShieldCheck" size={14} className="mt-0.5 shrink-0" /> <span>{ok}</span>
        </div>
      )}

      {showBlock && state?.clientBlock && (
        <IniShareModal
          block={state.clientBlock}
          subtitle={<>The land-claim timer is client-side too. For it to work on a player&apos;s end, they must add this exact block to their own <span className="font-mono">Game.ini</span>.</>}
          onClose={() => setShowBlock(false)}
        />
      )}
    </div>
  )
}
