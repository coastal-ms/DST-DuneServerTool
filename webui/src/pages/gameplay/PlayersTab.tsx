import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getPlayers, getPlayerDetail,
  giveSolari, giveItem, renamePlayer, awardSpecXp, deleteInventoryItem, repairInventoryItem,
  type Player, type PlayerDetailResponse, type InventoryItem, type DataSource,
} from '../../api/gameplay'
import { fmtNum, fmtSolari, SourceBadge, StatCard, DemoNotice, qualityClass } from './shared'

type SortKey = 'name' | 'class' | 'map' | 'faction_name' | 'online_status'

export function PlayersTab() {
  const [players, setPlayers] = useState<Player[]>([])
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [online, setOnline] = useState<'' | 'online' | 'offline'>('')
  const [sort, setSort] = useState<SortKey>('name')
  const [dir, setDir] = useState<'asc' | 'desc'>('asc')
  const [selected, setSelected] = useState<Player | null>(null)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getPlayers()
      setPlayers(r.players); setSource(r.source); setLiveError(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const toggleSort = (col: SortKey) => {
    if (sort === col) setDir(d => (d === 'asc' ? 'desc' : 'asc'))
    else { setSort(col); setDir('asc') }
  }

  const isOnline = (s: string) => s.toLowerCase().includes('online')

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    let out = players
    if (q) out = out.filter(p =>
      p.name.toLowerCase().includes(q) || p.faction_name.toLowerCase().includes(q) || String(p.id).includes(q))
    if (online === 'online') out = out.filter(p => isOnline(p.online_status))
    else if (online === 'offline') out = out.filter(p => !isOnline(p.online_status))
    const mul = dir === 'asc' ? 1 : -1
    return [...out].sort((a, b) => String(a[sort]).localeCompare(String(b[sort])) * mul)
  }, [players, search, online, sort, dir])

  const onlineCount = useMemo(() => players.filter(p => isOnline(p.online_status)).length, [players])

  return (
    <div>
      <section className="grid grid-cols-2 md:grid-cols-3 gap-3 mb-4">
        <StatCard label="Players" value={fmtNum(players.length)} icon="Users" />
        <StatCard label="Online now" value={fmtNum(onlineCount)} icon="Wifi" />
        <StatCard label="Factions" value={fmtNum(new Set(players.map(p => p.faction_name).filter(Boolean)).size)} icon="Flag" />
      </section>

      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input type="text" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search players or factions…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div className="flex rounded-lg border border-border overflow-hidden">
          {([['', 'All'], ['online', 'Online'], ['offline', 'Offline']] as const).map(([val, label]) => (
            <button key={val} onClick={() => setOnline(val)}
              className={`px-3 py-2 text-sm ${online === val ? 'bg-accent/20 text-accent-bright' : 'bg-surface-2 text-text-muted hover:text-text'}`}>
              {label}
            </button>
          ))}
        </div>
        <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="player data" />}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <Th label="Player" col="name" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="Faction" col="faction_name" sort={sort} dir={dir} onSort={toggleSort} className="hidden md:table-cell" />
              <Th label="Map" col="map" sort={sort} dir={dir} onSort={toggleSort} className="hidden lg:table-cell" />
              <Th label="Status" col="online_status" sort={sort} dir={dir} onSort={toggleSort} align="right" />
            </tr>
          </thead>
          <tbody>
            {loading && players.length === 0 && (
              <tr><td colSpan={4} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading players…
              </td></tr>
            )}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={4} className="px-3 py-8 text-center text-text-dim">No players match.</td></tr>
            )}
            {rows.map(p => (
              <tr key={p.id} onClick={() => setSelected(p)}
                className="border-b border-border/50 hover:bg-surface-2 cursor-pointer">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[240px]">{p.name || <span className="text-text-dim italic">Unnamed</span>}</div>
                  <div className="text-[11px] text-text-dim font-mono">#{p.id}</div>
                </td>
                <td className="px-3 py-2 hidden md:table-cell text-text-muted">{p.faction_name || '—'}</td>
                <td className="px-3 py-2 hidden lg:table-cell text-text-dim">{p.map || '—'}</td>
                <td className="px-3 py-2 text-right">
                  <span className={`inline-flex items-center gap-1 text-xs ${isOnline(p.online_status) ? 'text-success' : 'text-text-dim'}`}>
                    <Icon name={isOnline(p.online_status) ? 'Wifi' : 'WifiOff'} size={12} /> {p.online_status}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {selected && (
        <PlayerDetail player={selected} canWrite={source === 'live'} demo={source === 'demo'}
          onClose={() => setSelected(null)} onChanged={() => { void load() }} />
      )}
    </div>
  )
}

function PlayerDetail({ player, canWrite, demo, onClose, onChanged }: {
  player: Player; canWrite: boolean; demo: boolean; onClose: () => void; onChanged: () => void
}) {
  const [detail, setDetail] = useState<PlayerDetailResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [flash, setFlash] = useState<string | null>(null)
  const [form, setForm] = useState<'solari' | 'rename' | 'item' | null>(null)

  const loadDetail = useCallback(() => {
    let alive = true
    setLoading(true); setErr(null)
    getPlayerDetail(player.id, player.controller_id, demo)
      .then(r => { if (alive) setDetail(r) })
      .catch(e => { if (alive) setErr(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [player.id, player.controller_id, demo])
  useEffect(() => loadDetail(), [loadDetail])

  // Run a write action, then refresh detail + the parent list.
  const run = async (fn: () => Promise<{ ok: boolean; message: string }>, label: string) => {
    setBusy(true); setErr(null); setFlash(null)
    try {
      const r = await fn()
      setFlash(r.message || `${label} done.`)
      setForm(null)
      loadDetail()
      onChanged()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const solari = detail?.currency.find(c => c.currency_id === 1)?.balance

  // Separate emotes and contract (quest) items from real gear/loot so the
  // inventory list stays focused; they're shown in their own sub-sections.
  const groups = useMemo(() => {
    const inv = detail?.inventory ?? []
    return {
      gear: inv.filter(i => (i.kind ?? 'item') === 'item'),
      emotes: inv.filter(i => i.kind === 'emote'),
      contracts: inv.filter(i => i.kind === 'contract'),
    }
  }, [detail])

  return (
    <div className="fixed inset-0 z-40 flex justify-end" onClick={onClose}>
      <div className="absolute inset-0 bg-black/50" />
      <div className="relative w-full max-w-lg h-full bg-surface border-l border-border overflow-y-auto p-5" onClick={e => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <div>
            <h3 className="text-lg font-semibold text-text">{player.name || 'Unnamed player'}</h3>
            <div className="text-xs text-text-dim">{player.class || 'Player'} · #{player.id}</div>
            <div className="mt-1 flex items-center gap-2 text-xs text-text-muted">
              {player.faction_name && <span><Icon name="Flag" size={11} className="inline" /> {player.faction_name}</span>}
              {player.map && <span>· {player.map}</span>}
              <span className={isOnlineStr(player.online_status) ? 'text-success' : 'text-text-dim'}>· {player.online_status}</span>
            </div>
          </div>
          <button onClick={onClose} className="text-text-dim hover:text-text"><Icon name="X" size={20} /></button>
        </div>

        {/* Currency */}
        <div className="grid grid-cols-3 gap-2 mb-4">
          <MiniStat label="Solari" value={fmtSolari(solari)} />
          <MiniStat label="Inventory" value={fmtNum(groups.gear.length)} />
          <MiniStat label="Spec tracks" value={fmtNum(detail?.specs.length)} />
        </div>

        {/* Admin actions */}
        {canWrite ? (
          <div className="flex flex-wrap gap-2 mb-3">
            <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'solari' ? null : 'solari')}>
              <Icon name="Coins" size={14} /> Give Solari
            </button>
            <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'item' ? null : 'item')}>
              <Icon name="PackagePlus" size={14} /> Give Item
            </button>
            <button className="btn-secondary" disabled={busy} onClick={() => setForm(form === 'rename' ? null : 'rename')}>
              <Icon name="PenLine" size={14} /> Rename
            </button>
          </div>
        ) : (
          <div className="text-xs text-text-dim mb-3 flex items-center gap-1.5">
            <Icon name="Lock" size={12} /> Editing is available when the live game database is connected.
          </div>
        )}

        {form === 'solari' && (
          <InlineForm busy={busy} fields={[{ key: 'amount', label: 'Amount (Solari)', type: 'number', placeholder: 'e.g. 10000' }]}
            submitLabel="Give Solari"
            onSubmit={v => run(() => giveSolari(player.controller_id, Number(v.amount) || 0), 'Give Solari')} />
        )}
        {form === 'item' && (
          <InlineForm busy={busy} fields={[
            { key: 'template', label: 'Item template id', type: 'text', placeholder: 'e.g. Spice_Melange' },
            { key: 'qty', label: 'Quantity', type: 'number', placeholder: '1' },
            { key: 'quality', label: 'Quality (0–5)', type: 'number', placeholder: '0' },
          ]} submitLabel="Give Item"
            onSubmit={v => run(() => giveItem(player.id, String(v.template || '').trim(), Number(v.qty) || 0, Number(v.quality) || 0), 'Give Item')} />
        )}
        {form === 'rename' && (
          <InlineForm busy={busy} fields={[{ key: 'name', label: 'New character name', type: 'text', placeholder: player.name }]}
            submitLabel="Rename"
            onSubmit={v => run(() => renamePlayer(player.account_id, String(v.name || '').trim()), 'Rename')} />
        )}

        {flash && <div className="card p-2.5 mb-3 text-xs text-success border-l-2 border-success break-words">{flash}</div>}
        {err && <div className="card p-2.5 mb-3 text-xs text-danger break-words">{err}</div>}

        {loading ? (
          <div className="text-text-dim text-sm py-4"><Icon name="Loader2" size={16} className="animate-spin inline" /> Loading…</div>
        ) : (
          <>
            {/* Specs */}
            {detail && detail.specs.length > 0 && (
              <>
                <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Specialization tracks</h4>
                <div className="space-y-1 mb-4">
                  {detail.specs.map(s => (
                    <div key={s.track_type} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
                      <span className="text-text">{s.track_type}</span>
                      <span className="flex items-center gap-2">
                        <span className="font-mono text-text-muted text-xs">Lv {Math.round(s.level)} · {fmtNum(s.xp)} xp</span>
                        {canWrite && (
                          <button className="text-accent hover:text-accent-bright" title="Award +5000 XP" disabled={busy}
                            onClick={() => run(() => awardSpecXp(player.id, s.track_type, 5000), 'Award XP')}>
                            <Icon name="Plus" size={14} />
                          </button>
                        )}
                      </span>
                    </div>
                  ))}
                </div>
              </>
            )}

            {/* Inventory (gear/loot only — emotes & contracts shown separately) */}
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Inventory ({fmtNum(groups.gear.length)})</h4>
            {groups.gear.length === 0 ? (
              <div className="text-text-dim text-sm py-2">No items.</div>
            ) : (
              <div className="space-y-1">
                {groups.gear.map(it => (
                  <ItemRow key={it.id} item={it} canWrite={canWrite} busy={busy} run={run} />
                ))}
              </div>
            )}

            {/* Emotes & contract items — separated to keep the list above clean */}
            <ItemSection title="Emotes" icon="Smile" items={groups.emotes} canWrite={canWrite} busy={busy} run={run} />
            <ItemSection title="Contract items" icon="FileText" items={groups.contracts} canWrite={canWrite} busy={busy} run={run} />
          </>
        )}
      </div>
    </div>
  )
}

function isOnlineStr(s: string) { return s.toLowerCase().includes('online') }

type RunFn = (fn: () => Promise<{ ok: boolean; message: string }>, label: string) => void | Promise<void>

function ItemRow({ item: it, canWrite, busy, run }: {
  item: InventoryItem; canWrite: boolean; busy: boolean; run: RunFn
}) {
  return (
    <div className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
      <span className="truncate max-w-[240px]">
        <span className="text-text">{it.name}</span>
        {it.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(it.quality)}`}>Q{it.quality}</span>}
        <span className="ml-1.5 font-mono text-text-dim text-xs">×{fmtNum(it.stack_size)}</span>
      </span>
      {canWrite && (
        <span className="flex items-center gap-2 shrink-0">
          {it.durability !== 'N/A' && (
            <button className="text-info hover:text-accent-bright" title="Repair to full" disabled={busy}
              onClick={() => run(() => repairInventoryItem(it.id), 'Repair')}>
              <Icon name="Wrench" size={14} />
            </button>
          )}
          <button className="text-danger/80 hover:text-danger" title="Delete item" disabled={busy}
            onClick={() => { if (window.confirm(`Delete ${it.name} (×${it.stack_size})? This cannot be undone.`)) void run(() => deleteInventoryItem(it.id), 'Delete') }}>
            <Icon name="Trash2" size={14} />
          </button>
        </span>
      )}
    </div>
  )
}

// Collapsible sub-section for emotes / contract items, collapsed by default so
// they don't clutter the main inventory list. Hidden entirely when empty.
function ItemSection({ title, icon, items, canWrite, busy, run }: {
  title: string; icon: string; items: InventoryItem[]; canWrite: boolean; busy: boolean; run: RunFn
}) {
  const [open, setOpen] = useState(false)
  if (items.length === 0) return null
  return (
    <div className="mt-4">
      <button type="button" onClick={() => setOpen(o => !o)}
        className="flex w-full items-center gap-2 text-xs uppercase tracking-wider text-text-dim hover:text-text mb-2">
        <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={14} />
        <Icon name={icon} size={13} />
        <span>{title} ({fmtNum(items.length)})</span>
      </button>
      {open && (
        <div className="space-y-1">
          {items.map(it => (
            <ItemRow key={it.id} item={it} canWrite={canWrite} busy={busy} run={run} />
          ))}
        </div>
      )}
    </div>
  )
}

interface FieldDef { key: string; label: string; type: 'text' | 'number'; placeholder?: string }

function InlineForm({ fields, submitLabel, busy, onSubmit }: {
  fields: FieldDef[]; submitLabel: string; busy: boolean; onSubmit: (values: Record<string, string>) => void
}) {
  const [values, setValues] = useState<Record<string, string>>({})
  return (
    <div className="card p-3 mb-3 space-y-2">
      {fields.map(f => (
        <div key={f.key}>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">{f.label}</label>
          <input type={f.type} value={values[f.key] ?? ''} placeholder={f.placeholder}
            onChange={e => setValues(v => ({ ...v, [f.key]: e.target.value }))}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
      ))}
      <button className="btn-primary" disabled={busy} onClick={() => onSubmit(values)}>
        {busy ? <Icon name="Loader2" size={14} className="animate-spin" /> : <Icon name="Check" size={14} />} {submitLabel}
      </button>
    </div>
  )
}

function MiniStat({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-surface-2 rounded-lg p-2 border border-border/50 text-center">
      <div className="text-[11px] uppercase tracking-wider text-text-dim">{label}</div>
      <div className="text-sm font-semibold font-mono text-text mt-0.5">{value}</div>
    </div>
  )
}

function Th({ label, col, sort, dir, onSort, align = 'left', className = '' }: {
  label: string; col: SortKey; sort: SortKey; dir: 'asc' | 'desc'
  onSort: (c: SortKey) => void; align?: 'left' | 'right' | 'center'; className?: string
}) {
  const active = sort === col
  const justify = align === 'right' ? 'justify-end' : align === 'center' ? 'justify-center' : 'justify-start'
  return (
    <th className={`px-3 py-2 font-medium ${className}`}>
      <button type="button" onClick={() => onSort(col)}
        className={`flex w-full items-center gap-1 ${justify} uppercase tracking-wider transition-colors ${active ? 'text-accent-bright' : 'hover:text-text'}`}>
        <span>{label}</span>
        <Icon name={active ? (dir === 'asc' ? 'ChevronUp' : 'ChevronDown') : 'ChevronsUpDown'} size={12} className={active ? '' : 'opacity-40'} />
      </button>
    </th>
  )
}
