import { lazy, Suspense, type ReactNode } from 'react'
import { PageErrorBoundary } from './PageErrorBoundary'

const RemoteApp = lazy(() => import('../pages/remote/RemoteApp'))

export function RemotePortalBoundary({ children }: { children: ReactNode }) {
  return (
    <PageErrorBoundary pageName="Remote portal">
      <Suspense
        fallback={
          <main className="min-h-full p-4 flex items-center justify-center" role="status">
            <div className="card w-full max-w-sm px-5 py-4 text-sm text-text-muted">
              Loading Remote Portal…
            </div>
          </main>
        }
      >
        {children}
      </Suspense>
    </PageErrorBoundary>
  )
}

export function RemotePortalRoot() {
  return (
    <RemotePortalBoundary>
      <RemoteApp />
    </RemotePortalBoundary>
  )
}
