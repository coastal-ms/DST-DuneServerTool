import type { ReactNode } from 'react'
import { useLocation } from 'react-router-dom'
import { MenuBar } from './MenuBar'
import { Sidebar } from './Sidebar'
import { StatusBar } from './StatusBar'
import { UpdateBanner } from '../components/UpdateBanner'
import { useSidebarCollapsed } from '../hooks/useSidebarCollapsed'

// Routes that should render full-bleed below the menu bar — no sidebar, no
// status bar, no update banner, no max-width / padding. Keep the top menu bar
// because that's how the user navigates back out of the immersive view.
const IMMERSIVE_ROUTES = new Set<string>([])

export function AppShell({ children }: { children: ReactNode }) {
  const { collapsed, toggle } = useSidebarCollapsed()
  const { pathname } = useLocation()
  const immersive = IMMERSIVE_ROUTES.has(pathname)

  if (immersive) {
    return (
      <div className="h-full flex flex-col overflow-hidden">
        <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} />
        <main className="flex-1 min-h-0 overflow-hidden">
          {children}
        </main>
      </div>
    )
  }

  return (
    <div className="h-full flex flex-col overflow-hidden">
      <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} />
      <div className="flex-1 flex overflow-hidden min-h-0">
        <Sidebar collapsed={collapsed} />
        <div className="flex-1 flex flex-col min-w-0">
          <UpdateBanner />
          <StatusBar />
          <main className="flex-1 overflow-y-auto">
            <div className="max-w-7xl mx-auto px-6 py-6">
              {children}
            </div>
          </main>
        </div>
      </div>
    </div>
  )
}
