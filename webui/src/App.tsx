import { lazy, Suspense, useEffect, type ReactNode } from 'react'
import { Routes, Route, Navigate } from './router'
import { AppShell } from './layout/AppShell'
import { PageStub } from './pages/PageStub'
import { StatusProvider } from './hooks/useStatus'
import { isLocalViewer, isWindowsViewer } from './util/viewer'
import { api } from './api/client'
import { ReconnectOverlay } from './components/ReconnectOverlay'
import { PageErrorBoundary } from './components/PageErrorBoundary'
import { DataState } from './components/platform/DataState'
import { usePortalAccess } from './auth/portalAccess'
import { WORKSPACE_MANIFEST } from './platform/workspaces'
import { COMPATIBILITY_REDIRECTS, LEGACY_ROUTE_MANIFEST, type RouteAccess } from './platform/routes'
import { GameplayAdminShell } from './components/platform/GameplayAdminShell'
import type { GameplaySectionId } from './platform/gameplay'

const WORKSPACE_ROUTES = WORKSPACE_MANIFEST.map(workspace => ({
  ...workspace,
  Component: lazy(workspace.load),
}))

const LEGACY_ROUTES = LEGACY_ROUTE_MANIFEST.map(route => ({
  ...route,
  Component: lazy(route.load),
}))

function Boundary({ name, children }: { name: string; children: ReactNode }) {
  return <PageErrorBoundary pageName={name}>{children}</PageErrorBoundary>
}

function LazyPage({ name, children }: { name: string; children: ReactNode }) {
  return (
    <Boundary name={name}>
      <Suspense fallback={<DataState state="loading" title={`Loading ${name}…`} />}>
        {children}
      </Suspense>
    </Boundary>
  )
}

function canAccessRoute(
  access: RouteAccess,
  canAccessOwnerSurfaces: boolean,
  canAccessSetup: boolean,
) {
  if (access === 'owner') return canAccessOwnerSurfaces
  if (access === 'local') return isLocalViewer()
  if (access === 'local-windows') return isLocalViewer() && isWindowsViewer()
  if (access === 'setup') return canAccessSetup
  return true
}

export default function App() {
  const { canAccessOwnerSurfaces, canAccessSetup } = usePortalAccess()

  useEffect(() => {
    const inShell = !!(window as unknown as { chrome?: { webview?: unknown } }).chrome?.webview
    if (!inShell && isLocalViewer()) {
      api('/api/portal/checkin', { method: 'POST' }).catch(() => { /* best effort */ })
    }
  }, [])

  return (
    <StatusProvider>
      <ReconnectOverlay />
      <AppShell>
        <Routes>
          {COMPATIBILITY_REDIRECTS.map(route => (
            <Route
              key={route.from}
              path={route.from}
              element={<Navigate to={route.to} replace preserveLocation />}
            />
          ))}
          {WORKSPACE_ROUTES.map(({ id, path, label, visibility, domain, Component }) => (
            <Route
              key={id}
              path={path}
              element={
                visibility === 'owner' && !canAccessOwnerSurfaces
                  ? <Navigate to="/" replace />
                  : (
                      <LazyPage name={label}>
                        {domain === 'gameplay-admin'
                          ? (
                              <GameplayAdminShell activeSection={id as GameplaySectionId}>
                                <Component />
                              </GameplayAdminShell>
                            )
                          : <Component />}
                      </LazyPage>
                    )
              }
            />
          ))}
          {LEGACY_ROUTES.map(({ path, label, access, Component }) => (
            <Route
              key={path}
              path={path}
              element={
                canAccessRoute(access, canAccessOwnerSurfaces, canAccessSetup)
                  ? <LazyPage name={label}><Component /></LazyPage>
                  : <Navigate to="/" replace />
              }
            />
          ))}
          <Route
            path="*"
            element={<PageStub title="Not Found" icon="HelpCircle" description="No page at that path." phase="—" />}
          />
        </Routes>
      </AppShell>
    </StatusProvider>
  )
}
