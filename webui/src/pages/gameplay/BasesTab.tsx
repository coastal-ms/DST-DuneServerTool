import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getBases, exportBase, destroyClaim, downloadBlueprintFile, type BaseRow, type DataSource } from '../../api/gameplay'
import { fmtNum, SourceBadge, StatCard, DemoNotice } from './shared'

type SortKey = 'id' | 'name' | 'owner' | 'pieces' | 'placeables'

export function BasesTab() {
  const [bases, setBases] = useState<BaseRow[]>([])
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortKey>('pieces')
  const [dir, setDir] = useState<'asc' | 'desc'>('desc')
  const [busyId, setBusyId] = useState<number | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [confirmBase, setConfirmBase] = useState<BaseRow | null>(null)
  const [ackBackup, setAckBackup] = useState(false)
  const [destroying, setDestroying] = useState(false)

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

  const handleExport = async (b: BaseRow) => {
    setBusyId(b.id); setError(null); setFlash(null)
    try {
      const r = await exportBase(b.id, source === 'demo')
      downloadBlueprintFile(r.blueprint, r.filename)
      setFlash(`Exported ${r.filename}.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyId(null)
    }
  }

  const handleDestroy = async () => {
    if (!confirmBase || !confirmBase.totemId) return
    setDestroying(true); setError(null); setFlash(null)
    try {
      const r = await destroyClaim(confirmBase.totemId)
      setFlash(r.message || `Released claim (totem ${confirmBase.totemId}).`)
      setConfirmBase(null); setAckBackup(false)
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setDestroying(false)
    }
  }

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
      {flash && <div className="card p-3 mb-4 text-sm text-success break-words flex items-center gap-2"><Icon name="CheckCircle2" size={15} /> {flash}</div>}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <Th label="Base" col="name" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="Owner" col="owner" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="ID" col="id" sort={sort} dir={dir} onSort={toggleSort} align="right" className="hidden sm:table-cell" />
              <Th label="Pieces" col="pieces" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <Th label="Placeables" col="placeables" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <th className="px-3 py-2 font-medium text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading && bases.length === 0 && (
              <tr><td colSpan={6} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading bases…
              </td></tr>
            )}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={6} className="px-3 py-8 text-center text-text-dim">No bases match.</td></tr>
            )}
            {rows.map(b => (
              <tr key={b.id} className="border-b border-border/50 hover:bg-surface-2">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[280px]">{b.name || <span className="text-text-dim italic">Unnamed base</span>}</div>
                </td>
                <td className="px-3 py-2 text-text-muted truncate max-w-[160px]">{b.owner || <span className="text-text-dim">—</span>}</td>
                <td className="px-3 py-2 text-right hidden sm:table-cell font-mono text-text-dim">{b.id}</td>
                <td className="px-3 py-2 text-right font-mono">{fmtNum(b.pieces)}</td>
                <td className="px-3 py-2 text-right font-mono text-text-muted">{fmtNum(b.placeables)}</td>
                <td className="px-3 py-2 text-right whitespace-nowrap">
                  <button className="btn-secondary py-1 px-2 text-xs" disabled={busyId === b.id}
                    onClick={() => { void handleExport(b) }} title="Download this base as a portable blueprint JSON file">
                    {busyId === b.id ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Download" size={13} />} Export
                  </button>
                  <button className="btn-secondary py-1 px-2 text-xs text-danger ml-2" disabled={!b.totemId || source === 'demo'}
                    onClick={() => { setConfirmBase(b); setAckBackup(false) }}
                    title={b.totemId ? "Release this base's land claim (removes ownership)" : 'No land claim on this base'}>
                    <Icon name="Trash2" size={13} /> Release claim
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {confirmBase && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4" onClick={() => { if (!destroying) setConfirmBase(null) }}>
          <div className="absolute inset-0 bg-black/50" />
          <div className="relative w-full max-w-md bg-surface border border-border rounded-xl p-5" onClick={e => e.stopPropagation()}>
            <div className="flex items-start justify-between mb-3">
              <h3 className="text-lg font-semibold text-text flex items-center gap-2"><Icon name="AlertTriangle" size={18} className="text-danger" /> Release base claim</h3>
              <button onClick={() => setConfirmBase(null)} disabled={destroying} className="text-text-dim hover:text-text"><Icon name="X" size={20} /></button>
            </div>

            <p className="text-sm text-text-muted mb-3">
              This deletes the land claim (totem <span className="font-mono text-text">#{confirmBase.totemId}</span>) for{' '}
              <span className="text-text font-medium">{confirmBase.name || 'this unnamed base'}</span>
              {confirmBase.owner && <> owned by <span className="text-text font-medium">{confirmBase.owner}</span></>}.
              {' '}Ownership and all permission grants are removed. Building pieces stay in the world as unclaimed
              structures and take effect after the next <span className="text-warning">battlegroup restart</span>.
            </p>

            <div className="card p-3 mb-3 border-l-2 border-danger bg-danger/5 text-xs text-text-muted flex items-start gap-2">
              <Icon name="AlertTriangle" size={15} className="text-danger mt-0.5 shrink-0" />
              <span>
                <span className="text-danger font-semibold">Make sure you have a recent backup before deleting.</span>{' '}
                This edits the live game database directly and cannot be undone from the tool. Take a database backup first.
              </span>
            </div>

            <label className="flex items-center gap-2 text-sm text-text mb-4 cursor-pointer select-none">
              <input type="checkbox" checked={ackBackup} onChange={e => setAckBackup(e.target.checked)} className="accent-danger" />
              I have a backup and understand this removes the claim.
            </label>

            <div className="flex justify-end gap-2">
              <button className="btn-secondary" onClick={() => setConfirmBase(null)} disabled={destroying}>Cancel</button>
              <button className="btn-primary bg-danger hover:bg-danger/90 border-danger" onClick={() => { void handleDestroy() }} disabled={destroying || !ackBackup}>
                {destroying ? <Icon name="Loader2" size={14} className="animate-spin" /> : <Icon name="Trash2" size={14} />} Release claim
              </button>
            </div>
          </div>
        </div>
      )}
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
