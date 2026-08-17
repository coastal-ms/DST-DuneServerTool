// VmMemoryPressureBanner — Server Health banner for runtime pressure and the
// separate scheduler-capacity fault where a map pod cannot fit on the VM node.
//
// Backed by GET /api/diagnostics/vm-memory, which is read-only and cached 60s
// server-side, so polling here is cheap. OPT-IN: hidden by default, shown only
// Runtime pressure remains opt-in. Scheduler Insufficient-memory is a concrete
// broken state, so it is polled/shown regardless of that preference.
import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getVmMemoryPressure, type VmMemoryPressure } from '../../api/diagnostics'
import { useVmMemPressureEnabled } from './vmMemoryPref'

type Props = {
  vmRunning: boolean   // gate on VM running — no point probing a stopped VM
}

export function VmMemoryPressureBanner({ vmRunning }: Props) {
  const [finding, setFinding] = useState<VmMemoryPressure | null>(null)
  const [show, setShow] = useVmMemPressureEnabled()

  const active = vmRunning

  const load = useCallback(async () => {
    if (!active) return
    try {
      setFinding(await getVmMemoryPressure())
    } catch {
      // Best-effort — a probe hiccup must never break the dashboard. Leave the
      // last good finding in place.
    }
  }, [active])

  useEffect(() => { void load() }, [load])

  // Poll on the same 60s cadence as the server-side cache TTL.
  useEffect(() => {
    if (!active) return
    const id = window.setInterval(() => { void load() }, 60_000)
    return () => window.clearInterval(id)
  }, [active, load])

  if (!active || !finding || !finding.ok) return null
  const capacityBlocked = finding.capacityBlocked === true
  if (!capacityBlocked && (!show || !finding.pressure)) return null

  const critical = capacityBlocked || finding.severity === 'critical'
  const tone = critical
    ? 'border-danger/50 bg-danger/10 text-danger'
    : 'border-warning/50 bg-warning/10 text-warning'

  return (
    <section className={`card p-4 mb-6 ${tone}`} role="alert">
      <div className="flex items-start gap-3">
        <Icon name="AlertTriangle" size={20} className="shrink-0 mt-0.5" />
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold">
            {finding.headline || 'VM memory pressure detected'}
          </h2>
          {finding.warnings.length > 0 && (
            <ul className="mt-2 space-y-1 text-xs text-text-muted list-disc pl-4">
              {finding.warnings.map((w, i) => (
                <li key={i} className="break-words">{w}</li>
              ))}
            </ul>
          )}
        </div>
        {!capacityBlocked && (
          <button
            type="button"
            onClick={() => setShow(false)}
            className="shrink-0 -mt-0.5 -mr-1 p-1 rounded hover:bg-current/10 text-current/70 hover:text-current transition-colors"
            title="Hide this warning. Turn it back on under Settings → Dashboard warnings."
            aria-label="Hide VM memory-pressure warning"
          >
            <Icon name="X" size={16} />
          </button>
        )}
      </div>
    </section>
  )
}
