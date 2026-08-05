import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { getChatCommands, saveChatCommands } from '../../api/gameplay'
import { getSpicefields, saveSpicefield } from '../../api/gameconfig'
import type { ChatCommandsState, SpicefieldType } from '../../api/types'

// In-game !commands. Players type into game chat and DST acts on it.
//
// Everything here is off until an admin turns it on, deliberately: these let
// ordinary players change the world (spawning spice fields) or receive items,
// which is a real shift in who controls the server. The master switch and each
// command are separate so "on" never means "all of it".
const CHANNELS = ['Proximity', 'Map', 'Faction', 'Guild', 'Party']

const DESCRIPTIONS: Record<string, string> = {
  kit:     'Hands over one of your item packages. Typing !kit on its own asks which.',
  item:    'Hands over any single item from the catalog, e.g. "!item plastone 500".',
  water:   'Refills the water in that player\u2019s stillsuit, jons and canteens.',
  vehicle: 'Hands over a vehicle part kit plus fuel and a repair tool, to be assembled at a Vehicle Assembly. Typing !vehicle on its own lists them.',
  small:   'Activates Small spice fields, up to the limit you have already set.',
  medium:  'Activates Medium spice fields, up to the limit you have already set.',
  large:   'Activates Large spice fields, up to the limit you have already set.',
}

const ORDER = ['kit', 'item', 'vehicle', 'water', 'small', 'medium', 'large']

// !kit, !item, !vehicle and !water only ever act on whoever typed them - the
// actor is taken from the chat message's sender id and none of them accept a
// player argument. Worth stating in the UI so an admin does not assume otherwise.
const SELF_ONLY = new Set(['kit', 'item', 'vehicle', 'water'])

const SPICE_VERBS = new Set(['small', 'medium', 'large'])

// Measured cost per poll interval (2026-08-04, 8-core VM): idle 9.14% busy vs
// 15.41% at a 3s poll, so ~1.5 core-seconds per check. Shown in the picker so
// the trade is made with the numbers visible rather than blind.
const POLL_COST: Record<number, string> = {
  3: '0.50', 5: '0.30', 10: '0.15', 15: '0.10', 30: '0.05',
}

// The cap a spice command works within is not part of this feature - it is the
// spicefield type's own max_globally_active, which already has an editor in Game
// Config. It is surfaced here anyway because "!large did nothing" is almost
// always "the map is already at its limit", and making an admin leave the page
// to find that out is the sort of thing that gets reported as a bug.
//
// There is one row per map+dimension, so a size can have several limits, and a
// size with no row at all (Hagga has no Large) means the command genuinely
// cannot do anything on that map. Both are worth showing plainly.
function SpiceLimits({
  size, rows, busy, onSaved,
}: {
  size: string
  rows: SpicefieldType[]
  busy: boolean
  onSaved: (row: SpicefieldType) => void
}) {
  const [draft, setDraft] = useState<Record<number, string>>({})
  const [saving, setSaving] = useState<number | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const mine = rows.filter(r => r.fieldType.toLowerCase() === size)
  // Only live/pinned partitions can drain a request, which is the same rule the
  // command itself follows - a limit on a retired map is noise here.
  const live = mine.filter(r => r.partitionActive !== false)

  if (rows.length === 0) return null
  if (live.length === 0) {
    return (
      <div className="mt-2 text-[11px] text-warning">
        No running map has {size} spice fields, so !{size} has nothing to activate.
      </div>
    )
  }

  async function commit(row: SpicefieldType) {
    const raw = draft[row.spicefieldTypeId]
    if (raw === undefined) return
    const n = Number(raw)
    if (!Number.isFinite(n) || n < 0 || n === row.maxActive) {
      setDraft(d => { const c = { ...d }; delete c[row.spicefieldTypeId]; return c })
      return
    }
    setSaving(row.spicefieldTypeId); setErr(null)
    try {
      const res = await saveSpicefield(row.spicefieldTypeId, {
        maxActive: n,
        maxPrimed: row.maxPrimed,
        isSpawningActive: row.isSpawningActive,
        spawnWeight: row.spawnWeight,
      })
      onSaved(res.row)
      setDraft(d => { const c = { ...d }; delete c[row.spicefieldTypeId]; return c })
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(null)
    }
  }

  return (
    <div className="mt-2 space-y-1">
      {err && <div className="text-[11px] text-danger">{err}</div>}
      {live.map(row => {
        const id = row.spicefieldTypeId
        const atCap = row.currentActive >= row.maxActive
        return (
          <div key={id} className="flex items-center gap-2 text-[11px]">
            <span className="text-text-dim w-28 shrink-0">{row.mapName}</span>
            <span className={atCap ? 'text-warning' : 'text-text-muted'}>
              {row.currentActive} of {row.maxActive} active
            </span>
            <span className="text-text-dim ml-auto">limit</span>
            <input
              type="text" inputMode="numeric"
              value={draft[id] ?? String(row.maxActive)}
              disabled={busy || saving === id}
              onChange={e => setDraft(d => ({ ...d, [id]: e.target.value.replace(/[^\d]/g, '') }))}
              onBlur={() => void commit(row)}
              onKeyDown={e => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur() }}
              className="w-16 px-2 py-0.5 rounded bg-surface border border-border text-text font-mono text-[11px]"
            />
            {saving === id && <Icon name="Loader2" size={11} className="animate-spin text-text-dim" />}
            {atCap && saving !== id && (
              <span className="text-warning">at cap — raise it or !{size} will do nothing</span>
            )}
          </div>
        )
      })}
    </div>
  )
}

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
  const [spice, setSpice] = useState<SpicefieldType[]>([])

  const load = useCallback(async () => {
    setLoading(true); setErr(null)
    try {
      setState(await getChatCommands())
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
    // Spice limits are a nice-to-have on this card, so a failure to read them
    // must not make the whole card look broken.
    try {
      const s = await getSpicefields()
      setSpice(s.available ? s.rows : [])
    } catch { setSpice([]) }
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

  function setCommand(verb: string, next: Partial<{ enabled: boolean; cooldownSeconds: number; maxQty: number }>) {
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
                  {SELF_ONLY.has(verb) && (
                    <span className="text-[10px] px-1.5 py-0.5 rounded-full border border-border text-text-dim">
                      self only
                    </span>
                  )}
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
              {verb === 'item' && c.enabled && (
                <div className="mt-2 flex items-center gap-2 text-[11px]">
                  <span className="text-text-dim">Most a player can ask for at once</span>
                  <input
                    type="text" inputMode="numeric"
                    value={String(c.maxQty ?? 1000)}
                    disabled={saving || loading}
                    onChange={e => {
                      const n = Number(e.target.value.replace(/[^\d]/g, ''))
                      setCommand(verb, { maxQty: Number.isFinite(n) ? n : 0 })
                    }}
                    onBlur={() => void patch({ commands: { item: { maxQty: c.maxQty ?? 1000 } } })}
                    className="w-24 px-2 py-1 rounded bg-surface border border-border text-text font-mono text-[11px]"
                  />
                  <span className="text-warning">
                    This one can produce anything in the game — keep the cap low.
                  </span>
                </div>
              )}
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
              {SPICE_VERBS.has(verb) && c.enabled && (
                <SpiceLimits
                  size={verb}
                  rows={spice}
                  busy={saving || loading}
                  onSaved={row => setSpice(prev =>
                    prev.map(r => (r.spicefieldTypeId === row.spicefieldTypeId ? row : r)))}
                />
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
        DST checks for new commands on a timer, so a reply takes about as long as
        the interval below. That check is not free — it costs the same whether or
        not anyone is chatting, and only while this is switched on.
      </p>

      <div className="mt-2 flex flex-wrap items-center gap-2">
        <span className="text-xs text-text-muted">Check for commands every</span>
        <select
          value={String(state?.pollSeconds ?? 3)}
          disabled={saving || loading}
          onChange={e => {
            const n = Number(e.target.value)
            setState(prev => (prev ? { ...prev, pollSeconds: n } : prev))
            void patch({ pollSeconds: n }, `Now checking every ${n} seconds.`)
          }}
          className="px-2 py-1 rounded bg-surface border border-border text-text text-xs"
        >
          {(state?.pollChoices ?? [3, 5, 10, 15, 30]).map(n => (
            <option key={n} value={n}>
              {n} seconds — about {POLL_COST[n] ?? (1.5 / n).toFixed(2)} of a processor core
            </option>
          ))}
        </select>
      </div>
      <p className="mt-1 text-[11px] text-text-dim">
        Measured on an 8-core server VM. The cost is per check rather than per
        message, so a longer interval is cheaper in direct proportion.
      </p>
    </CollapsibleCard>
  )
}
