// VmHealthBanner — the always-on Server Health banner for VM-side faults that
// DST used to be completely blind to. Every blocker it renders comes from a
// confirmed field case where DST's own board stayed FULLY GREEN while the
// server was down or degraded:
//
//   • a stuck DatabaseOperation holds the database, so the Funcom operator
//     creates no map pods at all — maps sit at Starting with no pod and any
//     restore also fails, from one cause (server down ~24h)
//   • DiskPressure / a filling root volume evicts pods with nothing anywhere
//     pointing at disk
//   • the per-port game UDP DNAT bridge does not survive moving the VM to a
//     different Hyper-V host, and "TCP ports open 1/1" only tests the
//     management port, so everything reads healthy while players get P34
//   • Funcom's experimental swap preset crushes per-map memory limits, and the
//     values survive a VM resize
//   • containerd retains every historical Funcom build (~4.8 GB each)
//
// Unlike the memory-pressure banner this is NOT opt-in: these are faults, not
// tuning advice. Backed by GET /api/diagnostics/vm-health, which shares the
// memory probe's 60s server-side cache, so polling is cheap.
import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getVmHealth, type VmHealth } from '../../api/diagnostics'
import { restoreMapMemoryLimits } from '../../api/maps'

type Props = {
  vmRunning: boolean   // no point probing a stopped VM
}

export function VmHealthBanner({ vmRunning }: Props) {
  const [health, setHealth] = useState<VmHealth | null>(null)
  const [fixing, setFixing] = useState(false)
  const [fixMsg, setFixMsg] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!vmRunning) return
    try {
      setHealth(await getVmHealth())
    } catch {
      // Best-effort — a probe hiccup must never break the dashboard.
    }
  }, [vmRunning])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    if (!vmRunning) return
    const id = window.setInterval(() => { void load() }, 60_000)
    return () => window.clearInterval(id)
  }, [vmRunning, load])

  const restoreLimits = useCallback(async () => {
    setFixing(true); setFixMsg(null)
    try {
      const r = await restoreMapMemoryLimits()
      setFixMsg(r.message ?? (r.ok ? 'Per-map memory limits restored.' : 'Could not restore the per-map memory limits.'))
      if (r.ok) await load()
    } catch (e) {
      setFixMsg(e instanceof Error ? e.message : String(e))
    } finally {
      setFixing(false)
    }
  }, [load])

  if (!vmRunning || !health || !health.ok) return null
  const blockers = health.blockers ?? []
  if (blockers.length === 0) return null

  const critical = blockers.some(b => b.severity === 'critical')
  const tone = critical
    ? 'border-danger/50 bg-danger/10 text-danger'
    : 'border-warning/50 bg-warning/10 text-warning'

  return (
    <section className={`card p-4 mb-6 ${tone}`} role="alert">
      <div className="flex items-start gap-3">
        <Icon name="AlertTriangle" size={20} className="shrink-0 mt-0.5" />
        <div className="min-w-0 flex-1 space-y-3">
          {blockers.map(b => (
            <div key={b.id} className="min-w-0">
              <h2 className="text-sm font-semibold break-words">{b.headline}</h2>
              <p className="mt-1 text-xs text-text-muted break-words">{b.detail}</p>
              <p className="mt-1 text-xs text-text-muted break-words">
                <span className="font-medium">Fix:</span> {b.action}
              </p>
              {b.id === 'map-limits-crushed' && (
                <button
                  type="button"
                  className="btn-secondary mt-2"
                  onClick={() => void restoreLimits()}
                  disabled={fixing}
                >
                  <Icon name={fixing ? 'Loader2' : 'Wrench'} size={14} className={fixing ? 'animate-spin' : ''} />
                  {fixing ? 'Restoring…' : 'Restore per-map memory limits'}
                </button>
              )}
            </div>
          ))}
          {fixMsg && <p className="text-xs text-text-muted break-words">{fixMsg}</p>}
        </div>
      </div>
    </section>
  )
}
