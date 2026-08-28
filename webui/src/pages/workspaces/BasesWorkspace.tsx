import { BasesTab } from '../gameplay/BasesTab'
import { WorkspaceLayout } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'

export default function BasesWorkspace() {
  return (
    <WorkspaceLayout workspace={getWorkspace('bases')}>
      <BasesTab />
    </WorkspaceLayout>
  )
}
