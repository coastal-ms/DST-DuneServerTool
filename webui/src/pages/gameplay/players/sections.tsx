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
  awardSpecXp, deleteInventoryItem, fillWater, getPlayerEvents, getPlayerSpecs, getPlayerStats,
  getPlayerTags, giveItem, giveSolari, grantAllKeystones, grantMaxSpec,
  renamePlayer, repairInventoryItem, resetAllKeystones, resetAllSpecs, resetSpec,
  setPlayerTags,
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
                onClick={() => { if (window.confirm(`Grant all ${keystones.max} keystones to ${player.name}?`)) void run(() => grantAllKeystones(player.controller_id), 'Grant all keystones') }}>
                <Icon name="Star" size={13} /> Grant Max Keystones
              </button>
              <button className="btn-secondary text-warning" disabled={busy}
                onClick={() => { if (window.confirm(`Reset ALL keystones for ${player.name}? Cannot be undone.`)) void run(() => resetAllKeystones(player.id), 'Reset all keystones') }}>
                <Icon name="RotateCcw" size={13} /> Reset All Keystones
              </button>
              <button className="btn-secondary text-danger" disabled={busy}
                onClick={() => { if (window.confirm(`Reset ALL spec tracks + keystones for ${player.name}? Cannot be undone.`)) void run(() => resetAllSpecs(player.id), 'Reset all specs') }}>
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
                onGrantMax={() => { if (window.confirm(`Grant max XP for ${name}?`)) void run(() => grantMaxSpec(player.id, name), 'Grant max') }}
                onReset={() => { if (window.confirm(`Reset ${name} track?`)) void run(() => resetSpec(player.id, name), 'Reset') }}
                onAdd5k={() => run(() => awardSpecXp(player.id, name, 5000), '+5000 XP')}
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
// Actions — write surface. Give Solari / Give Item / Rename / Fill Water.
// Inventory mgmt and per-track XP already covered by Inventory + Specs sections.
// v11.5.7: Give Item now uses the ItemPicker typeahead; Fill Water added
// (offline-safe SQL refill of stillsuits + literjons).
// ---------------------------------------------------------------------------
export function ActionsSection({ player, canWrite, flash, onChanged }: SectionProps) {
  const [form, setForm] = useState<'solari' | 'item' | 'rename' | null>(null)
  const [busy, setBusy] = useState(false)

  // Give-item form state lives at the section level so the ItemPicker keeps
  // its selection when the user tabs to Quantity / Quality fields.
  const [giveTpl, setGiveTpl] = useState('')
  const [giveQty, setGiveQty] = useState('1')
  const [giveQual, setGiveQual] = useState('0')

  const run = async (fn: () => Promise<{ message: string }>, label: string, closeAfter = true) => {
    setBusy(true)
    try {
      const r = await fn()
      flash(r.message || `${label} done.`, 'ok')
      if (closeAfter) setForm(null)
      onChanged()
    } catch (e) {
      flash(e instanceof Error ? e.message : String(e), 'err')
    } finally {
      setBusy(false)
    }
  }

  const handleFillWater = () => {
    if (!confirm(`Refill all water-fillable items (stillsuits, literjons, dewpacks) for ${player.name}?\n\nOnline players: takes effect on next relog.`)) return
    run(() => fillWater(player.id), 'Fill Water', false)
  }

  if (!canWrite) {
    return (
      <div className="card p-4 text-sm text-text-dim flex items-center gap-2">
        <Icon name="Lock" size={14} /> Editing is available when the live game database is connected.
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-2">
        <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'solari' ? null : 'solari')}>
          <Icon name="Coins" size={13} /> Give Solari
        </button>
        <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'item' ? null : 'item')}>
          <Icon name="PackagePlus" size={13} /> Give Item
        </button>
        <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'rename' ? null : 'rename')}>
          <Icon name="PenLine" size={13} /> Rename
        </button>
        <button className="btn-secondary" disabled={busy} onClick={handleFillWater} title="Refill stillsuits + literjons to max">
          <Icon name="Droplets" size={13} /> Fill Water
        </button>
      </div>

      {form === 'solari' && (
        <InlineForm busy={busy} submitLabel="Give Solari" fields={[
          { key: 'amount', label: 'Amount (Solari)', type: 'number', placeholder: 'e.g. 10000' },
        ]} onSubmit={v => run(() => giveSolari(player.controller_id, Number(v.amount) || 0), 'Give Solari')} />
      )}
      {form === 'item' && (
        <div className="card p-3 space-y-3">
          <ItemPicker
            label="Item — type to search by name or template id"
            value={giveTpl}
            onChange={setGiveTpl}
            autoFocus
            disabled={busy}
          />
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
              <input type="number" min={1} value={giveQty} disabled={busy}
                onChange={e => setGiveQty(e.target.value)}
                className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
            </div>
            <div>
              <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quality (0–5)</label>
              <input type="number" min={0} max={5} value={giveQual} disabled={busy}
                onChange={e => setGiveQual(e.target.value)}
                className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
            </div>
          </div>
          <button
            className="btn-primary w-full"
            disabled={busy || !giveTpl.trim()}
            onClick={() => run(
              () => giveItem(player.id, giveTpl.trim(), Number(giveQty) || 1, Number(giveQual) || 0),
              'Give Item',
            )}
          >
            {busy ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Check" size={13} />} Give Item
          </button>
        </div>
      )}
      {form === 'rename' && (
        <InlineForm busy={busy} submitLabel="Rename" fields={[
          { key: 'name', label: 'New character name', type: 'text', placeholder: player.name },
        ]} onSubmit={v => run(() => renamePlayer(player.account_id, String(v.name || '').trim()), 'Rename')} />
      )}
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
      <ItemList title={`Inventory (${fmtNum(groups.gear.length)})`} icon="Backpack" items={groups.gear}
        canWrite={canWrite} busy={busy} run={run} />
      <ItemList title={`Emotes (${fmtNum(groups.emotes.length)})`} icon="Smile" items={groups.emotes} collapsed
        canWrite={canWrite} busy={busy} run={run} />
      <ItemList title={`Contract items (${fmtNum(groups.contracts.length)})`} icon="FileText" items={groups.contracts} collapsed
        canWrite={canWrite} busy={busy} run={run} />
    </div>
  )
}

function ItemList({ title, icon, items, canWrite, busy, run, collapsed }: {
  title: string; icon: string; items: InventoryItem[]; canWrite: boolean; busy: boolean
  run: (fn: () => Promise<{ message: string }>, label: string) => void | Promise<void>
  collapsed?: boolean
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
      {open && (
        items.length === 0 ? (
          <div className="text-sm text-text-dim italic py-1">No items.</div>
        ) : (
          <div className="space-y-1">
            {items.map(it => (
              <div key={it.id} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
                <span className="truncate max-w-[320px]">
                  <span className="text-text">{it.name || it.template_id}</span>
                  {it.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(it.quality)}`}>Q{it.quality}</span>}
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
                      onClick={() => { if (window.confirm(`Delete ${it.name || it.template_id} (×${it.stack_size})?`)) void run(() => deleteInventoryItem(it.id), 'Delete') }}>
                      <Icon name="Trash2" size={13} />
                    </button>
                  </span>
                )}
              </div>
            ))}
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
