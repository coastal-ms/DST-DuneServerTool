import { PageHeader } from '../components/PageHeader'
import { Icon } from '../components/Icon'

const KPIS = [
  { label: 'Battlegroup', value: '—', icon: 'Activity', tone: 'text-text-muted' },
  { label: 'VM',          value: '—', icon: 'HardDrive', tone: 'text-text-muted' },
  { label: 'Characters',  value: '—', icon: 'Users',     tone: 'text-text-muted' },
  { label: 'Uptime',      value: '—', icon: 'Clock',     tone: 'text-text-muted' },
]

export function Dashboard() {
  return (
    <>
      <PageHeader
        title="Dashboard"
        icon="LayoutDashboard"
        description="Server status at a glance and quick commands."
        actions={
          <>
            <button className="btn-secondary">
              <Icon name="RefreshCw" size={15} /> Refresh
            </button>
            <button className="btn-primary">
              <Icon name="Play" size={15} /> Start Battlegroup
            </button>
          </>
        }
      />

      <section className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {KPIS.map(k => (
          <div key={k.label} className="card card-hover p-4">
            <div className="flex items-center justify-between">
              <span className="text-xs uppercase tracking-wider text-text-dim">{k.label}</span>
              <Icon name={k.icon} size={16} className={k.tone} />
            </div>
            <div className={`mt-2 text-2xl font-semibold ${k.tone}`}>{k.value}</div>
          </div>
        ))}
      </section>

      <section className="card p-5">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted">
            Command Palette
          </h2>
          <span className="text-xs text-text-dim">drag to reorder · phase 1</span>
        </div>
        <div className="text-sm text-text-dim italic">
          Quick-action buttons (start / stop / restart / SSH / dune-admin / etc.) will live here.
        </div>
      </section>
    </>
  )
}
