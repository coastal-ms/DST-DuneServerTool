import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import { getSietches, setSietchConfig, type SietchOverview } from '../api/sietches'

const GATE_PHRASE = 'I UNDERSTAND'
const SESSION_KEY = 'dune.sietches.unlocked'

function useUnlocked(): [boolean, () => void] {
  const [unlocked, setUnlocked] = useState<boolean>(() => sessionStorage.getItem(SESSION_KEY) === '1')
  const unlock = useCallback(() => {
    sessionStorage.setItem(SESSION_KEY, '1')
    setUnlocked(true)
  }, [])
  return [unlocked, unlock]
}

function Gate({ onUnlock }: { onUnlock: () => void }) {
  const [phrase, setPhrase] = useState('')
  const matches = phrase.trim().toUpperCase() === GATE_PHRASE
  return (
    <div className="card p-6 max-w-2xl">
      <div className="flex items-start gap-3 mb-3">
        <Icon name="AlertTriangle" size={20} className="text-warning shrink-0 mt-0.5" />
        <div>
          <h2 className="text-lg font-semibold text-warning">Experimental — read this first</h2>
          <p className="text-sm text-text mt-2">
            This feature patches the battlegroup Kubernetes CRD directly to add or remove
            additional Survival_1 shards (sietches). Each sietch costs ~12 GB of RAM and
            requires the UDP port range 7777-7900 to be open on the host.
          </p>
          <ul className="text-sm text-text-dim mt-2 list-disc ml-5 space-y-1">
            <li>Changes require a battlegroup restart to take effect.</li>
            <li>Removing a sietch destroys its world partition and any data in it.</li>
            <li>Unsupported by Funcom. You're on your own if something breaks.</li>
          </ul>
        </div>
      </div>
      <label className="block text-xs uppercase tracking-wider text-text-dim mt-4 mb-1">
        Type <span className="font-mono text-accent">{GATE_PHRASE}</span> to continue
      </label>
      <div className="flex gap-2">
        <input
          type="text"
          value={phrase}
          onChange={e => setPhrase(e.target.value)}
          className="flex-1 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
          autoFocus
          placeholder={GATE_PHRASE}
        />
        <button
          className="btn-primary"
          disabled={!matches}
          onClick={onUnlock}
        >
          Unlock
        </button>
      </div>
    </div>
  )
}

export function Sietches() {
  const [unlocked, unlock] = useUnlocked()
  const [data, setData] = useState<SietchOverview | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [applying, setApplying] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const [count, setCount] = useState(1)
  const [rename, setRename] = useState(false)
  const [names, setNames] = useState<string[]>([])

  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getSietches()
      setData(r)
      const c = Math.max(1, Math.min(6, r.sietchCount || 1))
      setCount(c)
      setNames(r.sietches.map(s => s.name ?? ''))
      setRename(Boolean(r.named))
    } catch (e) {
      setData(null)
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void refresh() }, [refresh])

  // Keep the names array length synced to the requested sietch count.
  useEffect(() => {
    setNames(prev => {
      const next = prev.slice(0, count)
      while (next.length < count) next.push('')
      return next
    })
  }, [count])

  const estTotalGB = data ? data.baseInfraGB + data.ramPerSietchGB * count : 0
  const exceedsHost = Boolean(data && data.hostRamGB > 0 && estTotalGB > data.hostRamGB)
  const showNames = count >= 2 && rename

  const setName = (i: number, v: string) => setNames(prev => prev.map((n, idx) => (idx === i ? v : n)))

  const onApply = useCallback(async () => {
    if (!data) return
    const applyNames = count >= 2 && rename
    if (applyNames && names.slice(0, count).some(n => !n.trim())) {
      setError('Give every sietch a name, or uncheck renaming to use the default Funcom name.')
      return
    }
    const warn = exceedsHost
      ? `\n\nWARNING: ~${estTotalGB} GB estimated exceeds ${data.hostRamGB} GB host RAM — the VM may swap or fail to start a shard.`
      : ''
    const nameNote = applyNames
      ? '\n\nThe MAIN sietch will also be renamed, and DST will disable the global server-name line in UserEngine.ini.'
      : (count >= 2 ? '\n\nAll shards will use the default Funcom name.' : '')
    if (!confirm(`Configure ${count} Hagga sietch${count === 1 ? '' : 'es'} and clean-restart the battlegroup?${nameNote}${warn}`)) return
    setApplying(true); setMessage(null); setError(null)
    try {
      const r = await setSietchConfig(count, applyNames ? names.slice(0, count) : [], applyNames)
      setMessage(r.message ?? 'Applied. Battlegroup restarting — watch Server Health.')
      setTimeout(() => { void refresh() }, 4000)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setApplying(false)
    }
  }, [data, count, rename, names, exceedsHost, estTotalGB, refresh])

  // Already running >1 sietch? Skip the experimental gate — the user has clearly
  // been here before, and re-typing "I UNDERSTAND" every visit is just noise.
  const multiSietch = Boolean(data && data.sietchCount > 1)
  const gated = !unlocked && !multiSietch

  if (gated) {
    // Don't flash the gate while the first load is still resolving whether this
    // server is already multi-sietch.
    if (loading && data === null && error === null) {
      return (
        <>
          <PageHeader title="Sietches" icon="Network" description="Run multiple Hagga Basin (Survival_1) shards (experimental)." />
          <div className="card p-6"><p className="text-sm text-text-dim italic">Checking sietch state…</p></div>
        </>
      )
    }
    return (
      <>
        <PageHeader title="Sietches" icon="Network" description="Run multiple Hagga Basin (Survival_1) shards (experimental)." />
        <Gate onUnlock={unlock} />
      </>
    )
  }

  return (
    <>
      <PageHeader
        title="Sietches"
        icon="Network"
        description="Run multiple Hagga Basin (Survival_1) shards (experimental)."
        actions={
          <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading || applying}>
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        }
      />

      {error && <div className="card p-4 mb-4 border-danger/40"><p className="text-sm text-danger break-words">{error}</p></div>}
      {message && <div className="card p-4 mb-4 border-accent/40"><p className="text-sm text-text break-words">{message}</p></div>}

      {!data ? (
        <div className="card p-6"><p className="text-sm text-text-dim italic">{loading ? 'Loading…' : 'No data yet.'}</p></div>
      ) : (
        <>
          <section className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            <SummaryTile label="Current sietches" value={String(data.sietchCount)} icon="Network" />
            <SummaryTile label="VM RAM" value={data.vmRamGB > 0 ? `${data.vmRamGB} GB` : '—'} icon="Cpu" />
            <SummaryTile label="Host RAM" value={data.hostRamGB > 0 ? `${data.hostRamGB} GB` : '—'} icon="Server" />
            <SummaryTile
              label={`RAM for ${count}`}
              value={`~${estTotalGB} GB`}
              icon="TrendingUp"
              tone={exceedsHost ? 'text-danger' : 'text-text'}
              sub={exceedsHost ? `exceeds host (${data.hostRamGB} GB)` : `base ${data.baseInfraGB} + ${data.ramPerSietchGB} × ${count}`}
            />
          </section>

          {/* Current shards */}
          <section className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4 mb-6">
            {data.sietches.map((s, i) => (
              <div key={s.partitionId ?? s.setIndex} className="card p-5">
                <div className="flex items-center justify-between mb-2">
                  <span className="text-xs uppercase tracking-wider text-text-dim">Sietch #{i + 1}</span>
                  <span className={s.replicas && s.replicas >= 1 ? 'pill-success' : 'pill-muted'}>
                    <Icon name={s.replicas && s.replicas >= 1 ? 'CheckCircle2' : 'CircleDashed'} size={10} />
                    {s.replicas ?? '?'} replica{s.replicas === 1 ? '' : 's'}
                  </span>
                </div>
                <div className="text-lg font-semibold mb-2">{s.name || s.map}</div>
                <dl className="grid grid-cols-[110px_1fr] gap-y-1 text-xs">
                  <dt className="text-text-dim">Map</dt>
                  <dd className="font-mono">{s.map}</dd>
                  <dt className="text-text-dim">Partition</dt>
                  <dd className="font-mono">{s.partitionId ?? (s.partitions.join(', ') || '—')}</dd>
                  <dt className="text-text-dim">Memory limit</dt>
                  <dd className="font-mono">{s.memoryLimit ?? '?'}</dd>
                </dl>
              </div>
            ))}
          </section>

          {/* Configure */}
          <section className="card p-5 max-w-2xl">
            <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted mb-4 flex items-center gap-2">
              <Icon name="Settings2" size={14} className="text-accent" /> Configure Hagga sietches
            </h2>

            <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">Number of Hagga sietches (1–6)</label>
            <input
              type="number" min={1} max={6} value={count} disabled={applying || loading}
              onChange={e => setCount(Math.max(1, Math.min(6, Math.floor(Number(e.target.value) || 1))))}
              className="w-28 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text font-mono focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 mb-1 disabled:opacity-50"
            />
            <p className="text-xs text-text-dim mb-4">Sets both the active and max Hagga servers. Each shard is a separate Hagga Basin world (~{data.ramPerSietchGB} GB RAM).</p>

            {count >= 2 && (
              <label className="flex items-start gap-2 text-sm text-text mb-3 cursor-pointer select-none">
                <input type="checkbox" checked={rename} disabled={applying || loading} onChange={e => setRename(e.target.checked)} className="accent-accent mt-0.5 disabled:opacity-50" />
                <span>
                  Give each sietch its own name.
                  <span className="block text-xs text-text-dim mt-0.5">
                    Renames the MAIN sietch too and disables the global server-name line in <span className="font-mono">UserEngine.ini</span>. Leave unchecked to use Funcom's single global name for all shards.
                  </span>
                </span>
              </label>
            )}

            {showNames && (
              <div className="space-y-2 mb-4">
                {Array.from({ length: count }).map((_, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <span className="text-xs text-text-dim w-20 shrink-0">{i === 0 ? 'Main' : `Sietch ${i + 1}`}</span>
                    <input
                      type="text" value={names[i] ?? ''} maxLength={40} disabled={applying || loading}
                      onChange={e => setName(i, e.target.value)}
                      placeholder={i === 0 ? 'e.g. Hagga Basin' : `e.g. Sietch ${i + 1}`}
                      className="flex-1 px-3 py-2 rounded-lg bg-surface-2 border border-border text-text focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 disabled:opacity-50"
                    />
                  </div>
                ))}
                <p className="text-xs text-text-dim">Apostrophes ( ' ) and pipes ( | ) aren't allowed in names.</p>
              </div>
            )}

            {exceedsHost && (
              <div className="card p-3 mb-3 border-l-2 border-danger bg-danger/5 text-xs text-text-muted">
                <Icon name="AlertTriangle" size={13} className="text-danger inline mr-1" />
                ~{estTotalGB} GB estimated exceeds {data.hostRamGB} GB host RAM. The VM may swap or a shard may fail to start.
              </div>
            )}

            <button className="btn-primary" onClick={() => { void onApply() }} disabled={applying || loading}>
              <Icon name={applying ? 'Loader2' : 'Check'} size={14} className={applying ? 'animate-spin' : ''} />
              {applying ? 'Applying…' : 'Apply & clean-restart'}
            </button>
            <p className="text-xs text-text-dim mt-2">DST applies the change and performs a clean battlegroup restart (~2–3 min). Watch Server Health for the shards to come back.</p>
          </section>
        </>
      )}
    </>
  )
}

function SummaryTile({ label, value, icon, tone = 'text-text', sub }: {
  label: string; value: string; icon: string; tone?: string; sub?: string
}) {
  return (
    <div className="card card-hover p-4">
      <div className="flex items-center justify-between">
        <span className="text-xs uppercase tracking-wider text-text-dim">{label}</span>
        <Icon name={icon} size={16} className={tone} />
      </div>
      <div className={`mt-2 text-2xl font-semibold truncate ${tone}`}>{value}</div>
      {sub && <div className="mt-1 text-xs text-text-dim truncate">{sub}</div>}
    </div>
  )
}
