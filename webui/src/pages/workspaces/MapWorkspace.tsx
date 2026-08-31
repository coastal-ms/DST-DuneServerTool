import { lazy, Suspense } from 'react'
import { DataState, FreshnessBadge } from '../../components/platform/DataState'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { usePlatformCapabilities } from '../../hooks/usePlatformCapabilities'
import { getWorkspace } from '../../platform/workspaces'
import { Navigate, useSearch } from '../../router'
import { LiveMapPreviewDisclosure } from './LiveMapPreviewDisclosure'

const Atlas = lazy(() => import('../WickMaps').then(module => ({ default: module.WickMaps })))
const LiveState = lazy(() => import('./MapLiveState').then(module => ({ default: module.MapLiveState })))
const Lifecycle = lazy(() => import('../MapSpinUp').then(module => ({ default: module.MapSpinUp })))

type MapView = 'atlas' | 'live' | 'lifecycle'

const STATIC_TABS: readonly WorkspaceTab[] = [
  { id: 'atlas', label: 'DD Atlas', to: '/map?view=atlas', icon: 'Map' },
  { id: 'lifecycle', label: 'Lifecycle', to: '/map?view=lifecycle', icon: 'Power' },
]

const LIVE_TAB: WorkspaceTab = {
  id: 'live',
  label: 'Live state',
  to: '/map?view=live',
  icon: 'Activity',
}

function currentView(search: string): MapView {
  const view = new URLSearchParams(search).get('view')
  return view === 'live' || view === 'lifecycle' ? view : 'atlas'
}

export default function MapWorkspace() {
  const search = useSearch()
  const requestedView = currentView(search)
  const { data, loading, error, refresh, hasCapability } = usePlatformCapabilities()
  const capabilityResponseReceived = data !== null
  const liveCacheAvailable = hasCapability('map.live-cache')
  const tabs = liveCacheAvailable
    ? [STATIC_TABS[0], LIVE_TAB, STATIC_TABS[1]]
    : STATIC_TABS

  if (requestedView === 'live' && !capabilityResponseReceived && loading) {
    return (
      <WorkspaceLayout
        workspace={getWorkspace('map')}
        tabs={STATIC_TABS}
        activeTab="atlas"
      >
        <div className="flex min-w-0 flex-col gap-4">
          <LiveMapPreviewDisclosure />
          <DataState state="loading" title="Checking live map availability…" />
        </div>
      </WorkspaceLayout>
    )
  }
  if (requestedView === 'live' && !capabilityResponseReceived && error) {
    return (
      <WorkspaceLayout
        workspace={getWorkspace('map')}
        tabs={STATIC_TABS}
        activeTab="atlas"
      >
        <div className="flex min-w-0 flex-col gap-4">
          <LiveMapPreviewDisclosure />
          <div className="flex flex-col items-start gap-3">
            <DataState
              state="error"
              title="Could not check live map availability"
              message={error}
            />
            <button className="btn-secondary min-h-11" onClick={() => { void refresh() }}>
              Retry capability check
            </button>
          </div>
        </div>
      </WorkspaceLayout>
    )
  }
  if (requestedView === 'live' && capabilityResponseReceived && !liveCacheAvailable) {
    return <Navigate to="/map?view=atlas" replace preserveLocation />
  }

  const view = requestedView
  return (
    <WorkspaceLayout
      workspace={getWorkspace('map')}
      tabs={tabs}
      activeTab={view}
      actions={
        view === 'atlas'
          ? <FreshnessBadge state="fresh" label="Shipped static atlas" />
          : view === 'live'
            ? undefined
            : <FreshnessBadge state="refreshing" label="Current server state" />
      }
    >
      <Suspense
        fallback={view === 'live'
          ? (
              <div className="flex min-w-0 flex-col gap-4">
                <LiveMapPreviewDisclosure />
                <DataState state="loading" title="Loading live map state…" />
              </div>
            )
          : <DataState state="loading" title={`Loading ${view === 'atlas' ? 'DD Atlas' : 'map lifecycle'}…`} />}
      >
        {view === 'atlas'
          ? <Atlas embedded />
          : view === 'live'
            ? <LiveState />
            : <Lifecycle embedded />}
      </Suspense>
    </WorkspaceLayout>
  )
}
