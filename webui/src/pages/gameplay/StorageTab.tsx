import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getStorage, getStorageItems,
  type StorageContainer, type InventoryItem, type DataSource,
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

      {selected && <ContainerDetail container={selected} demo={source === 'demo'} onClose={() => setSelected(null)} />}
    </div>
  )
}

function ContainerDetail({ container, demo, onClose }: { container: StorageContainer; demo: boolean; onClose: () => void }) {
  const [items, setItems] = useState<InventoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    setLoading(true); setError(null)
    getStorageItems(container.id, demo)
      .then(r => { if (alive) setItems(r.items) })
      .catch(e => { if (alive) setError(e instanceof Error ? e.message : String(e)) })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [container.id, demo])

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

        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Contents ({fmtNum(container.item_count)})</h4>
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
                </span>
                <span className="font-mono text-text-muted">×{fmtNum(it.stack_size)}</span>
              </div>
            ))}
          </div>
        )}
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
