import { useCallback, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import {
  sendGenericBroadcast,
  sendShutdownBroadcast,
  type ShutdownType,
} from '../api/broadcasts'

type Banner = { kind: 'ok' | 'err'; text: string } | null

export function Broadcasts() {
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [duration, setDuration] = useState(30)
  const [sendBusy, setSendBusy] = useState(false)
  const [sendMsg, setSendMsg] = useState<Banner>(null)

  const [shutdownType, setShutdownType] = useState<ShutdownType>('Restart')
  const [delay, setDelay] = useState(10)
  const [shutdownBusy, setShutdownBusy] = useState<'broadcast' | 'cancel' | null>(null)
  const [shutdownMsg, setShutdownMsg] = useState<Banner>(null)

  const onSend = useCallback(async () => {
    if (!title.trim()) return
    setSendBusy(true); setSendMsg(null)
    try {
      const r = await sendGenericBroadcast(title.trim(), body, Math.max(1, duration))
      setSendMsg({ kind: 'ok', text: r.message ?? 'Broadcast sent.' })
      setTitle(''); setBody('')
    } catch (e) {
      setSendMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setSendBusy(false)
    }
  }, [title, body, duration])

  const onShutdown = useCallback(async () => {
    const verb = shutdownType === 'Restart' ? 'restart' : 'shut down'
    if (!confirm(`Broadcast a ${verb} in ${delay} minute${delay === 1 ? '' : 's'}? All connected players will see a countdown.`)) return
    setShutdownBusy('broadcast'); setShutdownMsg(null)
    try {
      const r = await sendShutdownBroadcast(shutdownType, Math.max(0, delay), false)
      setShutdownMsg({ kind: 'ok', text: r.message ?? `${shutdownType} broadcast sent (${delay} min).` })
    } catch (e) {
      setShutdownMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setShutdownBusy(null)
    }
  }, [shutdownType, delay])

  const onCancel = useCallback(async () => {
    setShutdownBusy('cancel'); setShutdownMsg(null)
    try {
      const r = await sendShutdownBroadcast(shutdownType, 0, true)
      setShutdownMsg({ kind: 'ok', text: r.message ?? 'Shutdown broadcast cancelled.' })
    } catch (e) {
      setShutdownMsg({ kind: 'err', text: e instanceof ApiError ? e.message : String(e) })
    } finally {
      setShutdownBusy(null)
    }
  }, [shutdownType])

  return (
    <>
      <PageHeader
        title="Broadcasts"
        icon="Megaphone"
        description="Send in-game pop-ups and shutdown countdowns to all connected players."
      />

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        {/* Generic message */}
        <div className="card p-5">
          <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-3">
            Generic Message
          </div>

          <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Header</label>
          <input
            type="text"
            value={title}
            onChange={e => setTitle(e.target.value)}
            placeholder="Header"
            className="w-full mb-3 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
          />

          <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Message</label>
          <input
            type="text"
            value={body}
            onChange={e => setBody(e.target.value)}
            placeholder="Message"
            className="w-full mb-3 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
          />

          <div className="flex items-center gap-3 mt-2">
            <label className="text-xs text-text-dim shrink-0">How long should the message last on screen?</label>
            <input
              type="number"
              min={1}
              max={3600}
              value={duration}
              onChange={e => setDuration(Math.max(1, parseInt(e.target.value) || 30))}
              className="w-24 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
            <div className="flex-1" />
            <button
              className="btn-primary"
              disabled={sendBusy || !title.trim()}
              onClick={() => { void onSend() }}
            >
              <Icon name={sendBusy ? 'Loader2' : 'Megaphone'} size={14} className={sendBusy ? 'animate-spin' : ''} />
              {sendBusy ? 'Sending…' : 'Send'}
            </button>
          </div>

          {sendMsg && (
            <p className={`text-sm mt-3 break-words ${sendMsg.kind === 'err' ? 'text-danger' : 'text-text'}`}>
              {sendMsg.text}
            </p>
          )}
        </div>

        {/* Shutdown broadcast */}
        <div className="card p-5">
          <div className="text-xs font-semibold uppercase tracking-widest text-accent mb-3">
            Shutdown Broadcast
          </div>

          <div className="flex items-center gap-3 mb-3">
            <label className="text-xs text-text-dim shrink-0 w-16">Type</label>
            <select
              value={shutdownType}
              onChange={e => setShutdownType(e.target.value as ShutdownType)}
              className="flex-1 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            >
              <option value="Restart">Restart</option>
              <option value="Shutdown">Shutdown</option>
              <option value="Maintenance">Maintenance</option>
              <option value="Update">Update</option>
            </select>
          </div>

          <div className="flex items-center gap-3 mb-4">
            <label className="text-xs text-text-dim shrink-0 w-16">Delay (min)</label>
            <input
              type="number"
              min={0}
              max={1440}
              value={delay}
              onChange={e => setDelay(Math.max(0, parseInt(e.target.value) || 0))}
              className="w-24 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>

          <div className="flex items-center gap-2 mt-2">
            <button
              className="btn-danger"
              disabled={shutdownBusy !== null}
              onClick={() => { void onShutdown() }}
            >
              <Icon name={shutdownBusy === 'broadcast' ? 'Loader2' : 'AlertTriangle'} size={14} className={shutdownBusy === 'broadcast' ? 'animate-spin' : ''} />
              {shutdownBusy === 'broadcast' ? 'Sending…' : 'Broadcast'}
            </button>
            <button
              className="btn-secondary"
              disabled={shutdownBusy !== null}
              onClick={() => { void onCancel() }}
            >
              <Icon name={shutdownBusy === 'cancel' ? 'Loader2' : 'X'} size={14} className={shutdownBusy === 'cancel' ? 'animate-spin' : ''} />
              {shutdownBusy === 'cancel' ? 'Cancelling…' : 'Cancel'}
            </button>
          </div>

          {shutdownMsg && (
            <p className={`text-sm mt-3 break-words ${shutdownMsg.kind === 'err' ? 'text-danger' : 'text-text'}`}>
              {shutdownMsg.text}
            </p>
          )}
        </div>
      </div>

      <div className="card p-4 mt-4 border-border/60">
        <p className="text-xs text-text-dim">
          <Icon name="Info" size={12} className="inline mr-1" />
          Broadcasts are published to the battlegroup's <span className="font-mono">mq-game</span> RabbitMQ
          exchange and forwarded to every connected player. The VM must be running and the battlegroup must be healthy.
        </p>
      </div>
    </>
  )
}
