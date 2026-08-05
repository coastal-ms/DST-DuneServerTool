import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getChatCommands, saveChatCommands } from '../../api/gameplay'
import type { ChatCommandsState } from '../../api/types'

// In-game !commands. Players type into game chat and DST acts on it.
//
// Everything here is off until an admin turns it on, deliberately: these let
// ordinary players change the world (spawning spice fields) or receive items,
// which is a real shift in who controls the server. The master switch and each
// command are separate so "on" never means "all of it".
const CHANNELS = ['Proximity', 'Map', 'Faction', 'Guild', 'Party']

const DESCRIPTIONS: Record<string, string> = {
  kit:    'Hands over one of your item packages. Typing !kit on its own asks which.',
  small:  'Activates Small spice fields, up to the limit you have already set.',
  medium: 'Activates Medium spice fields, up to the limit you have already set.',
  large:  'Activates Large spice fields, up to the limit you have already set.',
}

const ORDER = ['kit', 'small', 'medium', 'large']

function humanCooldown(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds <= 0) return 'no cooldown'
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`
  if (seconds < 86400) return `${+(seconds / 3600).toFixed(1)} hours`
  return `${+(seconds / 86400).toFixed(1)} days`
}

export function ChatCommandsCard() {
  const [state, setState] = useState<ChatCommandsState | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      setState(await getChatCommands())
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  async function patch(body: Parameters<typeof saveChatCommands>[0], note?: string) {
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await saveChatCommands(body)
      // The PUT returns the top-level settings but not the per-command map, so
      // merge rather than replace - otherwise a cooldown edit would blank the
      // list until the next refresh.
      setState(prev => (prev ? { ...prev, ...res, commands: prev.commands } : prev))
      if (note) setOk(note)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  function setCommand(verb: string, next: Partial<{ enabled: boolean; cooldownSeconds: number }>) {
    setState(prev => {
      if (!prev) return prev
      const cur = prev.commands[verb] ?? { enabled: false, cooldownSeconds: 0 }
      return { ...prev, commands: { ...prev.commands, [verb]: { ...cur, ...next } } }
    })
  }

  const enabled = state?.enabled === true
  const commands = state?.commands ?? {}
  const anyOn = Object.values(commands).some(c => c.enabled)
  const packages = state?.packages ?? []
  const kitOn = commands['kit']?.enabled === true

  return (
    <CollapsibleCard
      id="gameplay.chatCommands"
      icon="MessageSquare"
      iconClassName="text-ibad shrink-0"
      title="In-game commands"
      titleClassName="text-sm font-semibold uppercase tracking-wider text-ibad"
      subtitle={
        <span className="text-xs text-text-muted">
          Let players trigger actions by typing in game chat. Off by default.
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
        DST reads game chat and responds with a server broadcast, the same popup the
        Broadcasts page sends. Replies are visible to everyone, not just the player who
        typed the command.
      </p>

      <label className="flex items-center gap-2 text-sm cursor-pointer">
        <input type="checkbox" checked={enabled} disabled={saving || loading}
               onChange={e => void patch({ enabled: e.target.checked },
                 e.target.checked ? 'Listening for commands.' : 'Stopped listening.')}
               className="accent-ibad" />
        <span className="font-medium text-text">Listen for commands in game chat</span>
      </label>

      {enabled && !anyOn && (
        <div className="mt-2 px-3 py-2 rounded border border-warning/40 bg-warning/10 text-warning text-xs">
          Listening is on but every command is off, so nothing will happen. Turn on at
          least one below.
        </div>
      )}

      <div className="mt-4 space-y-3">
        {ORDER.filter(v => v in commands).map(verb => {
          const c = commands[verb]
          return (
            <div key={verb} className="rounded-lg border border-border bg-surface-2/40 px-3 py-2">
              <div className="flex items-center justify-between gap-3">
                <label className="flex items-center gap-2 text-sm cursor-pointer">
                  <input type="checkbox" checked={c.enabled} disabled={saving || loading}
                         onChange={e => {
                           setCommand(verb, { enabled: e.target.checked })
                           void patch({ commands: { [verb]: { enabled: e.target.checked } } })
                         }}
                         className="accent-ibad" />
                  <code className="text-text font-medium">!{verb}</code>
                </label>
                <div className="flex items-center gap-2 text-xs">
                  <span className="text-text-dim">cooldown</span>
                  <input
                    type="text" inputMode="numeric"
                    value={String(c.cooldownSeconds)}
                    disabled={saving || loading}
                    onChange={e => {
                      const n = Number(e.target.value.replace(/[^\d]/g, ''))
                      setCommand(verb, { cooldownSeconds: Number.isFinite(n) ? n : 0 })
                    }}
                    onBlur={() => void patch({ commands: { [verb]: { cooldownSeconds: c.cooldownSeconds } } })}
                    className="w-24 px-2 py-1 rounded bg-surface border border-border text-text font-mono text-xs"
                  />
                  <span className="text-text-dim w-20">{humanCooldown(c.cooldownSeconds)}</span>
                </div>
              </div>
              <div className="mt-1 text-[11px] text-text-muted">{DESCRIPTIONS[verb]}</div>
              {verb === 'kit' && kitOn && packages.length === 0 && (
                <div className="mt-2 text-[11px] text-warning">
                  No item packages exist yet, so !kit has nothing to hand out. Create one
                  under Players &rsaquo; Give Package.
                </div>
              )}
              {verb === 'kit' && kitOn && packages.length > 0 && (
                <div className="mt-2 text-[11px] text-text-dim">
                  Players type <code>!kit &lt;name&gt;</code>. Available: {packages.join(', ')}
                </div>
              )}
            </div>
          )
        })}
      </div>

      <div className="mt-4 pt-4 border-t border-border">
        <div className="text-xs text-text-muted mb-2">Listen on these chat channels</div>
        <div className="flex flex-wrap gap-3">
          {CHANNELS.map(ch => {
            const on = (state?.channels ?? []).includes(ch)
            return (
              <label key={ch} className="flex items-center gap-1.5 text-xs cursor-pointer">
                <input type="checkbox" checked={on} disabled={saving || loading}
                       onChange={e => {
                         const next = e.target.checked
                           ? [...(state?.channels ?? []), ch]
                           : (state?.channels ?? []).filter(c => c !== ch)
                         setState(prev => (prev ? { ...prev, channels: next } : prev))
                         void patch({ channels: next })
                       }}
                       className="accent-ibad" />
                <span className="text-text">{ch}</span>
              </label>
            )
          })}
        </div>

        <div className="mt-3 flex items-center gap-2">
          <span className="text-xs text-text-muted">Reply heading</span>
          <input
            type="text"
            value={state?.replyTitle ?? ''}
            disabled={saving || loading}
            onChange={e => setState(prev => (prev ? { ...prev, replyTitle: e.target.value } : prev))}
            onBlur={() => void patch({ replyTitle: state?.replyTitle ?? 'Server' })}
            placeholder="Server"
            className="w-40 px-2 py-1 rounded bg-surface border border-border text-text text-xs"
          />
          <span className="text-[11px] text-text-dim">shown at the top of the popup</span>
        </div>
      </div>

      <p className="mt-4 text-[11px] text-text-dim">
        A response can take up to 30 seconds — DST checks for new commands on the same
        background cycle as its other scheduled work.
      </p>
    </CollapsibleCard>
  )
}
