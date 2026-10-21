import { BasesTab } from '../gameplay/BasesTab'
import { BlueprintsTab } from '../gameplay/BlueprintsTab'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { Navigate, useSearch } from '../../router'

type BasesView = 'bases' | 'blueprints' | 'inventory'

const TABS: readonly WorkspaceTab[] = [
  { id: 'bases', label: 'Bases', to: '/bases?view=bases', icon: 'Castle' },
  { id: 'blueprints', label: 'Blueprints', to: '/bases?view=blueprints', icon: 'ScrollText' },
]

function currentView(search: string): BasesView {
  const view = new URLSearchParams(search).get('view')
  if (view === 'blueprints' || view === 'inventory') return view
  return 'bases'
}

export default function BasesWorkspace() {
  const search = useSearch()
  const view = currentView(search)
  if (view === 'inventory') return <Navigate to={`/players?${search.replace(/^\?/, '')}&section=inventory`} replace />
  return (
    <WorkspaceLayout workspace={getWorkspace('bases')} tabs={TABS} activeTab={view}>
      {view === 'bases' && <BasesTab />}
      {view === 'blueprints' && <BlueprintsTab />}
    </WorkspaceLayout>
  )
}
