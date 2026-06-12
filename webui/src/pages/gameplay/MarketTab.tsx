import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getMarketItems, getMarketStats, getMarketListings, getMarketSales, getMarketCategories,
  type MarketItem, type MarketListing, type MarketSale, type MarketStats, type DataSource,
  type MarketSortKey,
} from '../../api/gameplay'
import { fmtSolari, fmtNum, SourceBadge, RarityTag, categoryLeaf } from './shared'

const PAGE_SIZE = 50

function SortTh({ label, col, sort, dir, onSort, align = 'left', className = '' }: {
  label: string
  col: MarketSortKey
  sort: MarketSortKey
  dir: 'asc' | 'desc'
  onSort: (col: MarketSortKey) => void
  align?: 'left' | 'center' | 'right'
  className?: string
}) {
  const active = sort === col
  const justify = align === 'right' ? 'justify-end' : align === 'center' ? 'justify-center' : 'justify-start'
  return (
    <th className={`px-3 py-2 font-medium ${className}`}>
      <button
        type="button"
        onClick={() => onSort(col)}
        className={`flex w-full items-center gap-1 ${justify} uppercase tracking-wider transition-colors ${active ? 'text-accent-bright' : 'hover:text-text'}`}
        aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}
      >
        <span>{label}</span>
        <Icon
          name={active ? (dir === 'asc' ? 'ChevronUp' : 'ChevronDown') : 'ChevronsUpDown'}
          size={12}
          className={active ? '' : 'opacity-40'}
        />
      </button>
    </th>
  )
}

export function MarketTab() {
  const [items, setItems] = useState<MarketItem[]>([])
  const [total, setTotal] = useState(0)
  const [stats, setStats] = useState<MarketStats | null>(null)
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>(undefined)
  const [categories, setCategories] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // Filters
  const [search, setSearch] = useState('')
  const [debouncedSearch, setDebouncedSearch] = useState('')
  const [category, setCategory] = useState('')
  const [owner, setOwner] = useState('')
  const [sort, setSort] = useState<MarketSortKey>('display_name')
  const [dir, setDir] = useState<'asc' | 'desc'>('asc')
  const [page, setPage] = useState(0)

  const toggleSort = (col: MarketSortKey) => {
    if (sort === col) setDir(d => (d === 'asc' ? 'desc' : 'asc'))
    else { setSort(col); setDir('asc') }
  }

  // Detail drawer
  const [selected, setSelected] = useState<MarketItem | null>(null)

  useEffect(() => {
    const id = window.setTimeout(() => setDebouncedSearch(search), 250)
    return () => window.clearTimeout(id)
  }, [search])

  useEffect(() => { setPage(0) }, [debouncedSearch, category, owner, sort, dir])

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [itemsRes, statsRes] = await Promise.all([
        getMarketItems({ search: debouncedSearch, category, owner, sort, dir, page, limit: PAGE_SIZE }),
        getMarketStats(),
      ])
      setItems(itemsRes.items)
      setTotal(itemsRes.total)
      setSource(itemsRes.source)
      setLiveError(itemsRes.liveError)
      setStats(statsRes.stats)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [debouncedSearch, category, owner, sort, dir, page])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    getMarketCategories().then(r => setCategories(r.categories)).catch(() => {})
  }, [])

  const topCategories = useMemo(() => {
    // Group by first segment for a compact dropdown.
    const set = new Set<string>()
    for (const c of categories) {
      const first = c.split('/')[0]
      if (first) set.add(first)
    }
    return Array.from(set).sort()
  }, [categories])

  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))

  return (
    <div>
      {/* Stats strip */}
      <section className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4">
        <StatCard label="Listings" value={fmtNum(stats?.total_listings)} icon="Tags"
          sub={`${fmtNum(stats?.bot_listings)} bot · ${fmtNum(stats?.player_listings)} player`} />
        <StatCard label="Unique items" value={fmtNum(stats?.unique_items)} icon="Boxes" />
        <StatCard label="Total stock" value={fmtNum(stats?.total_stock)} icon="Package"
          sub={`${fmtNum(stats?.bot_stock)} on bots`} />
        <StatCard label="Bot stock share" icon="Bot"
          value={stats && stats.total_stock > 0 ? `${Math.round((stats.bot_stock / stats.total_stock) * 100)}%` : '—'} />
      </section>

      {/* Toolbar */}
      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input
            type="text"
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder="Search items…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
          />
        </div>
        <select value={category} onChange={e => setCategory(e.target.value)}
          className="px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad">
          <option value="">All categories</option>
          {topCategories.map(c => <option key={c} value={c}>{c}</option>)}
        </select>
        <div className="flex rounded-lg border border-border overflow-hidden">
          {[['', 'All'], ['bot', 'Duke'], ['player', 'Players']].map(([val, label]) => (
            <button key={val}
              onClick={() => setOwner(val)}
              className={`px-3 py-2 text-sm ${owner === val ? 'bg-accent/20 text-accent-bright' : 'bg-surface-2 text-text-muted hover:text-text'}`}>
              {label}
            </button>
          ))}
        </div>
        <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && (
        <div className="card p-3 mb-4 text-xs text-text-muted border-l-2 border-accent flex items-start gap-2">
          <Icon name="Info" size={14} className="text-accent shrink-0 mt-0.5" />
          <span>
            Showing sample market data. {liveError ? <span className="text-warning">{liveError}</span> : 'Start the battlegroup'} — the
            Market reads the live game exchange automatically once the database is reachable.
          </span>
        </div>
      )}

      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      {/* Items table */}
      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <SortTh label="Item" col="display_name" sort={sort} dir={dir} onSort={toggleSort} />
              <SortTh label="Category" col="category" sort={sort} dir={dir} onSort={toggleSort} className="hidden md:table-cell" />
              <SortTh label="Tier" col="tier" sort={sort} dir={dir} onSort={toggleSort} align="center" className="hidden sm:table-cell" />
              <SortTh label="Rarity" col="rarity" sort={sort} dir={dir} onSort={toggleSort} className="hidden lg:table-cell" />
              <SortTh label="Lowest" col="lowest_price" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <SortTh label="Stock" col="total_stock" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <SortTh label="Listings" col="listing_count" sort={sort} dir={dir} onSort={toggleSort} align="right" className="hidden sm:table-cell" />
            </tr>
          </thead>
          <tbody>
            {loading && items.length === 0 && (
              <tr><td colSpan={7} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading market…
              </td></tr>
            )}
            {!loading && items.length === 0 && (
              <tr><td colSpan={7} className="px-3 py-8 text-center text-text-dim">No items match these filters.</td></tr>
            )}
            {items.map(it => (
              <tr key={`${it.template_id}-${it.quality}`}
                onClick={() => setSelected(it)}
                className="border-b border-border/50 hover:bg-surface-2 cursor-pointer">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[260px]">{it.display_name}</div>
                  <div className="text-[11px] text-text-dim font-mono truncate max-w-[260px]">{it.template_id}</div>
                </td>
                <td className="px-3 py-2 hidden md:table-cell text-text-muted">{categoryLeaf(it.category)}</td>
                <td className="px-3 py-2 text-center hidden sm:table-cell text-text-muted">{it.tier || '—'}</td>
                <td className="px-3 py-2 hidden lg:table-cell"><RarityTag rarity={it.rarity} /></td>
                <td className="px-3 py-2 text-right font-mono text-accent-bright">{fmtSolari(it.lowest_price)}</td>
                <td className="px-3 py-2 text-right font-mono">
                  {fmtNum(it.total_stock)}
                  {it.bot_stock > 0 && <span className="text-[11px] text-text-dim"> ({fmtNum(it.bot_stock)} Duke)</span>}
                </td>
                <td className="px-3 py-2 text-right hidden sm:table-cell text-text-muted">{it.listing_count}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Pagination */}
      {total > PAGE_SIZE && (
        <div className="flex items-center justify-between mt-3 text-sm text-text-muted">
          <span>{fmtNum(total)} items · page {page + 1} of {totalPages}</span>
          <div className="flex gap-2">
            <button className="btn-secondary" disabled={page === 0} onClick={() => setPage(p => Math.max(0, p - 1))}>
              <Icon name="ChevronLeft" size={15} /> Prev
            </button>
            <button className="btn-secondary" disabled={page + 1 >= totalPages} onClick={() => setPage(p => p + 1)}>
              Next <Icon name="ChevronRight" size={15} />
            </button>
          </div>
        </div>
      )}

      {selected && <ItemDetail item={selected} onClose={() => setSelected(null)} />}
    </div>
  )
}

function StatCard({ label, value, sub, icon }: { label: string; value: string; sub?: string; icon: string }) {
  return (
    <div className="card p-3">
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={15} className="text-accent" />
      </div>
      <div className="mt-1 text-xl font-semibold text-text truncate">{value}</div>
      {sub && <div className="text-[11px] text-text-dim truncate">{sub}</div>}
    </div>
  )
}

function ItemDetail({ item, onClose }: { item: MarketItem; onClose: () => void }) {
  const [listings, setListings] = useState<MarketListing[]>([])
  const [sales, setSales] = useState<MarketSale[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let alive = true
    setLoading(true)
    Promise.all([getMarketListings(item.template_id), getMarketSales()])
      .then(([l, s]) => {
        if (!alive) return
        setListings(l.listings)
        setSales(s.sales.filter(x => x.template_id === item.template_id))
      })
      .finally(() => { if (alive) setLoading(false) })
    return () => { alive = false }
  }, [item.template_id])

  return (
    <div className="fixed inset-0 z-40 flex justify-end" onClick={onClose}>
      <div className="absolute inset-0 bg-black/50" />
      <div className="relative w-full max-w-md h-full bg-surface border-l border-border overflow-y-auto p-5"
        onClick={e => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <div>
            <h3 className="text-lg font-semibold text-text">{item.display_name}</h3>
            <div className="text-xs text-text-dim font-mono">{item.template_id}</div>
            <div className="mt-1 flex items-center gap-2 text-xs text-text-muted">
              <span>{categoryLeaf(item.category)}</span>
              {item.tier ? <span>· Tier {item.tier}</span> : null}
              <RarityTag rarity={item.rarity} />
            </div>
          </div>
          <button onClick={onClose} className="text-text-dim hover:text-text"><Icon name="X" size={20} /></button>
        </div>

        <div className="grid grid-cols-3 gap-2 mb-4">
          <MiniStat label="Lowest" value={fmtSolari(item.lowest_price)} />
          <MiniStat label="Stock" value={fmtNum(item.total_stock)} />
          <MiniStat label="On Duke" value={fmtNum(item.bot_stock)} />
        </div>

        <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Active listings</h4>
        {loading ? (
          <div className="text-text-dim text-sm py-4"><Icon name="Loader2" size={16} className="animate-spin inline" /> Loading…</div>
        ) : listings.length === 0 ? (
          <div className="text-text-dim text-sm py-4">No active listings.</div>
        ) : (
          <div className="space-y-1 mb-4">
            {listings.map(l => (
              <div key={l.order_id} className="flex items-center justify-between text-sm bg-surface-2 rounded-lg px-3 py-2 border border-border/50">
                <span className={`flex items-center gap-1.5 ${l.owner_type === 'bot' ? 'text-accent-bright' : 'text-text'}`}>
                  <Icon name={l.owner_type === 'bot' ? 'Bot' : 'User'} size={13} />
                  {l.owner_name}
                </span>
                <span className="font-mono">
                  {fmtSolari(l.price)} <span className="text-text-dim text-xs">×{fmtNum(l.stock)}</span>
                </span>
              </div>
            ))}
          </div>
        )}

        {sales.length > 0 && (
          <>
            <h4 className="text-xs uppercase tracking-wider text-text-dim mb-2">Recent sales</h4>
            <div className="space-y-1">
              {sales.slice(0, 10).map(s => (
                <div key={s.order_id} className="flex items-center justify-between text-sm text-text-muted px-3 py-1.5">
                  <span>{s.seller_name}</span>
                  <span className="font-mono">{fmtSolari(s.price)} <span className="text-text-dim text-xs">×{fmtNum(s.quantity)}</span></span>
                </div>
              ))}
            </div>
          </>
        )}
      </div>
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
