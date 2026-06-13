import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ItemPicker } from '../../components/ItemPicker'
import {
  getStorage, getStorageItems, giveItemsToStorage, deleteStorageItem, isValidTemplateId,
  type StorageContainer, type InventoryItem, type DataSource, type StorageGiveItemInput,
} from '../../api/gameplay'
import { fmtNum, SourceBadge, StatCard, DemoNotice, qualityClass } from './shared'

type SortKey = 'id' | 'name' | 'class' | 'owner_name' | 'item_count'

export function StorageTab() {
  const [containers, setContainers] = useState<StorageContainer[]>([])
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortKey>('item_count')
  const [dir, setDir] = useState<'asc' | 'desc'>('desc')
  const [selected, setSelected] = useState<StorageContainer | null>(null)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getStorage()
      setContainers(r.containers); setSource(r.source); setLiveError(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const toggleSort = (col: SortKey) => {
    if (sort === col) setDir(d => (d === 'asc' ? 'desc' : 'asc'))
    else { setSort(col); setDir(col === 'item_count' ? 'desc' : 'asc') }
  }

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    let out = containers
    if (q) out = out.filter(c =>
      c.name.toLowerCase().includes(q) || c.owner_name.toLowerCase().includes(q) ||
      c.class.toLowerCase().includes(q) || c.item_names.some(n => n.toLowerCase().includes(q)))
    const mul = dir === 'asc' ? 1 : -1
    return [...out].sort((a, b) => {
      const av = a[sort], bv = b[sort]
      if (typeof av === 'string' || typeof bv === 'string') return String(av).localeCompare(String(bv)) * mul
      return ((av as number) - (bv as number)) * mul
    })
  }, [containers, search, sort, dir])

  const totalItems = useMemo(() => containers.reduce((s, c) => s + c.item_count, 0), [containers])

  return (
    <div>
      <section className="grid grid-cols-2 md:grid-cols-3 gap-3 mb-4">
        <StatCard label="Containers" value={fmtNum(containers.length)} icon="Package" />
        <StatCard label="Stored items" value={fmtNum(totalItems)} icon="Boxes" />
        <StatCard label="Owners" value={fmtNum(new Set(containers.map(c => c.owner_name).filter(Boolean)).size)} icon="Users" />
      </section>

      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input type="text" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search containers, owners, items…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="storage data" />}
      {source === 'live' && (
        <div className="card p-3 mb-4 text-xs text-warning border-l-2 border-warning flex items-start gap-2">
          <Icon name="AlertTriangle" size={14} className="shrink-0 mt-0.5" />
          <span>
            Items added to or removed from a container only become visible to players after a <strong>server zone restart</strong>.
            The game caches container contents while the zone is loaded.
          </span>
        </div>
      )}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <Th label="Container" col="name" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="Type" col="class" sort={sort} dir={dir} onSort={toggleSort} className="hidden md:table-cell" />
              <Th label="Owner" col="owner_name" sort={sort} dir={dir} onSort={toggleSort} className="hidden lg:table-cell" />
              <Th label="Map" col="id" sort={sort} dir={dir} onSort={toggleSort} className="hidden xl:table-cell" />
              <Th label="Items" col="item_count" sort={sort} dir={dir} onSort={toggleSort} align="right" />
            </tr>
          </thead>
          <tbody>
            {loading && containers.length === 0 && (
              <tr><td colSpan={5} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading storage…
              </td></tr>
            )}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={5} className="px-3 py-8 text-center text-text-dim">No containers match.</td></tr>
            )}
            {rows.map(c => (
              <tr key={c.id} onClick={() => setSelected(c)}
                className="border-b border-border/50 hover:bg-surface-2 cursor-pointer">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[240px]">{c.name || <span className="text-text-dim italic">Unnamed</span>}</div>
                  <div className="text-[11px] text-text-dim font-mono">#{c.id}</div>
                </td>
                <td className="px-3 py-2 hidden md:table-cell text-text-muted">{c.class}</td>
                <td className="px-3 py-2 hidden lg:table-cell text-text-muted">{c.owner_name || '—'}</td>
                <td className="px-3 py-2 hidden xl:table-cell text-text-dim">{c.map || '—'}</td>
                <td className="px-3 py-2 text-right font-mono">{fmtNum(c.item_count)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {selected && <ContainerDetail container={selected} demo={source === 'demo'} onClose={() => setSelected(null)} onChanged={() => { void load() }} />}
    </div>
  )
}

function ContainerDetail({ container, demo, onClose, onChanged }: {
  container: StorageContainer; demo: boolean; onClose: () => void; onChanged: () => void
}) {
  const [items, setItems] = useState<InventoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [flash, setFlash] = useState<string | null>(null)
  const [showAdd, setShowAdd] = useState(false)
  const canWrite = !demo

  const loadItems = useCallback(() => {
    let alive = true
    setLoading(true); setError(null)
    getStorageItems(container.id, demo)
      .then(r => { if (alive) setItems(r.items) })
      .catch(e => { if (alive) setError(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [container.id, demo])
  useEffect(() => loadItems(), [loadItems])

  const afterWrite = (msg: string) => {
    setFlash(msg)
    loadItems()
    onChanged()
  }

  const handleDelete = async (it: InventoryItem) => {
    if (!window.confirm(`Remove ${it.name} (×${it.stack_size}) from this container? This cannot be undone.`)) return
    setBusy(true); setError(null); setFlash(null)
    try {
      const r = await deleteStorageItem(it.id)
      afterWrite(r.message || 'Item removed.')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const handleAdd = async (staged: StorageGiveItemInput[]) => {
    setBusy(true); setError(null); setFlash(null)
    try {
      const r = await giveItemsToStorage(container.id, staged)
      setShowAdd(false)
      afterWrite(r.message || 'Items added.')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-40 flex justify-end" onClick={onClose}>
      <div className="absolute inset-0 bg-black/50" />
      <div className="relative w-full max-w-md h-full bg-surface border-l border-border overflow-y-auto p-5" onClick={e => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <div>
            <h3 className="text-lg font-semibold text-text">{container.name || 'Unnamed container'}</h3>
            <div className="text-xs text-text-dim">{container.class} · #{container.id}</div>
            <div className="mt-1 flex items-center gap-2 text-xs text-text-muted">
              {container.owner_name && <span><Icon name="User" size={11} className="inline" /> {container.owner_name}</span>}
              {container.map && <span>· {container.map}</span>}
            </div>
          </div>
          <button onClick={onClose} className="text-text-dim hover:text-text"><Icon name="X" size={20} /></button>
        </div>

        {canWrite ? (
          <div className="flex flex-wrap gap-2 mb-3">
            <button className="btn-primary" disabled={busy} onClick={() => setShowAdd(s => !s)}>
              <Icon name="PackagePlus" size={14} /> Add Items
            </button>
          </div>
        ) : (
          <div className="text-xs text-text-dim mb-3 flex items-center gap-1.5">
            <Icon name="Lock" size={12} /> Editing is available when the live game database is connected.
          </div>
        )}

        {showAdd && <AddItemsForm busy={busy} onSubmit={handleAdd} onCancel={() => setShowAdd(false)} />}

        {flash && <div className="text-sm text-success mb-3 flex items-center gap-2"><Icon name="CheckCircle2" size={15} /> {flash}</div>}

        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Contents ({fmtNum(items.length || container.item_count)})</h4>
        {loading ? (
          <div className="text-text-dim text-sm py-4"><Icon name="Loader2" size={16} className="animate-spin inline" /> Loading…</div>
        ) : error ? (
          <div className="text-danger text-sm py-4 break-words">{error}</div>
        ) : items.length === 0 ? (
          <div className="text-text-dim text-sm py-4">Empty container.</div>
        ) : (
          <div className="space-y-1">
            {items.map(it => (
              <div key={it.id} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
                <span className="truncate max-w-[220px]">
                  <span className="text-text">{it.name}</span>
                  {it.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(it.quality)}`}>Q{it.quality}</span>}
                  <span className="ml-1.5 font-mono text-text-dim text-xs">×{fmtNum(it.stack_size)}</span>
                </span>
                {canWrite && (
                  <button className="text-danger/80 hover:text-danger shrink-0" title="Remove item" disabled={busy}
                    onClick={() => { void handleDelete(it) }}>
                    <Icon name="Trash2" size={14} />
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}

// Staged "Add Items" form: build a list of template/qty/quality rows, then
// submit them all at once (mirrors the reference implementation's AddItemsModal).
function AddItemsForm({ busy, onSubmit, onCancel }: {
  busy: boolean; onSubmit: (items: StorageGiveItemInput[]) => void; onCancel: () => void
}) {
  const [staged, setStaged] = useState<StorageGiveItemInput[]>([])
  const [template, setTemplate] = useState('')
  const [templateName, setTemplateName] = useState('')
  const [qty, setQty] = useState('1')
  const [quality, setQuality] = useState('0')

  const add = () => {
    const t = template.trim()
    if (!t || !isValidTemplateId(t)) return
    setStaged(s => [...s, { template: t, qty: Math.max(1, Number(qty) || 1), quality: Math.max(0, Number(quality) || 0) }])
    setTemplate(''); setTemplateName(''); setQty('1'); setQuality('0')
  }

  return (
    <div className="card p-3 mb-3 space-y-2">
      <ItemPicker
        label="Item — type to search by name or template id"
        value={template}
        displayValue={templateName || template}
        onChange={(tpl, item) => { setTemplate(tpl); setTemplateName(item ? item.name : '') }}
        disabled={busy}
      />
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quantity</label>
          <input type="number" min={1} value={qty} onChange={e => setQty(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <div>
          <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Quality (0–5)</label>
          <input type="number" min={0} max={5} value={quality} onChange={e => setQuality(e.target.value)}
            className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
      </div>
      <button className="btn-secondary w-full" onClick={add} disabled={busy || !isValidTemplateId(template)}>
        <Icon name="Plus" size={14} /> Add to list
      </button>

      {staged.length > 0 && (
        <div className="space-y-1 pt-1">
          {staged.map((s, i) => (
            <div key={i} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-1.5 border border-border/50">
              <span className="truncate max-w-[220px] text-text">
                {s.template}
                {s.quality > 0 && <span className={`ml-1.5 text-[11px] ${qualityClass(s.quality)}`}>Q{s.quality}</span>}
                <span className="ml-1.5 font-mono text-text-dim text-xs">×{fmtNum(s.qty)}</span>
              </span>
              <button className="text-danger/80 hover:text-danger shrink-0" title="Remove from list"
                onClick={() => setStaged(list => list.filter((_, j) => j !== i))}>
                <Icon name="X" size={14} />
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="flex justify-end gap-2 pt-1">
        <button className="btn-secondary" onClick={onCancel} disabled={busy}>Cancel</button>
        <button className="btn-primary" onClick={() => onSubmit(staged)} disabled={busy || staged.length === 0}>
          {busy ? <Icon name="Loader2" size={14} className="animate-spin" /> : <Icon name="Check" size={14} />} Add {staged.length || ''} item{staged.length === 1 ? '' : 's'}
        </button>
      </div>
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
