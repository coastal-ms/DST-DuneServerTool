import { Icon } from '../../components/Icon'
import { useVmMemPressureHidden } from '../dashboard/vmMemoryPref'

// Settings → Dashboard warnings. Currently just the VM memory-pressure banner
// toggle: operators who understand the risk can silence it from the banner's X,
// and re-enable it here. Preference lives in localStorage (see vmMemoryPref.ts).
export function DashboardAlertsCard() {
  const [hidden, setHidden] = useVmMemPressureHidden()

  return (
    <div className="card mb-4 p-6">
      <div className="flex items-center gap-3 mb-3">
        <Icon name="BellRing" size={18} className="text-text-muted" />
        <h2 className="text-lg font-semibold">Dashboard warnings</h2>
      </div>

      <label className="flex items-start gap-3 cursor-pointer select-none">
        <input
          type="checkbox"
          checked={!hidden}
          onChange={e => setHidden(!e.target.checked)}
          className="h-4 w-4 mt-0.5"
        />
        <span className="min-w-0">
          <span className="text-sm font-medium">Show VM memory-pressure warning</span>
          <span className="block text-xs text-text-dim mt-0.5">
            The red banner on the dashboard that fires when the game VM is low on
            memory (Funcom operators OOM-killed, Postgres evicted, or swap
            exhausted). Turn this off to hide it permanently — you can also
            dismiss it from the banner's <Icon name="X" size={11} className="inline align-[-1px]" /> button.
          </span>
        </span>
      </label>
    </div>
  )
}
