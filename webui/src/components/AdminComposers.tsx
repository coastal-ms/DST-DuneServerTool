// Compact composer cards for the three admin "talk to players" actions that
// dune-admin exposes via its /api/v1/notify endpoint: a generic on-screen
// message ("broadcast"), a shutdown countdown ("server alert"), and a
// per-player chat whisper ("GM whisper"). DST already had backends for all
// three but only the standalone Broadcasts page wired the first two — and
// that page wasn't reachable from any nav. These composers are the canonical
// surface, embedded at the top of the Gameplay overview and reused by the
// standalone Broadcasts page.

import { useCallback, useEffect, useState } from 'react'
import { Icon } from './Icon'
import { ApiError } from '../api/client'
import {
  sendGenericBroadcast,
  sendShutdownBroadcast,
  type ShutdownType,
} from '../api/broadcasts'
import {
  chatWhisper,
  getPlayersOnline,
  type OnlinePlayer,
} from '../api/gameplay'

type Banner = { kind: 'ok' | 'err'; text: string } | null

function BannerLine({ b }: { b: Banner }) {
  if (!b) return null
  return (
    <p className={`text-sm mt-3 break-words ${b.kind === 'err' ? 'text-danger' : 'text-text'}`}>
      {b.text}
    </p>
  )
}

// ---------------------------------------------------------------------------
// Server-wide pop-up message ("broadcast"). Title + body + display duration.
// ---------------------------------------------------------------------------

export function GenericBroadcastComposer() {
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [duration, setDuration] = useState(30)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<Banner>(null)

  const onSend = useCallback(async () => {
    if (!title.trim()) return
    setBusy(true); setMsg(null)
    try {
      const r = await sendGenericBroadcast(title.trim(), body, Math.max(1, duration))
      setMsg({ kind: 'ok', text: r.message ?? 'Broadcast sent.' })
      setTitle(''); setBody('')
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setBusy(false)
    }
  }, [title, body, duration])

  return (
    <div className="card p-4 flex flex-col">
      <div className="flex items-center gap-2 mb-3">
        <div className="w-8 h-8 rounded-lg bg-accent/15 border border-accent/30 flex items-center justify-center text-accent-bright">
          <Icon name="Megaphone" size={16} />
        </div>
        <div>
          <h3 className="font-semibold text-text">Broadcast</h3>
          <p className="text-[11px] text-text-dim">On-screen pop-up to every connected player.</p>
        </div>
      </div>

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Header</label>
      <input type="text" value={title} onChange={e => setTitle(e.target.value)} placeholder="Header"
        disabled={busy}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Message</label>
      <input type="text" value={body} onChange={e => setBody(e.target.value)} placeholder="Message"
        disabled={busy}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />

      <div className="flex items-end gap-2 mt-auto">
        <div className="flex-1">
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Duration (s)</label>
          <input type="number" min={1} max={3600} value={duration}
            onChange={e => setDuration(Math.max(1, parseInt(e.target.value) || 30))}
            disabled={busy}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <button className="btn-primary" disabled={busy || !title.trim()} onClick={() => { void onSend() }}>
          <Icon name={busy ? 'Loader2' : 'Megaphone'} size={14} className={busy ? 'animate-spin' : ''} />
          {busy ? 'Sending…' : 'Send'}
        </button>
      </div>

      <BannerLine b={msg} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Shutdown/restart countdown ("Server Alert"). The big red banner Chopper saw.
// Mirrors dune-admin's /notify with the ServiceBroadcast routing key — wraps
// our richer Send-V6ShutdownBroadcast which supports Restart/Shutdown/
// Maintenance/Update types and a Cancel action.
// ---------------------------------------------------------------------------

export function ShutdownBroadcastComposer() {
  const [shutdownType, setShutdownType] = useState<ShutdownType>('Restart')
  const [delay, setDelay] = useState(10)
  const [busy, setBusy] = useState<'broadcast' | 'cancel' | null>(null)
  const [msg, setMsg] = useState<Banner>(null)

  const onBroadcast = useCallback(async () => {
    const verb = shutdownType === 'Restart' ? 'restart' : 'shut down'
    if (!confirm(`Broadcast a ${verb} in ${delay} minute${delay === 1 ? '' : 's'}? All connected players will see a countdown.`)) return
    setBusy('broadcast'); setMsg(null)
    try {
      const r = await sendShutdownBroadcast(shutdownType, Math.max(0, delay), false)
      setMsg({ kind: 'ok', text: r.message ?? `${shutdownType} broadcast sent (${delay} min).` })
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setBusy(null)
    }
  }, [shutdownType, delay])

  const onCancel = useCallback(async () => {
    setBusy('cancel'); setMsg(null)
    try {
      const r = await sendShutdownBroadcast(shutdownType, 0, true)
      setMsg({ kind: 'ok', text: r.message ?? 'Shutdown broadcast cancelled.' })
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setBusy(null)
    }
  }, [shutdownType])

  return (
    <div className="card p-4 flex flex-col">
      <div className="flex items-center gap-2 mb-3">
        <div className="w-8 h-8 rounded-lg bg-danger/15 border border-danger/30 flex items-center justify-center text-danger">
          <Icon name="AlertTriangle" size={16} />
        </div>
        <div>
          <h3 className="font-semibold text-text">Server Alert</h3>
          <p className="text-[11px] text-text-dim">Restart/shutdown countdown banner.</p>
        </div>
      </div>

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Type</label>
      <select value={shutdownType} onChange={e => setShutdownType(e.target.value as ShutdownType)}
        disabled={busy !== null}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50">
        <option value="Restart">Restart</option>
        <option value="Shutdown">Shutdown</option>
        <option value="Maintenance">Maintenance</option>
        <option value="Update">Update</option>
      </select>

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Delay (minutes)</label>
      <input type="number" min={0} max={1440} value={delay}
        onChange={e => setDelay(Math.max(0, parseInt(e.target.value) || 0))}
        disabled={busy !== null}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />

      <div className="flex items-center justify-end gap-2 mt-auto pt-1">
        <button className="btn-secondary" disabled={busy !== null} onClick={() => { void onCancel() }}>
          <Icon name={busy === 'cancel' ? 'Loader2' : 'X'} size={14} className={busy === 'cancel' ? 'animate-spin' : ''} />
          {busy === 'cancel' ? 'Cancelling…' : 'Cancel'}
        </button>
        <button className="btn-danger" disabled={busy !== null} onClick={() => { void onBroadcast() }}>
          <Icon name={busy === 'broadcast' ? 'Loader2' : 'AlertTriangle'} size={14} className={busy === 'broadcast' ? 'animate-spin' : ''} />
          {busy === 'broadcast' ? 'Sending…' : 'Broadcast'}
        </button>
      </div>

      <BannerLine b={msg} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// One-to-one chat whisper ("GM Whisper"). Picks an online player by name and
// posts via /api/gameplay/chat/whisper (RMQ chat envelope). Note: this is
// the same experimental path the per-player whisper button uses — broker
// accepts but the game may silently drop. We surface the same warning.
// ---------------------------------------------------------------------------

export function WhisperComposer() {
  const [players, setPlayers] = useState<OnlinePlayer[] | null>(null)
  const [loadErr, setLoadErr] = useState<string | null>(null)
  const [target, setTarget] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<Banner>(null)

  // Pull the online roster on mount so the dropdown is populated. Cheap call,
  // and admins typically open this card right after seeing a player online.
  useEffect(() => {
    let cancelled = false
    getPlayersOnline()
      .then(r => { if (!cancelled) setPlayers(r.players || []) })
      .catch(e => { if (!cancelled) setLoadErr(e instanceof ApiError ? e.message : String(e)) })
    return () => { cancelled = true }
  }, [])

  const selected = players?.find(p => String(p.account_id) === target)

  const onSend = useCallback(async () => {
    if (!selected?.fls_id || !message.trim()) return
    setBusy(true); setMsg(null)
    try {
      const r = await chatWhisper(selected.fls_id, message.trim())
      setMsg({ kind: 'ok', text: r.message ?? `Whisper sent to ${selected.display_name}.` })
      setMessage('')
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setBusy(false)
    }
  }, [selected, message])

  return (
    <div className="card p-4 flex flex-col">
      <div className="flex items-center gap-2 mb-3">
        <div className="w-8 h-8 rounded-lg bg-info/15 border border-info/30 flex items-center justify-center text-info">
          <Icon name="MessageCircle" size={16} />
        </div>
        <div>
          <h3 className="font-semibold text-text">GM Whisper</h3>
          <p className="text-[11px] text-text-dim">Private chat to one online player.</p>
        </div>
      </div>

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Player</label>
      <select value={target} onChange={e => setTarget(e.target.value)} disabled={busy || !players}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50">
        <option value="">{loadErr ? `Failed to load: ${loadErr}` : !players ? 'Loading online players…' : players.length === 0 ? 'No players online' : 'Pick a player'}</option>
        {players?.map(p => (
          <option key={p.account_id} value={String(p.account_id)} disabled={!p.fls_id}>
            {p.display_name}{p.fls_id ? '' : ' (no FLS id)'}
          </option>
        ))}
      </select>

      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Message</label>
      <textarea rows={3} value={message} onChange={e => setMessage(e.target.value)}
        placeholder="Hello from the admin team"
        disabled={busy}
        className="w-full mb-2 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 resize-none" />

      <p className="text-[11px] text-text-muted mb-2">
        Note: whisper publish is experimental — broker accepts but the game may silently drop.
      </p>

      <div className="flex items-center justify-end mt-auto">
        <button className="btn-primary" disabled={busy || !selected?.fls_id || !message.trim()}
          onClick={() => { void onSend() }}>
          <Icon name={busy ? 'Loader2' : 'Send'} size={14} className={busy ? 'animate-spin' : ''} />
          {busy ? 'Sending…' : 'Whisper'}
        </button>
      </div>

      <BannerLine b={msg} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Three-card row used by the Gameplay overview top and the standalone
// Broadcasts page. Stacks on small screens, three-up on lg.
// ---------------------------------------------------------------------------

export function AdminComposers({ className }: { className?: string }) {
  const cls = ['grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3', className].filter(Boolean).join(' ')
  return (
    <div className={cls}>
      <GenericBroadcastComposer />
      <ShutdownBroadcastComposer />
      <WhisperComposer />
    </div>
  )
}
