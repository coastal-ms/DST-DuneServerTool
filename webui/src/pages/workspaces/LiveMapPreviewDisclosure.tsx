import { Icon } from '../../components/Icon'

export function LiveMapPreviewDisclosure() {
  return (
    <aside
      aria-label="Live Map preview disclosure"
      className="card flex items-start gap-3 border-info/35 bg-info/10 p-4"
    >
      <Icon name="Info" size={17} className="mt-0.5 shrink-0 text-info" />
      <div>
        <h2 className="text-sm font-semibold text-text">Live Map visualization is still being built</h2>
        <p className="mt-1 text-sm leading-6 text-text-muted">
          Capability, freshness, and cached observation details are derived from your server when available.
          Plotted map and marker visualization is preview scaffolding and is not yet live game telemetry.
        </p>
      </div>
    </aside>
  )
}
