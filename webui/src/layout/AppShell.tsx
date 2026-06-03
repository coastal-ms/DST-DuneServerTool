import type { ReactNode } from 'react'
import { MenuBar } from './MenuBar'
import { Sidebar } from './Sidebar'
import { StatusBar } from './StatusBar'
import { UpdateBanner } from '../components/UpdateBanner'
import { useSidebarCollapsed } from '../hooks/useSidebarCollapsed'

export function AppShell({ children }: { children: ReactNode }) {
  const { collapsed, toggle } = useSidebarCollapsed()
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
