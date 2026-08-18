import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import {
  armChatTeleport,
  cancelChatTeleportCapture,
  deleteChatTeleport,
  getChatCommands,
  getPlayers,
  saveChatCommands,
  saveChatTeleport,
} from '../../api/gameplay'
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
  tp:      'Teleports the sender to an admin-saved destination on their current map. "!tp list" shows the shared list.',
  vehicle: 'Hands over a vehicle part kit plus fuel and a repair tool, to be assembled at a Vehicle Assembly. Typing !vehicle on its own lists them.',
  small:   'Activates Small spice fields, up to the limit you have already set.',
  medium:  'Activates Medium spice fields, up to the limit you have already set.',
  large:   'Activates Large spice fields, up to the limit you have already set.',
}

const ORDER = ['kit', 'item', 'vehicle', 'water', 'tp', 'small', 'medium', 'large']

// !kit, !item, !vehicle and !water only ever act on whoever typed them - the
// actor is taken from the chat message's sender id and none of them accept a
// player argument. Worth stating in the UI so an admin does not assume otherwise.
const SELF_ONLY = new Set(['kit', 'item', 'vehicle', 'water', 'tp'])

const SPICE_VERBS = new Set(['small', 'medium', 'large'])

// Measured cost per poll interval (2026-08-04, 8-core VM): idle 9.14% busy vs
// 15.41% at a 3s poll, so ~1.5 core-seconds per check. Shown in the picker so
// the trade is made with the numbers visible rather than blind.
const POLL_COST: Record<number, string> = {
  1: '1.50', 3: '0.50', 5: '0.30', 10: '0.15', 15: '0.10', 30: '0.05',
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
  const [onlinePlayers, setOnlinePlayers] = useState<Array<{ id: number; name: string; map: string }>>([])
  const [capturePawn, setCapturePawn] = useState<number>(0)
  const [captureName, setCaptureName] = useState('')
  const [deletingTeleport, setDeletingTeleport] = useState<string | null>(null)
  const [showTeleports, setShowTeleports] = useState(true)
  const [expandedTeleport, setExpandedTeleport] = useState<string | null>(null)
  const [copiedCapture, setCopiedCapture] = useState(false)

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
    try {
      const p = await getPlayers()
      const live = p.source === 'live'
        ? p.players
            .filter(player => player.online_status.toLowerCase() !== 'offline')
            .map(player => ({ id: player.id, name: player.name, map: player.map }))
        : []
      setOnlinePlayers(live)
      setCapturePawn(current => (
        current > 0 && live.some(player => player.id === current)
          ? current
          : (live[0]?.id ?? 0)
      ))
    } catch { setOnlinePlayers([]); setCapturePawn(0) }
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

  async function armTeleportCapture() {
    const name = captureName.trim()
    if (!name || capturePawn <= 0) {
      setErr('Choose an online player and enter a destination name.')
      return
    }
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await armChatTeleport(name, capturePawn)
      setState(prev => (prev ? { ...prev, pendingTeleportCapture: res.pending ?? null } : prev))
      setCaptureName('')
      setOk(`Capture armed for "${name}". The selected player must type !tp save in game.`)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  async function saveTeleportDirect() {
    const name = captureName.trim()
    if (!name || capturePawn <= 0) {
      setErr('Choose an online player and enter a destination name.')
      return
    }
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await saveChatTeleport(name, capturePawn)
      setState(prev => (prev ? { ...prev, teleports: res.teleports ?? [] } : prev))
      setCaptureName('')
      setOk(res.replaced ? `Updated "${name}".` : `Saved "${name}".`)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  async function cancelTeleportCapture(token: string) {
    setSaving(true); setErr(null); setOk(null)
    try {
      await cancelChatTeleportCapture(token)
      setState(prev => (prev ? { ...prev, pendingTeleportCapture: null } : prev))
      setOk('Pending teleport capture cancelled.')
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  function copyCaptureCommand(token: string) {
    const command = `!tp save ${token}`
    void navigator.clipboard?.writeText(command).then(() => {
      setCopiedCapture(true)
      setTimeout(() => setCopiedCapture(false), 1500)
    }).catch(() => {
      setErr(`Could not copy automatically. Type: ${command}`)
    })
  }

  async function removeTeleport(name: string) {
    if (deletingTeleport !== name) {
      setDeletingTeleport(name)
      return
    }
    setSaving(true); setErr(null); setOk(null)
    try {
      const res = await deleteChatTeleport(name)
      setState(prev => (prev ? { ...prev, teleports: res.teleports ?? [] } : prev))
      setDeletingTeleport(null)
      setOk(`Deleted "${name}".`)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  const enabled = state?.enabled === true
  const commands = state?.commands ?? {}
  const anyOn = Object.values(commands).some(c => c.enabled)
  const packages = state?.packages ?? []
  const kitOn = commands['kit']?.enabled === true
  const teleports = state?.teleports ?? []
  const pendingCapture = state?.pendingTeleportCapture ?? null
  const canArmTeleport = enabled && commands['tp']?.enabled === true

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
              {verb === 'tp' && (
                <div className="mt-3 rounded border border-border bg-surface/50 p-3">
                  <div className="text-[11px] text-text-muted">
                    Shared destinations are stored only on this DST PC. Use
                    <strong> Save location</strong> for normal areas. If that location returns
                    to a map opening point (observed in Hagga South), use
                    <strong> Arm live capture</strong>; the selected player then types the
                    one-time command at the destination. Teleports remain limited to the
                    same map, partition and dimension. Replies and <code>!tp list</code> are
                    public server broadcasts.
                  </div>
                  <div className="mt-3 grid gap-2 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]">
                    <select
                      value={capturePawn || ''}
                      disabled={saving || loading || onlinePlayers.length === 0}
                      onChange={e => setCapturePawn(Number(e.target.value))}
                      className="px-2 py-1.5 rounded bg-surface border border-border text-text text-xs"
                    >
                      {onlinePlayers.length === 0 && <option value="">No online players</option>}
                      {onlinePlayers.map(player => (
                        <option key={player.id} value={player.id}>
                          {player.name}{player.map ? ` - ${player.map}` : ''}
                        </option>
                      ))}
                    </select>
                    <input
                      type="text"
                      value={captureName}
                      maxLength={40}
                      disabled={saving || loading}
                      onChange={e => setCaptureName(e.target.value)}
                      onKeyDown={e => { if (e.key === 'Enter') void saveTeleportDirect() }}
                      placeholder="Destination name"
                      className="px-2 py-1.5 rounded bg-surface border border-border text-text text-xs"
                    />
                    <div className="flex flex-wrap gap-2">
                      <button
                        type="button"
                        className="btn-secondary"
                        disabled={saving || loading || capturePawn <= 0 || !captureName.trim()}
                        onClick={() => void saveTeleportDirect()}
                      >
                        <Icon name={saving ? 'Loader2' : 'MapPin'} size={13}
                              className={saving ? 'animate-spin' : ''} />
                        Save location
                      </button>
                      <button
                        type="button"
                        className="btn-secondary"
                        disabled={saving || loading || !canArmTeleport || capturePawn <= 0 || !captureName.trim()}
                        onClick={() => void armTeleportCapture()}
                      >
                        <Icon name="Radio" size={13} />
                        Arm live capture
                      </button>
                    </div>
                  </div>
                  {pendingCapture && (
                    <div className="mt-3 rounded border border-warning/40 bg-warning/10 p-2 text-[11px]">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="text-warning">
                          Waiting for {pendingCapture.playerName} to type{' '}
                          <code>!tp save {pendingCapture.token}</code>{' '}
                          for <strong>{pendingCapture.name}</strong>.
                        </span>
                        <button
                          type="button"
                          className="ml-auto text-text-dim hover:text-text"
                          onClick={() => copyCaptureCommand(pendingCapture.token)}
                        >
                          {copiedCapture ? 'Copied' : 'Copy command'}
                        </button>
                        <button
                          type="button"
                          className="text-text-dim hover:text-danger"
                          disabled={saving || loading}
                          onClick={() => void cancelTeleportCapture(pendingCapture.token)}
                        >
                          Cancel capture
                        </button>
                      </div>
                      <div className="mt-1 text-text-dim">
                        Armed on {pendingCapture.map}, partition {pendingCapture.partition}.
                        Expires {new Date(pendingCapture.expiresAt).toLocaleTimeString()}.
                        Click Refresh after the player receives the saved confirmation.
                      </div>
                    </div>
                  )}
                  {!canArmTeleport && (
                    <div className="mt-2 text-[11px] text-warning">
                      Turn on chat listening and <code>!tp</code> before using live capture.
                    </div>
                  )}
                  {teleports.length === 0 ? (
                    <div className="mt-3 text-[11px] text-text-dim">
                      No destinations saved. <code>!tp list</code> will report an empty list.
                    </div>
                  ) : (
                    <div className="mt-3">
                      <button
                        type="button"
                        className="flex w-full items-center justify-between text-left text-[11px] text-text-muted"
                        onClick={() => setShowTeleports(value => !value)}
                      >
                        <span>Saved destinations ({teleports.length})</span>
                        <span>{showTeleports ? 'Hide list' : 'Show list'}</span>
                      </button>
                      {showTeleports && <div className="mt-2 space-y-1">
                        {teleports.map(destination => {
                          const open = expandedTeleport === destination.key
                          return (
                            <div key={destination.key} className="rounded border border-border/70 bg-surface-2/50">
                              <button
                                type="button"
                                className="flex w-full items-center gap-2 px-2 py-1.5 text-left text-[11px]"
                                onClick={() => setExpandedTeleport(open ? null : destination.key)}
                              >
                                <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={12}
                                      className="text-text-dim" />
                                <code className="text-text min-w-32">{destination.name}</code>
                                <span className="text-text-muted">{destination.map}</span>
                                <span className="ml-auto text-text-dim">
                                  {open ? 'Close details' : 'Open details'}
                                </span>
                              </button>
                              {open && (
                                <div className="border-t border-border/70 px-2 py-2 text-[11px]">
                                  <div className="grid gap-1 sm:grid-cols-2">
                                    <span className="text-text-muted">
                                      Partition {destination.partition}, dimension {destination.dimension}
                                    </span>
                                    <span className="text-text-dim font-mono sm:text-right">
                                      {destination.x.toFixed(2)}, {destination.y.toFixed(2)}, {destination.z.toFixed(2)}
                                    </span>
                                    <span className="text-text-dim">
                                      Captured from {destination.capturedFrom || 'unknown player'}
                                    </span>
                                    <span className="text-text-dim sm:text-right">
                                      {destination.capturedAt
                                        ? new Date(destination.capturedAt).toLocaleString()
                                        : 'Capture time unavailable'}
                                    </span>
                                  </div>
                                  <div className="mt-2 flex justify-end">
                                    <button
                                      type="button"
                                      disabled={saving || loading}
                                      onClick={() => void removeTeleport(destination.name)}
                                      className={`text-[11px] ${
                                        deletingTeleport === destination.name
                                          ? 'text-danger'
                                          : 'text-text-dim hover:text-danger'
                                      }`}
                                    >
                                      {deletingTeleport === destination.name ? 'Confirm delete' : 'Delete destination'}
                                    </button>
                                  </div>
                                </div>
                              )}
                            </div>
                          )
                        })}
                      </div>}
                    </div>
                  )}
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
            void patch(
              { pollSeconds: n },
              n === 1 ? 'Real-time monitoring enabled.' : `Now checking every ${n} seconds.`,
            )
          }}
          className="px-2 py-1 rounded bg-surface border border-border text-text text-xs"
        >
          {(state?.pollChoices ?? [1, 3, 5, 10, 15, 30]).map(n => (
            <option key={n} value={n}>
              {n === 1 ? 'Real-time (1 second)' : `${n} seconds`} — about {POLL_COST[n] ?? (1.5 / n).toFixed(2)} of a processor core
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
