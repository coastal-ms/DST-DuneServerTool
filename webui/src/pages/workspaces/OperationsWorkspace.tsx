import { usePortalAccess } from '../../auth/portalAccess'
import { Icon } from '../../components/Icon'
import { WorkspaceLayout, WorkspaceSection } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { Link } from '../../router'
import { isLocalViewer } from '../../util/viewer'

type OperationLink = {
  to: string
  label: string
  description: string
  icon: string
  ownerOnly?: boolean
  localOnly?: boolean
}

const OPERATION_LINKS: readonly OperationLink[] = [
  { to: '/pods', label: 'Runtime and pods', description: 'Inspect Kubernetes workload health and one-shot operations.', icon: 'Boxes' },
  { to: '/commands', label: 'Commands', description: 'Run the existing curated lifecycle actions.', icon: 'Zap' },
  { to: '/map?view=lifecycle', label: 'Map lifecycle', description: 'Manage warm maps, partitions, and map pod restarts.', icon: 'Map' },
  { to: '/broadcasts', label: 'Communications', description: 'Send existing in-game broadcasts.', icon: 'Megaphone' },
  { to: '/database', label: 'Data protection', description: 'Use the existing backup, restore, and database operations.', icon: 'Database', ownerOnly: true },
  { to: '/sietches', label: 'Topology', description: 'Configure existing Hagga shard topology.', icon: 'Network', ownerOnly: true },
  { to: '/terminal', label: 'Host tools', description: 'Open the host-local PowerShell surface.', icon: 'SquareTerminal', localOnly: true },
]

export default function OperationsWorkspace() {
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const local = isLocalViewer()
  const links = OPERATION_LINKS.filter(item => !item.ownerOnly || canAccessOwnerSurfaces)
    .filter(item => !item.localOnly || local)

  return (
    <WorkspaceLayout workspace={getWorkspace('operations')}>
      <WorkspaceSection
        id="operations-current-tools"
        title="Operational tools"
        description="Existing tools remain at their compatibility URLs while the shared workspace structure settles."
      >
        <div className="divide-y divide-border overflow-hidden rounded-xl border border-border bg-surface/80">
          {links.map(item => (
            <Link
              key={item.to}
              to={item.to}
              className="flex min-h-16 items-start gap-3 px-4 py-3 text-left transition-colors hover:bg-surface-2 focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ibad"
            >
              <Icon name={item.icon} size={18} className="mt-0.5 shrink-0 text-accent-bright" />
              <span className="min-w-0 flex-1">
                <span className="block font-medium text-text">{item.label}</span>
                <span className="mt-0.5 block text-sm text-text-muted">{item.description}</span>
              </span>
              <Icon name="ChevronRight" size={16} className="mt-1 shrink-0 text-text-dim" />
            </Link>
          ))}
        </div>
      </WorkspaceSection>
    </WorkspaceLayout>
  )
}
