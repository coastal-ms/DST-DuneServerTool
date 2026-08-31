import { Icon } from '../../components/Icon'

export function LiveStateDemoDisclosure() {
  return (
    <aside
      aria-label="Live State data disclosure"
      className="card flex items-start gap-3 border-info/35 bg-info/10 p-4"
    >
      <Icon name="Info" size={17} className="mt-0.5 shrink-0 text-info" />
      <div>
        <h2 className="text-sm font-semibold text-text">Live State is an upcoming feature foundation</h2>
        <p className="mt-1 text-sm leading-6 text-text-muted">
          This view currently displays demo data for foundation and plumbing work. It is not live game telemetry.
        </p>
      </div>
    </aside>
  )
}
