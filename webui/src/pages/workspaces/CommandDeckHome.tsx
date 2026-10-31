import { useMemo, useState } from 'react'
import { Link } from '../../router'
import { useStatus } from '../../hooks/useStatus'
import { usePortalAccess } from '../../auth/portalAccess'
import { isLocalViewer, isWindowsViewer } from '../../util/viewer'
import { mapLabel } from '../../util/mapLabel'
import { Icon } from '../../components/Icon'
import { DECK_TASK_LABELS, getDeckDestinations, searchDeck } from '../../layout/commandDeckModel'
import '../../layout/commandDeck.css'

export default function CommandDeckHome({ onDetails }: { onDetails: () => void }) {
  const { status, loading, error } = useStatus()
  const { canAccessOwnerSurfaces, canAccessServerUpdates } = usePortalAccess()
  const [query, setQuery] = useState('')
  const local = isLocalViewer()
  const windows = isWindowsViewer()
  const destinations = useMemo(
    () => getDeckDestinations({ local, windows, canAccessOwnerSurfaces, canAccessServerUpdates }),
    [local, windows, canAccessOwnerSurfaces, canAccessServerUpdates],
  )
  const tasks = query.trim()
    ? searchDeck(destinations, query)
    : ['/players', '/database', '/commands', '/bases', '/vehicles', '/map']
        .flatMap(path => destinations.filter(item => item.to === path))
  const bg = status?.bg
  const servers = bg?.gameServers ?? []
  const stamp = status?.ts ? new Date(status.ts) : null
  const timestamp = stamp && Number.isFinite(stamp.getTime()) ? stamp.toLocaleString() : null
  const vmState = !status ? 'Unavailable' : !status.vm.exists ? 'Not found' : status.vm.running ? 'Running' : status.vm.state || 'Stopped'
  const report = !status ? 'Waiting for server status' : error ? 'Showing last known state' : loading ? 'Refreshing server state' : 'Server state'

  return (
    <div className="deck-home">
      <header className="deck-home-heading">
        <div>
          <h1>Command Deck</h1>
          <p>Find your next task. Your tools stay within reach.</p>
        </div>
        <button type="button" className="btn-secondary" onClick={onDetails}>
          <Icon name="LayoutDashboard" size={16} /> Detailed overview
        </button>
      </header>

      <section className="deck-system" aria-labelledby="deck-system-title">
        <div className="deck-system-heading">
          <h2 id="deck-system-title">{status?.serverName || 'Server state'}</h2>
          <span>{report}{timestamp ? ` · ${timestamp}` : ''}</span>
        </div>
        {error && <p role="status" className="deck-status-error">Status refresh failed: {error}. Use Refresh status above to retry.</p>}
        <div className="deck-system-chain" aria-label="Reported infrastructure state">
          <div className="deck-system-node">
            <Icon name="HardDrive" size={26} />
            <span>Virtual machine<strong>{vmState}</strong></span>
          </div>
          <span className="deck-chain-join" aria-hidden="true" />
          <div className="deck-system-node">
            <Icon name="Database" size={26} />
            <span>Database<strong>{bg?.info?.database || 'Unavailable'}</strong></span>
          </div>
          <span className="deck-chain-join" aria-hidden="true" />
          <div className="deck-system-node">
            <Icon name="Network" size={26} />
            <span>Battlegroup<strong>{bg?.available ? bg.state || 'Unknown' : 'Unavailable'}</strong></span>
          </div>
        </div>
        <div className="deck-system-footer">
          <span>Reported state, not a readiness prediction.</span>
          <Link to="/pods">Inspect workloads <Icon name="ArrowUpRight" size={15} /></Link>
        </div>
      </section>

      <div className="deck-workbench">
        <section className="deck-task-panel" aria-labelledby="deck-task-title">
          <h2 id="deck-task-title">Choose your next task</h2>
          <label className="deck-task-input">
            <Icon name="Search" size={22} />
            <input aria-label="Search DST tasks" placeholder="Find players, ammo, backups..." value={query} onChange={event => setQuery(event.target.value)} />
            {query && <button type="button" className="btn-ghost" aria-label="Clear task search" onClick={() => setQuery('')}><Icon name="X" size={18} /></button>}
          </label>
          <p className="deck-task-hint">Opens the right tool. Nothing runs until you choose an action there.</p>
          <div className="deck-task-results">
            {tasks.map(task => (
              <Link key={task.to} to={task.sidebarTo ?? task.to} className="deck-task">
                <Icon name={task.icon} size={22} />
                <span><strong>{DECK_TASK_LABELS[task.to] ?? task.label}</strong><small>{task.description}</small></span>
                <Icon name="ArrowUpRight" size={19} />
              </Link>
            ))}
            {tasks.length === 0 && <p className="deck-empty-search">No matching tools. Try “players”, “backup”, or “map”.</p>}
          </div>
        </section>
        <section className="deck-world-panel" aria-labelledby="deck-world-title">
          <div className="deck-world-heading"><h2 id="deck-world-title">World roster</h2><Link to="/map">Open map <Icon name="ArrowUpRight" size={15} /></Link></div>
          <p className="deck-task-hint">Maps reported by your battlegroup.</p>
          {servers.length > 0 ? (
            <ul className="deck-world-list">
              {servers.map((server, index) => (
                <li key={`${server.map}-${index}`}>
                  <Icon name="Globe" size={22} />
                  <div><strong>{server.sietchName || mapLabel(server.map)}</strong><span>{server.phase || 'Unknown phase'}</span></div>
                  <span className={`deck-readiness ${server.ready?.toLowerCase() === 'false' ? 'deck-not-ready' : server.ready?.toLowerCase() === 'true' ? 'deck-ready' : ''}`}>
                    {server.ready?.toLowerCase() === 'true' ? 'Ready' : server.ready?.toLowerCase() === 'false' ? 'Not ready' : 'Readiness unknown'}
                  </span>
                  <span className="deck-player-count">{server.players || '—'}<small>players</small></span>
                </li>
              ))}
            </ul>
          ) : (
            <div className="deck-world-empty"><Icon name="Globe" size={44} /><p>{loading ? 'Reading map state...' : 'No maps reported.'}</p><span>Missing data is not a zero-player reading.</span></div>
          )}
          <div className="deck-world-note"><Icon name="Info" size={17} /><span>Full diagnostics, schedules, and alerts remain in <button type="button" onClick={onDetails}>Detailed overview</button>.</span></div>
        </section>
      </div>
    </div>
  )
}
