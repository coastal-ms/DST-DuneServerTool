import { type ReactNode } from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { Icon } from '../../components/Icon'

// Mobile-first remote-portal layout (issue #74).
//
// - Sticky compact header at the top (DST mark + the current view's name).
// - Main content scrolls in the middle.
// - Sticky bottom tab bar with two tabs (Dashboard / Maps). Big touch
//   targets — each tab is 64px tall so thumbs land reliably on a phone.
//
// No sidebar, no menubar, no status bar — those belong to the desktop tree.
//
// Theme tokens flow through unchanged: <ThemeProvider> in main.tsx applies
// CSS custom properties on :root, so the same palette the user picks on
// desktop also colors the remote portal on their phone.

interface TabDef {
  to: string
  label: string
  icon: string
}

const TABS: TabDef[] = [
  { to: '/remote',      label: 'Dashboard', icon: 'LayoutDashboard' },
  { to: '/remote/maps', label: 'Maps',      icon: 'Map' },
]

export function RemoteShell({ children }: { children: ReactNode }) {
  const loc = useLocation()
  const active = TABS.find(t => t.to === loc.pathname || (t.to !== '/remote' && loc.pathname.startsWith(t.to))) ?? TABS[0]

  return (
    <div className="flex flex-col min-h-screen bg-base text-text">
      <header className="sticky top-0 z-20 border-b border-border bg-surface/95 backdrop-blur-sm">
        <div className="mx-auto max-w-2xl px-4 py-3 flex items-center gap-3">
          <Icon name="Shield" size={20} className="text-accent" />
          <h1 className="text-lg font-semibold tracking-tight">Dune Server · Remote</h1>
          <div className="ml-auto pill-muted text-xs">{active.label}</div>
        </div>
      </header>

      <main className="flex-1 mx-auto w-full max-w-2xl px-4 py-4 pb-24">
        {children}
      </main>

      <nav className="fixed bottom-0 left-0 right-0 z-20 border-t border-border bg-surface/95 backdrop-blur-sm">
        <div className="mx-auto max-w-2xl grid grid-cols-2">
          {TABS.map(t => (
            <NavLink
              key={t.to}
              to={t.to}
              end={t.to === '/remote'}
              className={({ isActive }) =>
                'flex flex-col items-center justify-center gap-1 h-16 text-xs font-medium transition-colors '
                + (isActive
                    ? 'text-accent bg-surface-2/60'
                    : 'text-text-muted hover:text-text hover:bg-surface-2/30')
              }
            >
              <Icon name={t.icon} size={22} />
              <span>{t.label}</span>
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  )
}
