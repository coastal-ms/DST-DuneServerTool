import { NavLink } from 'react-router-dom'
import { useState } from 'react'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS } from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { useInstallPrompt } from '../hooks/useInstallPrompt'

export function Sidebar() {
  const { data: upd } = useUpdateCheck()
  const version = upd?.currentVersion ?? ''
  const { canInstall, installed, install } = useInstallPrompt()
  const [showHelp, setShowHelp] = useState(false)

  const onInstallClick = async () => {
    if (canInstall) {
      const r = await install()
      if (r === 'unavailable') setShowHelp(true)
    } else {
      setShowHelp(true)
    }
  }

  const groups = (['overview', 'terminal', 'data', 'system'] as const).map(g => ({
    key: g,
    label: GROUP_LABELS[g],
    items: NAV_ITEMS.filter(i => i.group === g),
  }))

  return (
    <aside className="w-60 shrink-0 border-r border-border bg-surface/60 backdrop-blur-md flex flex-col">
      <div className="px-5 py-4 border-b border-border flex items-center gap-2.5">
        <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-accent-bright to-accent flex items-center justify-center shadow-lg shadow-accent/20">
          <Icon name="Hexagon" size={18} className="text-base" strokeWidth={2.5} />
        </div>
        <div>
          <div className="text-sm font-semibold tracking-wide">Dune Server</div>
          <div className="text-[10px] text-text-dim uppercase tracking-widest">Management Portal</div>
        </div>
      </div>

      <nav className="flex-1 overflow-y-auto px-2 py-3 space-y-5">
        {groups.map(g => (
          <div key={g.key}>
            <div className="px-3 mb-1 text-[10px] font-semibold uppercase tracking-widest text-text-dim">
              {g.label}
            </div>
            <ul className="space-y-0.5">
              {g.items.map(item => (
                <li key={item.to}>
                  <NavLink
                    to={item.to}
                    end={item.to === '/'}
                    className={({ isActive }) =>
                      `flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-all
                       ${isActive
                         ? 'bg-accent/15 text-accent-bright border border-accent/30 shadow-inner'
                         : 'text-text-muted hover:text-text hover:bg-surface-2/60 border border-transparent'}`
                    }
                  >
                    <Icon name={item.icon} size={16} />
                    <span>{item.label}</span>
                  </NavLink>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </nav>

      <div className="px-4 py-3 border-t border-border text-[10px] text-text-dim space-y-2">
        {!installed && (
          <button
            type="button"
            onClick={() => { void onInstallClick() }}
            title={canInstall ? 'Install Dune Server as a desktop app' : 'How to install as a Chrome/Edge app'}
            className="w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors uppercase tracking-widest"
          >
            <Icon name="Download" size={11} />
            <span>Install as app</span>
          </button>
        )}
        <div className="flex items-center justify-between">
          <span>{version ? `v${version}` : '—'}</span>
          <span className="font-mono">coastal-ms</span>
        </div>
      </div>

      {showHelp && (
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4"
          onClick={() => setShowHelp(false)}
        >
          <div
            className="card p-5 max-w-md w-full text-text"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 mb-3">
              <Icon name="Download" size={16} className="text-accent" />
              <h3 className="text-sm font-semibold uppercase tracking-widest text-accent">Install as app</h3>
            </div>
            <p className="text-sm text-text-muted mb-3">
              Run the portal in its own dedicated window without browser tabs or address bar.
            </p>
            <div className="space-y-3 text-xs">
              <div>
                <div className="font-semibold text-text mb-1">Chrome</div>
                <p className="text-text-muted">
                  Click the <span className="font-mono">⋮</span> menu (top-right) → <span className="text-text">Cast, save, and share</span> → <span className="text-text">Install page as app…</span>
                </p>
              </div>
              <div>
                <div className="font-semibold text-text mb-1">Edge</div>
                <p className="text-text-muted">
                  Click the <span className="font-mono">⋯</span> menu (top-right) → <span className="text-text">Apps</span> → <span className="text-text">Install Dune Server</span>
                </p>
              </div>
              <div>
                <div className="font-semibold text-text mb-1">Address bar shortcut</div>
                <p className="text-text-muted">
                  Look for the install icon (<span className="font-mono">⊕</span> or a small monitor icon) on the right side of the address bar and click it.
                </p>
              </div>
            </div>
            <div className="mt-4 flex justify-end">
              <button
                className="btn-secondary"
                onClick={() => setShowHelp(false)}
              >
                <Icon name="X" size={12} /> Close
              </button>
            </div>
          </div>
        </div>
      )}
    </aside>
  )
}
