import { PlayersTab } from '../gameplay/PlayersTab'
import { SharedInventoryExplorer } from '../../components/inventory/SharedInventoryExplorer'
import { WorkspaceLayout, type WorkspaceTab } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { useSearch } from '../../router'
import { PlayersCommunity } from './PlayersCommunity'

const TABS: readonly WorkspaceTab[] = [
  { id: 'admin', label: 'Player admin', to: '/players?view=admin', icon: 'Users' },
  { id: 'inventory', label: 'Inventory', to: '/players?view=inventory', icon: 'PackageSearch' },
  { id: 'community', label: 'Community tools', to: '/players?view=community', icon: 'MessageSquare' },
]

export default function PlayersWorkspace() {
  const requestedView = new URLSearchParams(useSearch()).get('view')
  const view = requestedView === 'inventory' || requestedView === 'community'
    ? requestedView
    : 'admin'
  return (
    <WorkspaceLayout workspace={getWorkspace('players')} tabs={TABS} activeTab={view}>
      {view === 'inventory'
        ? <SharedInventoryExplorer entityTypes={['player']} />
        : view === 'community'
          ? <PlayersCommunity />
          : <PlayersTab />}
    </WorkspaceLayout>
  )
}
