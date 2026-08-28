import { lazy, Suspense } from 'react'
import { DataState, FreshnessBadge } from '../../components/platform/DataState'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const Atlas = lazy(() => import('../WickMaps').then(module => ({ default: module.WickMaps })))
const Lifecycle = lazy(() => import('../MapSpinUp').then(module => ({ default: module.MapSpinUp })))

type MapView = 'atlas' | 'lifecycle'

const TABS: readonly WorkspaceTab[] = [
  { id: 'atlas', label: 'DD Atlas', to: '/map?view=atlas', icon: 'Map' },
  { id: 'lifecycle', label: 'Lifecycle', to: '/map?view=lifecycle', icon: 'Power' },
]

function currentView(search: string): MapView {
  return new URLSearchParams(search).get('view') === 'lifecycle'
    ? 'lifecycle'
    : 'atlas'
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
          : <FreshnessBadge state="refreshing" label="Current server state" />
      }
    >
      <Suspense
        fallback={<DataState state="loading" title={`Loading ${view === 'atlas' ? 'DD Atlas' : 'map lifecycle'}…`} />}
      >
        {view === 'atlas' ? <Atlas embedded /> : <Lifecycle embedded />}
      </Suspense>
    </WorkspaceLayout>
  )
}
