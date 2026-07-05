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
import { TagPicker } from '../../../components/TagPicker'
import {
  awardCharXp, awardIntel, setSpecLevel, cheatScript, cleanPlayerInventory,
  applyProgressionPreset, getProgressionPresets,
  progressionUnlock, progressionReverse,
  deleteAccount, deleteInventoryItem, deleteTutorials,
  fillWater, getPlayerEvents, getPlayerSpecs,
  getPlayerStats, getPlayerTags, giveFactionRep, giveItem,
  giveScrip, giveSolari, grantAllKeystones, grantLive, grantMaxSpec,
  kickPlayer, refuelVehicle, renamePlayer, repairGear, repairInventoryItem,
  getPlayerVehicles,
  setItemDurability, setItemStack, setItemWater,
  resetAllKeystones, resetAllSpecs, resetJourney, resetProgressionLive, resetSpec,
  restoreDestroyed,
  setFactionTier, setPlayerTags, setSkillPoints,
  setStarterClass, teleportToPlayer, teleportToLocation, setRespawn, getTeleportDestinations, getPlayers, updatePlayerTags, wipeCodex, wipeJourney, resetFaction, snapshotBuilds, getFreshStartSnapshots, restoreBuilds, grantAllSkills,
  chatWhisper, isValidTemplateId, getItemCatalog, getCosmeticsCatalog, type CosmeticEntry,
  parseTcnoPackageText,
  giveItems, getItemPackages, saveItemPackage, deleteItemPackage,
  getLandsraadOverview, getLandsraadPlayerContributions, setLandsraadContribution,
  getPlayerJourneyNodes, completeJourneyNode, resetJourneyNode,
  getTrainerCatalog, getTrainerStatus, unlockTrainer, resetTrainerSkills,
  getMainQuestCatalog, unlockMainQuest,
  getContracts, completeContract,
  getVehicleKitCatalog,
  type Player, type PlayerEvent, type PlayerStats, type ProgressionPreset, type SpecTrackFull,
  type CatalogItem, type ItemPackage, type GiveItemEntry, type FreshStartSnapshot,
  type LandsraadHouse, type LandsraadIniSetting,
  type JourneyNode, type TrainerInfo, type TrainerStatus, type MainQuestInfo,
  type PlayerVehicleRow, type TeleportDestination,
  type VehicleTemplate, type VehicleKitCatalog,
  type ContractRow,
} from '../../../api/gameplay'
import { fmtNum, fmtSolari } from '../shared'

type Flash = (msg: string, kind?: 'ok' | 'err') => void

interface SectionProps {
  player: Player
  canWrite: boolean
  demo: boolean
  refreshKey: number
  flash: Flash
  // Mark that data changed but DON'T trigger a disruptive full refresh — keeps
  // the user's place (open form, selection, scroll) so they can grant several
  // things in a row. The deferred refresh is flushed via onFlush.
  onChanged: () => void
  // Flush any deferred refresh now (full reload). Called when the user collapses
  // the open action, switches player/section, or hits a Refresh control.
  onFlush?: () => void
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
// keystones; per-row controls: editable Level field (set exact level) +
// grant max / reset one track. Level is the game-authoritative value (the
// game keeps level and recomputes xp from it on login); xp is shown read-only.
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
                onSetLevel={(level) => {
                  if (window.confirm(`Set ${name} to level ${level} for ${player.name}?\n\nThis writes the track's level directly, which the game treats as authoritative on next login (it recomputes the track's XP from this level). If the character has in-game spec progress not yet saved to the server, it can be overwritten (the stored value wins). Make sure you have a database backup before using this. The change appears in-game after a full re-login.`)) {
                    void run(() => setSpecLevel(player.controller_id, name, level), 'Set level')
                  }
                }}
              />
            )
          })}
        </div>
      )}
    </div>
  )
}

const SPEC_TRACK_ORDER = ['Combat', 'Crafting', 'Exploration', 'Gathering', 'Sabotage']

function SpecRow({ name, track, canWrite, busy, onGrantMax, onReset, onSetLevel }: {
  name: string; track: SpecTrackFull | undefined; canWrite: boolean; busy: boolean
  onGrantMax: () => void; onReset: () => void; onSetLevel: (level: number) => void
}) {
  const xp = track?.xp ?? 0
  const level = Math.round(track?.level ?? 0)
  const xpMax = track?.xp_max ?? 44182
  const levelMax = Math.round(track?.level_max ?? 100)
  const pct = Math.min(100, Math.max(0, (level / levelMax) * 100))

  const [draft, setDraft] = useState<string>(String(level))
  // Re-sync the field to the live value whenever the track reloads.
  useEffect(() => { setDraft(String(level)) }, [level])

  const parsed = Math.trunc(Number(draft))
  const valid = draft.trim() !== '' && Number.isFinite(parsed) && parsed >= 0 && parsed <= levelMax
  const changed = valid && parsed !== level

  return (
    <div className="card p-3">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-[140px]">
          <div className="text-sm font-medium text-text">{name}</div>
          <div className="text-[11px] text-text-dim font-mono">Lv {level}/{levelMax} · {fmtNum(xp)}/{fmtNum(xpMax)} xp</div>
        </div>
        {canWrite ? (
          <>
            <div className="flex-1 mx-2 flex items-center gap-2">
              <input
                type="range" min={0} max={levelMax} step={1}
                className="flex-1 h-1.5 accent-accent cursor-pointer disabled:cursor-not-allowed"
                value={valid ? parsed : level} disabled={busy}
                title={`Drag to set level (0–${levelMax})`}
                onChange={e => setDraft(e.target.value)}
              />
              <span className="text-[11px] text-text-dim font-mono w-14 text-right tabular-nums">
                Lv {valid ? parsed : level}/{levelMax}
              </span>
            </div>
            <div className="flex items-center gap-1.5 shrink-0">
              <input
                type="number" inputMode="numeric" step={1} min={0} max={levelMax}
                className="w-16 font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1" value={draft} disabled={busy}
                title={`Set exact level (0–${levelMax})`}
                onChange={e => setDraft(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter' && changed) onSetLevel(parsed) }}
              />
              <button className="btn-secondary" disabled={busy || !changed} title={`Set level to typed value (0–${levelMax})`} onClick={() => onSetLevel(parsed)}>
                <Icon name="Check" size={13} /> Set
              </button>
              <button className="btn-secondary" disabled={busy} title="Grant max level for this track" onClick={onGrantMax}>
                <Icon name="ChevronsUp" size={13} /> Max
              </button>
              <button className="btn-secondary text-warning" disabled={busy} title="Reset this track" onClick={onReset}>
                <Icon name="RotateCcw" size={13} />
              </button>
            </div>
          </>
        ) : (
          <div className="flex-1 mx-2">
            <div className="h-1.5 bg-surface-2 rounded-full overflow-hidden">
              <div className="h-full bg-accent" style={{ width: `${pct}%` }} />
            </div>
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
  const [filter, setFilter] = useState('')
  const [dirty, setDirty] = useState(false)
  const [unsupported, setUnsupported] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())

  useEffect(() => {
    let alive = true
    setLoading(true); setErr(null); setDirty(false)
    getPlayerTags(player.account_id, demo)
      .then(r => { if (alive) { setTags(r.tags); setUnsupported(Boolean(r.unsupported)) } })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.account_id, demo, refreshKey])

  const add = () => addTagValue(draft)
  const addTagValue = (raw: string) => {
    const t = raw.trim()
    if (!t) return
    if (tags.includes(t)) { setDraft(''); return }
    setTags([...tags, t].sort())
    setDraft('')
    setDirty(true)
  }
  const addTagValues = (raws: string[]) => {
    const cleaned = raws.map(r => r.trim()).filter(Boolean)
    if (cleaned.length === 0) return
    const next = Array.from(new Set([...tags, ...cleaned])).sort()
    if (next.length !== tags.length) { setTags(next); setDirty(true) }
    setDraft('')
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

  // Group tags by first dot-segment prefix.
  const groupedTags = useMemo(() => {
    const lc = filter.toLowerCase()
    const filtered = lc ? tags.filter(t => t.toLowerCase().includes(lc)) : tags
    const groups = new Map<string, string[]>()
    for (const t of filtered) {
      const dot = t.indexOf('.')
      const prefix = dot > 0 ? t.slice(0, dot) : '(Other)'
      const arr = groups.get(prefix)
      if (arr) arr.push(t)
      else groups.set(prefix, [t])
    }
    return Array.from(groups.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([prefix, items]) => ({ prefix, items: items.sort() }))
  }, [tags, filter])

  const toggleCollapse = (prefix: string) => {
    setCollapsed(prev => {
      const next = new Set(prev)
      if (next.has(prefix)) next.delete(prefix)
      else next.add(prefix)
      return next
    })
  }

  const totalFiltered = groupedTags.reduce((n, g) => n + g.items.length, 0)

  if (loading) return <Loading label="Loading tags…" />

  return (
    <div className="space-y-3">
      {err && <ErrorBox msg={err} />}
      {unsupported && (
        <div className="card p-3 text-xs text-text-muted border-l-2 border-warning">
          The live game database has no <code className="text-text">dune.player_tags</code> table — feature unavailable.
        </div>
      )}

      {canWrite && !unsupported && (
        <div className="flex gap-2 items-start">
          <TagPicker value={draft} onChange={setDraft} exclude={tags}
            onPick={addTagValue} onPickMany={addTagValues} onEnterRaw={add} disabled={busy}
            placeholder="Search tags to add by name or id…" />
          <button className="btn-secondary" onClick={add} disabled={busy || !draft.trim()}>
            <Icon name="Plus" size={13} /> Add
          </button>
          <button className="btn-primary" onClick={save} disabled={busy || !dirty}>
            <Icon name="Save" size={13} /> Save
          </button>
        </div>
      )}

      {tags.length === 0 ? (
        <EmptyBox msg="No tags. Add one above." />
      ) : (
        <>
          {/* Filter existing tags */}
          <div className="relative">
            <input
              type="text"
              value={filter}
              onChange={e => setFilter(e.target.value)}
              placeholder="Filter tags…"
              className="w-full pl-9 pr-3 py-1.5 rounded-lg bg-surface-2 border border-border text-text text-xs focus:outline-none focus:ring-1 focus:ring-ibad"
            />
            <Icon name="Filter" size={13} className="absolute left-3 top-1/2 -translate-y-1/2 text-text-dim pointer-events-none" />
            {filter && (
              <button type="button" className="absolute right-2 top-1/2 -translate-y-1/2 text-text-dim hover:text-text"
                onClick={() => setFilter('')}><Icon name="X" size={13} /></button>
            )}
          </div>

          <div className="text-[11px] text-text-dim">
            {fmtNum(totalFiltered)} tag{totalFiltered === 1 ? '' : 's'} in {groupedTags.length} group{groupedTags.length === 1 ? '' : 's'}
            {filter && ` (filtered from ${fmtNum(tags.length)})`}
          </div>

          <div className="space-y-1">
            {groupedTags.map(g => {
              const isCollapsed = collapsed.has(g.prefix)
              return (
                <div key={g.prefix} className="rounded-lg border border-border/60 overflow-hidden">
                  <button
                    type="button"
                    onClick={() => toggleCollapse(g.prefix)}
                    className="w-full flex items-center gap-2 px-3 py-2 bg-surface-2/60 hover:bg-surface-2 text-left"
                  >
                    <Icon name={isCollapsed ? 'ChevronRight' : 'ChevronDown'} size={13} className="text-text-dim shrink-0" />
                    <span className="text-xs font-medium text-text">{g.prefix}</span>
                    <span className="text-[11px] text-text-dim">({g.items.length})</span>
                  </button>
                  {!isCollapsed && (
                    <div className="divide-y divide-border/40">
                      {g.items.map(t => {
                        const suffix = t.indexOf('.') > 0 ? t.slice(t.indexOf('.') + 1) : t
                        return (
                          <div key={t} className="px-3 py-1.5 flex items-center gap-2 hover:bg-surface-2/30">
                            <span className="flex-1 min-w-0">
                              <span className="block text-xs text-text truncate" title={t}>{suffix}</span>
                            </span>
                            {canWrite && !unsupported && (
                              <button type="button" className="btn-secondary text-[11px] px-2 py-0.5 text-error shrink-0"
                                onClick={() => remove(t)} title={`Remove ${t}`}>
                                <Icon name="X" size={11} /> Remove
                              </button>
                            )}
                          </div>
                        )
                      })}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        </>
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
  experimental?: boolean  // unverified — may not take effect in-game; shown with an EXPERIMENTAL badge
  fields?: ActionField[]
  custom?: 'give-item' | 'grant-reward' | 'whisper' | 'spawn-vehicle' | 'quick-presets' | 'vehicle-kit' | 'give-package' | 'cheat-scripts' | 'dev-scripts' | 'unlock-trainers' | 'unlock-mainquest' | 'complete-contract' | 'progression-unlock' | 'refuel-vehicle' | 'starter-class' | 'update-tags' | 'teleport-player' | 'teleport-location' | 'set-respawn' | 'reset-faction' | 'grant-cosmetic' | 'fresh-start'
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
  { id: 'grant-live', group: 'Currency', label: 'Grant Reward (popup)', icon: 'Gift', custom: 'grant-reward',
    rowNote: 'Sends a Claim Rewards popup — works online or offline',
    run: () => Promise.resolve({ message: '' }) },

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
  { id: 'apply-progression-preset', group: 'Progression', label: 'Apply Quick Preset', icon: 'Zap', custom: 'quick-presets', offlineOnly: true,
    rowNote: 'Completes a story/journey chapter instantly — incl. Find the Fremen (3rd ability slot + prescience). Player must be offline.',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'progression-unlock', group: 'Progression', label: 'Progression Unlock', icon: 'Milestone', custom: 'progression-unlock',
    rowNote: 'Completes DA_FQ_ClimbTheRanks journey nodes + writes faction tier tags',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'unlock-trainers', group: 'Progression', label: 'Unlock Trainers', icon: 'GraduationCap', custom: 'unlock-trainers',
    rowNote: 'Complete a skill-trainer quest line + grant its skill tree — separated by trainer',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'unlock-main-quest', group: 'Progression', label: 'Unlock Main Quest', icon: 'Flag', custom: 'unlock-mainquest',
    rowNote: 'Complete an entire main-quest story line',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'complete-contract', group: 'Progression', label: 'Complete Contract', icon: 'Check', custom: 'complete-contract', offlineOnly: true,
    rowNote: 'Force-complete a stuck / in-flight contract — writes its completion tags and dismisses the active contract item',
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
    doubleConfirm: true,
    rowNote: 'Double confirmation required',
    confirm: p => `WIPE ${p.name}'s entire journey and restart it from the beginning? All journey/quest progress is lost. This cannot be undone.\n\n` +
      `This is the FIRST of two confirmations. If you continue, the next step asks you to type an acknowledgement before the journey is wiped.`,
    run: p => {
      const typed = window.prompt(
        `SECOND confirmation — WIPE ${p.name}'s journey.\n` +
        `This cannot be undone.\n\n` +
        `Type  i acknowledge  to proceed:`
      ) || ''
      if (typed.trim().toLowerCase() !== 'i acknowledge') {
        throw new Error('Did not type "i acknowledge" — wipe aborted.')
      }
      return wipeJourney(p.account_id)
    } },
  { id: 'reset-faction', group: 'Progression', label: 'Reset Faction', icon: 'Swords', custom: 'reset-faction', offlineOnly: true,
    rowNote: 'Wipe faction rep + tags + ClimbTheRanks nodes. Optional Deep also clears codex. Offline.',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'fresh-start', group: 'Progression', label: 'Fresh Start (keep purchases)', icon: 'Sunrise', custom: 'fresh-start',
    rowNote: 'Snapshot cosmetics, delete + recreate character in-game (same name), then restore. Offline to restore.',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'grant-all-skills', group: 'Progression', label: 'Enable All Skills', icon: 'Sparkles', offlineOnly: true,
    rowNote: 'Only do this AFTER applying "Unlock Trainers" above. Do NOT use this if you plan to level some skill trainer trees yourself. Enables every skill (multi-level left below max) + a ~20 skill-point buffer + 100 Intel. Offline.',
    confirm: p => `Enable all skills for ${p.name}?\n\nOnly do this AFTER applying "Unlock Trainers". Do NOT use this if you plan to level some skill trainer trees yourself.\n\nUnlocks all 145 skills but leaves multi-level skills BELOW max on purpose so the tutorial step "Learn a new Ability from the Skills menu" stays completable (maxing everything soft-locks it). Also grants a small (~20) spendable skill-point buffer and tops Intel to 100 so nothing gates. Existing progress preserved. Player must be offline.`,
    run: p => grantAllSkills(p.account_id) },
  // Grant All Tech Recipes — DISABLED pending rework. The DB write marks every
  // recipe UnlockedState="Purchased", but in-game the items stay unclaimed/0-cost
  // and Intel isn't consumed, so buildables are not actually usable. Backend
  // (Invoke-DunePlayerGrantAllTech, the /grant-all-tech route, grantAllTech() in
  // the API, and dune-tech-catalog.json) is intentionally left in place so this
  // can be revisited once the correct "researched/usable" state is worked out.
  // { id: 'grant-all-tech', group: 'Progression', label: 'Grant All Tech Recipes', icon: 'BookOpenCheck', offlineOnly: true,
  //   rowNote: 'Purchase every buildable + recipe + starter group. Existing preserved. Tops Intel up to 5000 so recipes can be redeemed. Offline.',
  //   confirm: p => `Grant every tech recipe to ${p.name}?\n\nMarks every buildable patent, crafting recipe, and starter group (449 total) as Purchased in the Intel terminal, and tops the character's Intel up to at least 5000 (a higher balance is left untouched) so the recipes can actually be redeemed on next login. Existing entries preserved. Player must be offline.`,
  //   run: p => grantAllTech(p.account_id) },

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
  { id: 'grant-cosmetic', group: 'Items', label: 'Grant Cosmetic / Building Set', icon: 'Shirt', custom: 'grant-cosmetic',
    rowNote: 'Unlock appearance variants, swatches, vehicle skins & building sets — works online or offline',
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
  { id: 'teleport', group: 'Live', label: 'Teleport To Player', icon: 'Move', custom: 'teleport-player',
    rowNote: 'Move this player to another player (pick by name)',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'teleport-location', group: 'Live', label: 'Teleport To Location', icon: 'MapPin', offlineOnly: true, custom: 'teleport-location',
    rowNote: 'Move this player to a map or hub (Hagga Basin, Deep Desert, Arrakeen…). Player must be offline.',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'set-respawn', group: 'Live', label: 'Set Respawn Location', icon: 'Tent', offlineOnly: true, custom: 'set-respawn',
    rowNote: 'Add a respawn point at a map or hub (keeps existing ones). Player must be offline.',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'whisper', group: 'Live', label: 'Whisper', icon: 'MessageCircle', liveOnly: true, custom: 'whisper',
    run: () => Promise.resolve({ message: '' }) },
  { id: 'cheat-script', group: 'Live', label: 'Cheat Scripts', icon: 'Terminal', liveOnly: true, custom: 'cheat-scripts',
    doubleConfirm: true,
    rowNote: 'Fire a server cheat script — loadouts, XP, unlock skills/abilities. Online only · Double confirmation required',
    confirm: p => `Run a cheat script on ${p.name}?\n\n` +
      `This is the FIRST of two confirmations. Cheat scripts run server-side game commands (loadouts, XP, skill/ability unlocks) and cannot be undone. If you continue, the next step asks you to type an acknowledgement before the script fires.`,
    run: () => Promise.resolve({ message: '' }) },
  { id: 'dev-scripts', group: 'Live', label: 'Dev / Perf Scripts', icon: 'FlaskConical', liveOnly: true, custom: 'dev-scripts',
    doubleConfirm: true,
    rowNote: 'Developer performance-test harnesses (hitch tests). Playtest-only, online only · Double confirmation required',
    confirm: p => `Run a dev/perf script on ${p.name}?\n\n` +
      `This is the FIRST of two confirmations. These are developer performance-test harnesses that change the running game session. If you continue, the next step asks you to type an acknowledgement before the script fires.`,
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

  // ----- Danger Zone -----
  { id: 'delete-account', group: 'Danger', label: 'Delete Account (permanent)', icon: 'AlertTriangle',
    doubleConfirm: true,
    offlineOnly: true,
    rowNote: 'Double confirmation required — character must be offline',
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

export function ActionsSection({ player, canWrite, demo, flash, onChanged, onFlush }: SectionProps) {
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
  // Toggling an action: opening one leaves the user's place alone; closing or
  // switching away from the currently-open action flushes any deferred refresh.
  const openAction = (id: string) => {
    if (openId) onFlush?.()
    setOpenId(o => (o === id ? null : id))
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
      // Keep the form OPEN (grant several in a row) + mark deferred refresh only.
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
        <span className="flex-1 min-w-0 font-medium">{def.label}</span>
        {def.experimental && (
          <span className="text-[10px] font-bold uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/20 text-accent border border-accent/50 shrink-0" title="Experimental — may not take effect in-game">EXPERIMENTAL</span>
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
          {def.rowNote && (
            <div className="text-xs text-text-dim italic mb-3 leading-relaxed">{def.rowNote}</div>
          )}
          {def.custom === 'give-item' ? (
            <GiveItemForm busy={busy} submitLabel={def.label}
              onSubmit={(tpl, qty, qual, overflow) => runAction(def, () => giveItem(player.id, tpl, qty, qual, overflow))}
              onSubmitTierSet={(tpl, qty, overflow) => runAction(def, async () => {
                for (let q = 0; q <= 5; q++) await giveItem(player.id, tpl, qty, q, overflow)
                return { message: `Gave ${tpl} Mk1–Mk6 (x${qty} each) to ${player.name}.` }
              })} />
          ) : def.custom === 'grant-reward' ? (
            <GrantRewardForm busy={busy} submitLabel={def.label}
              onSubmit={(tpl, amount) => runAction(def, () => grantLive(player.controller_id, tpl, amount))} />
          ) : def.custom === 'whisper' ? (
            <WhisperForm busy={busy}
              onSubmit={msg => runAction(def, () => chatWhisper(String(player.id), msg))} />
          ) : def.custom === 'spawn-vehicle' || def.custom === 'vehicle-kit' ? (
            <VehicleKitForm busy={busy}
              onSubmit={(veh, parts, overflow) => runAction(def, async () => {
                for (const tpl of parts) await giveItem(player.id, tpl, veh.qty?.[tpl] ?? 1, 0, overflow)
                const count = veh.kit.length + veh.unique.length
                return { message: `Gave ${veh.label} kit — ${count} part${count === 1 ? '' : 's'} + Large Fuel Cell + Welding Torch Mk5 to ${player.name}.` }
              })} />
          ) : def.custom === 'cheat-scripts' ? (
            <CheatScriptForm busy={busy}
              onSubmit={name => runAction(def, async () => {
                const typed = window.prompt(
                  `SECOND confirmation — fire cheat script "${name}" on ${player.name}.\n` +
                  `This runs a server-side cheat command and cannot be undone.\n\n` +
                  `Type  i acknowledge  to proceed:`
                ) || ''
                if (typed.trim().toLowerCase() !== 'i acknowledge') {
                  return Promise.reject(new Error('Did not type "i acknowledge" — cheat script aborted.'))
                }
                await cheatScript({ actor_id: player.id }, name)
                return { message: `Sent cheat script "${name}" to ${player.name}.` }
              })} />
          ) : def.custom === 'dev-scripts' ? (
            <DevScriptForm busy={busy}
              onSubmit={name => runAction(def, async () => {
                const typed = window.prompt(
                  `SECOND confirmation — fire dev script "${name}" on ${player.name}.\n` +
                  `This runs a server-side dev/perf command and cannot be undone.\n\n` +
                  `Type  i acknowledge  to proceed:`
                ) || ''
                if (typed.trim().toLowerCase() !== 'i acknowledge') {
                  return Promise.reject(new Error('Did not type "i acknowledge" — dev script aborted.'))
                }
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
          ) : def.custom === 'complete-contract' ? (
            <CompleteContractForm busy={busy}
              onSubmit={(contractId, label) => runAction(def, async () => {
                const r = await completeContract(player.account_id, contractId)
                return { message: r.message || `Completed contract "${label}" for ${player.name}.` }
              })} />
          ) : def.custom === 'progression-unlock' ? (
            <ProgressionUnlockForm busy={busy}
              onUnlock={(faction, preset, presetName) => runAction(def, async () => {
                const r = await progressionUnlock(player.id, faction, preset)
                return { message: r.message || `Progression unlock (${presetName}) applied for ${player.name}.` }
              })}
              onReverse={(faction, preset, presetName) => runAction(def, async () => {
                const r = await progressionReverse(player.id, faction, preset)
                return { message: r.message || `Progression unlock (${presetName}) reversed for ${player.name}.` }
              })} />
          ) : def.custom === 'reset-faction' ? (
            <ResetFactionForm busy={busy} playerName={player.name}
              onReset={(deep) => runAction(def, async () => {
                const r = await resetFaction(player.account_id, 'both', deep)
                return { message: r.message || `Reset faction for ${player.name}.` }
              })} />
          ) : def.custom === 'fresh-start' ? (
            <FreshStartForm busy={busy} player={player} runAction={runAction} />
          ) : def.custom === 'give-package' ? (
            <GivePackageForm busy={busy} playerName={player.name}
              onGive={(items, pkgName, overflow) => runAction(def, async () => {
                await giveItems(player.id, items, overflow)
                const n = items.length
                return { message: `Gave package "${pkgName}" — ${n} item${n === 1 ? '' : 's'} to ${player.name}.` }
              })} />
          ) : def.custom === 'grant-cosmetic' ? (
            <GrantCosmeticForm busy={busy} playerName={player.name}
              onGrant={(tpl, label) => runAction(def, async () => {
                const r = await giveItem(player.id, tpl, 1, 0, true)
                return { message: r.message || `Granted "${label}" to ${player.name}.` }
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
                return setStarterClass(player.account_id, job)
              })} />
          ) : def.custom === 'update-tags' ? (
            <UpdateTagsForm busy={busy} accountId={player.account_id} demo={false}
              onSubmit={(add, remove) => runAction(def, () => updatePlayerTags(player.account_id, add, remove))} />
          ) : def.custom === 'teleport-player' ? (
            <TeleportPlayerForm busy={busy} self={player}
              onSubmit={(targetPawnId, targetName) => runAction(def, async () => {
                const r = await teleportToPlayer(player.id, targetPawnId)
                return { message: r.message || `Teleported ${player.name} to ${targetName}.` }
              })} />
          ) : def.custom === 'teleport-location' ? (
            <DestinationForm busy={busy} submitLabel="Teleport To Location" icon="MapPin"
              note="Moves the player to the chosen map/hub. Player must be offline; takes effect on next login."
              onSubmit={(destId, destLabel) => runAction(def, async () => {
                const r = await teleportToLocation(player.account_id, destId)
                return { message: r.message || `Teleported ${player.name} to ${destLabel}.` }
              })} />
          ) : def.custom === 'set-respawn' ? (
            <DestinationForm busy={busy} submitLabel="Set Respawn Location" icon="Tent"
              note="Adds a respawn point at the chosen map/hub (existing respawn points are kept). Player must be offline; takes effect on next login."
              onSubmit={(destId, destLabel) => runAction(def, async () => {
                const r = await setRespawn(player.account_id, destId)
                return { message: r.message || `Set ${player.name}'s respawn to ${destLabel}.` }
              })} />
          ) : (
            <InlineForm busy={busy} submitLabel={def.label} fields={def.fields || []} note={balanceNote}
              onSubmit={v => runAction(def, () => def.run(player, v))} />
          )}
        </div>
      )}
    </div>
  )
}

// Fresh Start (keep purchases) - after live-comparing what the game's own
// Funcom in-game delete flow does vs what DST was doing, we ripped out the
// "detach" / "wipe" middleware entirely. The game's purge (fired when a
// player creates a new character on a world that has their deleted one)
// correctly handles ownership cleanup: it wipes every rank=1 row the old
// character's controllers held, keeps rank=2+ co-owner rows, and marks
// the old encrypted_player_state.character_state='Deleted'. Physical
// totems/actors/buildings stay in the world. So DST no longer touches
// any of that - the game does it right.
//
// DST's only role is bracketing the delete: snapshot purchases BEFORE the
// player deletes in-game (so we can put them back), and restore AFTER the
// player has recreated the character with the same name.
function FreshStartForm({ busy, player, runAction }: {
  busy: boolean
  player: Player
  runAction: (def: ActionDef, exec: () => Promise<{ message: string }>) => void
}) {
  const [snap, setSnap] = useState<FreshStartSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const refresh = () => {
    setLoading(true)
    getFreshStartSnapshots()
      .then(r => setSnap((r.snapshots || []).find(s => s.name.toLowerCase() === player.name.toLowerCase()) || null))
      .catch(() => setSnap(null))
      .finally(() => setLoading(false))
  }
  useEffect(() => { refresh() }, [player.name])
  const localDef: ActionDef = { id: 'fresh-start', group: 'Progression', label: 'Fresh Start', icon: 'Sunrise', run: () => Promise.resolve({ message: '' }) }

  return (
    <div className="space-y-3 text-sm">
      <div className="rounded-lg bg-surface-2 border border-border/50 p-3 text-text-dim text-xs leading-relaxed">
        DST brackets the game's built-in character-delete + character-recreate flow so purchases carry over. The game handles the actual delete correctly on its own: it wipes ownership on your solo-owned vehicles/bases and leaves your co-owner grants on others' stuff intact.
      </div>

      <div className="rounded-lg bg-info/10 border border-info/40 p-3 text-info text-xs leading-relaxed">
        <b>Pro tip - clean up before you delete:</b> pick up your fiefs and disassemble your vehicles first. That way the game has nothing abandoned to "gift" to co-owners or leave sitting for other players to claim, and your new character starts on truly empty ground.
      </div>

      <div className="card p-3 space-y-2">
        <div className="font-medium text-text flex items-center gap-2"><Icon name="Save" size={14} /> Step 1 - Snapshot purchases</div>
        <div className="text-text-dim text-xs">Saves {player.name}'s purchased CHOAM/MTX sets, pieces, and cosmetics to <code className="text-text">%APPDATA%\DuneServer\fresh-start-snapshots.json</code>. Do this <b className="text-text">before</b> deleting in-game (the data goes with the character).</div>
        <button type="button" disabled={busy}
          className="px-3 py-2 rounded-lg bg-ibad/20 border border-ibad/50 text-text hover:bg-ibad/30 disabled:opacity-50 text-sm font-medium"
          onClick={() => runAction(localDef, async () => {
            const r = await snapshotBuilds(player.account_id)
            refresh()
            return { message: r.message || `Snapshot saved for ${player.name}.` }
          })}>
          Snapshot {player.name}'s purchases
        </button>
      </div>

      <div className="card p-3 space-y-2">
        <div className="font-medium text-text flex items-center gap-2"><Icon name="Gamepad2" size={14} /> Step 2 - Delete in-game</div>
        <div className="text-text-dim text-xs leading-relaxed">Once the snapshot is saved, exit to the main menu, open <b className="text-text">Server Browser</b>, right-click your world, and delete {player.name}. Then create a new character with the <b className="text-text">same name</b>. The game will prompt "<i>Character data detected... this will purge the deleted character</i>" - confirm it. The game will strip ownership on your solo-owned stuff, keep your co-owner grants on others' stuff, and leave your physical bases in the world for you (or anyone else) to claim on the new character.</div>
      </div>

      <div className="card p-3 space-y-2">
        <div className="font-medium text-text flex items-center gap-2"><Icon name="Sunrise" size={14} /> Step 3 - Restore purchases by name</div>
        {loading ? (
          <div className="text-text-dim text-xs flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Checking snapshots...</div>
        ) : snap ? (
          <>
            <div className="text-text-dim text-xs">Saved snapshot for <b className="text-text">{snap.name}</b> - {snap.sets} set{snap.sets === 1 ? '' : 's'}, {snap.pieces} piece{snap.pieces === 1 ? '' : 's'}{snap.cosmetics ? ' + cosmetics' : ''} ({new Date(snap.saved_at).toLocaleString()}). Restore filters to purchased-only (CHOAM + MTX).</div>
            <div className="text-warning text-xs">Only after you've recreated the character (same name) and spawned in. Player must be offline.</div>
            <button type="button" disabled={busy}
              className="px-3 py-2 rounded-lg bg-info/20 border border-info/50 text-text hover:bg-info/30 disabled:opacity-50 text-sm font-medium"
              onClick={() => runAction(localDef, async () => {
                const r = await restoreBuilds(player.name)
                return { message: r.message || `Restored purchases for ${player.name}.` }
              })}>
              Restore {player.name}'s purchases
            </button>
          </>
        ) : (
          <div className="text-text-dim text-xs">No saved snapshot for {player.name}. Run Step 1 first.</div>
        )}
      </div>
    </div>
  )
}

// Teleport To Player — fetches the roster and picks the target by NAME (resolving
// to the target's pawn id behind the scenes), so admins never type a raw pawn id.
function TeleportPlayerForm({ busy, self, onSubmit }: {
  busy: boolean; self: Player; onSubmit: (targetPawnId: number, targetName: string) => void
}) {
  const [players, setPlayers] = useState<Player[]>([])
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let alive = true
    setLoading(true)
    getPlayers()
      .then(r => {
        if (!alive) return
        const list = (r.players || []).filter(p => p.id !== self.id)
        setPlayers(list)
        setSel(list[0] ? String(list[0].id) : '')
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [self.id])
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading players…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (players.length === 0) return <div className="text-sm text-text-dim">No other players to teleport to.</div>
  const chosen = players.find(p => String(p.id) === sel)
  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Teleport to player</label>
        <select value={sel} disabled={busy} className={selectCls} onChange={e => setSel(e.target.value)}>
          {players.map(p => (
            <option key={p.id} value={String(p.id)}>
              {(p.name && p.name.trim()) ? p.name : `Player ${p.id}`}{p.map ? ` — ${p.map}` : ''}{p.online_status && /online/i.test(p.online_status) ? ' (online)' : ''}
            </option>
          ))}
        </select>
      </div>
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => onSubmit(Number(sel) || 0, (chosen?.name && chosen.name.trim()) ? chosen.name : `Player ${sel}`)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Move" size={13} />} Teleport To Player
      </button>
    </div>
  )
}

// Destination picker shared by Teleport To Location + Set Respawn — fetches the
// named map/hub catalog and resolves to the destination id behind the scenes.
function DestinationForm({ busy, submitLabel, icon, note, onSubmit }: {
  busy: boolean; submitLabel: string; icon: string; note: string
  onSubmit: (destId: string, destLabel: string) => void
}) {
  const [dests, setDests] = useState<TeleportDestination[]>([])
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')
  useEffect(() => {
    let alive = true
    setLoading(true)
    getTeleportDestinations()
      .then(r => {
        if (!alive) return
        const raw = r.destinations as TeleportDestination[] | TeleportDestination | undefined
        const list = Array.isArray(raw) ? raw : raw ? [raw] : []
        setDests(list)
        setSel(list[0]?.id || '')
      })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [])
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading destinations…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (dests.length === 0) return <div className="text-sm text-text-dim">No destinations available.</div>
  const chosen = dests.find(d => d.id === sel)
  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Destination</label>
        <select value={sel} disabled={busy} className={selectCls} onChange={e => setSel(e.target.value)}>
          {dests.map(d => (<option key={d.id} value={d.id}>{d.label}</option>))}
        </select>
      </div>
      <div className="text-[11px] text-text-muted">{note}</div>
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => onSubmit(sel, chosen?.label || sel)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name={icon} size={13} />} {submitLabel}
      </button>
    </div>
  )
}

// Grant Reward (popup) form — shared ItemPicker (search + categories + friendly
// names) + amount. Unlike Give Item this doesn't write to inventory directly; it
// queues a Claim Rewards popup the player accepts in-game (works online or
// offline). Renders without a card wrapper — ActionRow provides the container.
function GrantRewardForm({ busy, submitLabel, onSubmit }: {
  busy: boolean; submitLabel: string
  onSubmit: (tpl: string, amount: number) => void
}) {
  const [tpl, setTpl]       = useState('')
  const [name, setName]     = useState('')
  const [amount, setAmount] = useState('1')
  return (
    <div className="space-y-3">
      <ItemPicker label="Item — type to search by name or template id"
        value={tpl} displayValue={name || tpl}
        onChange={(t, item) => { setTpl(t); setName(item ? item.name : '') }}
        autoFocus disabled={busy} />
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Amount</label>
        <input type="number" min={1} value={amount} disabled={busy}
          onChange={e => setAmount(e.target.value)}
          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
      </div>
      <p className="text-[11px] text-text-dim">
        Queues a <span className="text-text">Claim Rewards</span> popup the player accepts in-game — delivered whether they're online or offline.
      </p>
      <button className="btn-primary w-full" disabled={busy || !isValidTemplateId(tpl)}
        onClick={() => onSubmit(tpl.trim(), Number(amount) || 1)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} {submitLabel}
      </button>
    </div>
  )
}

// Grant Cosmetic / Variant — picks from the cosmetics catalog (set variants,
// swatches, vehicle skins) and delivers the chosen template via the normal
// give-item path so the player unlocks the appearance. Loads the catalog on
// mount; filters by name/template; groups results by type.
function GrantCosmeticForm({ busy, playerName, onGrant }: {
  busy: boolean
  playerName: string
  onGrant: (template: string, label: string) => void
}) {
  const [catalog, setCatalog] = useState<CosmeticEntry[] | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [filter, setFilter] = useState('')
  const [sel, setSel] = useState('')
  useEffect(() => {
    let alive = true
    getCosmeticsCatalog()
      .then(c => { if (alive) setCatalog(c) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
    return () => { alive = false }
  }, [])
  const matches = useMemo(() => {
    const q = filter.trim().toLowerCase()
    const list = catalog || []
    return q ? list.filter(e => e.name.toLowerCase().includes(q) || e.template.toLowerCase().includes(q)) : list
  }, [catalog, filter])
  const groups = useMemo(() => {
    const m = new Map<string, CosmeticEntry[]>()
    for (const e of matches) { const a = m.get(e.group); if (a) a.push(e); else m.set(e.group, [e]) }
    return Array.from(m.entries()).sort(([a], [b]) => a.localeCompare(b))
  }, [matches])
  const chosen = (catalog || []).find(e => e.template === sel)
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

  if (err) return <ErrorBox msg={err} />
  if (!catalog) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading catalog…</div>

  return (
    <div className="space-y-3">
      <p className="text-[11px] text-text-dim">Delivers the unlock item to {playerName}'s inventory (online: instant; offline: next login). The unlock applies when acquired in-game.</p>
      <input type="text" value={filter} disabled={busy} placeholder="Filter cosmetics & building sets by name or id…"
        onChange={e => setFilter(e.target.value)} className={selectCls} />
      <select value={sel} disabled={busy} className={selectCls} onChange={e => setSel(e.target.value)} size={1}>
        <option value="">Select a cosmetic or building set… ({matches.length})</option>
        {groups.map(([g, items]) => (
          <optgroup key={g} label={`${g} (${items.length})`}>
            {items.map(e => <option key={e.template} value={e.template}>{e.name}</option>)}
          </optgroup>
        ))}
      </select>
      {chosen && <p className="text-[11px] font-mono text-text-dim truncate">{chosen.template}</p>}
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => chosen && onGrant(chosen.template, chosen.name)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Shirt" size={13} />} Grant
      </button>
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

export function GivePackageForm({ busy, playerName, targetLabel, showOverflow = true, onGive }: {
  busy: boolean
  playerName?: string
  targetLabel?: string
  showOverflow?: boolean
  onGive: (items: GiveItemEntry[], pkgName: string, allowOverflow: boolean) => void
}) {
  const giveLabel = targetLabel ?? playerName ?? 'player'
  const [packages, setPackages] = useState<ItemPackage[]>([])
  const [loading, setLoading]   = useState(true)
  const [err, setErr]           = useState<string | null>(null)
  const [selectedId, setSelectedId] = useState('')
  const [mode, setMode]         = useState<'list' | 'edit' | 'import'>('list')
  const [draftId, setDraftId]   = useState<string | undefined>(undefined)
  const [draftName, setDraftName] = useState('')
  const [draftRows, setDraftRows] = useState<PkgDraftRow[]>([])
  const [importText, setImportText] = useState('')
  const [overflow, setOverflow] = useState(false)
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
  const startImport = () => {
    setDraftId(undefined); setDraftName('')
    setImportText('')
    setErr(null); setMode('import')
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

  const importPackage = async () => {
    setSaving(true); setErr(null)
    try {
      const catalog = await getItemCatalog()
      const parsed = parseTcnoPackageText(importText, catalog)
      if (parsed.warnings.length > 0) {
        setErr(parsed.warnings.join(' '))
        return
      }
      if (parsed.items.length === 0) {
        setErr('Paste at least one item and quantity.')
        return
      }
      setDraftId(undefined)
      setDraftName(draftName.trim() || 'Imported package')
      setDraftRows(parsed.items.map(it => ({
        template: it.template,
        name: it.name,
        qty: String(it.qty),
        quality: String(it.quality ?? 0),
      })))
      setMode('edit')
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  if (mode === 'import') {
    return (
      <div className="space-y-3">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Package name</label>
          <input type="text" value={draftName} disabled={saving} maxLength={80}
            placeholder="e.g. Deep Desert run kit"
            onChange={e => setDraftName(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Paste tcno.co item list</label>
          <textarea value={importText} disabled={saving} rows={10}
            placeholder={'Complex Machinery:\n50\nDuraluminum Ingot:\n150'}
            onChange={e => setImportText(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
          <div className="mt-1 text-[11px] text-text-dim">
            Format: item name line ending with ":" followed by quantity on the next line.
          </div>
        </div>
        {err && <div className="text-xs text-error">{err}</div>}
        <div className="grid grid-cols-2 gap-2">
          <button className="btn-secondary" disabled={saving}
            onClick={() => { setMode('list'); setErr(null) }}>
            Cancel
          </button>
          <button className="btn-primary" disabled={saving || !importText.trim()}
            onClick={() => void importPackage()}>
            {saving ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Upload" size={13} />} Import to editor
          </button>
        </div>
      </div>
    )
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
      {showOverflow && selected && <OverflowToggle checked={overflow} disabled={busy || saving} onChange={setOverflow} />}
      {selected && (
        <button className="btn-primary w-full" disabled={busy || saving}
          onClick={() => onGive(selected.items, selected.name, overflow)}>
          {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Give to {giveLabel}
        </button>
      )}
      <div className="grid grid-cols-4 gap-2">
        <button className="btn-secondary" disabled={busy || saving} onClick={startNew}>
          <Icon name="Plus" size={13} /> New
        </button>
        <button className="btn-secondary" disabled={busy || saving} onClick={startImport}>
          <Icon name="Upload" size={13} /> Import
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
  busy: boolean; onSubmit: (veh: VehicleTemplate, parts: string[], allowOverflow: boolean) => void
}) {
  const [catalog, setCatalog] = useState<VehicleKitCatalog | null>(null)
  const [catErr, setCatErr] = useState(false)
  const [vid, setVid] = useState('')
  const [names, setNames] = useState<Record<string, string>>({})
  const [overflow, setOverflow] = useState(false)
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'

  // Fetch the shared vehicle-kit catalog once (single source of truth, served by
  // the backend). Default the selection to the first vehicle that has part items.
  useEffect(() => {
    let cancelled = false
    getVehicleKitCatalog()
      .then(cat => {
        if (cancelled) return
        setCatalog(cat)
        const first = cat.vehicles.find(v => v.kit.length > 0)
        if (first) setVid(first.id)
      })
      .catch(() => { if (!cancelled) setCatErr(true) })
    return () => { cancelled = true }
  }, [])

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

  if (catErr) return <div className="text-sm text-danger">Failed to load vehicle catalog.</div>
  if (!catalog) return <div className="text-sm text-text-muted">Loading vehicle catalog…</div>

  const kitVehicles = catalog.vehicles.filter(v => v.kit.length > 0)
  const veh = kitVehicles.find(v => v.id === vid) || kitVehicles[0]
  if (!veh) return <div className="text-sm text-text-muted">No vehicles with part kits available.</div>

  const label = (tpl: string) => names[tpl] || tpl
  const qtyOf = (tpl: string) => veh.qty?.[tpl] ?? 1
  const qtySuffix = (tpl: string) => qtyOf(tpl) > 1 ? ` ×${qtyOf(tpl)}` : ''
  const parts = [...veh.kit, ...veh.unique, catalog.fuelTemplate, catalog.torchTemplate]

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
            <Icon name="Fuel" size={12} className="shrink-0" /> {label(catalog.fuelTemplate)}{qtySuffix(catalog.fuelTemplate)}
          </li>
          <li className="flex items-center gap-1.5 text-amber-200/90">
            <Icon name="Wrench" size={12} className="shrink-0" /> {label(catalog.torchTemplate)}
          </li>
        </ul>
      </div>
      <OverflowToggle checked={overflow} disabled={busy} onChange={setOverflow} />
      <button className="btn-primary w-full" disabled={busy}
        onClick={() => onSubmit(veh, parts, overflow)}>
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

// Complete Contract — force-complete a single stuck / in-flight contract.
// Writes the contract's completion tags AND dismisses the active ContractItem
// via the existing completeContract API. Offline-only (tags are RAM-authoritative
// while the player is connected). Catalog is large, so the picker is searchable —
// e.g. type "Skorda" or "Atre" to narrow it down.
function CompleteContractForm({ busy, onSubmit }: { busy: boolean; onSubmit: (contractId: string, label: string) => void }) {
  const [contracts, setContracts] = useState<ContractRow[]>([])
  const [search, setSearch] = useState('')
  const [sel, setSel] = useState('')
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState('')

  useEffect(() => {
    let alive = true
    setLoading(true)
    getContracts()
      .then(r => { if (alive) setContracts(r.contracts || []) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [])

  const q = search.trim().toLowerCase()
  const filtered = useMemo(() => {
    const list = q
      ? contracts.filter(c => c.id.toLowerCase().includes(q) || (c.alias || '').toLowerCase().includes(q))
      : contracts
    return list.slice(0, 300)
  }, [contracts, q])

  // Keep the selection valid as the filter changes.
  useEffect(() => {
    if (filtered.length === 0) { setSel(''); return }
    if (!filtered.some(c => c.id === sel)) setSel(filtered[0].id)
  }, [filtered, sel])

  const chosen = contracts.find(c => c.id === sel)
  const label = (c: ContractRow) => (c.alias && c.alias !== c.id) ? `${c.alias} — ${c.id}` : c.id
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  const inputCls = selectCls

  if (loading) return <div className="text-sm text-text-dim flex items-center gap-2"><Icon name="Loader2" size={13} className="animate-spin" /> Loading contracts…</div>
  if (err) return <div className="text-sm text-danger">{err}</div>
  if (contracts.length === 0) return <div className="text-sm text-text-dim">No contracts available.</div>

  const total = q
    ? contracts.filter(c => c.id.toLowerCase().includes(q) || (c.alias || '').toLowerCase().includes(q)).length
    : contracts.length

  return (
    <div className="space-y-3">
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Search</label>
        <input type="text" value={search} disabled={busy} className={inputCls}
          placeholder="e.g. Skorda, Atre, Hawat…" onChange={e => setSearch(e.target.value)} />
      </div>
      <div>
        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">
          Contract{total > 0 ? ` (${total} match${total === 1 ? '' : 'es'}${total > filtered.length ? `, showing ${filtered.length}` : ''})` : ''}
        </label>
        <select value={sel} disabled={busy} size={8} className={`${selectCls} font-mono`} onChange={e => setSel(e.target.value)}>
          {filtered.map(c => (
            <option key={c.id} value={c.id}>{label(c)}</option>
          ))}
        </select>
        {filtered.length === 0 && <div className="text-[11px] text-text-muted mt-1">No contracts match “{search}”.</div>}
      </div>
      <div className="text-[11px] text-text-muted">
        Force-completes the selected contract: writes its completion tags and dismisses the active
        contract item. Use this to clear a contract left stuck after a faction one-click. Takes effect on next login.
      </div>
      <button className="btn-primary w-full" disabled={busy || !sel}
        onClick={() => onSubmit(sel, chosen ? label(chosen) : sel)}>
        {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Complete Contract
      </button>
    </div>
  )
}

function ResetFactionForm({ busy, playerName, onReset }: {
  busy: boolean
  playerName: string
  onReset: (deep: boolean) => void
}) {
  const [deep, setDeep] = useState(false)
  const go = () => {
    const extra = deep ? '\nDEEP RESET: also wipes faction-related Dunipedia lore fragments (House Atreides/Harkonnen/Leto/Paul/Baron/Feyd/etc.).' : ''
    const typed = window.prompt(
      `Reset ALL faction progression for ${playerName} — zeroes rep, removes every faction tag (rank grid, MaasKharet, storyline milestones), and resets ClimbTheRanks journey nodes (revealed AND completed) for both factions. Cannot be undone.${extra}\n\nType  reset faction  to proceed:`
    ) || ''
    if (typed.trim().toLowerCase() !== 'reset faction') return
    onReset(deep)
  }
  return (
    <div className="space-y-2">
      <p className="text-[11px] text-text-dim">Removes Atreides + Harkonnen rep, tags, and faction journey nodes (both revealed &amp; completed state). Player must be offline; takes effect on next login.</p>
      <label className="flex items-start gap-2 text-[12px] text-text cursor-pointer select-none">
        <input type="checkbox" checked={deep} disabled={busy}
          onChange={e => setDeep(e.target.checked)}
          className="mt-0.5 h-3.5 w-3.5 rounded border-border bg-surface-2 accent-ibad" />
        <span>
          <span className="font-medium">Deep reset</span>
          <span className="text-text-dim"> — also wipe faction lore + Dunipedia entries for this faction (House Atreides / Harkonnen character codex).</span>
        </span>
      </label>
      <button className="btn-danger w-full" disabled={busy} onClick={go}>
        <Icon name="Swords" size={13} /> Reset Faction{deep ? ' (Deep)' : ''}
      </button>
    </div>
  )
}

// Progression Unlock — faction + stage picker that drives the existing// progression-unlock / progression-reverse routes. Completes the
// DA_FQ_ClimbTheRanks journey nodes for the chosen faction and writes the
// faction tier tags + reputation. 'Ch3 Start' = tier 5 (start of chapter 3);
// 'Rank 19 Eligible' = tier 19 + the Landsraad onboarding nodes. Works for both
// Atreides and Harkonnen. Takes effect on next login.
const PROGRESSION_PRESETS: { value: string; label: string }[] = [
  { value: 'ch3_start', label: 'Ch3 Start' },
  { value: 'rank19_eligible', label: 'Rank 19 Eligible' },
]
function ProgressionUnlockForm({ busy, onUnlock, onReverse }: {
  busy: boolean
  onUnlock: (faction: string, preset: string, presetName: string) => void
  onReverse: (faction: string, preset: string, presetName: string) => void
}) {
  const [faction, setFaction] = useState('atreides')
  const [preset, setPreset] = useState('ch3_start')
  const presetName = PROGRESSION_PRESETS.find(p => p.value === preset)?.label || preset
  const selectCls = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50'
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Faction</label>
          <select value={faction} disabled={busy} className={selectCls} onChange={e => setFaction(e.target.value)}>
            <option value="atreides">Atreides</option>
            <option value="harkonnen">Harkonnen</option>
          </select>
        </div>
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Stage</label>
          <select value={preset} disabled={busy} className={selectCls} onChange={e => setPreset(e.target.value)}>
            {PROGRESSION_PRESETS.map(p => <option key={p.value} value={p.value}>{p.label}</option>)}
          </select>
        </div>
      </div>
      <div className="text-[11px] text-text-muted">
        Completes the <span className="text-text">DA_FQ_ClimbTheRanks</span> journey nodes and writes the faction tier tags + reputation.
        {' '}<span className="text-text">Ch3 Start</span> sets tier 5; <span className="text-text">Rank 19 Eligible</span> sets tier 19 and adds the Landsraad onboarding nodes. Takes effect on next login.
      </div>
      <div className="flex gap-2">
        <button className="btn-primary flex-1" disabled={busy}
          onClick={() => onUnlock(faction, preset, presetName)}>
          {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Milestone" size={13} />} Apply Unlock
        </button>
        <button className="btn-ghost flex-1" disabled={busy}
          onClick={() => onReverse(faction, preset, presetName)}>
          {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Undo2" size={13} />} Reverse Unlock
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Items action block — the 'Items' group of ACTIONS, rendered inside the
// Inventory section (between the inventory title and the items list).
// Mirrors ActionsSection's per-group rendering, scoped to one group, with
// its own openId/busy/give-item form state.
// ---------------------------------------------------------------------------
function ItemsActionBlock({ player, canWrite, flash, onChanged, onFlush }: {
  player: Player; canWrite: boolean; flash: Flash; onChanged: () => void; onFlush?: () => void
}) {
  const [openId, setOpenId] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const acts = useMemo(() => ACTIONS.filter(a => a.group === ITEMS_GROUP), [])

  if (!canWrite || acts.length === 0) return null

  const openAction = (id: string) => {
    if (openId) onFlush?.()
    setOpenId(o => (o === id ? null : id))
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
      // Keep the form OPEN (grant several in a row) + mark deferred refresh only.
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

export function InventorySection({ player, canWrite, demo, refreshKey, flash, onChanged, onFlush }: SectionProps) {
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
        <button className="btn-secondary" disabled={loading || busy} onClick={() => { onFlush?.(); setTick(t => t + 1) }}>
          <Icon name="RefreshCw" size={13} className={loading ? 'animate-spin' : ''} /> Refresh inventory
        </button>
      </div>
      <ItemList title={`Inventory (${fmtNum(groups.gear.length)})`} icon="Backpack" items={groups.gear}
        canWrite={canWrite} busy={busy} run={run} isOnline={isOnline}
        extra={<ItemsActionBlock player={player} canWrite={canWrite} flash={flash} onChanged={onChanged} onFlush={onFlush} />} />
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
              const canEdit = canWrite
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
                    title={canEdit ? (isEditing ? 'Hide item editor' : 'Click to edit stack / durability / water') : undefined}
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
                      <StackEditor item={it} busy={busy} run={run} isOnline={isOnline} onClose={() => setEditingId(null)} />
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

// Inline stack-quantity editor — appears underneath an inventory row for every
// item (all items carry a stack_size). Writes the stack_size column directly.
// When the player is online the map pod caches inventory in RAM and flushes it
// on its save tick, so the value won't reflect in-game until the player relogs.
function StackEditor({ item, busy, run, isOnline, onClose }: {
  item: InventoryItem
  busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  isOnline: boolean
  onClose: () => void
}) {
  const [str, setStr] = useState(String(item.stack_size))
  const n = parseInt(str, 10)
  const valid = Number.isFinite(n) && n >= 1

  return (
    <div className="border-t border-border/50 px-3 py-3 bg-surface-1/60 rounded-b-lg space-y-3">
      {isOnline && (
        <div className="text-[11px] text-warning flex items-start gap-1.5">
          <Icon name="Wifi" size={11} className="mt-0.5 shrink-0" />
          <span>
            Player is online — the map pod caches inventory in memory, so the new
            quantity writes to the database immediately but won't appear in-game
            until the player relogs.
          </span>
        </div>
      )}
      <div className="flex items-end gap-2">
        <label className="text-xs flex-1">
          <div className="text-text-dim mb-1">Stack quantity</div>
          <input
            type="number" inputMode="numeric" step={1} min={1}
            value={str}
            onChange={e => setStr(e.target.value)}
            disabled={busy}
            className="w-full font-mono text-sm bg-surface-2 border border-border rounded px-2 py-1"
          />
        </label>
        <button
          type="button"
          className="btn-primary text-xs"
          disabled={busy || !valid}
          onClick={() => {
            if (!valid) return
            void run(() => setItemStack(item.id, n), 'Save')
            onClose()
          }}
        >
          <Icon name="Save" size={12} /> Save
        </button>
      </div>
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
// Filter tabs (All / Done / Incomplete / Revealed / Reward), node-id search, client-side
// pagination, per-row Complete/Reset, and a Wipe-All control. All writes work
// online or offline (DB writes); they take effect on the player's next login.
// ---------------------------------------------------------------------------
const JOURNEY_PAGE_SIZE = 50
type JourneyFilter = 'all' | 'done' | 'incomplete' | 'revealed' | 'reward'

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
    incomplete: nodes.filter(n => !n.is_complete).length,
    revealed: nodes.filter(n => n.is_revealed).length,
    reward: nodes.filter(n => n.has_pending_reward).length,
  }), [nodes])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return nodes.filter(n => {
      if (filter === 'done' && !n.is_complete) return false
      if (filter === 'incomplete' && n.is_complete) return false
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
      `WIPE ${player.name}'s entire journey and restart it from the beginning? All journey/quest progress is lost. This cannot be undone.\n\n` +
      `This is the FIRST of two confirmations. If you continue, the next step asks you to type an acknowledgement before the journey is wiped.`
    )) return
    const typed = window.prompt(
      `SECOND confirmation — WIPE ${player.name}'s journey.\n` +
      `This cannot be undone.\n\n` +
      `Type  i acknowledge  to proceed:`
    ) || ''
    if (typed.trim().toLowerCase() !== 'i acknowledge') {
      flash('Did not type "i acknowledge" — wipe aborted.', 'err')
      return
    }
    void run(() => wipeJourney(player.account_id))
  }

  if (loading) return <Loading label="Loading journey…" />

  const tabs: Array<{ id: JourneyFilter; label: string; n: number }> = [
    { id: 'all', label: 'All', n: counts.all },
    { id: 'done', label: 'Done', n: counts.done },
    { id: 'incomplete', label: 'Incomplete', n: counts.incomplete },
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
