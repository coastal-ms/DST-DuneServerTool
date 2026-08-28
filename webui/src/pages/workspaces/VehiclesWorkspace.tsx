import { DataState } from '../../components/platform/DataState'
import { WorkspaceLayout, WorkspaceSection } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { Link } from '../../router'

export default function VehiclesWorkspace() {
  return (
    <WorkspaceLayout workspace={getWorkspace('vehicles')}>
      <WorkspaceSection
        id="vehicles-current-tools"
        title="Current vehicle tools"
        description="The workspace boundary exists now; the existing player-scoped vehicle actions stay in Gameplay Admin until a proven fleet read model is available."
      >
        <DataState
          state="unavailable"
          title="Fleet view not available yet"
          message="No vehicle data or permissions have been broadened. Existing Spawn Vehicle and Refuel Vehicle behavior remains unchanged."
          action={<Link className="btn-secondary" to="/gameplay?view=players">Open current player tools</Link>}
        />
      </WorkspaceSection>
    </WorkspaceLayout>
  )
}
