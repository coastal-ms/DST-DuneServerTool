import { useCallback, useEffect, useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import {
  getBlueprints, exportBlueprint, importBlueprint, downloadBlueprintFile, getPlayers,
  type BlueprintRow, type BlueprintFile, type DataSource, type Player,
} from '../../api/gameplay'
import { fmtNum, SourceBadge, StatCard, DemoNotice } from './shared'

type SortKey = 'id' | 'name' | 'owner_name' | 'pieces' | 'placeables'

export function BlueprintsTab() {
  const [blueprints, setBlueprints] = useState<BlueprintRow[]>([])
  const [source, setSource] = useState<DataSource>('demo')
  const [liveError, setLiveError] = useState<string | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortKey>('pieces')
  const [dir, setDir] = useState<'asc' | 'desc'>('desc')
  const [busyId, setBusyId] = useState<number | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const [showImport, setShowImport] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getBlueprints()
      setBlueprints(r.blueprints); setSource(r.source); setLiveError(r.liveError)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])
  useEffect(() => { void load() }, [load])

  const toggleSort = (col: SortKey) => {
    if (sort === col) setDir(d => (d === 'asc' ? 'desc' : 'asc'))
    else { setSort(col); setDir(col === 'name' || col === 'owner_name' ? 'asc' : 'desc') }
  }

  const handleExport = async (b: BlueprintRow) => {
    setBusyId(b.id); setError(null); setFlash(null)
    try {
      const r = await exportBlueprint(b.id, source === 'demo')
      downloadBlueprintFile(r.blueprint, r.filename)
      setFlash(`Exported ${r.filename}.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyId(null)
    }
  }

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    let out = blueprints
    if (q) out = out.filter(b =>
      b.name.toLowerCase().includes(q) || b.owner_name.toLowerCase().includes(q) || String(b.id).includes(q))
    const mul = dir === 'asc' ? 1 : -1
    return [...out].sort((a, b) => {
      const av = a[sort], bv = b[sort]
      if (typeof av === 'string' || typeof bv === 'string') return String(av).localeCompare(String(bv)) * mul
      return ((av as number) - (bv as number)) * mul
    })
  }, [blueprints, search, sort, dir])

  const totalPieces = useMemo(() => blueprints.reduce((s, b) => s + b.pieces, 0), [blueprints])
  const canWrite = source === 'live'

  return (
    <div>
      <section className="grid grid-cols-2 md:grid-cols-3 gap-3 mb-4">
        <StatCard label="Blueprints" value={fmtNum(blueprints.length)} icon="ScrollText" />
        <StatCard label="Total pieces" value={fmtNum(totalPieces)} icon="Blocks" />
        <StatCard label="Owners" value={fmtNum(new Set(blueprints.map(b => b.owner_name).filter(Boolean)).size)} icon="Users" />
      </section>

      <div className="card p-3 mb-4 flex flex-wrap items-center gap-2">
        <div className="relative flex-1 min-w-[200px]">
          <Icon name="Search" size={15} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-text-dim" />
          <input type="text" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search blueprints or owners…"
            className="w-full pl-8 pr-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50" />
        </div>
        <button className="btn-primary" onClick={() => setShowImport(true)} disabled={!canWrite}
          title={canWrite ? 'Import a blueprint file into a player inventory' : 'Importing is available when the live game database is connected.'}>
          <Icon name="Upload" size={15} /> Import Blueprint
        </button>
        <button className="btn-secondary" onClick={() => { void load() }} disabled={loading}>
          <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
        </button>
        <a className="btn-secondary" href="https://dune.layout.tools/" target="_blank" rel="noopener noreferrer"
          title="Open the Dune base/blueprint layout designer in a new tab">
          <Icon name="ExternalLink" size={15} /> Blueprint Designer
        </a>
        <SourceBadge source={source} />
      </div>

      {source === 'demo' && <DemoNotice liveError={liveError} what="blueprint data" />}
      {!canWrite && (
        <div className="text-xs text-text-dim mb-4 flex items-center gap-1.5">
          <Icon name="Lock" size={12} /> Importing is available when the live game database is connected. Export works on demo data too.
        </div>
      )}
      {flash && <div className="card p-3 mb-4 text-sm text-success break-words flex items-center gap-2"><Icon name="CheckCircle2" size={15} /> {flash}</div>}
      {error && <div className="card p-3 mb-4 text-sm text-danger break-words">{error}</div>}

      <div className="card overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wider text-text-dim border-b border-border">
              <Th label="Blueprint" col="name" sort={sort} dir={dir} onSort={toggleSort} />
              <Th label="Owner" col="owner_name" sort={sort} dir={dir} onSort={toggleSort} className="hidden md:table-cell" />
              <Th label="Pieces" col="pieces" sort={sort} dir={dir} onSort={toggleSort} align="right" />
              <Th label="Placeables" col="placeables" sort={sort} dir={dir} onSort={toggleSort} align="right" className="hidden sm:table-cell" />
              <th className="px-3 py-2 font-medium text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading && blueprints.length === 0 && (
              <tr><td colSpan={5} className="px-3 py-8 text-center text-text-dim">
                <Icon name="Loader2" size={18} className="animate-spin inline" /> Loading blueprints…
              </td></tr>
            )}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={5} className="px-3 py-8 text-center text-text-dim">No blueprints match.</td></tr>
            )}
            {rows.map(b => (
              <tr key={b.id} className="border-b border-border/50 hover:bg-surface-2">
                <td className="px-3 py-2">
                  <div className="font-medium text-text truncate max-w-[280px]">{b.name || <span className="text-text-dim italic">Unnamed blueprint</span>}</div>
                  <div className="text-[11px] text-text-dim font-mono">#{b.id}</div>
                </td>
                <td className="px-3 py-2 hidden md:table-cell text-text-muted">{b.owner_name || '—'}</td>
                <td className="px-3 py-2 text-right font-mono">{fmtNum(b.pieces)}</td>
                <td className="px-3 py-2 text-right hidden sm:table-cell font-mono text-text-muted">{fmtNum(b.placeables)}</td>
                <td className="px-3 py-2 text-right">
                  <button className="btn-secondary py-1 px-2 text-xs" disabled={busyId === b.id}
                    onClick={() => { void handleExport(b) }} title="Download this blueprint as a portable JSON file">
                    {busyId === b.id ? <Icon name="Loader2" size={13} className="animate-spin" /> : <Icon name="Download" size={13} />} Export
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {showImport && <ImportModal demo={source === 'demo'} onClose={() => setShowImport(false)} onDone={() => { setShowImport(false); void load() }} />}
    </div>
  )
}

function ImportModal({ demo, onClose, onDone }: { demo: boolean; onClose: () => void; onDone: () => void }) {
  const [players, setPlayers] = useState<Player[]>([])
  const [playerId, setPlayerId] = useState<number | ''>('')
  const [bp, setBp] = useState<BlueprintFile | null>(null)
  const [fileName, setFileName] = useState('')
  const [parseErr, setParseErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [flash, setFlash] = useState<string | null>(null)

  useEffect(() => {
    let alive = true
    getPlayers(demo).then(r => { if (alive) setPlayers(r.players) }).catch(() => {})
    return () => { alive = false }
  }, [demo])

  const onFile = async (file: File | undefined) => {
    setParseErr(null); setBp(null); setFileName('')
    if (!file) return
    try {
      const text = await file.text()
      const parsed = JSON.parse(text) as BlueprintFile
      if (!parsed || !Array.isArray(parsed.instances)) {
        throw new Error('Not a valid blueprint file (missing instances).')
      }
      setBp(parsed); setFileName(file.name)
    } catch (e) {
      setParseErr(e instanceof Error ? e.message : String(e))
    }
  }

  const submit = async () => {
    if (!bp || playerId === '') return
    setBusy(true); setErr(null); setFlash(null)
    try {
      const r = await importBlueprint(Number(playerId), bp)
      setFlash(r.message || 'Blueprint imported.')
      setTimeout(onDone, 1200)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy(false)
    }
  }

  const counts = bp
    ? `${bp.instances?.length ?? 0} pieces · ${bp.placeables?.length ?? 0} placeables · ${bp.pentashields?.length ?? 0} pentashields`
    : ''

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4" onClick={onClose}>
      <div className="absolute inset-0 bg-black/50" />
      <div className="relative w-full max-w-md bg-surface border border-border rounded-xl p-5" onClick={e => e.stopPropagation()}>
        <div className="flex items-start justify-between mb-4">
          <h3 className="text-lg font-semibold text-text flex items-center gap-2"><Icon name="Upload" size={18} /> Import Blueprint</h3>
          <button onClick={onClose} className="text-text-dim hover:text-text"><Icon name="X" size={20} /></button>
        </div>

        <p className="text-xs text-text-muted mb-4">
          Recreate a blueprint from a JSON file into a player's backpack. The target player must be <span className="text-warning">offline</span>.
        </p>

        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1">Blueprint file (.json)</label>
        <input type="file" accept="application/json,.json"
          onChange={e => { void onFile(e.target.files?.[0]) }}
          className="w-full text-sm text-text-muted file:mr-3 file:py-1.5 file:px-3 file:rounded-lg file:border-0 file:bg-surface-2 file:text-text file:text-sm mb-1" />
        {fileName && <div className="text-[11px] text-success mb-1">{fileName} — {counts}</div>}
        {parseErr && <div className="text-[11px] text-danger mb-1">{parseErr}</div>}

        <label className="block text-[11px] uppercase tracking-wider text-text-dim mb-1 mt-3">Target player</label>
        <select value={playerId} onChange={e => setPlayerId(e.target.value === '' ? '' : Number(e.target.value))}
          className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm mb-3 focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50">
          <option value="">Select a player…</option>
          {players.map(p => (
            <option key={p.id} value={p.id}>{p.name || `Player #${p.id}`}{p.online_status ? ` (${p.online_status})` : ''}</option>
          ))}
        </select>

        {flash && <div className="text-sm text-success mb-3 flex items-center gap-2"><Icon name="CheckCircle2" size={15} /> {flash}</div>}
        {err && <div className="text-sm text-danger mb-3 break-words">{err}</div>}

        <div className="flex justify-end gap-2">
          <button className="btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
          <button className="btn-primary" onClick={() => { void submit() }} disabled={busy || !bp || playerId === ''}>
            {busy ? <Icon name="Loader2" size={14} className="animate-spin" /> : <Icon name="Upload" size={14} />} Import
          </button>
        </div>
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
