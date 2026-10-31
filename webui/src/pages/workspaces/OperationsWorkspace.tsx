import { useState } from 'react'
import { usePortalAccess } from '../../auth/portalAccess'
import { Icon } from '../../components/Icon'
import { WorkspaceLayout } from '../../components/platform/WorkspaceLayout'
import { getWorkspace } from '../../platform/workspaces'
import { Link } from '../../router'
import { isLocalViewer } from '../../util/viewer'
import { useStatus } from '../../hooks/useStatus'

const OPERATION_LINKS = [
  { to: '/commands?category=battlegroup', label: 'Server controls', description: 'Start, stop and restart your game servers.', icon: 'Power', group: 'everyday' },
  { to: '/database?section=database.maint.Take+Backup', label: 'Backups', description: 'Create a backup or restore a saved copy.', icon: 'Archive', group: 'everyday', ownerOnly: true },
  { to: '/commands?task=updates', label: 'Server updates', description: 'Apply an available Funcom server update.', icon: 'Download', group: 'everyday', serverUpdatesOnly: true },
  { to: '/map?view=live', label: 'Live Map', description: 'Open your map and its live layers.', icon: 'Map', group: 'everyday' },
  { to: '/database?section=database.backupSchedule', label: 'Backup schedule', description: 'Set when backups run and how long to keep them.', icon: 'CalendarClock', group: 'maintenance', ownerOnly: true },
  { to: '/map?view=lifecycle', label: 'Map management', description: 'Manage map instances and restart a map.', icon: 'Network', group: 'maintenance' },
  { to: '/pods', label: 'Service health', description: 'Inspect running services and their status.', icon: 'Boxes', group: 'maintenance' },
  { to: '/broadcasts', label: 'Broadcasts', description: 'Send an in-game message to your players.', icon: 'Megaphone', group: 'maintenance' },
  { to: '/server-settings', label: 'Server Settings', description: 'Edit your server settings and configuration.', icon: 'ServerCog', group: 'maintenance', ownerOnly: true },
  { to: '/sietches', label: 'Sietches', description: 'Configure your Hagga server groups.', icon: 'Network', group: 'maintenance', ownerOnly: true },
  { to: '/database', label: 'Database', description: 'Inspect data, run SQL and open migration tools.', icon: 'Database', group: 'advanced', ownerOnly: true },
  { to: '/commands', label: 'All commands', description: 'Browse every available server and VM command.', icon: 'Zap', group: 'advanced' },
  { to: '/terminal', label: 'PowerShell', description: 'Open PowerShell on the host PC.', icon: 'SquareTerminal', group: 'advanced', localOnly: true },
] as const

export default function OperationsWorkspace() {
  const { canAccessOwnerSurfaces, canAccessServerUpdates } = usePortalAccess()
  const local = isLocalViewer()
  const { status, error, loading, refresh } = useStatus()
  const [query, setQuery] = useState('')
  const [refreshError, setRefreshError] = useState('')
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const links = OPERATION_LINKS
    .filter(item => !('ownerOnly' in item) || canAccessOwnerSurfaces)
    .filter(item => !('serverUpdatesOnly' in item) || canAccessServerUpdates)
    .filter(item => !('localOnly' in item) || local)
    .filter(item => words.every(word => (item.label + ' ' + item.description).toLowerCase().includes(word)))
  const observed = status?.ts ? new Date(status.ts) : null
  const stamp = observed && Number.isFinite(observed.getTime()) ? observed.toLocaleString() : null
  return <WorkspaceLayout workspace={getWorkspace('operations')}>
    <section className="card mb-5 p-4 sm:p-5" aria-label="Server status">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div><h2 className="text-lg font-semibold">Your server at a glance</h2>{stamp && <p className="mt-1 text-xs text-text-dim">Updated {stamp}</p>}</div>
        <button className="btn-secondary" disabled={loading} onClick={() => { setRefreshError(''); void refresh().catch(reason => setRefreshError(reason instanceof Error ? reason.message : 'Refresh failed')) }}><Icon name="RefreshCw" size={15} />Refresh</button>
      </div>
      <dl className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="rounded-lg border border-border bg-surface-2 p-3"><dt className="text-xs text-text-muted">Virtual machine</dt><dd className="mt-1 font-semibold">{status?.vm?.state || 'Not reported'}</dd></div>
        <div className="rounded-lg border border-border bg-surface-2 p-3"><dt className="text-xs text-text-muted">Battlegroup</dt><dd className="mt-1 font-semibold">{status?.bg?.state || 'Not reported'}</dd></div>
        <div className="rounded-lg border border-border bg-surface-2 p-3"><dt className="text-xs text-text-muted">Map instances</dt><dd className="mt-1 font-semibold">{status?.bg?.gameServers?.length ?? 'Not reported'}</dd></div>
      </dl>
      {(error || refreshError) && <p role="status" className="mt-3 text-sm text-warning">{refreshError || error}. Last available observation shown; refresh to check again.</p>}
    </section>
    <label className="mb-5 flex items-center gap-3 rounded-lg border border-border bg-surface px-4 py-3"><Icon name="Search" size={18} /><input className="min-w-0 flex-1 bg-transparent text-sm outline-none" type="search" aria-label="Find a server task" placeholder="Find a task: backups, updates, maps..." value={query} onChange={event => setQuery(event.target.value)} /></label>
    {[{ id: 'everyday', title: 'Everyday tasks' }, { id: 'maintenance', title: 'Manage your server' }, { id: 'advanced', title: 'Advanced tools' }].map(group => {
      const items = links.filter(link => link.group === group.id)
      return items.length > 0 && <section key={group.id} className="mb-7" aria-label={group.title}>
        <h2 className="mb-3 text-base font-semibold text-text">{words.length ? group.title + ' · matches' : group.title}</h2>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">{items.map(link => <Link key={link.to} to={link.to} className="group flex min-h-32 items-start gap-3 rounded-xl border border-border bg-surface p-4 transition-colors hover:border-accent/60 hover:bg-surface-2 focus-visible:ring-2 focus-visible:ring-ibad">
          <Icon name={link.icon} size={21} className="mt-0.5 shrink-0 text-accent-bright" /><span className="min-w-0 flex-1"><strong className="block font-semibold text-text">{link.label}</strong><span className="mt-2 block text-sm leading-relaxed text-text-muted">{link.description}</span></span><Icon name="ArrowUpRight" size={15} className="shrink-0 text-text-dim group-hover:text-text" />
        </Link>)}</div>
      </section>
    })}
    {!links.length && <p className="card p-6 text-sm text-text-muted" role="status">No matching tasks. Try another task name.</p>}
  </WorkspaceLayout>
}
