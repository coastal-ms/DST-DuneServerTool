import { PlayersTab } from '../gameplay/PlayersTab'
import { SharedInventoryExplorer } from '../../components/inventory/SharedInventoryExplorer'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'

const TABS: readonly WorkspaceTab[] = [
  { id: 'admin', label: 'Player admin', to: '/players?view=admin', icon: 'Users' },
  { id: 'inventory', label: 'Inventory', to: '/players?view=inventory', icon: 'PackageSearch' },
]

export default function PlayersWorkspace() {
  const view = new URLSearchParams(useSearch()).get('view') === 'inventory' ? 'inventory' : 'admin'
  return (
    <WorkspaceLayout workspace={getWorkspace('players')} tabs={TABS} activeTab={view}>
      {view === 'inventory'
        ? <SharedInventoryExplorer entityTypes={['player']} />
        : <PlayersTab />}
    </WorkspaceLayout>
  )
}
