import { lazy, Suspense } from 'react'
import { DataState, FreshnessBadge } from '../../components/platform/DataState'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const Atlas = lazy(() => import('../WickMaps').then(module => ({ default: module.WickMaps })))
const LiveState = lazy(() => import('./MapLiveState').then(module => ({ default: module.MapLiveState })))
const Lifecycle = lazy(() => import('../MapSpinUp').then(module => ({ default: module.MapSpinUp })))

type MapView = 'atlas' | 'live' | 'lifecycle'

const TABS: readonly WorkspaceTab[] = [
  { id: 'atlas', label: 'DD Atlas', to: '/map?view=atlas', icon: 'Map' },
  { id: 'live', label: 'Live state', to: '/map?view=live', icon: 'Activity' },
  { id: 'lifecycle', label: 'Lifecycle', to: '/map?view=lifecycle', icon: 'Power' },
]

function currentView(search: string): MapView {
  const view = new URLSearchParams(search).get('view')
  return view === 'live' || view === 'lifecycle' ? view : 'atlas'
}

export default function MapWorkspace() {
  const search = useSearch()
  const view = currentView(search)
  return (
    <WorkspaceLayout
      workspace={getWorkspace('map')}
      tabs={TABS}
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
        fallback={<DataState state="loading" title={`Loading ${
          view === 'atlas' ? 'DD Atlas' : view === 'live' ? 'live map state' : 'map lifecycle'
        }…`} />}
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
