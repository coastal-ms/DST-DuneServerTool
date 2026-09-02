import { BasesTab } from '../gameplay/BasesTab'
import { SharedInventoryExplorer } from '../../components/inventory/SharedInventoryExplorer'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const TABS: readonly WorkspaceTab[] = [
  { id: 'bases', label: 'Bases', to: '/bases?view=bases', icon: 'Castle' },
  { id: 'inventory', label: 'Storage inventory', to: '/bases?view=inventory', icon: 'PackageSearch' },
]

export default function BasesWorkspace() {
  const view = new URLSearchParams(useSearch()).get('view') === 'inventory' ? 'inventory' : 'bases'
  return (
    <WorkspaceLayout workspace={getWorkspace('bases')} tabs={TABS} activeTab={view}>
      {view === 'inventory'
        ? (
            <SharedInventoryExplorer
              entityTypes={['storage']}
              description="Search proven storage-container contents. Base-wide membership is not inferred in this slice."
            />
          )
        : <BasesTab />}
    </WorkspaceLayout>
  )
}
