import { useSoloInstallation } from '../hooks/useInstallationMode'
import { lazy, Suspense, useRef, type ReactNode } from 'react'
import { useLocation } from '../router'
import { MenuBar } from './MenuBar'
import { StatusBar } from './StatusBar'
import { UpdateBanner } from '../components/UpdateBanner'
import { DecoupleNoticeModal } from '../components/DecoupleNoticeModal'
import { useSidebarCollapsed } from '../hooks/useSidebarCollapsed'
import { usePortalAccess } from '../auth/portalAccess'
import { SectionJumpNav } from '../components/SectionJumpNav'
import { OnlinePlayerGuardModal } from '../components/OnlinePlayerGuardModal'
import { useCommandDeck } from '../hooks/useCommandDeck'
import { useDocumentFontScale, useFontScale } from '../hooks/useFontScale'

const Sidebar = lazy(() => import('./Sidebar').then(module => ({ default: module.Sidebar })))
const SpatialFrame = lazy(() => import('./SpatialFrame'))

// Routes that should render full-bleed below the menu bar — no sidebar, no
// status bar, no update banner, no max-width / padding. Keep the top menu bar
// because that's how the user navigates back out of the immersive view.
const IMMERSIVE_ROUTES = new Set<string>([])

export function AppShell({ children }: { children: ReactNode }) {
  const mainRef = useRef<HTMLElement | null>(null)
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const soloOnly = useSoloInstallation()
  const classicSidebar = useSidebarCollapsed()
  const deckSidebar = useSidebarCollapsed('dst.deck.sidebar.collapsed', true)
  const { pathname } = useLocation()
  const immersive = IMMERSIVE_ROUTES.has(pathname)
  const commandDeck = useCommandDeck()
  const fontScale = useFontScale()
  useDocumentFontScale(fontScale)
  const spatialHome = commandDeck && pathname === '/'
  const { collapsed, setCollapsed, toggle } = commandDeck ? deckSidebar : classicSidebar

  if (immersive) {
    return (
      <div className={`h-full w-full max-w-full flex flex-col overflow-hidden ${commandDeck ? 'command-deck' : ''}`}>
        <DecoupleNoticeModal />
        <OnlinePlayerGuardModal />
        <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} sidebarAvailable={!commandDeck} />
        <main className="flex-1 min-h-0 min-w-0 max-w-full overflow-hidden">
          {children}
        </main>
      </div>
    )
  }

  return (
    <div className={`h-full w-full max-w-full flex flex-col overflow-hidden ${commandDeck ? 'command-deck' : ''}`}>
      <DecoupleNoticeModal />
      <OnlinePlayerGuardModal />
      <MenuBar sidebarCollapsed={collapsed} onToggleSidebar={toggle} sidebarAvailable={!commandDeck} />
      <div className="flex-1 flex overflow-hidden min-h-0">
        {!commandDeck && <Suspense fallback={<div className="hidden md:block w-20 shrink-0" aria-label="Loading navigation" />}>
          <Sidebar collapsed={collapsed} onExpand={() => setCollapsed(false)} />
        </Suspense>}
        <div className="flex-1 flex flex-col min-w-0 min-h-0">
          {canAccessOwnerSurfaces && <UpdateBanner />}
          {!commandDeck && !soloOnly && <StatusBar />}
          <main ref={mainRef} data-app-scroll-container={commandDeck && !spatialHome ? undefined : ''}
            data-app-scroll-host={commandDeck && !spatialHome ? '' : undefined}
            className={`flex-1 min-h-0 min-w-0 max-w-full overflow-x-hidden ${commandDeck && !spatialHome ? 'overflow-y-hidden' : 'overflow-y-auto'} overscroll-y-contain`}>
            <div className={commandDeck ? 'w-full min-w-0' : 'w-full min-w-0 max-w-7xl mx-auto px-3 pt-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:px-4 md:px-6 md:py-6'}>
              {commandDeck && !spatialHome
                ? <Suspense fallback={<div role="status" className="p-6">Opening workspace...</div>}>
                    <SpatialFrame tools>
                      <SectionJumpNav containerRef={mainRef} />
                      {children}
                    </SpatialFrame>
                  </Suspense>
                : <>{pathname !== '/' && <SectionJumpNav containerRef={mainRef} />}{children}</>}
            </div>
          </main>
        </div>
      </div>
    </div>
  )
}
