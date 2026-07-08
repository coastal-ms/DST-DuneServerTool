// VmMemoryPressureBanner — red Server Health banner that fires when the VM is
// low on memory: Funcom operators OOM-killed (exit 137 / high restart counts),
// Postgres evicted, or a tiny MemAvailable with Swap: 0. This is the root cause
// of the "battlegroup restarted outside its schedule" / "ping surge under load"
// class of report (murm, Hagga per-map sizing, Pat 2026-07-07), and until now
// could only be found by exporting logs and hand-reading them.
//
// Backed by GET /api/diagnostics/vm-memory, which is read-only and cached 60s
// server-side, so polling here is cheap. Renders nothing unless the probe
// succeeded AND detected pressure.
import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { getVmMemoryPressure, type VmMemoryPressure } from '../../api/diagnostics'
import { useVmMemPressureHidden } from './vmMemoryPref'

type Props = {
  enabled: boolean   // gate on VM running — no point probing a stopped VM
}

export function VmMemoryPressureBanner({ enabled }: Props) {
  const [finding, setFinding] = useState<VmMemoryPressure | null>(null)
  const [hidden, setHidden] = useVmMemPressureHidden()

  const load = useCallback(async () => {
    if (!enabled) return
    try {
      setFinding(await getVmMemoryPressure())
    } catch {
      // Best-effort — a probe hiccup must never break the dashboard. Leave the
      // last good finding in place.
    }
  }, [enabled])

  useEffect(() => { void load() }, [load])

  // Poll on the same 60s cadence as the server-side cache TTL.
  useEffect(() => {
    if (!enabled) return
    const id = window.setInterval(() => { void load() }, 60_000)
    return () => window.clearInterval(id)
  }, [enabled, load])

  if (!enabled || hidden || !finding || !finding.ok || !finding.pressure) return null

  const critical = finding.severity === 'critical'
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
        <button
          type="button"
          onClick={() => setHidden(true)}
          className="shrink-0 -mt-0.5 -mr-1 p-1 rounded hover:bg-current/10 text-current/70 hover:text-current transition-colors"
          title="Dismiss this warning permanently. Re-enable it under Settings → Dashboard warnings."
          aria-label="Dismiss VM memory-pressure warning permanently"
        >
          <Icon name="X" size={16} />
        </button>
      </div>
    </section>
  )
}
