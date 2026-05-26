import { useCallback, useEffect, useState } from 'react'
import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'
import { ApiError } from '../api/client'
import { addSietch, getSietches, removeLastSietch, type SietchOverview } from '../api/sietches'

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
  const [busy, setBusy] = useState<'add' | 'remove' | null>(null)
  const [message, setMessage] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true); setError(null)
    try {
      const r = await getSietches()
      setData(r)
    } catch (e) {
      setData(null)
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { if (unlocked) void refresh() }, [unlocked, refresh])

  const onAdd = useCallback(async () => {
    if (!data) return
    const next = data.sietchCount + 1
    const ram = data.estimatedAfterAddGB
    const host = data.hostRamGB
    const warn = data.willExceedHostRam
      ? `\n\nWARNING: ${ram} GB estimated > ${host} GB host RAM. The VM may swap or fail to start the new shard.`
      : ''
    if (!confirm(`Add sietch #${next}? Estimated total RAM after add: ${ram} GB.${warn}\n\nA battlegroup restart is required to apply.`)) return
    setBusy('add'); setMessage(null); setError(null)
    try {
      const r = await addSietch()
      setMessage(r.message ?? 'Sietch added.')
      await refresh()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setBusy(null)
    }
  }, [data, refresh])

  const onRemove = useCallback(async () => {
    if (!data || data.sietchCount <= 1) return
    if (!confirm(`Remove sietch #${data.sietchCount}? Its world partition and any data inside it will be destroyed.\n\nA battlegroup restart is required to apply.`)) return
    setBusy('remove'); setMessage(null); setError(null)
    try {
      const r = await removeLastSietch()
      setMessage(r.message ?? 'Sietch removed.')
      await refresh()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : String(e))
    } finally {
      setBusy(null)
    }
  }, [data, refresh])

  if (!unlocked) {
    return (
      <>
        <PageHeader title="Sietches" icon="Network" description="Manage additional Survival_1 shards (experimental)." />
        <Gate onUnlock={unlock} />
      </>
    )
  }

  return (
    <>
      <PageHeader
        title="Sietches"
        icon="Network"
        description="Manage additional Survival_1 shards (experimental)."
        actions={
          <button className="btn-secondary" onClick={() => { void refresh() }} disabled={loading || busy !== null}>
            <Icon name="RefreshCw" size={15} className={loading ? 'animate-spin' : ''} /> Refresh
          </button>
        }
      />

      {error && (
        <div className="card p-4 mb-4 border-danger/40">
          <p className="text-sm text-danger break-words">{error}</p>
        </div>
      )}
      {message && (
        <div className="card p-4 mb-4 border-accent/40">
          <p className="text-sm text-text">{message}</p>
        </div>
      )}

      {!data ? (
        <div className="card p-6">
          <p className="text-sm text-text-dim italic">{loading ? 'Loading…' : 'No data yet.'}</p>
        </div>
      ) : (
        <>
          <section className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            <SummaryTile label="Sietches" value={String(data.sietchCount)} icon="Network" />
            <SummaryTile label="VM RAM" value={data.vmRamGB > 0 ? `${data.vmRamGB} GB` : '—'} icon="Cpu" />
            <SummaryTile label="Host RAM" value={data.hostRamGB > 0 ? `${data.hostRamGB} GB` : '—'} icon="Server" />
            <SummaryTile
              label="After add"
              value={`${data.estimatedAfterAddGB} GB`}
              icon="TrendingUp"
              tone={data.willExceedHostRam ? 'text-danger' : 'text-text'}
              sub={data.willExceedHostRam ? `exceeds host (${data.hostRamGB} GB)` : `base ${data.baseInfraGB} + ${data.ramPerSietchGB} × (${data.sietchCount} + 1)`}
            />
          </section>

          <section className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
            {data.sietches.map((s, i) => (
              <div key={s.setIndex} className="card p-5">
                <div className="flex items-center justify-between mb-2">
                  <span className="text-xs uppercase tracking-wider text-text-dim">Sietch #{i + 1}</span>
                  <span className={s.replicas && s.replicas >= 1 ? 'pill-success' : 'pill-muted'}>
                    <Icon name={s.replicas && s.replicas >= 1 ? 'CheckCircle2' : 'CircleDashed'} size={10} />
                    {s.replicas ?? '?'} replica{s.replicas === 1 ? '' : 's'}
                  </span>
                </div>
                <div className="text-lg font-semibold mb-2">{s.map}</div>
                <dl className="grid grid-cols-[110px,1fr] gap-y-1 text-xs">
                  <dt className="text-text-dim">Set index</dt>
                  <dd className="font-mono">{s.setIndex}</dd>
                  <dt className="text-text-dim">Partitions</dt>
                  <dd className="font-mono">{s.partitions.join(', ') || '—'}</dd>
                  <dt className="text-text-dim">Memory limit</dt>
                  <dd className="font-mono">{s.memoryLimit ?? '?'}</dd>
                </dl>
              </div>
            ))}

            <div className="card p-5 border-dashed border-2 border-border/60 flex flex-col items-center justify-center text-center min-h-[180px]">
              <Icon name="Plus" size={28} className="text-accent mb-2" />
              <p className="text-sm text-text-dim mb-3">
                Adds a new Survival_1 set with partition #{data.maxPartitionId + 1}.
              </p>
              <button
                className="btn-primary"
                onClick={() => { void onAdd() }}
                disabled={busy !== null || loading}
              >
                <Icon name={busy === 'add' ? 'Loader2' : 'Plus'} size={14} className={busy === 'add' ? 'animate-spin' : ''} />
                {busy === 'add' ? 'Adding…' : 'Add sietch'}
              </button>
            </div>
          </section>

          {data.sietchCount > 1 && (
            <section className="mt-6">
              <div className="card p-5">
                <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted mb-3 flex items-center gap-2">
                  <Icon name="Trash2" size={14} className="text-danger" /> Danger zone
                </h2>
                <p className="text-sm text-text-dim mb-3">
                  Removes the last sietch (#{data.sietchCount}) and its world partition. Data in that
                  partition is destroyed.
                </p>
                <button
                  className="btn-danger"
                  onClick={() => { void onRemove() }}
                  disabled={busy !== null || loading}
                >
                  <Icon name={busy === 'remove' ? 'Loader2' : 'Trash2'} size={14} className={busy === 'remove' ? 'animate-spin' : ''} />
                  {busy === 'remove' ? 'Removing…' : `Remove sietch #${data.sietchCount}`}
                </button>
              </div>
            </section>
          )}
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
