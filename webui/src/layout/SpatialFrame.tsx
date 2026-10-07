import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Link, useLocation, useSearch } from '../router'
import { Icon } from '../components/Icon'
import { useStatus } from '../hooks/useStatus'
import { useSoloInstallation } from '../hooks/useInstallationMode'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import { setCommandDeck } from '../hooks/useCommandDeck'
import { usePortalAccess } from '../auth/portalAccess'
import { isLocalViewer, isWindowsViewer } from '../util/viewer'
import { PRESETS, useTheme } from '../theme/ThemeContext'
import { getDeckDestinations, searchDeck } from './commandDeckModel'
import { useFloatingDock } from './useFloatingDock'
import { useDashboardViewport } from './useDashboardViewport'
import { colorSchemeForBase } from '../theme/colorScheme'
import { fmtToolVersion } from '../format'
import '../pages/workspaces/spatial.css'
import './floatingDock.css'
import './dashboardFrame.css'
import './portalWorkspace.css'

const DOCK = ['/', '/map?view=atlas', '/solo', '/players', '/bases', '/vehicles', '/economy', '/commands', '/database']
const NEUTRAL_PALETTES = new Set(['world-control', 'daylight', 'signal'])

function isActiveDockDestination(destination: string, pathname: string, search: string) {
  const target = new URL(destination, window.location.origin)
  if (pathname !== target.pathname) return false
  const current = new URLSearchParams(search)
  return [...target.searchParams].every(([key, value]) => current.get(key) === value)
}

export default function SpatialFrame({ children, onDetails, tools = false, dashboard = false }: {
  children: ReactNode
  onDetails?: () => void
  tools?: boolean
  dashboard?: boolean
}) {
  const { status, error, loading } = useStatus()
  const soloOnly = useSoloInstallation()
  const { data: update } = useUpdateCheck()
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const theme = useTheme()
  const { pathname } = useLocation()
  const search = useSearch()
  const [query, setQuery] = useState('')
  const dialog = useRef<HTMLDialogElement>(null)
  const input = useRef<HTMLInputElement>(null)
  const opener = useRef<HTMLElement | null>(null)
  const portal = tools && !dashboard && pathname !== '/'
  const toolScroll = useRef<HTMLDivElement>(null)
  const { dockRef, dockAnchorRef } = useFloatingDock({ enabled: !dashboard && !portal })
  const frameRef = useDashboardViewport(dashboard || portal)
  const destinations = getDeckDestinations({ local: isLocalViewer(), windows: isWindowsViewer(), canAccessOwnerSurfaces, soloOnly })
  const results = searchDeck(destinations, query)
  const current = destinations.find(item => item.to === pathname)

  function openFinder() {
    opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
    setQuery('')
    dialog.current?.showModal()
    input.current?.focus()
  }
  useEffect(() => {
    function keyboard(event: KeyboardEvent) {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !event.defaultPrevented) {
        event.preventDefault()
        opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null
        setQuery('')
        dialog.current?.showModal()
        input.current?.focus()
      }
    }
    window.addEventListener('keydown', keyboard)
    return () => window.removeEventListener('keydown', keyboard)
  }, [])
  useEffect(() => { dialog.current?.close() }, [pathname, search])
  useEffect(() => {
    if (portal && toolScroll.current) toolScroll.current.scrollTop = 0
  }, [portal, pathname, search])

  return (
    <div ref={frameRef} data-portal-tone={colorSchemeForBase(theme.resolved['--color-base'] || '#0c0a09')}
      className={`spatial-workspace${tools && !dashboard ? ' spatial-tool-workspace' : ''}${dashboard ? ' spatial-dashboard-frame' : ''}${portal ? ' spatial-tool-portal' : ''}`}>
      <header className="spatial-header">
        <Link to="/" className="spatial-brand" aria-label="DST home"><span>◈</span><strong>DST<span>WORLD CONTROL</span></strong></Link>
        <div className="spatial-server-name"><span>{soloOnly ? 'Solo Mode' : status?.serverName || 'Server connection'}</span><small>{soloOnly ? 'Local save tools' : error ? 'Last known snapshot' : loading ? 'Refreshing snapshot' : 'Observed snapshot'}</small></div>
        <div className="spatial-header-actions">
          <label className="spatial-palette">
            <Icon name="Palette" size={17} />
            <span className="sr-only">Workspace palette</span>
            <select value={theme.presetId} onChange={event => theme.setPreset(event.target.value)}>
              <optgroup label="Light & dark">
                {PRESETS.filter(preset => NEUTRAL_PALETTES.has(preset.id)).map(preset => <option key={preset.id} value={preset.id}>{preset.name}</option>)}
              </optgroup>
              <optgroup label="Dune worlds & houses">
                {PRESETS.filter(preset => !NEUTRAL_PALETTES.has(preset.id)).map(preset => <option key={preset.id} value={preset.id}>{preset.name}</option>)}
              </optgroup>
            </select>
          </label>
          <button onClick={openFinder} aria-haspopup="dialog" aria-label="Find a tool" title="Find a tool (Ctrl+K)"><Icon name="Search" size={17} /><span>Find a tool</span></button>
          {onDetails
            ? <button onClick={onDetails} aria-label="Dashboard" title="Server health dashboard"><Icon name="LayoutDashboard" size={17} /><span>Dashboard</span></button>
            : soloOnly ? <Link to="/settings" aria-label="Settings"><Icon name="Settings" size={17} /><span>Settings</span></Link>
            : <Link to="/operations" aria-label="Diagnostics"><Icon name="Activity" size={17} /><span>Diagnostics</span></Link>}
          <button onClick={() => setCommandDeck(false)} aria-label="Classic" title="Return to classic layout"><Icon name="PanelsTopLeft" size={17} /><span>Classic</span></button>
        </div>
      </header>
      <div className="spatial-workarea">
        {tools && !dashboard && !portal && <nav className="spatial-tool-path" aria-label="Workspace location">
          <Link to="/"><Icon name="ArrowLeft" size={15} />World control</Link>
          <span aria-hidden="true">/</span><span aria-current="page">{current?.label || 'Workspace'}</span>
        </nav>}
        {tools && !dashboard && !portal && error && <p className="spatial-error" role="status">{error}. Server indicators show the last available observation.</p>}
        <div ref={portal ? toolScroll : undefined} data-app-scroll-container={portal ? '' : undefined}
          className={portal ? 'spatial-tool-scroll' : dashboard ? 'spatial-dashboard-body' : tools ? 'spatial-tool-content' : undefined}>
          {portal && error && <p className="portal-status-error" role="status">{error}. Server indicators show the last available observation.</p>}
          {children}
        </div>
        <footer className="spatial-bottom">
          {!dashboard && !soloOnly && <div className="spatial-infrastructure"><span>VM <b>{status ? status.vm.running ? 'Running' : status.vm.state || 'Unknown' : 'Unknown'}</b></span><span>Database <b>{status?.bg?.info?.database || 'Unknown'}</b></span></div>}
          <div ref={dockAnchorRef} className="spatial-dock-slot">
            <nav ref={dockRef} className="spatial-dock" aria-label="Workspace dock">
              {(soloOnly ? ['/solo', '/settings', '/sponsors'] : DOCK).filter(route => tools || route !== '/').flatMap(route => destinations.filter(item => item.to === route)).map(item => (
                <Link to={item.to} key={item.to} aria-current={isActiveDockDestination(item.to, pathname, search) ? 'page' : undefined}><Icon name={item.icon} size={20} /><span>{item.to === '/' ? 'World' : item.label}</span></Link>
              ))}
              <button onClick={openFinder} aria-haspopup="dialog"><Icon name="Grid2X2" size={20} /><span>All tools</span></button>
            </nav>
          </div>
          {!dashboard && (
            <span className="spatial-system-label">
              LOCAL CONTROL
              <b>BUILT WITH DUKE WITH LOVE</b>
              <small>{update?.currentVersion ? fmtToolVersion(update.currentVersion) : '—'}</small>
            </span>
          )}
        </footer>
      </div>
      <dialog ref={dialog} className="spatial-finder" aria-labelledby="spatial-finder-title"
        onClose={() => opener.current?.focus()}
        onClick={event => { if (event.target === event.currentTarget) dialog.current?.close() }}>
        <div>
          <header><h2 id="spatial-finder-title">Find your next move.</h2><button onClick={() => dialog.current?.close()} aria-label="Close tool finder"><Icon name="X" size={22} /></button></header>
          <input ref={input} aria-label="Search DST tools" placeholder="Search players, backups, ammo..." value={query} onChange={event => setQuery(event.target.value)} />
          <nav>{results.map(item => <Link to={item.to} key={item.to} onClick={() => dialog.current?.close()}><Icon name={item.icon} size={20} /><span><strong>{item.label}</strong><small>{item.description}</small></span><Icon name="ArrowUpRight" size={16} /></Link>)}</nav>
          {!results.length && <p className="spatial-empty">No matching tool. Try a page or task name.</p>}
        </div>
      </dialog>
    </div>
  )
}
