import { Icon } from '../components/Icon'

export function StatusBar() {
  // Phase 0: static placeholders. Phase 1 wires to /api/status.
  return (
    <header className="h-14 shrink-0 border-b border-border bg-surface/60 backdrop-blur-md px-5 flex items-center justify-between">
      <div className="flex items-center gap-2 text-sm text-text-muted">
        <Icon name="Server" size={16} className="text-text-dim" />
        <span>Dune Awakening dedicated server</span>
      </div>
      <div className="flex items-center gap-2">
        <span className="pill-muted">
          <Icon name="HardDrive" size={11} /> VM —
        </span>
        <span className="pill-muted">
          <Icon name="Activity" size={11} /> BG —
        </span>
        <span className="pill-muted">
          <Icon name="Plug" size={11} /> Ports —
        </span>
        <button className="btn-ghost ml-2" title="Refresh">
          <Icon name="RefreshCw" size={15} />
        </button>
      </div>
    </header>
  )
}
