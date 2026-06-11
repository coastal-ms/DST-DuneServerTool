import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getBases, type BaseRow, type DataSource } from '../../api/gameplay'
import { fmtNum, SourceBadge, StatCard, DemoNotice } from './shared'

type SortKey = 'id' | 'name' | 'pieces' | 'placeables'

export function BasesTab() {
  const [bases, setBases] = useState<BaseRow[]>([])
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortKey>('pieces')
  const [dir, setDir] = useState<'asc' | 'desc'>('desc')

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getBases()
      setBases(r.bases); setSource(r.source); setLiveError(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const toggleSort = (col: SortKey) => {
    if (sort === col) setDir(d => (d === 'asc' ? 'desc' : 'asc'))
    else { setSort(col); setDir(col === 'name' ? 'asc' : 'desc') }
  }

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    let out = bases
    if (q) out = out.filter(b => b.name.toLowerCase().includes(q) || String(b.id).includes(q))
    const mul = dir === 'asc' ? 1 : -1
    return [...out].sort((a, b) => {
      const av = a[sort], bv = b[sort]
      if (typeof av === 'string' || typeof bv === 'string') return String(av).localeCompare(String(bv)) * mul
      return ((av as number) - (bv as number)) * mul
    })
  }, [bases, search, sort, dir])

  const totalPieces = useMemo(() => bases.reduce((s, b) => s + b.pieces, 0), [bases])
  const totalPlaceables = useMemo(() => bases.reduce((s, b) => s + b.placeables, 0), [bases])

  return (
    <div>
      <section className="grid grid-cols-2 md:grid-cols-3 gap-3 mb-4">
        <StatCard label="Bases" value={fmtNum(bases.length)} icon="Castle" />
        <StatCard label="Building pieces" value={fmtNum(totalPieces)} icon="Blocks" />
        <StatCard label="Placeables" value={fmtNum(totalPlaceables)} icon="Package" />
      </section>

      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input type="text" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search bases…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="base data" />}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <Th label="Base" col="name" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="ID" col="id" sort={sort} dir={dir} onSort={toggleSort} align="right" className="hidden sm:table-cell" />
              <Th label="Pieces" col="pieces" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <Th label="Placeables" col="placeables" sort={sort} dir={dir} onSort={toggleSort} align="right" />
            </tr>
          </thead>
          <tbody>
            {loading && bases.length === 0 && (
              <tr><td colSpan={4} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading bases…
              </td></tr>
            )}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={4} className="px-3 py-8 text-center text-text-dim">No bases match.</td></tr>
            )}
            {rows.map(b => (
              <tr key={b.id} className="border-b border-border/50 hover:bg-surface-2">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[280px]">{b.name || <span className="text-text-dim italic">Unnamed base</span>}</div>
                </td>
                <td className="px-3 py-2 text-right hidden sm:table-cell font-mono text-text-dim">{b.id}</td>
                <td className="px-3 py-2 text-right font-mono">{fmtNum(b.pieces)}</td>
                <td className="px-3 py-2 text-right font-mono text-text-muted">{fmtNum(b.placeables)}</td>
              </tr>
            ))}
          </tbody>
        </table>
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
