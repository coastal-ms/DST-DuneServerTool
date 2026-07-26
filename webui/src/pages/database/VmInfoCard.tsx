// VmInfoCard — read-only VM facts on the Database page.
//
// Design rule for this card: it REPORTS, it does not judge. Disk usage,
// retained Funcom build images, swap, per-map memory limits and the game UDP
// rule count are shown as plain numbers with no colour-coding, no thresholds,
// no "recommended" values and no fix-it buttons. DST cannot know the intent
// behind a number — a limit deliberately raised for a busy shard and one
// crushed by Funcom's experimental swap preset look identical to code, and
// Funcom changes its own template defaults between patches. The operator has
// the context; this card just hands them the numbers.
//
// The one exception is `faults`: states the system ITSELF reports as broken
// (an unfinished database operation while the battlegroup says DATABASE is not
// Ready, Kubernetes' own DiskPressure condition, or a public IP configured with
// zero game UDP rules while pods are running). None of those can be true on a
// healthy server, so they are stated plainly here rather than pushed at anyone.
//
// Collapsed by default: nothing here interrupts anyone who has not asked.
import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getVmHealth, type VmHealth } from '../../api/diagnostics'

function fmtKiB(k: number | null | undefined): string {
  if (k == null || k < 0) return '—'
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let v = k
  let i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return i === 0 ? `${Math.round(v)} ${units[i]}` : `${v.toFixed(1)} ${units[i]}`
}

function fmtBytes(b: number | null | undefined): string {
  if (b == null || b < 0) return '—'
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let v = b
  let i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return i <= 1 ? `${Math.round(v)} ${units[i]}` : `${v.toFixed(1)} ${units[i]}`
}

export function VmInfoCard() {
  const [open, setOpen] = useState(false)
  const [info, setInfo] = useState<VmHealth | null>(null)
  const [loading, setLoading] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      setInfo(await getVmHealth())
    } catch {
      // Read-only info — a probe hiccup just leaves the card empty.
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { if (open && !info) void load() }, [open, info, load])

  const faults = info?.faults ?? []

  return (
    <div className="card mb-6">
      <button
        type="button"
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center justify-between gap-3 p-5 text-left"
      >
        <div className="flex items-center gap-2 min-w-0">
          <Icon name="Info" size={18} className="text-text-muted shrink-0" />
          <div className="min-w-0">
            <div className="font-medium">VM info</div>
            <div className="text-sm text-text-muted truncate">
              Disk, swap, database operations, retained builds and per-map memory limits — read-only.
            </div>
          </div>
        </div>
        <Icon name={open ? 'ChevronUp' : 'ChevronDown'} size={18} className="text-text-muted shrink-0" />
      </button>

      {open && (
        <div className="px-5 pb-5 space-y-4">
          {loading && !info && <p className="text-sm text-text-dim italic">Reading the VM…</p>}

          {info && !info.ok && (
            <p className="text-sm text-text-dim">{info.message || 'The VM could not be read right now.'}</p>
          )}

          {info?.ok && (
            <>
              {faults.map(f => (
                <div key={f.id} className="rounded-lg border border-border bg-surface-2 p-3 text-sm">
                  <div className="font-medium">{f.headline}</div>
                  <p className="mt-1 text-xs text-text-muted break-words">{f.detail}</p>
                  <p className="mt-1 text-xs text-text-muted break-words">{f.action}</p>
                </div>
              ))}

              <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-2 text-sm">
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Root disk</dt>
                  <dd className="font-mono">
                    {info.disk?.known
                      ? `${info.disk.usePct ?? '—'}% used · ${fmtKiB(info.disk.availK)} free of ${fmtKiB(info.disk.sizeK)}`
                      : '—'}
                  </dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Swap</dt>
                  <dd className="font-mono">{info.swap?.active ? fmtKiB(info.swap.totalK) : 'off'}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Database phase</dt>
                  <dd className="font-mono">{info.database?.phase || '—'}</dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Database operations</dt>
                  <dd className="font-mono">
                    {info.database ? `${info.database.total} total · ${info.database.open} unfinished` : '—'}
                  </dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Retained build images</dt>
                  <dd className="font-mono">
                    {info.images ? `${info.images.buildCount} · ${fmtBytes(info.images.totalBytes)}` : '—'}
                  </dd>
                </div>
                <div className="flex justify-between gap-3">
                  <dt className="text-text-dim">Game UDP rules</dt>
                  <dd className="font-mono">{info.dnat?.udpRules ?? '—'}</dd>
                </div>
                <div className="flex justify-between gap-3 sm:col-span-2">
                  <dt className="text-text-dim">Node conditions</dt>
                  <dd className="font-mono">
                    {info.node
                      ? `Ready ${info.node.ready ? 'True' : 'False'} · DiskPressure ${info.node.diskPressure ? 'True' : 'False'} · MemoryPressure ${info.node.memoryPressure ? 'True' : 'False'}`
                      : '—'}
                  </dd>
                </div>
              </dl>

              {info.database && info.database.stuck.length > 0 && (
                <div>
                  <h3 className="text-sm font-medium mb-1">Unfinished database operations</h3>
                  <ul className="text-xs font-mono text-text-muted space-y-0.5">
                    {info.database.stuck.map(op => (
                      <li key={op.name}>
                        {op.name} — {op.phase}{op.ageMinutes != null ? ` · ${Math.round(op.ageMinutes)}m` : ''}
                      </li>
                    ))}
                  </ul>
                </div>
              )}

              {info.mapLimits?.known && info.mapLimits.entries.length > 0 && (
                <div>
                  <h3 className="text-sm font-medium">Per-map memory limits</h3>
                  <p className="text-xs text-text-dim mb-2">
                    The reference column is a snapshot of Funcom's world template taken in May 2026. Funcom changes
                    these between patches and operators tune them on purpose, so a difference here is not by itself a
                    problem — it is only here so you can see what your battlegroup is actually set to.
                  </p>
                  <div className="max-h-64 overflow-auto rounded-lg border border-border">
                    <table className="w-full text-xs font-mono">
                      <thead className="text-text-dim">
                        <tr>
                          <th className="text-left font-normal px-3 py-1.5">Map</th>
                          <th className="text-right font-normal px-3 py-1.5">Limit</th>
                          <th className="text-right font-normal px-3 py-1.5">Reference</th>
                        </tr>
                      </thead>
                      <tbody>
                        {info.mapLimits.entries.map(e => (
                          <tr key={e.map} className="border-t border-border/60">
                            <td className="px-3 py-1">{e.map}</td>
                            <td className="px-3 py-1 text-right">{e.limit || '—'}</td>
                            <td className="px-3 py-1 text-right text-text-dim">{e.reference || '—'}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}

              <button type="button" className="btn-secondary" onClick={() => void load()} disabled={loading}>
                <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
                Refresh
              </button>
            </>
          )}
        </div>
      )}
    </div>
  )
}
