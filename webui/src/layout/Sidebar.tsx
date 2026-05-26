import { NavLink } from 'react-router-dom'
import { Icon } from '../components/Icon'
import { NAV_ITEMS, GROUP_LABELS } from '../nav'

export function Sidebar() {
  const groups = (['core', 'data', 'system'] as const).map(g => ({
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

      <div className="px-4 py-3 border-t border-border text-[10px] text-text-dim">
        <div className="flex items-center justify-between">
          <span>v6.1.0</span>
          <span className="font-mono">coastal-ms</span>
        </div>
      </div>
    </aside>
  )
}
