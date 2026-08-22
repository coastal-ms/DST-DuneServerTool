import { useRef, type ReactNode } from 'react'
import { useLocation } from '../router'
import { MenuBar } from './MenuBar'
import { Sidebar } from './Sidebar'
import { StatusBar } from './StatusBar'
import { UpdateBanner } from '../components/UpdateBanner'
import { DecoupleNoticeModal } from '../components/DecoupleNoticeModal'
import { useSidebarCollapsed } from '../hooks/useSidebarCollapsed'
import { usePortalAccess } from '../auth/portalAccess'
import { SectionJumpNav } from '../components/SectionJumpNav'

// Routes that should render full-bleed below the menu bar — no sidebar, no
// status bar, no update banner, no max-width / padding. Keep the top menu bar
// because that's how the user navigates back out of the immersive view.
const IMMERSIVE_ROUTES = new Set<string>([])

export function AppShell({ children }: { children: ReactNode }) {
  const mainRef = useRef<HTMLElement | null>(null)
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const { collapsed, toggle } = useSidebarCollapsed()
  const { pathname } = useLocation()
  const immersive = IMMERSIVE_ROUTES.has(pathname)

  if (immersive) {
    return (
      <div className="h-full w-full max-w-full flex flex-col overflow-hidden">
        <DecoupleNoticeModal />
        <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} />
        <main className="flex-1 min-h-0 min-w-0 max-w-full overflow-hidden">
          {children}
        </main>
      </div>
    )
  }

  return (
    <div className="h-full w-full max-w-full flex flex-col overflow-hidden">
      <DecoupleNoticeModal />
      <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} />
      <div className="flex-1 flex overflow-hidden min-h-0">
        <Sidebar collapsed={collapsed} />
        <div className="flex-1 flex flex-col min-w-0">
          {canAccessOwnerSurfaces && <UpdateBanner />}
          <StatusBar />
          <main ref={mainRef} className="flex-1 min-w-0 max-w-full overflow-x-hidden overflow-y-auto overscroll-y-contain">
            <div className="w-full min-w-0 max-w-7xl mx-auto px-3 pt-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:px-4 md:px-6 md:py-6">
              {pathname !== '/' && <SectionJumpNav containerRef={mainRef} />}
              {children}
            </div>
          </main>
        </div>
      </div>
    </div>
  )
}
