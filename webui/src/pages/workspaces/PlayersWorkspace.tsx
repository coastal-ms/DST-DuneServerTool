import { PlayersTab } from '../gameplay/PlayersTab'
import { WorkspaceLayout } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'

export default function PlayersWorkspace() {
  return (
    <WorkspaceLayout workspace={getWorkspace('players')}>
      <PlayersTab />
    </WorkspaceLayout>
  )
}
