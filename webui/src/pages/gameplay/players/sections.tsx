// v11.5.6 — Player section panels. One component per section nav entry
// (Stats / Specs / Tags / History / Inventory / Actions). All sections take
// a common props shape: the selected player + a `canWrite` flag (live DB)
// + a callback to flash status messages to the parent.
//
// Most sections are self-contained: they fetch their own data, render, and
// expose action buttons. The parent owns selection + refresh ticks; sections
// re-fetch when `refreshKey` changes.

import { useCallback, useEffect, useMemo, useState, type ReactElement } from 'react'
import { Icon } from '../../../components/Icon'
import { ItemPicker } from '../../../components/ItemPicker'
import {
  awardCharXp, awardIntel, awardSpecXp, cheatScript, cleanPlayerInventory,
  deleteAccount, deleteInventoryItem, deleteTutorials,
  dismissReturningPlayerAward, fillWater, getPlayerEvents, getPlayerSpecs,
  getPlayerStats, getPlayerTags, giveFactionRep, giveItem, giveItemLive,
  giveScrip, giveSolari, grantAllKeystones, grantLive, grantMaxSpec,
  kickPlayer, refuelVehicle, renamePlayer, repairGear, repairInventoryItem,
  resetAllKeystones, resetAllSpecs, resetJourney, resetProgressionLive, resetSpec,
  restoreDestroyed,
  returningPlayerAward, setFactionTier, setPlayerTags, setSkillPoints,
  setStarterClass, teleportToPlayer, updatePlayerTags, wipeCodex, wipeJourney,
  chatWhisper,
  type Player, type PlayerEvent, type PlayerStats, type SpecTrackFull,
} from '../../../api/gameplay'
import { fmtNum, fmtSolari } from '../shared'

type Flash = (msg: string, kind?: 'ok' | 'err') => void

interface SectionProps {
  player: Player
  canWrite: boolean
  demo: boolean
  refreshKey: number
  flash: Flash
  onChanged: () => void
}

// ---------------------------------------------------------------------------
// Stats — per-player snapshot. Shows currency, faction, last seen, account
// numbers. Read-only here; mutations live in Actions.
// ---------------------------------------------------------------------------
export function StatsSection({ player, demo, refreshKey }: SectionProps) {
  const [stats, setStats] = useState<PlayerStats | null>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerStats(player.id, demo)
      .then(r => { if (alive) setStats(r.stats) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.id, demo, refreshKey])

  if (loading) return <Loading label="Loading stats…" />
  if (err)     return <ErrorBox msg={err} />
  if (!stats)  return <EmptyBox msg="No stats for this player." />

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat label="Solari" value={fmtSolari(stats.solaris)} icon="Coins" />
        <Stat label="Total currency" value={fmtNum(stats.total_currency)} icon="Banknote" />
        <Stat label="Faction" value={stats.faction_name || 'Unaligned'} icon="Flag" />
        <Stat label="Status" value={stats.online_status} icon={stats.online_status.toLowerCase().includes('online') ? 'Wifi' : 'WifiOff'} />
      </div>

      <Card title="Identity">
        <KV k="Character" v={stats.character_name || '(unnamed)'} />
        <KV k="Class" v={stats.class || '—'} />
        <KV k="Map" v={stats.map || '—'} />
        <KV k="Last seen" v={fmtTs(stats.last_seen)} />
      </Card>

      <Card title="Account">
        <KV k="Pawn id"       v={`#${stats.pawn_id}`}       mono />
        <KV k="Account id"    v={`#${stats.account_id}`}    mono />
        <KV k="Controller id" v={`#${stats.controller_id}`} mono />
        <KV k="Faction id"    v={`#${stats.faction_id}`}    mono />
      </Card>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Specs — 5 tracks + keystone counter. Header buttons grant/reset all
// keystones; per-row buttons grant max XP / reset one track / +5000 XP.
// ---------------------------------------------------------------------------
export function SpecsSection({ player, canWrite, demo, refreshKey, flash, onChanged }: SectionProps) {
  const [tracks, setTracks] = useState<SpecTrackFull[]>([])
  const [keystones, setKeystones] = useState({ total: 0, max: 205 })
  const [unsupported, setUnsupported] = useState(false)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerSpecs(player.id, player.controller_id, demo)
      .then(r => {
        if (!alive) return
        setTracks(r.tracks)
        setKeystones({ total: r.keystones_total, max: r.keystones_max })
        setUnsupported(Boolean(r.unsupported))
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.id, player.controller_id, demo, refreshKey, tick])

  const run = useCallback(async (fn: () => Promise<{ message: string }>, label: string) => {
    setBusy(true)
    try {
      const r = await fn()
      flash(r.message || `${label} done.`, 'ok')
      setTick(t => t + 1)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }, [flash, onChanged])

  return (
    <div className="space-y-3">
      {/* Header bar — refresh + bulk keystone actions */}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-xs text-text-dim">
          Keystones: <span className="font-mono text-text">{fmtNum(keystones.total)}</span> / {fmtNum(keystones.max)}
        </div>
        <div className="flex flex-wrap gap-2">
          <button className="btn-secondary" disabled={loading || busy} onClick={() => setTick(t => t + 1)}>
            <Icon name="RefreshCw" size={13} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
          {canWrite && (
            <>
              <button className="btn-secondary" disabled={busy}
                onClick={() => void run(() => grantAllKeystones(player.controller_id), 'Grant all keystones')}>
                <Icon name="Star" size={13} /> Grant Max Keystones
              </button>
              <button className="btn-secondary text-warning" disabled={busy}
                onClick={() => { if (window.confirm(`Reset ALL keystones for ${player.name}? Cannot be undone.`)) void run(() => resetAllKeystones(player.controller_id), 'Reset all keystones') }}>
                <Icon name="RotateCcw" size={13} /> Reset All Keystones
              </button>
              <button className="btn-secondary text-danger" disabled={busy}
                onClick={() => { if (window.confirm(`Reset ALL spec tracks + keystones for ${player.name}? Cannot be undone.`)) void run(() => resetAllSpecs(player.controller_id), 'Reset all specs') }}>
                <Icon name="AlertTriangle" size={13} /> Reset All
              </button>
            </>
          )}
        </div>
      </div>

      {err && <ErrorBox msg={err} />}
      {unsupported && (
        <div className="card p-3 text-xs text-text-muted border-l-2 border-warning">
          The live game database doesn't expose specialization tables on this server — feature unavailable.
        </div>
      )}

      {loading && tracks.length === 0 ? (
        <Loading label="Loading specs…" />
      ) : (
        <div className="space-y-2">
          {SPEC_TRACK_ORDER.map(name => {
            const t = tracks.find(x => x.track_type.toLowerCase() === name.toLowerCase())
            return (
              <SpecRow key={name} name={name} track={t} canWrite={canWrite} busy={busy}
                onGrantMax={() => void run(() => grantMaxSpec(player.controller_id, name), 'Grant max')}
                onReset={() => void run(() => resetSpec(player.controller_id, name), 'Reset')}
                onAdd5k={() => run(() => awardSpecXp(player.controller_id, name, 5000), '+5000 XP')}
              />
            )
          })}
        </div>
      )}
    </div>
  )
}

const SPEC_TRACK_ORDER = ['Combat', 'Crafting', 'Exploration', 'Gathering', 'Sabotage']

function SpecRow({ name, track, canWrite, busy, onGrantMax, onReset, onAdd5k }: {
  name: string; track: SpecTrackFull | undefined; canWrite: boolean; busy: boolean
  onGrantMax: () => void; onReset: () => void; onAdd5k: () => void
}) {
  const xp = track?.xp ?? 0
  const level = Math.round(track?.level ?? 0)
  const xpMax = track?.xp_max ?? 44182
  const levelMax = Math.round(track?.level_max ?? 100)
  const pct = Math.min(100, Math.max(0, (xp / xpMax) * 100))
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-[140px]">
          <div className="text-sm font-medium text-text">{name}</div>
          <div className="text-[11px] text-text-dim font-mono">Lv {level}/{levelMax} · {fmtNum(xp)}/{fmtNum(xpMax)} xp</div>
        </div>
        <div className="flex-1 mx-2">
          <div className="h-1.5 bg-surface-2 rounded-full overflow-hidden">
            <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
          </div>
        </div>
        {canWrite && (
          <div className="flex gap-1.5 shrink-0">
            <button className="btn-secondary" disabled={busy} title="+5000 XP" onClick={onAdd5k}>
              <Icon name="Plus" size={13} /> 5k
            </button>
            <button className="btn-secondary" disabled={busy} title="Grant max XP for this track" onClick={onGrantMax}>
              <Icon name="ChevronsUp" size={13} /> Max
            </button>
            <button className="btn-secondary text-warning" disabled={busy} title="Reset this track" onClick={onReset}>
              <Icon name="RotateCcw" size={13} />
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Tags — chip list with add/remove + Save button. Writes the full set in
// one POST (matches backend's replace semantics).
// ---------------------------------------------------------------------------
export function TagsSection({ player, canWrite, demo, refreshKey, flash, onChanged }: SectionProps) {
  const [tags, setTags] = useState<string[]>([])
  const [draft, setDraft] = useState('')
  const [dirty, setDirty] = useState(false)
  const [unsupported, setUnsupported] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null); setDirty(false)
    getPlayerTags(player.account_id, demo)
      .then(r => { if (alive) { setTags(r.tags); setUnsupported(Boolean(r.unsupported)) } })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.account_id, demo, refreshKey])

  const add = () => {
    const t = draft.trim()
    if (!t) return
    if (tags.includes(t)) { setDraft(''); return }
    setTags([...tags, t].sort())
    setDraft('')
    setDirty(true)
  }
  const remove = (t: string) => { setTags(tags.filter(x => x !== t)); setDirty(true) }

  const save = async () => {
    setBusy(true); setErr(null)
    try {
      const r = await setPlayerTags(player.account_id, tags)
      flash(r.message, 'ok')
      setDirty(false)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  if (loading) return <Loading label="Loading tags…" />

  return (
    <div className="space-y-3">
      {err && <ErrorBox msg={err} />}
      {unsupported && (
        <div className="card p-3 text-xs text-text-muted border-l-2 border-warning">
          The live game database has no <code className="text-text">dune.player_tags</code> table — feature unavailable.
        </div>
      )}

      <div className="card p-3">
        {tags.length === 0 ? (
          <div className="text-sm text-text-dim">No tags. Add one below.</div>
        ) : (
          <div className="flex flex-wrap gap-2">
            {tags.map(t => (
              <span key={t} className="inline-flex items-center gap-1.5 px-2 py-1 rounded-full bg-surface-2 border border-border text-xs text-text">
                {t}
                {canWrite && !unsupported && (
                  <button className="text-text-dim hover:text-danger" onClick={() => remove(t)} title="Remove">
                    <Icon name="X" size={11} />
                  </button>
                )}
              </span>
            ))}
          </div>
        )}
      </div>

      {canWrite && !unsupported && (
        <div className="flex gap-2">
          <input type="text" value={draft} onChange={e => setDraft(e.target.value)}
            placeholder="Add tag (e.g. VIP, Banned, Verified)…" maxLength={64}
            onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); add() } }}
            className="flex-1 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
          <button className="btn-secondary" onClick={add} disabled={busy || !draft.trim()}>
            <Icon name="Plus" size={13} /> Add
          </button>
          <button className="btn-primary" onClick={save} disabled={busy || !dirty}>
            <Icon name="Save" size={13} /> Save
          </button>
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// History — recent event_log rows. Read-only. Pretty-prints event type +
// timestamps; raw meta JSON shown in an expandable details block.
// ---------------------------------------------------------------------------
export function HistorySection({ player, demo, refreshKey }: SectionProps) {
  const [events, setEvents] = useState<PlayerEvent[]>([])
  const [unsupported, setUnsupported] = useState(false)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [limit, setLimit] = useState(50)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerEvents(player.account_id, limit, demo)
      .then(r => { if (alive) { setEvents(r.events); setUnsupported(Boolean(r.unsupported)) } })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.account_id, demo, refreshKey, limit])

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="text-xs text-text-dim">{fmtNum(events.length)} event(s)</div>
        <select value={limit} onChange={e => setLimit(Number(e.target.value))}
          className="px-2 py-1 rounded-md bg-surface-2 border border-border text-text text-xs">
          <option value={25}>Last 25</option>
          <option value={50}>Last 50</option>
          <option value={100}>Last 100</option>
          <option value={250}>Last 250</option>
        </select>
      </div>

      {err && <ErrorBox msg={err} />}
      {unsupported && (
        <div className="card p-3 text-xs text-text-muted border-l-2 border-warning">
          <code className="text-text">dune.event_log</code> is unavailable on this server — history feature offline.
        </div>
      )}

      {loading && events.length === 0 ? (
        <Loading label="Loading events…" />
      ) : events.length === 0 ? (
        <EmptyBox msg="No events recorded for this player." />
      ) : (
        <div className="space-y-1">
          {events.map(ev => <EventRow key={ev.id} ev={ev} />)}
        </div>
      )}
    </div>
  )
}

function EventRow({ ev }: { ev: PlayerEvent }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="card p-2.5 text-sm">
      <button type="button" onClick={() => setOpen(o => !o)} className="w-full flex items-center justify-between gap-2 text-left">
        <span className="flex items-center gap-2 min-w-0">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={12} className="text-text-dim shrink-0" />
          <span className="text-text font-medium truncate">{ev.event_type || 'event'}</span>
        </span>
        <span className="text-[11px] text-text-dim font-mono shrink-0">{fmtTs(ev.ts)}</span>
      </button>
      {open && (
        <pre className="mt-2 p-2 bg-surface-2 rounded-md text-[11px] text-text-muted overflow-x-auto font-mono">
{prettyMeta(ev.meta)}
        </pre>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Actions — write surface. v11.5.9: full the reference implementation player toolkit.
// Bucketed into Currency / Progression / Items / Vehicle / Live (RMQ) /
// Identity / Danger Zone for discoverability. All actions use the inline-form
// pattern: click button to open form, fill fields, submit.
// ---------------------------------------------------------------------------
type ActionGroup = 'Currency' | 'Progression' | 'Items' | 'Vehicle' | 'Live' | 'Identity' | 'Danger'
interface ActionField { key: string; label: string; type: 'text' | 'number'; placeholder?: string; min?: number; max?: number }
interface ActionDef {
  id: string
  group: ActionGroup
  label: string
  icon: string
  liveOnly?: boolean      // requires player to be online (RMQ path)
  fields?: ActionField[]
  custom?: 'give-item' | 'give-item-live' | 'whisper'
  confirm?: (p: Player) => string  // confirm message; if returns '' no prompt
  run: (p: Player, v: Record<string, string>) => Promise<{ message: string }>
}

const ACTIONS: ActionDef[] = [
  // ----- Currency -----
  { id: 'give-solari', group: 'Currency', label: 'Give Solari', icon: 'Coins',
    fields: [{ key: 'amount', label: 'Amount', type: 'number', placeholder: '10000' }],
    run: (p, v) => giveSolari(p.controller_id, Number(v.amount) || 0) },
  { id: 'give-scrip', group: 'Currency', label: 'Give Scrip', icon: 'Banknote',
    fields: [{ key: 'amount', label: 'Amount', type: 'number', placeholder: '500' }],
    run: (p, v) => giveScrip(p.account_id, Number(v.amount) || 0) },
  { id: 'give-intel', group: 'Currency', label: 'Give Intel', icon: 'BookOpen',
    fields: [{ key: 'amount', label: 'Tech Knowledge Points', type: 'number', placeholder: '100' }],
    run: (p, v) => awardIntel(p.controller_id, Number(v.amount) || 0) },
  { id: 'grant-live', group: 'Currency', label: 'Grant Reward (popup)', icon: 'Gift',
    fields: [
      { key: 'template', label: 'Item template id', type: 'text', placeholder: 'Item_…' },
      { key: 'amount',   label: 'Amount',           type: 'number', placeholder: '1' },
    ],
    run: (p, v) => grantLive(p.controller_id, String(v.template || '').trim(), Number(v.amount) || 1) },

  // ----- Progression -----
  { id: 'award-char-xp', group: 'Progression', label: 'Award Character XP', icon: 'TrendingUp',
    fields: [{ key: 'delta', label: 'XP delta', type: 'number', placeholder: '5000' }],
    run: (p, v) => awardCharXp(p.id, Number(v.delta) || 0) },
  { id: 'set-skill-points', group: 'Progression', label: 'Set Skill Points (live)', icon: 'Sparkles', liveOnly: true,
    fields: [{ key: 'sp', label: 'Unspent Skill Points', type: 'number', placeholder: '50' }],
    run: (p, v) => setSkillPoints({ actor_id: p.id }, Number(v.sp) || 0) },
  { id: 'give-faction-rep', group: 'Progression', label: 'Give Faction Rep', icon: 'Shield',
    fields: [
      { key: 'faction', label: 'Faction id (atreides / harkonnen)', type: 'text', placeholder: 'atreides' },
      { key: 'delta',   label: 'Delta',                              type: 'number', placeholder: '500' },
    ],
    run: (p, v) => giveFactionRep(p.account_id, String(v.faction || '').trim(), Number(v.delta) || 0) },
  { id: 'set-faction-tier', group: 'Progression', label: 'Set Faction Tier', icon: 'BarChart3',
    fields: [
      { key: 'faction', label: 'Faction id', type: 'text', placeholder: 'atreides' },
      { key: 'tier',    label: 'Tier (0-20)', type: 'number', placeholder: '10', min: 0, max: 20 },
    ],
    run: (p, v) => setFactionTier(p.account_id, String(v.faction || '').trim(), Number(v.tier) || 0) },
  { id: 'reset-progression', group: 'Progression', label: 'Reset Progression (live)', icon: 'RotateCcw', liveOnly: true,
    confirm: p => `Reset ALL progression for ${p.name}? Cannot be undone.`,
    run: p => resetProgressionLive({ actor_id: p.id }) },
  { id: 'reset-journey', group: 'Progression', label: 'Reset Journey', icon: 'Map',
    run: p => resetJourney(p.account_id) },
  { id: 'wipe-journey', group: 'Progression', label: 'Wipe Journey (restart)', icon: 'RefreshCw',
    run: p => wipeJourney(p.account_id) },

  // ----- Items -----
  { id: 'give-item',      group: 'Items', label: 'Give Item', icon: 'PackagePlus', custom: 'give-item',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'give-item-live', group: 'Items', label: 'Give Item (force live)', icon: 'Zap', liveOnly: true, custom: 'give-item-live',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'repair-gear', group: 'Items', label: 'Repair All Items', icon: 'Wrench',
    run: p => repairGear(p.id) },
  { id: 'restore-destroyed', group: 'Items', label: 'Restore Destroyed Items', icon: 'Heart',
    confirm: p => `Restore destroyed gear on ${p.name}? Re-seeds CurrentDurability for items at 0/NULL.`,
    run: p => restoreDestroyed(p.id) },
  { id: 'fill-water', group: 'Items', label: 'Fill Water', icon: 'Droplets',
    run: p => fillWater(p.id) },
  { id: 'clean-inventory', group: 'Items', label: 'Clean Inventory (live)', icon: 'Trash', liveOnly: true,
    confirm: p => `WIPE ${p.name}'s inventory? Cannot be undone.`,
    run: p => cleanPlayerInventory({ actor_id: p.id }) },

  // ----- Vehicle -----
  { id: 'refuel-vehicle', group: 'Vehicle', label: 'Refuel Vehicle', icon: 'Fuel',
    fields: [{ key: 'vid', label: 'Vehicle id', type: 'number', placeholder: '12345' }],
    run: (_p, v) => refuelVehicle(Number(v.vid) || 0) },

  // ----- Live (RMQ) -----
  { id: 'kick', group: 'Live', label: 'Kick Player', icon: 'LogOut', liveOnly: true,
    run: p => kickPlayer({ actor_id: p.id }) },
  { id: 'teleport', group: 'Live', label: 'Teleport To Player', icon: 'Move',
    fields: [{ key: 'target', label: 'Target pawn id', type: 'number', placeholder: '67890' }],
    run: (p, v) => teleportToPlayer(p.id, Number(v.target) || 0) },
  { id: 'whisper', group: 'Live', label: 'Whisper', icon: 'MessageCircle', liveOnly: true, custom: 'whisper',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'cheat-script', group: 'Live', label: 'Cheat Script', icon: 'Terminal', liveOnly: true,
    fields: [{ key: 'script', label: 'Cheat command', type: 'text', placeholder: 'ce God' }],
    run: (p, v) => cheatScript({ actor_id: p.id }, String(v.script || '').trim()) },

  // ----- Identity -----
  { id: 'rename', group: 'Identity', label: 'Rename Character', icon: 'PenLine',
    fields: [{ key: 'name', label: 'New character name', type: 'text' }],
    run: (p, v) => renamePlayer(p.account_id, String(v.name || '').trim()) },
  { id: 'set-starter-class', group: 'Identity', label: 'Set Starter Class', icon: 'Compass',
    fields: [{ key: 'class', label: 'Class id', type: 'text', placeholder: 'mentat' }],
    run: (p, v) => setStarterClass(p.id, String(v.class || '').trim()) },
  { id: 'tags-add-remove', group: 'Identity', label: 'Update Tags (add / remove)', icon: 'Tag',
    fields: [
      { key: 'add',    label: 'Add (comma-separated)',    type: 'text', placeholder: 'vip, tester' },
      { key: 'remove', label: 'Remove (comma-separated)', type: 'text', placeholder: 'banned' },
    ],
    run: (p, v) => updatePlayerTags(
      p.account_id,
      String(v.add || '').split(',').map(s => s.trim()).filter(Boolean),
      String(v.remove || '').split(',').map(s => s.trim()).filter(Boolean),
    ) },
  { id: 'delete-tutorials', group: 'Identity', label: 'Clear Tutorial Flags', icon: 'Eraser',
    run: p => deleteTutorials(p.account_id) },
  { id: 'wipe-codex', group: 'Identity', label: 'Wipe Codex', icon: 'BookX',
    run: p => wipeCodex(p.account_id) },
  { id: 'returning-award', group: 'Identity', label: 'Grant Returning-Player Award', icon: 'Star',
    run: p => returningPlayerAward(p.account_id) },
  { id: 'dismiss-returning', group: 'Identity', label: 'Dismiss Returning-Player Award', icon: 'X',
    run: p => dismissReturningPlayerAward(p.account_id) },

  // ----- Danger Zone -----
  { id: 'delete-account', group: 'Danger', label: 'Delete Account (permanent)', icon: 'AlertTriangle',
    run: p => {
      const typed = window.prompt(
        `PERMANENTLY delete account ${p.account_id} (${p.name}).\n` +
        `This cannot be undone.\n\n` +
        `Type  i acknowledge  to proceed:`
      ) || ''
      if (typed.trim().toLowerCase() !== 'i acknowledge') {
        throw new Error('Did not type "i acknowledge" — delete aborted.')
      }
      return deleteAccount(p.account_id)
    } },
]

// 'Items' is rendered inside the Inventory section (between the inventory
// title and the items list), not in the Actions section.
const GROUP_ORDER: ActionGroup[] = ['Currency', 'Progression', 'Vehicle', 'Live', 'Identity', 'Danger']
const ITEMS_GROUP: ActionGroup = 'Items'

export function ActionsSection({ player, canWrite, flash, onChanged }: SectionProps) {
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Give-item form state lives at the section level so the ItemPicker keeps
  // its selection when the user tabs to Quantity / Quality fields.
  // giveTpl is the template_id we post to the API. giveName is the friendly
  // display name shown in the picker after a selection — clears once the
  // user types again, so picker continues to filter the live search query.
  const [giveTpl, setGiveTpl]   = useState('')
  const [giveName, setGiveName] = useState('')
  const [giveQty, setGiveQty]   = useState('1')
  const [giveQual, setGiveQual] = useState('0')
  const [whisper, setWhisper]   = useState('')

  const isOnline = (player.online_status || '').toLowerCase() === 'online'

  const openAction = (id: string) => {
    if (openId === id) { setOpenId(null); return }
    setOpenId(id)
    if (id === 'give-item' || id === 'give-item-live') { setGiveTpl(''); setGiveName(''); setGiveQty('1'); setGiveQual('0') }
    if (id === 'whisper') setWhisper('')
  }

  const runAction = async (def: ActionDef, exec: () => Promise<{ message: string }>) => {
    if (def.confirm) {
      const msg = def.confirm(player)
      if (msg && !window.confirm(msg)) return
    }
    setBusy(true)
    try {
      const r = await exec()
      flash(r.message || `${def.label} done.`, 'ok')
      setOpenId(null)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  // ACTIONS is a module-level constant; computing the grouped view once is
  // cheap, but useMemo must run before any conditional early-return below to
  // satisfy the rules of hooks.
  const grouped = useMemo(() => {
    const map: Record<ActionGroup, ActionDef[]> = {
      Currency: [], Progression: [], Items: [], Vehicle: [], Live: [], Identity: [], Danger: [],
    }
    for (const a of ACTIONS) {
      // Items is rendered inside InventorySection — skip here.
      if (a.group === ITEMS_GROUP) continue
      map[a.group].push(a)
    }
    return map
  }, [])

  if (!canWrite) {
    return (
      <div className="card p-4 text-sm text-text-dim flex items-center gap-2">
        <Icon name="Lock" size={14} /> Editing is available when the live game database is connected.
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {!isOnline && (
        <div className="card p-2.5 text-xs text-text-muted border-l-2 border-warning flex items-center gap-2">
          <Icon name="WifiOff" size={12} /> Player is offline — buttons marked "(live)" are disabled (require RMQ + an online player).
        </div>
      )}

      {GROUP_ORDER.map(group => {
        const acts = grouped[group]
        if (!acts || acts.length === 0) return null
        return (
          <div key={group} className="space-y-2">
            <div className="text-[11px] uppercase tracking-wider text-text-dim font-medium flex items-center gap-2">
              {group === 'Danger' && <Icon name="AlertTriangle" size={11} className="text-error" />}
              {group}
            </div>
            <div className="flex flex-wrap gap-2">
              {acts.map(a => {
                const disabled = busy || (a.liveOnly && !isOnline)
                const btnClass = group === 'Danger' ? 'btn-secondary text-error border-error/50' : 'btn-secondary'
                return (
                  <button
                    key={a.id}
                    className={btnClass}
                    disabled={disabled}
                    onClick={() => openAction(a.id)}
                    title={a.liveOnly ? 'Requires player to be online' : undefined}
                  >
                    <Icon name={a.icon} size={13} /> {a.label}
                  </button>
                )
              })}
            </div>

            {acts.filter(a => a.id === openId).map(def => {
              // Custom forms (item picker, whisper textarea).
              if (def.custom === 'give-item' || def.custom === 'give-item-live') {
                return (
                  <div key={def.id} className="card p-3 space-y-3">
                    <ItemPicker label="Item — type to search by name or template id"
                      value={giveTpl} displayValue={giveName || giveTpl}
                      onChange={(tpl, item) => { setGiveTpl(tpl); setGiveName(item ? item.name : '') }}
                      autoFocus disabled={busy} />
                    <div className="grid grid-cols-2 gap-3">
                      <div>
                        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
                        <input type="number" min={1} value={giveQty} disabled={busy}
                          onChange={e => setGiveQty(e.target.value)}
                          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                      </div>
                      <div>
                        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quality (0-5)</label>
                        <input type="number" min={0} max={5} value={giveQual} disabled={busy}
                          onChange={e => setGiveQual(e.target.value)}
                          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                      </div>
                    </div>
                    <button className="btn-primary w-full" disabled={busy || !giveTpl.trim()}
                      onClick={() => runAction(def, () => def.custom === 'give-item-live'
                        ? giveItemLive({ actor_id: player.id }, giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0)
                        : giveItem(player.id, giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0))}>
                      {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {def.label}
                    </button>
                  </div>
                )
              }
              if (def.custom === 'whisper') {
                return (
                  <div key={def.id} className="card p-3 space-y-3">
                    <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Whisper message</label>
                    <textarea rows={3} value={whisper} disabled={busy}
                      onChange={e => setWhisper(e.target.value)} placeholder="Hello from the admin tool"
                      className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 resize-none" />
                    <div className="text-[11px] text-text-muted">
                      Note: chat/whisper external publish is experimental — broker accepts but the game may silently drop.
                    </div>
                    <button className="btn-primary w-full" disabled={busy || !whisper.trim()}
                      onClick={() => runAction(def, () => chatWhisper(String(player.id), whisper.trim()))}>
                      {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Send" size={13} />} Send Whisper
                    </button>
                  </div>
                )
              }
              // Standard form built from field defs.
              return (
                <InlineForm key={def.id} busy={busy} submitLabel={def.label}
                  fields={def.fields || []}
                  onSubmit={v => runAction(def, () => def.run(player, v))}
                />
              )
            })}
          </div>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Items action block — the 'Items' group of ACTIONS, rendered inside the
// Inventory section (between the inventory title and the items list).
// Mirrors ActionsSection's per-group rendering, scoped to one group, with
// its own openId/busy/give-item form state.
// ---------------------------------------------------------------------------
function ItemsActionBlock({ player, canWrite, flash, onChanged }: {
  player: Player; canWrite: boolean; flash: Flash; onChanged: () => void
}) {
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [giveTpl, setGiveTpl]   = useState('')
  const [giveName, setGiveName] = useState('')
  const [giveQty, setGiveQty]   = useState('1')
  const [giveQual, setGiveQual] = useState('0')

  const isOnline = (player.online_status || '').toLowerCase() === 'online'

  const acts = useMemo(() => ACTIONS.filter(a => a.group === ITEMS_GROUP), [])

  if (!canWrite || acts.length === 0) return null

  const openAction = (id: string) => {
    if (openId === id) { setOpenId(null); return }
    setOpenId(id)
    if (id === 'give-item' || id === 'give-item-live') { setGiveTpl(''); setGiveName(''); setGiveQty('1'); setGiveQual('0') }
  }

  const runAction = async (def: ActionDef, exec: () => Promise<{ message: string }>) => {
    if (def.confirm) {
      const msg = def.confirm(player)
      if (msg && !window.confirm(msg)) return
    }
    setBusy(true)
    try {
      const r = await exec()
      flash(r.message || `${def.label} done.`, 'ok')
      setOpenId(null)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-2 mb-2">
      <div className="flex flex-wrap gap-2">
        {acts.map(a => {
          const disabled = busy || (a.liveOnly && !isOnline)
          return (
            <button key={a.id} className="btn-secondary" disabled={disabled}
              onClick={() => openAction(a.id)}
              title={a.liveOnly ? 'Requires player to be online' : undefined}>
              <Icon name={a.icon} size={13} /> {a.label}
            </button>
          )
        })}
      </div>

      {acts.filter(a => a.id === openId).map(def => {
        if (def.custom === 'give-item' || def.custom === 'give-item-live') {
          return (
            <div key={def.id} className="card p-3 space-y-3">
              <ItemPicker label="Item — type to search by name or template id"
                value={giveTpl} displayValue={giveName || giveTpl}
                onChange={(tpl, item) => { setGiveTpl(tpl); setGiveName(item ? item.name : '') }}
                autoFocus disabled={busy} />
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
                  <input type="number" min={1} value={giveQty} disabled={busy}
                    onChange={e => setGiveQty(e.target.value)}
                    className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                </div>
                <div>
                  <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quality (0-5)</label>
                  <input type="number" min={0} max={5} value={giveQual} disabled={busy}
                    onChange={e => setGiveQual(e.target.value)}
                    className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                </div>
              </div>
              <button className="btn-primary w-full" disabled={busy || !giveTpl.trim()}
                onClick={() => runAction(def, () => def.custom === 'give-item-live'
                  ? giveItemLive({ actor_id: player.id }, giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0)
                  : giveItem(player.id, giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0))}>
                {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {def.label}
              </button>
            </div>
          )
        }
        return (
          <InlineForm key={def.id} busy={busy} submitLabel={def.label}
            fields={def.fields || []}
            onSubmit={v => runAction(def, () => def.run(player, v))}
          />
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Inventory — re-uses the existing detail endpoint via the section pattern.
// Repair + delete per item; sub-sections for emotes & contract items.
// ---------------------------------------------------------------------------
import { getPlayerDetail, type InventoryItem, type PlayerDetailResponse } from '../../../api/gameplay'
import { qualityClass } from '../shared'

export function InventorySection({ player, canWrite, demo, refreshKey, flash, onChanged }: SectionProps) {
  const [detail, setDetail] = useState<PlayerDetailResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerDetail(player.id, player.controller_id, demo)
      .then(r => { if (alive) setDetail(r) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.id, player.controller_id, demo, refreshKey, tick])

  const groups = useMemo(() => {
    const inv = detail?.inventory ?? []
    return {
      gear:      inv.filter(i => (i.kind ?? 'item') === 'item'),
      emotes:    inv.filter(i => i.kind === 'emote'),
      contracts: inv.filter(i => i.kind === 'contract'),
    }
  }, [detail])

  const run = async (fn: () => Promise<{ message: string }>, label: string) => {
    setBusy(true)
    try {
      const r = await fn()
      flash(r.message || `${label} done.`, 'ok')
      setTick(t => t + 1)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  if (loading && !detail) return <Loading label="Loading inventory…" />
  if (err) return <ErrorBox msg={err} />

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-end">
        <button className="btn-secondary" disabled={loading || busy} onClick={() => setTick(t => t + 1)}>
          <Icon name="RefreshCw" size={13} className={loading ? 'animate-spin' : ''} /> Refresh inventory
        </button>
      </div>
      <ItemList title={`Inventory (${fmtNum(groups.gear.length)})`} icon="Backpack" items={groups.gear}
        canWrite={canWrite} busy={busy} run={run}
        extra={<ItemsActionBlock player={player} canWrite={canWrite} flash={flash} onChanged={() => { onChanged(); setTick(t => t + 1) }} />} />
      <ItemList title={`Emotes (${fmtNum(groups.emotes.length)})`} icon="Smile" items={groups.emotes} collapsed
        canWrite={canWrite} busy={busy} run={run} />
      <ItemList title={`Contract items (${fmtNum(groups.contracts.length)})`} icon="FileText" items={groups.contracts} collapsed
        canWrite={canWrite} busy={busy} run={run} />
    </div>
  )
}

function ItemList({ title, icon, items, canWrite, busy, run, collapsed, extra }: {
  title: string; icon: string; items: InventoryItem[]; canWrite: boolean; busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  collapsed?: boolean
  extra?: React.ReactNode
}) {
  const [open, setOpen] = useState(!collapsed)
  if (collapsed && items.length === 0) return null
  return (
    <div>
      <button type="button" onClick={() => setOpen(o => !o)}
        className="flex w-full items-center gap-2 text-xs uppercase tracking-wider text-text-dim hover:text-text mb-2">
        <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={13} />
        <Icon name={icon} size={13} />
        <span>{title}</span>
      </button>
      {open && extra}
      {open && (
        items.length === 0 ? (
          <div className="text-sm text-text-dim italic py-1">No items.</div>
        ) : (
          <div className="space-y-1">
            {items.map(it => {
              const curN = parseFloat(it.durability)
              const maxN = parseFloat(it.max_durability)
              const hasDur = it.durability !== 'N/A' && Number.isFinite(curN) && Number.isFinite(maxN) && maxN > 0
              const ratio = hasDur ? curN / maxN : 1
              const durCls =
                !hasDur          ? 'text-text-dim' :
                ratio <= 0.0001  ? 'text-danger font-semibold' :  // fully dead
                ratio < 0.25     ? 'text-danger' :
                ratio < 0.5      ? 'text-warning' :
                                   'text-text-dim'
              return (
                <div key={it.id} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
                  <span className="truncate max-w-[320px]">
                    <span className="text-text">{it.name || it.template_id}</span>
                    {it.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(it.quality)}`}>Q{it.quality}</span>}
                    {hasDur && (
                      <span className={`ml-1.5 font-mono text-[11px] ${durCls}`} title={`Durability ${curN.toFixed(0)} / ${maxN.toFixed(0)} (${Math.round(ratio * 100)}%)`}>
                        {curN.toFixed(0)}/{maxN.toFixed(0)}
                      </span>
                    )}
                    <span className="ml-1.5 font-mono text-text-dim text-xs">×{fmtNum(it.stack_size)}</span>
                  </span>
                  {canWrite && (
                    <span className="flex items-center gap-2 shrink-0">
                      {it.durability !== 'N/A' && (
                        <button className="text-info hover:text-accent-bright" title="Repair to full" disabled={busy}
                          onClick={() => run(() => repairInventoryItem(it.id), 'Repair')}>
                          <Icon name="Wrench" size={13} />
                        </button>
                      )}
                      <button className="text-danger/80 hover:text-danger" title="Delete item" disabled={busy}
                        onClick={() => void run(() => deleteInventoryItem(it.id), 'Delete')}>
                        <Icon name="Trash2" size={13} />
                      </button>
                    </span>
                  )}
                </div>
              )
            })}
          </div>
        )
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Small shared widgets
// ---------------------------------------------------------------------------
function Stat({ label, value, icon }: { label: string; value: string; icon: string }) {
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between">
        <span className="text-[11px] uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={14} className="text-accent" />
      </div>
      <div className="mt-1 text-lg font-semibold text-text truncate">{value}</div>
    </div>
  )
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="card p-3">
      <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">{title}</h4>
      <div className="space-y-1.5 text-sm">{children}</div>
    </div>
  )
}

function KV({ k, v, mono }: { k: string; v: string; mono?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span className="text-text-dim">{k}</span>
      <span className={mono ? 'font-mono text-text-muted text-xs' : 'text-text truncate max-w-[200px]'}>{v}</span>
    </div>
  )
}

function Loading({ label }: { label: string }) {
  return (
    <div className="text-text-dim text-sm py-4 flex items-center gap-2">
      <Icon name="Loader2" size={15} className="animate-spin" /> {label}
    </div>
  )
}

function EmptyBox({ msg }: { msg: string }) {
  return <div className="card p-4 text-sm text-text-dim text-center">{msg}</div>
}

function ErrorBox({ msg }: { msg: string }) {
  return <div className="card p-3 text-sm text-danger break-words">{msg}</div>
}

interface FieldDef { key: string; label: string; type: 'text' | 'number'; placeholder?: string }

function InlineForm({ fields, submitLabel, busy, onSubmit }: {
  fields: FieldDef[]; submitLabel: string; busy: boolean; onSubmit: (values: Record<string, string>) => void
}) {
  const [values, setValues] = useState<Record<string, string>>({})
  return (
    <div className="card p-3 space-y-2">
      {fields.map(f => (
        <div key={f.key}>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">{f.label}</label>
          <input type={f.type} value={values[f.key] ?? ''} placeholder={f.placeholder}
            onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
      ))}
      <button className="btn-primary w-full" disabled={busy} onClick={() => onSubmit(values)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {submitLabel}
      </button>
    </div>
  )
}

// Format an ISO 8601 timestamp into a compact local-time string, or '—' on
// empty / unparseable. Used in Stats + History.
function fmtTs(ts: string | undefined): string {
  if (!ts) return '—'
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return ts
  return d.toLocaleString()
}

// Pretty-print event meta JSON, falling back to the raw string when it
// can't be parsed (older event_log rows have free-form meta).
function prettyMeta(meta: string): string {
  if (!meta) return '{}'
  try {
    const o = JSON.parse(meta)
    return JSON.stringify(o, null, 2)
  } catch {
    return meta
  }
}

// Re-export the section component type for the tab shell.
export type SectionId = 'stats' | 'specs' | 'tags' | 'history' | 'inventory' | 'actions'

export const SECTIONS: Array<{ id: SectionId; label: string; icon: string }> = [
  { id: 'stats',     label: 'Stats',     icon: 'User' },
  { id: 'specs',     label: 'Specs',     icon: 'Sparkles' },
  { id: 'inventory', label: 'Inventory', icon: 'Backpack' },
  { id: 'tags',      label: 'Tags',      icon: 'Tag' },
  { id: 'history',   label: 'History',   icon: 'History' },
  { id: 'actions',   label: 'Actions',   icon: 'Wand2' },
]

export const SECTION_COMPONENTS: Record<SectionId, (p: SectionProps) => ReactElement> = {
  stats:     StatsSection,
  specs:     SpecsSection,
  tags:      TagsSection,
  history:   HistorySection,
  inventory: InventorySection,
  actions:   ActionsSection,
}
