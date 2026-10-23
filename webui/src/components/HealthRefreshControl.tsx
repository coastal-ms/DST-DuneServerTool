import {
  HEALTH_REFRESH_OPTIONS,
  HEALTH_REFRESH_PRESETS,
  setHealthRefreshPreset,
  useHealthRefreshPreset,
  type HealthRefreshPreset,
} from '../hooks/useHealthRefresh'

export function HealthRefreshControl() {
  const preset = useHealthRefreshPreset()
  return (
    <div className="min-w-0 max-w-sm text-left">
      <label className="flex items-center gap-2 text-sm text-text-muted">
        <span className="shrink-0 font-medium text-text">Auto-refresh</span>
        <select
          aria-label="Server Overview refresh interval"
          value={preset.id}
          onChange={event => setHealthRefreshPreset(event.target.value as HealthRefreshPreset)}
          className="min-h-9 min-w-0 rounded border border-border bg-surface-2 px-2 text-sm text-text"
        >
          {HEALTH_REFRESH_OPTIONS.map(id => (
            <option key={id} value={id}>
              {HEALTH_REFRESH_PRESETS[id].label}
            </option>
          ))}
        </select>
      </label>
      <p className="mt-1 text-xs leading-snug text-text-dim">
        {preset.detail} Faster checks use more VM and database traffic. Inconclusive port checks retry after 10 seconds.
      </p>
    </div>
  )
}
