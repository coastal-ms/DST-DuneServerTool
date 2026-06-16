// v11.5.6 — Player section panels. One component per section nav entry
// (Stats / Specs / Tags / History / Inventory / Actions). All sections take
// a common props shape: the selected player + a `canWrite` flag (live DB)
// + a callback to flash status messages to the parent.
//
// Most sections are self-contained: they fetch their own data, render, and
// expose action buttons. The parent owns selection + refresh ticks; sections
// re-fetch when `refreshKey` changes.

import { useCallback, useEffect, useMemo, useState, type ReactElement, type ReactNode } from 'react'
import { Icon } from '../../../components/Icon'
import { ItemPicker } from '../../../components/ItemPicker'
import {
  awardCharXp, awardIntel, awardSpecXp, cheatScript, cleanPlayerInventory,
  applyProgressionPreset, getProgressionPresets,
  deleteAccount, deleteInventoryItem, deleteTutorials,
  dismissReturningPlayerAward, fillWater, getPlayerEvents, getPlayerSpecs,
  getPlayerStats, getPlayerTags, giveFactionRep, giveItem,
  giveScrip, giveSolari, grantAllKeystones, grantLive, grantMaxSpec,
  kickPlayer, refuelVehicle, renamePlayer, repairGear, repairInventoryItem,
  getPlayerVehicles,
  setItemDurability, setItemWater,
  resetAllKeystones, resetAllSpecs, resetJourney, resetProgressionLive, resetSpec,
  restoreDestroyed,
  returningPlayerAward, setFactionTier, setPlayerTags, setSkillPoints,
  setStarterClass, teleportToPlayer, updatePlayerTags, wipeCodex, wipeJourney,
  chatWhisper, isValidTemplateId, getItemCatalog,
  giveItems, getItemPackages, saveItemPackage, deleteItemPackage,
  getLandsraadOverview, getLandsraadPlayerContributions, setLandsraadContribution,
  getPlayerJourneyNodes, completeJourneyNode, resetJourneyNode,
  getTrainerCatalog, getTrainerStatus, unlockTrainer, resetTrainerSkills,
  getMainQuestCatalog, unlockMainQuest,
  type Player, type PlayerEvent, type PlayerStats, type ProgressionPreset, type SpecTrackFull,
  type CatalogItem, type ItemPackage, type GiveItemEntry,
  type LandsraadHouse, type LandsraadIniSetting,
  type JourneyNode, type TrainerInfo, type TrainerStatus, type MainQuestInfo,
  type PlayerVehicleRow,
} from '../../../api/gameplay'
import { VEHICLE_CATALOG, VEHICLE_KIT_FUEL_TEMPLATE, VEHICLE_KIT_TORCH_TEMPLATE, type VehicleTemplate } from '../../../data/vehicles'
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

      {stats.faction_reps && stats.faction_reps.length > 0 && (
        <Card title="Faction reputation">
          {stats.faction_reps.map(fr => (
            <KV
              key={fr.faction_id}
              k={fr.faction_name || `Faction #${fr.faction_id}`}
              v={stats.faction_rep_cap
                ? `${fmtNum(fr.reputation)} / ${fmtNum(stats.faction_rep_cap)}`
                : fmtNum(fr.reputation)}
            />
          ))}
        </Card>
      )}
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
interface ActionField { key: string; label: string; type: 'text' | 'number' | 'select'; placeholder?: string; min?: number; max?: number; options?: { value: string; label: string }[] }
interface ActionDef {
  id: string
  group: ActionGroup
  label: string
  icon: string
  liveOnly?: boolean      // requires player to be online (RMQ path)
  offlineOnly?: boolean   // requires player to be offline (DB write the game caches in memory)
  fields?: ActionField[]
  custom?: 'give-item' | 'whisper' | 'spawn-vehicle' | 'quick-presets' | 'vehicle-kit' | 'give-package' | 'cheat-scripts' | 'dev-scripts' | 'unlock-trainers' | 'unlock-mainquest' | 'refuel-vehicle' | 'starter-class' | 'update-tags'
  balance?: 'solari' | 'scrip' | 'intel'  // show the player's current balance read-only above the form
  confirm?: (p: Player) => string  // confirm message; if returns '' no prompt
  doubleConfirm?: boolean // also requires a typed "i acknowledge" prompt inside run()
  rowNote?: string        // short italic note shown inline on the row heading
  run: (p: Player, v: Record<string, string>) => Promise<{ message: string }>
}

const ACTIONS: ActionDef[] = [
  // ----- Currency -----
  { id: 'give-solari', group: 'Currency', label: 'Give Solari', icon: 'Coins', balance: 'solari',
    fields: [{ key: 'amount', label: 'Amount', type: 'number', placeholder: '10000' }],
    run: (p, v) => giveSolari(p.controller_id, Number(v.amount) || 0) },
  { id: 'give-scrip', group: 'Currency', label: 'Give Scrip', icon: 'Banknote', balance: 'scrip',
    fields: [{ key: 'amount', label: 'Amount', type: 'number', placeholder: '500' }],
    run: (p, v) => giveScrip(p.controller_id, Number(v.amount) || 0) },
  { id: 'give-intel', group: 'Currency', label: 'Give Intel', icon: 'BookOpen', offlineOnly: true, balance: 'intel',
    fields: [{ key: 'amount', label: 'Tech Knowledge Points', type: 'number', placeholder: '100' }],
    run: (p, v) => awardIntel(p.controller_id, p.id, Number(v.amount) || 0) },
  { id: 'grant-live', group: 'Currency', label: 'Grant Reward (popup)', icon: 'Gift',
    fields: [
      { key: 'template', label: 'Item template id', type: 'text', placeholder: 'Item_…' },
      { key: 'amount',   label: 'Amount',           type: 'number', placeholder: '1' },
    ],
    run: (p, v) => grantLive(p.controller_id, String(v.template || '').trim(), Number(v.amount) || 1) },

  // ----- Progression -----
  { id: 'award-char-xp', group: 'Progression', label: 'Award Character XP', icon: 'TrendingUp', liveOnly: true,
    fields: [{ key: 'delta', label: 'XP delta', type: 'number', placeholder: '5000' }],
    run: (p, v) => awardCharXp(p.id, Number(v.delta) || 0) },
  { id: 'set-skill-points', group: 'Progression', label: 'Set Skill Points (live)', icon: 'Sparkles', liveOnly: true,
    fields: [{ key: 'sp', label: 'Unspent Skill Points', type: 'number', placeholder: '50' }],
    run: (p, v) => setSkillPoints({ actor_id: p.id }, Number(v.sp) || 0) },
  { id: 'give-faction-rep', group: 'Progression', label: 'Give Faction Rep', icon: 'Shield',
    fields: [
      { key: 'faction', label: 'Faction', type: 'select', options: [
        { value: 'atreides', label: 'Atreides' },
        { value: 'harkonnen', label: 'Harkonnen' },
      ] },
      { key: 'delta',   label: 'Delta',                              type: 'number', placeholder: '500' },
    ],
    run: (p, v) => giveFactionRep(p.controller_id, String(v.faction || 'atreides').trim(), Number(v.delta) || 0) },
  { id: 'set-faction-tier', group: 'Progression', label: 'Set Faction Tier', icon: 'BarChart3',
    fields: [
      { key: 'faction', label: 'Faction', type: 'select', options: [
        { value: 'atreides', label: 'Atreides' },
        { value: 'harkonnen', label: 'Harkonnen' },
      ] },
      { key: 'tier',    label: 'Tier (0-20)', type: 'number', placeholder: '10', min: 0, max: 20 },
    ],
    run: (p, v) => setFactionTier(p.controller_id, String(v.faction || 'atreides').trim(), Number(v.tier) || 0) },
  { id: 'apply-progression-preset', group: 'Progression', label: 'Apply Quick Preset', icon: 'Zap', custom: 'quick-presets',
    rowNote: 'Completes a story/journey chapter instantly',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'unlock-trainers', group: 'Progression', label: 'Unlock Trainers', icon: 'GraduationCap', custom: 'unlock-trainers',
    rowNote: 'Complete a skill-trainer quest line + grant its skill tree — separated by trainer',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'unlock-main-quest', group: 'Progression', label: 'Unlock Main Quest', icon: 'Flag', custom: 'unlock-mainquest',
    rowNote: 'Complete an entire main-quest story line',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'reset-progression', group: 'Progression', label: 'Reset Progression (live)', icon: 'RotateCcw', liveOnly: true,
    rowNote: 'Single confirmation required',
    confirm: p => `Reset ALL progression for ${p.name}? Cannot be undone.\n\n` +
      `This single confirmation is required so the action can't run on an accidental click.`,
    run: p => resetProgressionLive({ actor_id: p.id }) },
  { id: 'reset-journey', group: 'Progression', label: 'Reset Journey', icon: 'Map',
    rowNote: 'Single confirmation required',
    confirm: p => `Reset ${p.name}'s journey/quest progress? They'll restart the current journey step. This cannot be undone.\n\n` +
      `This single confirmation is required so the action can't run on an accidental click.`,
    run: p => resetJourney(p.account_id) },
  { id: 'wipe-journey', group: 'Progression', label: 'Wipe Journey (restart)', icon: 'RefreshCw',
    rowNote: 'Single confirmation required',
    confirm: p => `WIPE ${p.name}'s entire journey and restart it from the beginning? All journey/quest progress is lost. This cannot be undone.\n\n` +
      `This single confirmation is required so the action can't run on an accidental click.`,
    run: p => wipeJourney(p.account_id) },

  // ----- Items -----
  { id: 'give-item',      group: 'Items', label: 'Give Item', icon: 'PackagePlus', custom: 'give-item',
    rowNote: 'Works online or offline — delivered instantly when online, on next login when offline',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'give-vehicle-kit', group: 'Items', label: 'Give Vehicle Kit', icon: 'Truck', custom: 'vehicle-kit',
    rowNote: 'Parts + fuel cell + welding torch Mk5 — works online or offline, needs inventory space',
    confirm: p => `Give vehicle parts to ${p.name}'s inventory? They'll need to assemble at a Vehicle Assembly. Works online or offline.`,
    run: () => Promise.resolve({ message: '' }) },
  { id: 'give-package', group: 'Items', label: 'Give Package', icon: 'PackageCheck', custom: 'give-package',
    rowNote: 'Hand a saved item package to this player — build & reuse your own bundles. Works online or offline',
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
  { id: 'spawn-vehicle', group: 'Vehicle', label: 'Spawn Vehicle', icon: 'Car', custom: 'spawn-vehicle',
    rowNote: 'Hands unassembled Mk6 parts — assemble at a Vehicle Assembly. Works online or offline',
    confirm: p => `Give vehicle parts to ${p.name}'s inventory? They'll need to assemble at a Vehicle Assembly. Works online or offline.`,
    run: () => Promise.resolve({ message: '' }) },
  { id: 'refuel-vehicle', group: 'Vehicle', label: 'Refuel Vehicle', icon: 'Fuel', custom: 'refuel-vehicle',
    run: () => Promise.resolve({ message: '' }) },

  // ----- Live (RMQ) -----
  { id: 'kick', group: 'Live', label: 'Kick Player', icon: 'LogOut', liveOnly: true,
    run: p => kickPlayer({ actor_id: p.id }) },
  { id: 'teleport', group: 'Live', label: 'Teleport To Player', icon: 'Move',
    fields: [{ key: 'target', label: 'Target pawn id', type: 'number', placeholder: '67890' }],
    run: (p, v) => teleportToPlayer(p.id, Number(v.target) || 0) },
  { id: 'whisper', group: 'Live', label: 'Whisper', icon: 'MessageCircle', liveOnly: true, custom: 'whisper',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'cheat-script', group: 'Live', label: 'Cheat Scripts', icon: 'Terminal', liveOnly: true, custom: 'cheat-scripts',
    rowNote: 'Fire a server cheat script — loadouts, XP, unlock skills/abilities. Online only',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'dev-scripts', group: 'Live', label: 'Dev / Perf Scripts', icon: 'FlaskConical', liveOnly: true, custom: 'dev-scripts',
    rowNote: 'Developer performance-test harnesses (hitch tests). Playtest-only, online only',
    run: () => Promise.resolve({ message: '' }) },

  // ----- Identity -----
  { id: 'rename', group: 'Identity', label: 'Rename Character', icon: 'PenLine',
    fields: [{ key: 'name', label: 'New character name', type: 'text' }],
    run: (p, v) => renamePlayer(p.account_id, String(v.name || '').trim()) },
  { id: 'set-starter-class', group: 'Identity', label: 'Set Starter Class', icon: 'Compass', custom: 'starter-class',
    doubleConfirm: true,
    rowNote: 'Double confirmation required',
    confirm: p => `Set ${p.name}'s starter class?\n\n` +
      `This is the FIRST of two confirmations. If you continue, the next step asks you to type an acknowledgement before the change is applied. This cannot be undone.`,
    run: () => Promise.resolve({ message: '' }) },
  { id: 'tags-add-remove', group: 'Identity', label: 'Update Tags (add / remove)', icon: 'Tag', custom: 'update-tags',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'delete-tutorials', group: 'Identity', label: 'Clear Tutorial Flags', icon: 'Eraser',
    run: p => deleteTutorials(p.account_id) },
  { id: 'wipe-codex', group: 'Identity', label: 'Wipe Codex', icon: 'BookX',
    doubleConfirm: true,
    rowNote: 'Double confirmation required',
    confirm: p => `Wipe ${p.name}'s codex?\n\n` +
      `This is the FIRST of two confirmations. If you continue, the next step asks you to type an acknowledgement before the codex is wiped. This cannot be undone.`,
    run: p => {
      const typed = window.prompt(
        `SECOND confirmation — WIPE ${p.name}'s codex.\n` +
        `This cannot be undone.\n\n` +
        `Type  i acknowledge  to proceed:`
      ) || ''
      if (typed.trim().toLowerCase() !== 'i acknowledge') {
        throw new Error('Did not type "i acknowledge" — wipe aborted.')
      }
      return wipeCodex(p.account_id)
    } },
  { id: 'returning-award', group: 'Identity', label: 'Grant Returning-Player Award', icon: 'Star',
    run: p => returningPlayerAward(p.account_id) },
  { id: 'dismiss-returning', group: 'Identity', label: 'Dismiss Returning-Player Award', icon: 'X',
    run: p => dismissReturningPlayerAward(p.account_id) },

  // ----- Danger Zone -----
  { id: 'delete-account', group: 'Danger', label: 'Delete Account (permanent)', icon: 'AlertTriangle',
    doubleConfirm: true,
    rowNote: 'Double confirmation required',
    confirm: p => `Permanently delete account ${p.account_id} (${p.name})?\n\n` +
      `This is the FIRST of two confirmations. If you continue, the next step asks you to type an acknowledgement before the account is deleted. This cannot be undone.`,
    run: p => {
      const typed = window.prompt(
        `SECOND confirmation — PERMANENTLY delete account ${p.account_id} (${p.name}).\n` +
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
const GROUP_ORDER: ActionGroup[] = ['Live', 'Currency', 'Progression', 'Vehicle', 'Identity', 'Danger']
const ITEMS_GROUP: ActionGroup = 'Items'

export function ActionsSection({ player, canWrite, demo, flash, onChanged }: SectionProps) {
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  // Current balances for read-only context on the Give Solari/Scrip/Intel rows,
  // so admins see what the player already has before adjusting it.
  const [stats, setStats] = useState<PlayerStats | null>(null)
  useEffect(() => {
    let alive = true
    getPlayerStats(player.id, demo).then(r => { if (alive) setStats(r.stats) }).catch(() => {})
    return () => { alive = false }
  }, [player.id, demo])

  // A live session exists during Online AND LoggingOut (the logout grace
  // window where the pod still owns the player's state in memory - 30s on
  // Hagga / Arrakeen / Harkonnen / etc., 5 min in Deep Desert). liveOnly
  // actions run via RMQ to that session, so they're valid in both states -
  // kick during LoggingOut force-flushes instead of waiting out the timer.
  const hasLiveSession = ['online', 'loggingout'].includes((player.online_status || '').toLowerCase())
  const openAction = (id: string) => setOpenId(o => (o === id ? null : id))

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
      {!hasLiveSession && (
        <div className="card p-2.5 text-xs text-text-muted border-l-2 border-warning flex items-center gap-2">
          <Icon name="WifiOff" size={12} /> Player is offline — actions marked "LIVE REQ'D" need the player online (RMQ + an online or mid-logout player) to take effect.
        </div>
      )}

      {GROUP_ORDER.map(group => {
        const acts = grouped[group]
        if (!acts || acts.length === 0) return null
        return (
          <div key={group} className="space-y-1.5">
            <div className="text-[11px] uppercase tracking-wider text-text-dim font-medium flex items-center gap-2">
              {group === 'Danger' && <Icon name="AlertTriangle" size={11} className="text-error" />}
              {group}
            </div>
            <div className="space-y-1.5">
              {acts.map(a => (
                <ActionRow key={a.id} def={a} player={player} busy={busy} stats={stats}
                  open={openId === a.id} danger={group === 'Danger'}
                  onToggle={() => openAction(a.id)} runAction={runAction} />
              ))}
            </div>
          </div>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// ActionRow — one accordion row for a single ActionDef. The row header is a
// full-width clickable list item; clicking expands the action's form inline
// directly beneath it. Replaces the older wrap-of-buttons layout so the panel
// reads as a vertical list rather than a wall of buttons.
// ---------------------------------------------------------------------------
function ActionRow({ def, player, busy, stats, open, danger, onToggle, runAction }: {
  def: ActionDef
  player: Player
  busy: boolean
  stats: PlayerStats | null
  open: boolean
  danger?: boolean
  onToggle: () => void
  runAction: (def: ActionDef, exec: () => Promise<{ message: string }>) => void
}) {
  const disabled = busy
  // Read-only "current balance" note shown above currency actions.
  const balanceNote = (() => {
    if (!def.balance || !stats) return null
    let label = '', value = ''
    if (def.balance === 'solari') { label = 'Current Solari'; value = fmtSolari(stats.solaris) }
    else if (def.balance === 'scrip') { label = 'Current Scrip'; value = fmtNum(stats.scrip ?? 0) }
    else if (def.balance === 'intel') { label = 'Current Intel'; value = `${fmtNum(stats.intel ?? 0)}${stats.intel_max ? ` / ${fmtNum(stats.intel_max)}` : ''}` }
    return (
      <div className="flex items-center justify-between rounded-lg bg-surface-2 border border-border/50 px-3 py-2 mb-2 text-sm">
        <span className="text-text-dim">{label}</span>
        <span className="font-mono text-text">{value}</span>
      </div>
    )
  })()
  return (
    <div className="card overflow-hidden">
      <button type="button"
        className={`w-full flex items-center gap-2.5 px-3 py-2 text-left text-sm transition-colors ${disabled ? 'opacity-50 cursor-not-allowed' : 'hover:bg-surface-2'} ${danger ? 'text-error' : 'text-text'}`}
        disabled={disabled}
        onClick={onToggle}
        title={def.liveOnly ? 'Requires player to be online' : def.offlineOnly ? 'Requires player to be offline — the game caches this value in memory while online and overwrites it on logout' : undefined}>
        <Icon name={def.icon} size={14} className={`shrink-0 ${danger ? 'text-error' : 'text-text-dim'}`} />
        <span className="flex-1 min-w-0 truncate font-medium">{def.label}</span>
        {def.rowNote && (
          <span className="shrink-0 hidden sm:flex items-center gap-1.5 text-xs">
            <span className="text-text-dim">---</span>
            <span className="italic text-white">{def.rowNote}</span>
          </span>
        )}
        {def.liveOnly && (
          <span className="text-[10px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-warning/20 text-warning border border-warning/50 shrink-0">LIVE REQ'D</span>
        )}
        {def.offlineOnly && (
          <span className="text-[10px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-info/20 text-info border border-info/50 shrink-0">OFFLINE REQ'D</span>
        )}
        <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} className="shrink-0 text-text-dim" />
      </button>
      {open && (
        <div className="border-t border-border p-3">
          {def.custom === 'give-item' ? (
            <GiveItemForm busy={busy} submitLabel={def.label}
              onSubmit={(tpl, qty, qual, overflow) => runAction(def, () => giveItem(player.id, tpl, qty, qual, overflow))}
              onSubmitTierSet={(tpl, qty, overflow) => runAction(def, async () => {
                for (let q = 0; q <= 5; q++) await giveItem(player.id, tpl, qty, q, overflow)
                return { message: `Gave ${tpl} Mk1–Mk6 (x${qty} each) to ${player.name}.` }
              })} />
          ) : def.custom === 'whisper' ? (
            <WhisperForm busy={busy}
              onSubmit={msg => runAction(def, () => chatWhisper(String(player.id), msg))} />
          ) : def.custom === 'spawn-vehicle' || def.custom === 'vehicle-kit' ? (
            <VehicleKitForm busy={busy}
              onSubmit={(veh, overflow) => runAction(def, async () => {
                const parts = [...veh.kit, ...veh.unique, VEHICLE_KIT_FUEL_TEMPLATE, VEHICLE_KIT_TORCH_TEMPLATE]
                for (const tpl of parts) await giveItem(player.id, tpl, veh.qty?.[tpl] ?? 1, 0, overflow)
                const count = veh.kit.length + veh.unique.length
                return { message: `Gave ${veh.label} kit — ${count} part${count === 1 ? '' : 's'} + Large Fuel Cell + Welding Torch Mk5 to ${player.name}.` }
              })} />
          ) : def.custom === 'cheat-scripts' ? (
            <CheatScriptForm busy={busy}
              onSubmit={name => runAction(def, async () => {
                await cheatScript({ actor_id: player.id }, name)
                return { message: `Sent cheat script "${name}" to ${player.name}.` }
              })} />
          ) : def.custom === 'dev-scripts' ? (
            <DevScriptForm busy={busy}
              onSubmit={name => runAction(def, async () => {
                await cheatScript({ actor_id: player.id }, name)
                return { message: `Sent dev script "${name}" to ${player.name}.` }
              })} />
          ) : def.custom === 'quick-presets' ? (
            <QuickPresetsForm busy={busy}
              onSubmit={presetId => runAction(def, () => applyProgressionPreset(player.account_id, presetId))} />
          ) : def.custom === 'unlock-trainers' ? (
            <UnlockTrainersForm busy={busy} accountId={player.account_id}
              onUnlock={(job, name) => runAction(def, async () => {
                const r = await unlockTrainer(player.account_id, job)
                return { message: r.message || `Unlocked ${name} trainer for ${player.name}.` }
              })}
              onReset={(job, name) => runAction(def, async () => {
                const r = await resetTrainerSkills(player.account_id, job)
                return { message: r.message || `Reset ${name} skill tree for ${player.name}.` }
              })} />
          ) : def.custom === 'unlock-mainquest' ? (
            <UnlockMainQuestForm busy={busy}
              onSubmit={(quest, name) => runAction(def, async () => {
                const r = await unlockMainQuest(player.account_id, quest)
                return { message: r.message || `Unlocked main quest "${name}" for ${player.name}.` }
              })} />
          ) : def.custom === 'give-package' ? (
            <GivePackageForm busy={busy} playerName={player.name}
              onGive={(items, pkgName) => runAction(def, async () => {
                await giveItems(player.id, items)
                const n = items.length
                return { message: `Gave package "${pkgName}" — ${n} item${n === 1 ? '' : 's'} to ${player.name}.` }
              })} />
          ) : def.custom === 'refuel-vehicle' ? (
            <RefuelVehicleForm busy={busy} controllerId={player.controller_id} playerName={player.name}
              onSubmit={vid => runAction(def, () => refuelVehicle(vid))} />
          ) : def.custom === 'starter-class' ? (
            <StarterClassForm busy={busy}
              onSubmit={(job, name) => runAction(def, () => {
                const typed = window.prompt(
                  `SECOND confirmation — set ${player.name}'s starter class to "${name}".\n` +
                  `This cannot be undone.\n\n` +
                  `Type  i acknowledge  to proceed:`
                ) || ''
                if (typed.trim().toLowerCase() !== 'i acknowledge') {
                  return Promise.reject(new Error('Did not type "i acknowledge" — change aborted.'))
                }
                return setStarterClass(player.id, job)
              })} />
          ) : def.custom === 'update-tags' ? (
            <UpdateTagsForm busy={busy} accountId={player.account_id} demo={false}
              onSubmit={(add, remove) => runAction(def, () => updatePlayerTags(player.account_id, add, remove))} />
          ) : (
            <InlineForm busy={busy} submitLabel={def.label} fields={def.fields || []} note={balanceNote}
              onSubmit={v => runAction(def, () => def.run(player, v))} />
          )}
        </div>
      )}
    </div>
  )
}

// Self-contained give-item form (item picker + qty/quality). Owns its own
// state so it resets whenever the accordion row mounts. Renders without a card
// wrapper — ActionRow provides the container.
function GiveItemForm({ busy, submitLabel, onSubmit, onSubmitTierSet }: {
  busy: boolean; submitLabel: string
  onSubmit: (tpl: string, qty: number, qual: number, allowOverflow: boolean) => void
  onSubmitTierSet: (tpl: string, qty: number, allowOverflow: boolean) => void
}) {
  const [giveTpl, setGiveTpl]   = useState('')
  const [giveName, setGiveName] = useState('')
  const [giveQty, setGiveQty]   = useState('1')
  const [giveQual, setGiveQual] = useState('0')
  const [gradeable, setGradeable] = useState(false)
  const [overflow, setOverflow] = useState(false)
  return (
    <div className="space-y-3">
      <ItemPicker label="Item — type to search by name or template id"
        value={giveTpl} displayValue={giveName || giveTpl}
        onChange={(tpl, item) => { setGiveTpl(tpl); setGiveName(item ? item.name : ''); setGradeable(!!item?.gradeable) }}
        autoFocus disabled={busy} />
      <div className="grid grid-cols-2 gap-3">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
          <input type="number" min={1} value={giveQty} disabled={busy}
            onChange={e => setGiveQty(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Tier — Mk1-Mk6 (0-5)</label>
          <input type="number" min={0} max={5} value={giveQual} disabled={busy}
            onChange={e => setGiveQual(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
      </div>
      <OverflowToggle checked={overflow} disabled={busy} onChange={setOverflow} />
      <button className="btn-primary w-full" disabled={busy || !isValidTemplateId(giveTpl)}
        onClick={() => onSubmit(giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0, overflow)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {submitLabel}
      </button>
      {gradeable && (
        <button className="btn-secondary w-full" disabled={busy || !isValidTemplateId(giveTpl)}
          title="Gives one of this item at every grade, Mk1 through Mk6"
          onClick={() => onSubmitTierSet(giveTpl.trim(), Number(giveQty) || 1, overflow)}>
          {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Layers" size={13} />} Give whole tier set (Mk1-Mk6)
        </button>
      )}
    </div>
  )
}

// Shared "drop overflow to the ground" toggle. When checked, the give skips
// DST's inventory-capacity guard so the game's native AddItemToInventory command
// handles a full backpack by dropping the excess on the ground. Online players
// only — offline (SQL) gives can't drop to ground, so the flag is ignored there.
function OverflowToggle({ checked, disabled, onChange }: {
  checked: boolean; disabled: boolean; onChange: (v: boolean) => void
}) {
  return (
    <label className="flex items-start gap-2 text-xs text-text-muted cursor-pointer select-none">
      <input type="checkbox" checked={checked} disabled={disabled}
        onChange={e => onChange(e.target.checked)}
        className="mt-0.5 accent-ibad" />
      <span>
        <span className="text-text">Allow overflow (drop to ground)</span>
        <span className="block text-[11px] text-text-dim">
          If the inventory is full, drop the items that don't fit on the ground next to the player. Online players only.
        </span>
      </span>
    </label>
  )
}

// Admin-defined item packages: build and reuse named bundles of items, then
// hand the whole bundle to the selected player in one click. Packages are
// global (shared across the app + remote portal), persisted server-side. This
// form owns two modes — a give/list view and an inline create/edit editor.
interface PkgDraftRow { template: string; name: string; qty: string; quality: string }

function GivePackageForm({ busy, playerName, onGive }: {
  busy: boolean; playerName: string
  onGive: (items: GiveItemEntry[], pkgName: string) => void
}) {
  const [packages, setPackages] = useState<ItemPackage[]>([])
  const [loading, setLoading]   = useState(true)
  const [err, setErr]           = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState('')
  const [mode, setMode]         = useState<'list' | 'edit'>('list')
  const [draftId, setDraftId]   = useState<string | undefined>(undefined)
  const [draftName, setDraftName] = useState('')
  const [draftRows, setDraftRows] = useState<PkgDraftRow[]>([])
  const [saving, setSaving]     = useState(false)

  const load = useCallback(async (preferId?: string) => {
    setLoading(true); setErr(null)
    try {
      const list = await getItemPackages()
      setPackages(list)
      setSelectedId(prev => {
        const want = preferId ?? prev
        return list.some(p => p.id === want) ? want : (list[0]?.id ?? '')
      })
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  const selected = packages.find(p => p.id === selectedId) ?? null

  const startNew = () => {
    setDraftId(undefined); setDraftName('')
    setDraftRows([{ template: '', name: '', qty: '1', quality: '0' }])
    setErr(null); setMode('edit')
  }
  const startEdit = () => {
    if (!selected) return
    setDraftId(selected.id); setDraftName(selected.name)
    setDraftRows(selected.items.map(it => ({ template: it.template, name: it.template, qty: String(it.qty), quality: String(it.quality ?? 0) })))
    setErr(null); setMode('edit')
  }

  const draftItems: GiveItemEntry[] = draftRows
    .filter(r => isValidTemplateId(r.template))
    .map(r => ({ template: r.template.trim(), qty: Number(r.qty) || 1, quality: Number(r.quality) || 0 }))
  const canSave = draftName.trim().length > 0 && draftItems.length > 0

  const save = async () => {
    if (!canSave) return
    setSaving(true); setErr(null)
    try {
      const saved = await saveItemPackage({ id: draftId, name: draftName.trim(), items: draftItems })
      setMode('list')
      await load(saved.id)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }
  const remove = async () => {
    if (!selected) return
    setSaving(true); setErr(null)
    try {
      await deleteItemPackage(selected.id)
      await load()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  if (mode === 'edit') {
    return (
      <div className="space-y-3">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Package name</label>
          <input type="text" value={draftName} disabled={saving} maxLength={80}
            placeholder="e.g. Starter survival kit"
            onChange={e => setDraftName(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div className="space-y-3">
          {draftRows.map((row, i) => (
            <div key={i} className="rounded-lg border border-border p-2.5 space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-[11px] uppercase tracking-wider text-text-dim">Item {i + 1}</span>
                <button type="button" disabled={saving} title="Remove item"
                  onClick={() => setDraftRows(rows => rows.filter((_, j) => j !== i))}
                  className="text-text-dim hover:text-error transition-colors">
                  <Icon name="X" size={14} />
                </button>
              </div>
              <ItemPicker value={row.template} displayValue={row.name || row.template}
                onChange={(tpl, item) => setDraftRows(rows => rows.map((r, j) => j === i ? { ...r, template: tpl, name: item ? item.name : '' } : r))}
                disabled={saving} placeholder="type to search by name or template id" />
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
                  <input type="number" min={1} value={row.qty} disabled={saving}
                    onChange={e => setDraftRows(rows => rows.map((r, j) => j === i ? { ...r, qty: e.target.value } : r))}
                    className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                </div>
                <div>
                  <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Tier — Mk1-Mk6 (0-5)</label>
                  <input type="number" min={0} max={5} value={row.quality} disabled={saving}
                    onChange={e => setDraftRows(rows => rows.map((r, j) => j === i ? { ...r, quality: e.target.value } : r))}
                    className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
                </div>
              </div>
            </div>
          ))}
        </div>
        <button className="btn-secondary w-full" disabled={saving}
          onClick={() => setDraftRows(rows => [...rows, { template: '', name: '', qty: '1', quality: '0' }])}>
          <Icon name="Plus" size={13} /> Add item
        </button>
        {err && <div className="text-xs text-error">{err}</div>}
        <div className="grid grid-cols-2 gap-2">
          <button className="btn-secondary" disabled={saving}
            onClick={() => { setMode('list'); setErr(null) }}>
            Cancel
          </button>
          <button className="btn-primary" disabled={saving || !canSave}
            onClick={() => void save()}>
            {saving ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Save package
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      {loading ? (
        <div className="text-xs text-text-dim flex items-center gap-2">
          <Icon name="Loader2" size={12} className="animate-spin" /> Loading packages…
        </div>
      ) : packages.length === 0 ? (
        <div className="text-xs text-text-dim">No packages yet. Create one to reuse a bundle of items.</div>
      ) : (
        <>
          <div>
            <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Package</label>
            <select value={selectedId} disabled={busy || saving}
              onChange={e => setSelectedId(e.target.value)}
              className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50">
              {packages.map(p => <option key={p.id} value={p.id}>{p.name} ({p.items.length})</option>)}
            </select>
          </div>
          {selected && (
            <ul className="text-xs text-text-dim space-y-1 max-h-40 overflow-y-auto rounded-lg border border-border p-2">
              {selected.items.map((it, i) => (
                <li key={i} className="flex items-center gap-2">
                  <Icon name="Box" size={11} className="shrink-0 text-text-dim/70" />
                  <span className="flex-1 min-w-0 truncate font-mono">{it.template}</span>
                  <span className="shrink-0">x{it.qty}{it.quality ? ` · Mk${it.quality + 1}` : ''}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
      {err && <div className="text-xs text-error">{err}</div>}
      {selected && (
        <button className="btn-primary w-full" disabled={busy || saving}
          onClick={() => onGive(selected.items, selected.name)}>
          {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Give to {playerName}
        </button>
      )}
      <div className="grid grid-cols-3 gap-2">
        <button className="btn-secondary" disabled={busy || saving} onClick={startNew}>
          <Icon name="Plus" size={13} /> New
        </button>
        <button className="btn-secondary" disabled={busy || saving || !selected} onClick={startEdit}>
          <Icon name="Pencil" size={13} /> Edit
        </button>
        <button className="btn-secondary" disabled={busy || saving || !selected} onClick={() => void remove()}>
          {saving ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Trash2" size={13} />} Delete
        </button>
      </div>
    </div>
  )
}

// Self-contained vehicle-parts form. Picks a vehicle that has discrete part
// items and previews its Mk6 parts list; submitting hands every part plus a
// Large Vehicle Fuel Cell and a Welding Torch Mk5 into the player's inventory
// via the normal give-item path (works online or offline). Vehicles the game
// has no part items for (Tank / Treadwheel / Container) are omitted — there is
// no DST path to deliver those because the game has no inventory-form of their
// chassis/modules. Shared by both the "Spawn Vehicle" and "Give Vehicle Kit"
// actions, which call the same handler.
function VehicleKitForm({ busy, onSubmit }: {
  busy: boolean; onSubmit: (veh: VehicleTemplate, allowOverflow: boolean) => void
}) {
  const kitVehicles = useMemo(() => VEHICLE_CATALOG.filter(v => v.kit.length > 0), [])
  const [vid, setVid] = useState(kitVehicles[0]?.id ?? '')
  const [names, setNames] = useState<Record<string, string>>({})
  const [overflow, setOverflow] = useState(false)
  const veh = kitVehicles.find(v => v.id === vid) || kitVehicles[0]
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

  // Resolve readable part names from the item catalog for the preview. Falls
  // back to the raw template id if the catalog hasn't loaded or lacks an entry.
  useEffect(() => {
    let cancelled = false
    getItemCatalog()
      .then((cat: CatalogItem[]) => {
        if (cancelled) return
        const map: Record<string, string> = {}
        for (const it of cat) map[it.template_id] = it.name
        setNames(map)
      })
      .catch(() => { /* preview just shows template ids */ })
    return () => { cancelled = true }
  }, [])

  if (!veh) return <div className="text-sm text-text-muted">No vehicles with part kits available.</div>

  const label = (tpl: string) => names[tpl] || tpl
  const qtyOf = (tpl: string) => veh.qty?.[tpl] ?? 1
  const qtySuffix = (tpl: string) => qtyOf(tpl) > 1 ? ` ×${qtyOf(tpl)}` : ''

  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Vehicle</label>
        <select value={vid} disabled={busy} className={selectCls}
          onChange={e => setVid(e.target.value)}>
          {kitVehicles.map(v => <option key={v.id} value={v.id}>{v.label}</option>)}
        </select>
      </div>
      <div className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
        <div className="text-[11px] uppercase tracking-wider text-text-dim mb-1.5">
          Delivers {veh.kit.length + veh.unique.length} part{veh.kit.length + veh.unique.length === 1 ? '' : 's'} (Mk6) + fuel + tool — into the player's inventory (online or offline). Assemble at a Vehicle Assembly.
        </div>
        <ul className="space-y-0.5 text-text-muted">
          {veh.kit.map(tpl => (
            <li key={tpl} className="flex items-center gap-1.5">
              <Icon name="Cog" size={12} className="shrink-0 text-text-dim" /> {label(tpl)}{qtySuffix(tpl)}
            </li>
          ))}
          {veh.unique.map(tpl => (
            <li key={tpl} className="flex items-center gap-1.5 text-ibad">
              <Icon name="Sparkles" size={12} className="shrink-0" /> {label(tpl)}{qtySuffix(tpl)}
            </li>
          ))}
          <li className="flex items-center gap-1.5 text-amber-200/90">
            <Icon name="Fuel" size={12} className="shrink-0" /> {label(VEHICLE_KIT_FUEL_TEMPLATE)}
          </li>
          <li className="flex items-center gap-1.5 text-amber-200/90">
            <Icon name="Wrench" size={12} className="shrink-0" /> {label(VEHICLE_KIT_TORCH_TEMPLATE)}
          </li>
        </ul>
      </div>
      <OverflowToggle checked={overflow} disabled={busy} onChange={setOverflow} />
      <button className="btn-primary w-full" disabled={busy}
        onClick={() => onSubmit(veh, overflow)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Truck" size={13} />} Give Vehicle Kit
      </button>
    </div>
  )
}

// Cheat-script panel. Buttons fire named server cheat scripts (CheatScript
// ServerCommand) for the online player — loadouts, XP, skill/ability unlocks.
// The named scripts are defined server-side in the game's [CheatScript.*] INI;
// DST can only invoke ones the server ships. These are transcribed from the
// Dune: Awakening PLAYTEST server, so they may be absent / no-ops on a retail
// dedicated server (see the disclaimer). A freeform box sends any other name.
const CHEAT_SCRIPTS: { name: string; label: string; desc: string; icon: string; group: string }[] = [
  { name: 'PlaytestSetup',      label: 'Playtest Setup',         desc: 'Full loadout — resets progression, refills, grants a large weapon/armor/consumable kit, awards XP, unlocks skills (items by display name).', icon: 'PackagePlus', group: 'Loadout & Progression' },
  { name: 'PlaytestSetupAdmin', label: 'Playtest Setup (Admin)', desc: 'Same as Playtest Setup but items are referenced by class string only.', icon: 'PackagePlus', group: 'Loadout & Progression' },
  { name: 'AwardPlayerXP',      label: 'Award Player XP',        desc: 'Grants 10,000 XP in each of the three categories.', icon: 'Star', group: 'Loadout & Progression' },
  { name: 'UnlockAllSkills',    label: 'Unlock All Skills',      desc: 'Sets every key skill module and capstone to level 1.', icon: 'Sparkles', group: 'Loadout & Progression' },
  { name: 'UnlockAllAbilities', label: 'Unlock All Abilities',   desc: 'Sets every ability module to level 1.', icon: 'Sparkles', group: 'Loadout & Progression' },
  { name: 'LeaveMeAlone',       label: 'Leave Me Alone',         desc: 'Clears nearby threats and disables environmental hazards (NPCs, sandstorms, worms).', icon: 'ShieldOff', group: 'Utility' },
]

// Dev/perf-test harnesses, kept on a separate action row.
const DEV_SCRIPTS: { name: string; label: string; desc: string; icon: string }[] = [
  { name: 'StartHitchVehicleTest', label: 'Start Hitch Test', desc: 'Dev/perf harness — forces frame hitches and unsteady FPS.', icon: 'Activity' },
  { name: 'StopHitchVehicleTest',  label: 'Stop Hitch Test',  desc: 'Reverts the hitch/FPS performance test.', icon: 'Activity' },
]

function PlaytestDisclaimer() {
  return (
    <div className="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning flex items-start gap-2">
      <Icon name="TriangleAlert" size={14} className="shrink-0 mt-0.5" />
      <span>
        These scripts come from the Dune: Awakening <strong>Playtest</strong> server and are defined server-side. On a
        retail dedicated server they may be absent and have <strong>no effect</strong>. Online players only.
      </span>
    </div>
  )
}

function ScriptButton({ s, busy, onSubmit }: {
  s: { name: string; label: string; desc: string; icon: string }; busy: boolean; onSubmit: (name: string) => void
}) {
  return (
    <button type="button" disabled={busy} onClick={() => onSubmit(s.name)} title={s.desc}
      className="w-full flex items-start gap-2 px-2.5 py-1.5 rounded border border-border bg-surface-2 hover:bg-surface-3 text-left text-sm text-text-muted hover:text-text transition-colors disabled:opacity-60 disabled:cursor-wait">
      <Icon name={s.icon} size={14} className="mt-0.5 shrink-0 text-text-dim" />
      <span className="flex-1 min-w-0">
        <span className="block text-text">{s.label}</span>
        <span className="block text-[11px] text-text-dim">{s.desc}</span>
      </span>
    </button>
  )
}

function CheatScriptForm({ busy, onSubmit }: { busy: boolean; onSubmit: (name: string) => void }) {
  const [freeform, setFreeform] = useState('')
  const groups = ['Loadout & Progression', 'Utility']
  const inputCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  return (
    <div className="space-y-3">
      <PlaytestDisclaimer />
      {groups.map(g => (
        <div key={g}>
          <div className="text-[11px] uppercase tracking-wider text-text-dim mb-1.5">{g}</div>
          <div className="space-y-1.5">
            {CHEAT_SCRIPTS.filter(s => s.group === g).map(s => (
              <ScriptButton key={s.name} s={s} busy={busy} onSubmit={onSubmit} />
            ))}
          </div>
        </div>
      ))}
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Other script name</label>
        <div className="flex gap-2">
          <input type="text" value={freeform} disabled={busy} placeholder="e.g. PlaytestSetup"
            className={inputCls} onChange={e => setFreeform(e.target.value)} />
          <button type="button" className="btn-primary shrink-0" disabled={busy || !freeform.trim()}
            onClick={() => onSubmit(freeform.trim())}>
            {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Send" size={13} />} Send
          </button>
        </div>
      </div>
    </div>
  )
}

function DevScriptForm({ busy, onSubmit }: { busy: boolean; onSubmit: (name: string) => void }) {
  return (
    <div className="space-y-3">
      <PlaytestDisclaimer />
      <div className="space-y-1.5">
        {DEV_SCRIPTS.map(s => (
          <ScriptButton key={s.name} s={s} busy={busy} onSubmit={onSubmit} />
        ))}
      </div>
    </div>
  )
}

// Self-contained whisper form. Renders without a card wrapper.
function WhisperForm({ busy, onSubmit }: { busy: boolean; onSubmit: (msg: string) => void }) {
  const [whisper, setWhisper] = useState('')
  return (
    <div className="space-y-3">
      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Whisper message</label>
      <textarea rows={3} value={whisper} disabled={busy}
        onChange={e => setWhisper(e.target.value)} placeholder="Hello from the admin tool"
        className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 resize-none" />
      <div className="text-[11px] text-text-muted">
        Note: chat/whisper external publish is experimental — broker accepts but the game may silently drop.
      </div>
      <button className="btn-primary w-full" disabled={busy || !whisper.trim()}
        onClick={() => onSubmit(whisper.trim())}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Send" size={13} />} Send Whisper
      </button>
    </div>
  )
}

// Self-contained quick-preset form. Fetches the progression preset catalog on
// mount and applies the chosen preset (completes its journey nodes) by
// account_id. Renders without a card wrapper — ActionRow provides the container.
function QuickPresetsForm({ busy, onSubmit }: { busy: boolean; onSubmit: (presetId: string) => void }) {
  const [presets, setPresets] = useState<ProgressionPreset[]>([])
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  useEffect(() => {
    let alive = true
    setLoading(true)
    getProgressionPresets()
      .then(r => {
        if (!alive) return
        const list = r.presets || []
        setPresets(list)
        setSel(list[0]?.id || '')
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [])

  const chosen = presets.find(p => p.id === sel)
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading presets…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (presets.length === 0) return <div className="text-sm text-text-dim">No presets available.</div>

  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Preset</label>
        <select value={sel} disabled={busy} className={selectCls} onChange={e => setSel(e.target.value)}>
          {presets.map(p => (
            <option key={p.id} value={p.id}>
              {p.name}{typeof p.node_count === 'number' && p.node_count > 0 ? ` (${p.node_count} nodes)` : ''}
            </option>
          ))}
        </select>
      </div>
      {chosen?.description && <div className="text-xs text-text-muted">{chosen.description}</div>}
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => onSubmit(sel)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Zap" size={13} />} Apply Preset
      </button>
    </div>
  )
}

// Self-contained Unlock-Trainers form. Fetches the skill-trainer catalog AND
// the selected character's current ownership on mount, then renders one card
// per trainer type (separated by trainer). Each card shows present values —
// which skill blocks / tree modules the character already has — plus an
// "Unlock" button (completes the trainer's quest line + grants the full job
// skill tree) and a "Reset Skill Tree" button. Renders without a card wrapper.
function UnlockTrainersForm({ busy, accountId, onUnlock, onReset }: {
  busy: boolean
  accountId: number
  onUnlock: (job: string, name: string) => void
  onReset: (job: string, name: string) => void
}) {
  const [trainers, setTrainers] = useState<TrainerInfo[]>([])
  const [status, setStatus] = useState<Record<string, TrainerStatus>>({})
  const [hasPawn, setHasPawn] = useState(true)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  useEffect(() => {
    let alive = true
    setLoading(true)
    Promise.all([
      getTrainerCatalog(),
      getTrainerStatus(accountId).catch(() => null),
    ])
      .then(([cat, st]) => {
        if (!alive) return
        setTrainers(cat.trainers || [])
        if (st) {
          setHasPawn(st.has_pawn)
          const map: Record<string, TrainerStatus> = {}
          for (const j of st.jobs || []) map[j.job] = j
          setStatus(map)
        }
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [accountId])

  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading trainers…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (trainers.length === 0) return <div className="text-sm text-text-dim">No trainers available.</div>

  return (
    <div className="space-y-3">
      <div className="text-[11px] text-text-muted">
        Completes the trainer's starting quest line and grants the full job skill tree. Works online or offline — takes effect on next login.
      </div>
      {!hasPawn && (
        <div className="text-[11px] text-warning">
          This character has no pawn yet (never logged in) — current skill data can't be read, so everything shows as locked.
        </div>
      )}
      <div className="space-y-2">
        {trainers.map(t => {
          const st = status[t.job]
          const owned = st?.blocks_owned ?? 0
          const total = st?.blocks_total ?? t.skill_count
          const isUnlocked = st?.unlocked ?? false
          const isPartial = !isUnlocked && owned > 0
          return (
          <div key={t.job} className="rounded-lg border border-border bg-surface-2 px-3 py-2">
            <div className="flex items-center gap-2 mb-1.5">
              <Icon name="GraduationCap" size={14} className="shrink-0 text-text-dim" />
              <span className="flex-1 min-w-0 text-sm text-text font-medium">{t.name}</span>
              {st?.is_starter && (
                <span className="text-[10px] uppercase tracking-wide rounded px-1.5 py-0.5 bg-surface-3 text-text-dim border border-border">Starter</span>
              )}
              {st && (
                isUnlocked ? (
                  <span className="text-[10px] font-medium rounded px-1.5 py-0.5 bg-success/15 text-success border border-success/30">Unlocked</span>
                ) : isPartial ? (
                  <span className="text-[10px] font-medium rounded px-1.5 py-0.5 bg-warning/15 text-warning border border-warning/30">Partial</span>
                ) : (
                  <span className="text-[10px] font-medium rounded px-1.5 py-0.5 bg-surface-3 text-text-dim border border-border">Locked</span>
                )
              )}
            </div>
            <div className="flex items-center gap-2 mb-1.5 text-[11px] text-text-dim">
              <span>{t.contract_count} quest{t.contract_count === 1 ? '' : 's'}</span>
              <span>·</span>
              <span>{owned}/{total} skill block{total === 1 ? '' : 's'}</span>
              {st && st.modules_total > 0 && (
                <>
                  <span>·</span>
                  <span>{st.modules_owned}/{st.modules_total} tree skills</span>
                </>
              )}
            </div>
            <div className="flex gap-2">
              <button type="button" className="btn-primary flex-1 text-xs" disabled={busy}
                onClick={() => onUnlock(t.job, t.name)}>
                {busy ? <Icon name="Loader2" size={12} className="animate-spin" /> : <Icon name="Unlock" size={12} />} {isUnlocked ? 'Re-grant' : 'Unlock'}
              </button>
              <button type="button" className="btn-secondary shrink-0 text-xs" disabled={busy}
                onClick={() => onReset(t.job, t.name)} title="Reset this job's skill tree">
                <Icon name="RotateCcw" size={12} /> Reset Skill Tree
              </button>
            </div>
          </div>
          )
        })}
      </div>
    </div>
  )
}

// Self-contained Unlock-Main-Quest form. Fetches the main-quest catalog and
// completes the chosen story line (flips every node in the subtree complete).
function UnlockMainQuestForm({ busy, onSubmit }: { busy: boolean; onSubmit: (quest: string, name: string) => void }) {
  const [quests, setQuests] = useState<MainQuestInfo[]>([])
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  useEffect(() => {
    let alive = true
    setLoading(true)
    getMainQuestCatalog()
      .then(r => {
        if (!alive) return
        const list = r.main_quests || []
        setQuests(list)
        setSel(list[0]?.id || '')
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [])

  const chosen = quests.find(q => q.id === sel)
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading main quests…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (quests.length === 0) return <div className="text-sm text-text-dim">No main quests available.</div>

  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Main quest</label>
        <select value={sel} disabled={busy} className={selectCls} onChange={e => setSel(e.target.value)}>
          {quests.map(q => (
            <option key={q.id} value={q.id}>
              {q.name}{q.node_count > 0 ? ` (${q.node_count} nodes)` : ''}
            </option>
          ))}
        </select>
      </div>
      <div className="text-[11px] text-text-muted">
        Flips every node in this story line complete and applies its reward tags. Takes effect on next login.
      </div>
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => onSubmit(sel, chosen?.name || sel)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Flag" size={13} />} Unlock Main Quest
      </button>
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

  const acts = useMemo(() => ACTIONS.filter(a => a.group === ITEMS_GROUP), [])

  if (!canWrite || acts.length === 0) return null

  const openAction = (id: string) => setOpenId(o => (o === id ? null : id))

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
    <div className="space-y-1.5 mb-2">
      {acts.map(a => (
        <ActionRow key={a.id} def={a} player={player} busy={busy} stats={null}
          open={openId === a.id} onToggle={() => openAction(a.id)} runAction={runAction} />
      ))}
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
  const isOnline = (player.online_status || '').toLowerCase() === 'online'

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
        canWrite={canWrite} busy={busy} run={run} isOnline={isOnline}
        extra={<ItemsActionBlock player={player} canWrite={canWrite} flash={flash} onChanged={() => { onChanged(); setTick(t => t + 1) }} />} />
      <ItemList title={`Emotes (${fmtNum(groups.emotes.length)})`} icon="Smile" items={groups.emotes} collapsed
        canWrite={canWrite} busy={busy} run={run} isOnline={isOnline} />
      <ItemList title={`Contract items (${fmtNum(groups.contracts.length)})`} icon="FileText" items={groups.contracts} collapsed
        canWrite={canWrite} busy={busy} run={run} isOnline={isOnline} />
    </div>
  )
}

function ItemList({ title, icon, items, canWrite, busy, run, collapsed, extra, isOnline }: {
  title: string; icon: string; items: InventoryItem[]; canWrite: boolean; busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  collapsed?: boolean
  extra?: React.ReactNode
  isOnline: boolean
}) {
  const [open, setOpen] = useState(!collapsed)
  const [editingId, setEditingId] = useState<number | null>(null)
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
              const waterN = parseFloat(it.water_amount)
              const hasWater = it.water_amount !== 'N/A' && it.water_type === 'Water' && Number.isFinite(waterN)
              const ratio = hasDur ? curN / maxN : 1
              const durCls =
                !hasDur          ? 'text-text-dim' :
                ratio <= 0.0001  ? 'text-danger font-semibold' :
                ratio < 0.25     ? 'text-danger' :
                ratio < 0.5      ? 'text-warning' :
                                   'text-text-dim'
              const canEdit = canWrite && (it.durability !== 'N/A' || hasWater)
              const isEditing = canEdit && editingId === it.id
              const toggleEdit = () => {
                if (!canEdit) return
                setEditingId(prev => (prev === it.id ? null : it.id))
              }
              return (
                <div key={it.id} className="bg-surface-2 rounded-lg border border-border/50">
                  <div
                    className={`flex items-center justify-between text-sm px-3 py-2 ${canEdit ? 'cursor-pointer hover:bg-surface-3/40' : ''}`}
                    onClick={canEdit ? toggleEdit : undefined}
                    role={canEdit ? 'button' : undefined}
                    tabIndex={canEdit ? 0 : undefined}
                    onKeyDown={canEdit ? (e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleEdit() } }) : undefined}
                    title={canEdit ? (isEditing ? 'Hide item editor' : 'Click to edit durability / water') : undefined}
                  >
                    <span className="truncate max-w-[320px]">
                      {canEdit && (
                        <Icon name={isEditing ? 'ChevronDown' : 'ChevronRight'} size={11} className="inline-block mr-1 text-text-dim" />
                      )}
                      <span className="text-text">{it.name || it.template_id}</span>
                      {it.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(it.quality)}`}>Q{it.quality}</span>}
                      {hasDur && (
                        <span className={`ml-1.5 font-mono text-[11px] ${durCls}`} title={`Durability ${curN.toFixed(0)} / ${maxN.toFixed(0)} (${Math.round(ratio * 100)}%)`}>
                          {curN.toFixed(0)}/{maxN.toFixed(0)}
                        </span>
                      )}
                      {hasWater && (
                        <span className="ml-1.5 font-mono text-[11px] text-info" title={`Water ${waterN.toFixed(0)}`}>
                          <Icon name="Droplet" size={10} className="inline-block mr-0.5 -mt-0.5" />{waterN.toFixed(0)}
                        </span>
                      )}
                      <span className="ml-1.5 font-mono text-text-dim text-xs">×{fmtNum(it.stack_size)}</span>
                    </span>
                    {canWrite && (
                      <span className="flex items-center gap-2 shrink-0" onClick={e => e.stopPropagation()}>
                        {it.durability !== 'N/A' && (
                          <button className="text-info hover:text-accent-bright" title="Repair to full (best-guess from catalog)" disabled={busy}
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
                  {isEditing && (
                    <div>
                      {it.durability !== 'N/A' && (
                        <DurabilityEditor item={it} busy={busy} run={run} isOnline={isOnline} onClose={() => setEditingId(null)} />
                      )}
                      {hasWater && (
                        <WaterEditor item={it} busy={busy} run={run} onClose={() => setEditingId(null)} />
                      )}
                    </div>
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

// Inline durability editor — appears underneath an inventory row when the user
// clicks it. Only rendered when the item already has the
// FItemStackAndDurabilityStats nodes (it.durability !== 'N/A'), so if a future
// game patch adds the block to a new item type it picks up the editor
// automatically — no per-template allowlist.
function DurabilityEditor({ item, busy, run, isOnline, onClose }: {
  item: InventoryItem
  busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  isOnline: boolean
  onClose: () => void
}) {
  const cur0 = parseFloat(item.durability)
  const max0 = parseFloat(item.max_durability)
  const [maxStr, setMaxStr] = useState(Number.isFinite(max0) ? String(max0) : '0')
  const [curStr, setCurStr] = useState(Number.isFinite(cur0) ? String(cur0) : '0')
  const [decStr, setDecStr] = useState(Number.isFinite(max0) ? String(max0) : '0')

  const parse = (s: string) => {
    const n = parseFloat(s)
    return Number.isFinite(n) && n >= 0 ? n : null
  }
  const mN = parse(maxStr), cN = parse(curStr), dN = parse(decStr)
  const valid = mN !== null && cN !== null && dN !== null

  return (
    <div className="border-t border-border/50 px-3 py-3 bg-surface-1/60 rounded-b-lg space-y-3">
      <div className="text-[11px] text-text-dim italic flex items-start gap-1.5">
        <Icon name="Info" size={11} className="mt-0.5 shrink-0" />
        <span>
          Repair uses a best-guess maximum from the bundled game-item catalog. The catalog
          can be out of date or missing values for newer items — if Repair gives the wrong
          numbers, edit the fields below and Save instead.
        </span>
      </div>
      {isOnline && (
        <div className="text-[11px] text-warning flex items-start gap-1.5">
          <Icon name="Wifi" size={11} className="mt-0.5 shrink-0" />
          <span>
            Player is online — the game server caches inventory in memory, so the new
            values write to the database immediately but won't appear in-game until the
            player relogs.
          </span>
        </div>
      )}
      <div className="grid grid-cols-3 gap-2">
        <label className="text-xs">
          <div className="text-text-dim mb-1">MaxDurability</div>
          <input
            type="number" inputMode="decimal" step="any" min="0"
            value={maxStr}
            onChange={e => setMaxStr(e.target.value)}
            disabled={busy}
            className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
          />
        </label>
        <label className="text-xs">
          <div className="text-text-dim mb-1">CurrentDurability</div>
          <input
            type="number" inputMode="decimal" step="any" min="0"
            value={curStr}
            onChange={e => setCurStr(e.target.value)}
            disabled={busy}
            className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
          />
        </label>
        <label className="text-xs">
          <div className="text-text-dim mb-1">DecayedMaxDurability</div>
          <input
            type="number" inputMode="decimal" step="any" min="0"
            value={decStr}
            onChange={e => setDecStr(e.target.value)}
            disabled={busy}
            className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
          />
        </label>
      </div>
      <div className="flex items-center justify-end gap-2">
        <button
          type="button"
          className="btn-secondary text-xs"
          disabled={busy}
          onClick={() => run(() => repairInventoryItem(item.id), 'Repair')}
        >
          <Icon name="Wrench" size={12} /> Repair (catalog max)
        </button>
        <button
          type="button"
          className="btn-primary text-xs"
          disabled={busy || !valid}
          onClick={() => {
            if (!valid) return
            void run(() => setItemDurability(item.id, mN!, cN!, dN!), 'Save')
            onClose()
          }}
        >
          <Icon name="Save" size={12} /> Save
        </button>
      </div>
    </div>
  )
}

// Inline water editor — appears underneath an inventory row for any item that
// carries the FFillableItemStats block (water canteens / literjons + stillsuit
// hydration), so new water-holding items pick up the editor automatically with
// no per-template allowlist. Capacity is cooked into the template (no per-item
// max), so only the current amount is editable. The value will NOT reflect
// in-game until the map pod / battlegroup is restarted — the pod caches
// inventory in RAM and flushes it over DB writes on its save tick.
function WaterEditor({ item, busy, run, onClose }: {
  item: InventoryItem
  busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  onClose: () => void
}) {
  const amt0 = parseFloat(item.water_amount)
  const [amtStr, setAmtStr] = useState(Number.isFinite(amt0) ? String(amt0) : '0')
  const n = parseFloat(amtStr)
  const valid = Number.isFinite(n) && n >= 0

  return (
    <div className="border-t border-border/50 px-3 py-3 bg-surface-1/60 rounded-b-lg space-y-3">
      <div className="text-[11px] text-warning flex items-start gap-1.5">
        <Icon name="AlertTriangle" size={11} className="mt-0.5 shrink-0" />
        <span>
          Editing the water amount writes to the database immediately, but the map
          server caches inventory in memory and flushes it back on its save tick.
          The new value will <strong>not</strong> appear in-game until that map's
          pod / the battlegroup is restarted.
        </span>
      </div>
      <div className="text-[11px] text-warning flex items-start gap-1.5">
        <Icon name="Droplet" size={11} className="mt-0.5 shrink-0" />
        <span>
          Filling a container <strong>above its normal capacity</strong> costs
          durability — the further over the limit you go, the more durability the
          overfill requires. If you raise the water well past the container's cap,
          bump this item's durability in the editor above to match, otherwise the
          game may clamp the overfill or burn the container's durability down.
        </span>
      </div>
      <div className="grid grid-cols-2 gap-2 items-end">
        <label className="text-xs">
          <div className="text-text-dim mb-1">Water amount{item.water_type ? ` (${item.water_type})` : ''}</div>
          <input
            type="number" inputMode="decimal" step="any" min="0"
            value={amtStr}
            onChange={e => setAmtStr(e.target.value)}
            disabled={busy}
            className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
          />
        </label>
        <div className="flex items-center justify-end">
          <button
            type="button"
            className="btn-primary text-xs"
            disabled={busy || !valid}
            onClick={() => {
              if (!valid) return
              void run(() => setItemWater(item.id, n), 'Save')
              onClose()
            }}
          >
            <Icon name="Save" size={12} /> Save water
          </button>
        </div>
      </div>
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

interface FieldDef { key: string; label: string; type: 'text' | 'number' | 'select'; placeholder?: string; options?: { value: string; label: string }[] }

function InlineForm({ fields, submitLabel, busy, note, onSubmit }: {
  fields: FieldDef[]; submitLabel: string; busy: boolean; note?: ReactNode; onSubmit: (values: Record<string, string>) => void
}) {
  // Seed select fields with their first option so a dropdown is never submitted
  // empty (the run() handlers also default, but this keeps the UI honest).
  const [values, setValues] = useState<Record<string, string>>(() => {
    const seed: Record<string, string> = {}
    for (const f of fields) {
      if (f.type === 'select' && f.options && f.options.length > 0) seed[f.key] = f.options[0].value
    }
    return seed
  })
  const inputCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  return (
    <div className="space-y-2">
      {note}
      {fields.map(f => (
        <div key={f.key}>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">{f.label}</label>
          {f.type === 'select' ? (
            <select value={values[f.key] ?? f.options?.[0]?.value ?? ''}
              onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
              className={inputCls}>
              {(f.options ?? []).map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          ) : (
            <input type={f.type} value={values[f.key] ?? ''} placeholder={f.placeholder}
              onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
              className={inputCls} />
          )}
        </div>
      ))}
      <button className="btn-primary w-full" disabled={busy} onClick={() => onSubmit(values)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {submitLabel}
      </button>
    </div>
  )
}

const formSelectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 disabled:opacity-50'

// Friendly label for a vehicle actor class basename (e.g. "Ornithopter_Mk6"
// -> "Ornithopter Mk6"). Vehicle ids mean nothing to an admin, so the dropdown
// shows the name + a short id suffix instead.
function prettyVehicle(v: PlayerVehicleRow): string {
  const base = (v.vehicle_name && v.vehicle_name.trim()) ? v.vehicle_name.trim() : (v.class || `Vehicle ${v.id}`)
  const clean = base.replace(/_+/g, ' ').replace(/\bBP /i, '').trim()
  const tags: string[] = []
  if (v.map) tags.push(v.map)
  if (v.is_backup) tags.push('backup')
  return `${clean}${tags.length ? ` — ${tags.join(', ')}` : ''} (#${v.id})`
}

// Refuel Vehicle — pick from the player's actual vehicles instead of typing a
// raw vehicle id the admin can't know.
function RefuelVehicleForm({ busy, controllerId, playerName, onSubmit }: {
  busy: boolean; controllerId: number; playerName: string; onSubmit: (vehicleId: number) => void
}) {
  const [vehicles, setVehicles] = useState<PlayerVehicleRow[]>([])
  const [vid, setVid] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let alive = true
    setLoading(true); setErr('')
    getPlayerVehicles(controllerId)
      .then(r => { if (!alive) return; const vs = r.vehicles || []; setVehicles(vs); setVid(vs[0] ? String(vs[0].id) : '') })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [controllerId])
  if (loading) return <Loading label="Loading vehicles…" />
  if (err) return <ErrorBox msg={err} />
  if (vehicles.length === 0) return <EmptyBox msg={`No vehicles found for ${playerName}.`} />
  return (
    <div className="space-y-2">
      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Vehicle</label>
      <select value={vid} disabled={busy} className={formSelectCls} onChange={e => setVid(e.target.value)}>
        {vehicles.map(v => <option key={v.id} value={v.id}>{prettyVehicle(v)}</option>)}
      </select>
      <button className="btn-primary w-full" disabled={busy || !vid} onClick={() => onSubmit(Number(vid) || 0)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Fuel" size={13} />} Refuel Vehicle
      </button>
    </div>
  )
}

// Set Starter Class — dropdown of the friendly trainer/class names instead of
// a raw "mentat" job id.
function StarterClassForm({ busy, onSubmit }: {
  busy: boolean; onSubmit: (job: string, name: string) => void
}) {
  const [classes, setClasses] = useState<TrainerInfo[]>([])
  const [job, setJob] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let alive = true
    setLoading(true); setErr('')
    getTrainerCatalog()
      .then(r => { if (!alive) return; const c = r.trainers || []; setClasses(c); setJob(c[0]?.job ?? '') })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [])
  if (loading) return <Loading label="Loading classes…" />
  if (err) return <ErrorBox msg={err} />
  if (classes.length === 0) return <EmptyBox msg="No starter classes available." />
  const name = classes.find(c => c.job === job)?.name ?? job
  return (
    <div className="space-y-2">
      <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Starter class</label>
      <select value={job} disabled={busy} className={formSelectCls} onChange={e => setJob(e.target.value)}>
        {classes.map(c => <option key={c.job} value={c.job}>{c.name}</option>)}
      </select>
      <button className="btn-primary w-full" disabled={busy || !job} onClick={() => onSubmit(job, name)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Compass" size={13} />} Set Starter Class
      </button>
    </div>
  )
}

// Update Tags — Remove is a dropdown of the player's CURRENT tags (you can't
// remove one they don't have); Add accepts a new tag, suggesting existing tags
// via a datalist. Avoids the comma-separated raw-text boxes.
function UpdateTagsForm({ busy, accountId, demo, onSubmit }: {
  busy: boolean; accountId: number; demo: boolean; onSubmit: (add: string[], remove: string[]) => void
}) {
  const [current, setCurrent] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  const [addTag, setAddTag] = useState('')
  const [removeTag, setRemoveTag] = useState('')
  useEffect(() => {
    let alive = true
    setLoading(true); setErr('')
    getPlayerTags(accountId, demo)
      .then(r => { if (alive) setCurrent(r.tags || []) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [accountId, demo])
  if (loading) return <Loading label="Loading tags…" />
  if (err) return <ErrorBox msg={err} />
  const add = addTag.trim()
  const remove = removeTag.trim()
  const canSubmit = !!add || !!remove
  return (
    <div className="space-y-2">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Current tags</label>
        {current.length === 0
          ? <div className="text-xs text-text-dim">None.</div>
          : <div className="flex flex-wrap gap-1">{current.map(t => <span key={t} className="text-[11px] px-2 py-0.5 rounded-full bg-surface-3 text-text-muted">{t}</span>)}</div>}
      </div>
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Add tag</label>
        <input list="known-tags" value={addTag} placeholder="vip" disabled={busy}
          onChange={e => setAddTag(e.target.value)} className={formSelectCls} />
        <datalist id="known-tags">
          {['vip', 'tester', 'banned', 'verified', 'staff'].map(t => <option key={t} value={t} />)}
        </datalist>
      </div>
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Remove tag</label>
        <select value={removeTag} disabled={busy || current.length === 0} className={formSelectCls}
          onChange={e => setRemoveTag(e.target.value)}>
          <option value="">{current.length === 0 ? 'No tags to remove' : '— select —'}</option>
          {current.map(t => <option key={t} value={t}>{t}</option>)}
        </select>
      </div>
      <button className="btn-primary w-full" disabled={busy || !canSubmit}
        onClick={() => onSubmit(add ? [add] : [], remove ? [remove] : [])}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Update Tags
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

// ---------------------------------------------------------------------------
// Landsraad — set a player's per-House contribution for the current term, and
// show the [LandsraadSettings] INI config for context (#224). Reads DB (term +
// Houses + the player's present contributions) AND the INI settings.
// ---------------------------------------------------------------------------
function LandsraadSection({ player, canWrite, demo, refreshKey, flash, onChanged }: SectionProps) {
  const [termId, setTermId] = useState(0)
  const [houses, setHouses] = useState<LandsraadHouse[]>([])
  const [settings, setSettings] = useState<LandsraadIniSetting[]>([])
  const [byTask, setByTask] = useState<Record<number, number>>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [editing, setEditing] = useState<number | null>(null)
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [showSettings, setShowSettings] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const ov = await getLandsraadOverview(demo)
      const pc = await getLandsraadPlayerContributions(player.controller_id, demo)
      setTermId(ov.term_id)
      setHouses(ov.houses ?? [])
      setSettings(ov.settings ?? [])
      const map: Record<number, number> = {}
      for (const c of (pc.contributions ?? [])) map[c.task_id] = c.amount
      setByTask(map)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [player.controller_id, demo])

  useEffect(() => { void load() }, [load, refreshKey])

  const beginEdit = (h: LandsraadHouse) => {
    if (!canWrite) return
    setEditing(h.task_id)
    setDraft(String(byTask[h.task_id] ?? 0))
  }

  const save = async (taskId: number) => {
    const amt = parseFloat(draft)
    if (!Number.isFinite(amt) || amt < 0) { flash('Amount must be a number ≥ 0.', 'err'); return }
    setBusy(true)
    try {
      const r = await setLandsraadContribution(player.controller_id, taskId, amt)
      flash(r.message ?? 'Saved.', r.ok ? 'ok' : 'err')
      setEditing(null); onChanged(); await load()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  if (loading) {
    return <div className="flex items-center gap-2 text-sm text-text-muted py-6 justify-center">
      <Icon name="Loader2" size={16} className="animate-spin" /> Loading Landsraad…
    </div>
  }
  if (error) {
    return <div className="card p-3 border-danger/40 bg-danger/10 text-danger text-sm flex items-center gap-2">
      <Icon name="AlertCircle" size={14} /> {error}
    </div>
  }
  if (termId <= 0) {
    return <div className="text-sm text-text-muted py-6 text-center">No active Landsraad term on this server.</div>
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-text">
          <span className="text-text-muted">Current term</span> <span className="font-mono">#{termId}</span>
          <span className="text-text-dim"> · {houses.length} Houses</span>
        </div>
        {!canWrite && <span className="text-[11px] text-text-dim">Read-only (start the battlegroup to edit)</span>}
      </div>

      <div className="text-[11px] text-warning flex items-start gap-1.5">
        <Icon name="AlertTriangle" size={11} className="mt-0.5 shrink-0" />
        <span>
          Setting a contribution writes directly to the live Landsraad tables and
          recomputes the House's faction + guild totals. The player must belong to a
          faction. Changes show in-game on the next Landsraad progress update.
        </span>
      </div>

      <div className="space-y-1">
        {houses.map(h => {
          const cur = byTask[h.task_id] ?? 0
          const isEditing = editing === h.task_id
          const pct = h.goal_amount > 0 ? Math.min(100, Math.round((cur / h.goal_amount) * 100)) : 0
          return (
            <div key={h.task_id} className="bg-surface-2 rounded-lg border border-border/50">
              <div
                className={`flex items-center justify-between text-sm px-3 py-2 ${canWrite ? 'cursor-pointer hover:bg-surface-3/40' : ''}`}
                onClick={canWrite ? () => (isEditing ? setEditing(null) : beginEdit(h)) : undefined}
                role={canWrite ? 'button' : undefined}
                tabIndex={canWrite ? 0 : undefined}
              >
                <span className="truncate">
                  {canWrite && <Icon name={isEditing ? 'ChevronDown' : 'ChevronRight'} size={11} className="inline-block mr-1 text-text-dim" />}
                  <span className="text-text">{h.display_name}</span>
                  {h.completed && <span className="ml-1.5 text-[10px] text-success uppercase tracking-wider">done</span>}
                </span>
                <span className="font-mono text-xs text-text-muted shrink-0" title={`${cur} / ${h.goal_amount} (${pct}%)`}>
                  {fmtNum(cur)}/{fmtNum(h.goal_amount)}
                </span>
              </div>
              {isEditing && (
                <div className="border-t border-border/50 px-3 py-3 bg-surface-1/60 rounded-b-lg flex items-end gap-2" onClick={e => e.stopPropagation()}>
                  <label className="text-xs flex-1">
                    <div className="text-text-dim mb-1">Contribution to House {h.display_name}</div>
                    <input
                      type="number" inputMode="decimal" step="any" min="0"
                      value={draft}
                      onChange={e => setDraft(e.target.value)}
                      disabled={busy}
                      className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
                    />
                  </label>
                  <button type="button" className="btn-primary text-xs" disabled={busy} onClick={() => void save(h.task_id)}>
                    <Icon name="Save" size={12} /> Save
                  </button>
                </div>
              )}
            </div>
          )
        })}
      </div>

      {settings.length > 0 && (
        <div className="border-t border-border/40 pt-3">
          <button type="button" onClick={() => setShowSettings(s => !s)}
            className="flex w-full items-center gap-2 text-xs uppercase tracking-wider text-text-dim hover:text-text mb-2">
            <Icon name={showSettings ? 'ChevronDown' : 'ChevronRight'} size={13} />
            <Icon name="Settings" size={13} />
            <span>Landsraad settings (from UserGame.ini)</span>
          </button>
          {showSettings && (
            <div className="space-y-1">
              <div className="text-[11px] text-text-dim mb-1">These are read-only here — edit them in <span className="text-text">Game Config → Landsraad</span>.</div>
              {settings.map(s => (
                <div key={s.key} className="flex items-center justify-between text-xs px-3 py-1.5 bg-surface-2/40 rounded" title={s.help}>
                  <span className="text-text-muted">{s.label}</span>
                  <span className="font-mono text-text">{s.value ?? '—'}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Journey — full browser over every journey_story_node row for the account.
// Filter tabs (All / Done / Revealed / Reward), node-id search, client-side
// pagination, per-row Complete/Reset, and a Wipe-All control. All writes work
// online or offline (DB writes); they take effect on the player's next login.
// ---------------------------------------------------------------------------
const JOURNEY_PAGE_SIZE = 50
type JourneyFilter = 'all' | 'done' | 'revealed' | 'reward'

export function JourneySection({ player, canWrite, demo, refreshKey, flash, onChanged }: SectionProps) {
  const [nodes, setNodes] = useState<JourneyNode[]>([])
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [filter, setFilter] = useState<JourneyFilter>('all')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(0)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerJourneyNodes(player.account_id, demo)
      .then(r => { if (alive) setNodes(r.nodes || []) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.account_id, demo, refreshKey, tick])

  const counts = useMemo(() => ({
    all: nodes.length,
    done: nodes.filter(n => n.is_complete).length,
    revealed: nodes.filter(n => n.is_revealed).length,
    reward: nodes.filter(n => n.has_pending_reward).length,
  }), [nodes])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return nodes.filter(n => {
      if (filter === 'done' && !n.is_complete) return false
      if (filter === 'revealed' && !n.is_revealed) return false
      if (filter === 'reward' && !n.has_pending_reward) return false
      if (q && !n.node_id.toLowerCase().includes(q)) return false
      return true
    })
  }, [nodes, filter, search])

  useEffect(() => { setPage(0) }, [filter, search])

  const pageCount = Math.max(1, Math.ceil(filtered.length / JOURNEY_PAGE_SIZE))
  const pageClamped = Math.min(page, pageCount - 1)
  const pageRows = filtered.slice(pageClamped * JOURNEY_PAGE_SIZE, (pageClamped + 1) * JOURNEY_PAGE_SIZE)

  const run = async (fn: () => Promise<{ message: string }>) => {
    setBusy(true); setErr(null)
    try {
      const r = await fn()
      flash(r.message, 'ok')
      onChanged()
      setTick(t => t + 1)
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  const wipeAll = () => {
    if (!window.confirm(
      `WIPE ${player.name}'s entire journey and restart it from the beginning? All journey/quest progress is lost. This cannot be undone.`
    )) return
    void run(() => wipeJourney(player.account_id))
  }

  if (loading) return <Loading label="Loading journey…" />

  const tabs: Array<{ id: JourneyFilter; label: string; n: number }> = [
    { id: 'all', label: 'All', n: counts.all },
    { id: 'done', label: 'Done', n: counts.done },
    { id: 'revealed', label: 'Revealed', n: counts.revealed },
    { id: 'reward', label: 'Reward', n: counts.reward },
  ]

  return (
    <div className="space-y-3">
      {err && <ErrorBox msg={err} />}

      <div className="flex flex-wrap items-center gap-2">
        <div className="flex flex-wrap gap-1">
          {tabs.map(t => (
            <button key={t.id} type="button" onClick={() => setFilter(t.id)}
              className={`px-2.5 py-1 rounded-md text-xs border transition-colors ${filter === t.id ? 'bg-ibad/20 border-ibad/50 text-text' : 'bg-surface-2 border-border text-text-muted hover:text-text'}`}>
              {t.label} <span className="text-text-dim">({fmtNum(t.n)})</span>
            </button>
          ))}
        </div>
        <div className="flex-1 min-w-[160px]">
          <input type="text" value={search} onChange={e => setSearch(e.target.value)}
            placeholder="Search node id…"
            className="w-full px-3 py-1.5 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        {canWrite && (
          <button type="button" className="btn-secondary shrink-0 text-xs text-error" disabled={busy} onClick={wipeAll}
            title="Delete every journey node for this account">
            <Icon name="RefreshCw" size={12} /> Wipe All
          </button>
        )}
      </div>

      {nodes.length === 0 ? (
        <EmptyBox msg={demo ? 'Journey browsing is unavailable in demo mode.' : 'No journey nodes recorded for this player yet.'} />
      ) : filtered.length === 0 ? (
        <EmptyBox msg="No nodes match the current filter." />
      ) : (
        <>
          <div className="space-y-1">
            {pageRows.map(n => (
              <div key={n.node_id} className="card px-3 py-2 flex items-center gap-2">
                <span className="flex-1 min-w-0 font-mono text-xs text-text truncate" title={n.node_id}>{n.node_id}</span>
                <div className="flex items-center gap-1 shrink-0">
                  {n.is_complete && <span className="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-success/20 text-success border border-success/40">Done</span>}
                  {n.is_revealed && <span className="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-info/20 text-info border border-info/40">Rev</span>}
                  {n.has_pending_reward && <span className="text-[10px] font-bold uppercase px-1.5 py-0.5 rounded bg-warning/20 text-warning border border-warning/40">Reward</span>}
                </div>
                {canWrite && (
                  <div className="flex items-center gap-1 shrink-0">
                    <button type="button" className="btn-secondary text-[11px] px-2 py-1" disabled={busy}
                      onClick={() => void run(() => completeJourneyNode(player.account_id, n.node_id))}
                      title={n.is_complete ? 'Re-apply completion + reward tags' : 'Complete this node + subtree'}>
                      <Icon name="Check" size={11} /> {n.is_complete ? 'Re-do' : 'Complete'}
                    </button>
                    <button type="button" className="btn-secondary text-[11px] px-2 py-1" disabled={busy}
                      onClick={() => void run(() => resetJourneyNode(player.account_id, n.node_id))}
                      title="Reset this node + subtree">
                      <Icon name="RotateCcw" size={11} /> Reset
                    </button>
                  </div>
                )}
              </div>
            ))}
          </div>

          {pageCount > 1 && (
            <div className="flex items-center justify-between text-xs text-text-dim">
              <span>{fmtNum(filtered.length)} node(s) · page {pageClamped + 1} of {pageCount}</span>
              <div className="flex gap-1">
                <button type="button" className="btn-secondary px-2 py-1" disabled={pageClamped <= 0}
                  onClick={() => setPage(p => Math.max(0, p - 1))}>
                  <Icon name="ChevronLeft" size={13} />
                </button>
                <button type="button" className="btn-secondary px-2 py-1" disabled={pageClamped >= pageCount - 1}
                  onClick={() => setPage(p => Math.min(pageCount - 1, p + 1))}>
                  <Icon name="ChevronRight" size={13} />
                </button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  )
}

// Re-export the section component type for the tab shell.
export type SectionId = 'stats' | 'specs' | 'tags' | 'history' | 'inventory' | 'landsraad' | 'journey' | 'actions'

export const SECTIONS: Array<{ id: SectionId; label: string; icon: string }> = [
  { id: 'stats',     label: 'Stats',     icon: 'User' },
  { id: 'specs',     label: 'Specs',     icon: 'Sparkles' },
  { id: 'inventory', label: 'Inventory', icon: 'Backpack' },
  { id: 'landsraad', label: 'Landsraad', icon: 'Landmark' },
  { id: 'tags',      label: 'Tags',      icon: 'Tag' },
  { id: 'history',   label: 'History',   icon: 'History' },
  { id: 'journey',   label: 'Journey',   icon: 'Map' },
  { id: 'actions',   label: 'Actions',   icon: 'Wand2' },
]

export const SECTION_COMPONENTS: Record<SectionId, (p: SectionProps) => ReactElement> = {
  stats:     StatsSection,
  specs:     SpecsSection,
  tags:      TagsSection,
  history:   HistorySection,
  inventory: InventorySection,
  landsraad: LandsraadSection,
  journey:   JourneySection,
  actions:   ActionsSection,
}
