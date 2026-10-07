import { useSoloInstallation } from '../hooks/useInstallationMode'
import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation, useSearch } from '../router'
import { usePortalAccess } from '../auth/portalAccess'
import { isLocalViewer, isWindowsViewer } from '../util/viewer'
import { Icon } from '../components/Icon'
import { isNavItemActive } from '../nav'
import { getDeckDestinations, searchDeck } from './commandDeckModel'
import './commandDeck.css'

// THESIS: A task-led operating surface, not another dashboard of cards.
// OWN-WORLD: DST desert neutrals, amber selection, Ibad focus, crisp ruled planes.
// STORY: Locate a task, inspect its state, then use the existing guarded tools.
// FIRST VIEWPORT: Compact navigation beside a broad task bar and working canvas.
// FORM: Command Deck; persistent navigation, inline task finder, no new polling.
export default function CommandDeck({ collapsed }: { collapsed: boolean }) {
  const { pathname } = useLocation()
  const search = useSearch()
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const soloOnly = useSoloInstallation()
  const [query, setQuery] = useState('')
  const input = useRef<HTMLInputElement>(null)
  const local = isLocalViewer()
  const windows = isWindowsViewer()
  const destinations = useMemo(
    () => getDeckDestinations({ local, windows, canAccessOwnerSurfaces, soloOnly }),
    [local, windows, canAccessOwnerSurfaces, soloOnly],
  )
  const results = searchDeck(destinations, query)

  useEffect(() => {
    const focusFinder = (event: KeyboardEvent) => {
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k' && !event.altKey) {
        const target = event.target
        if (target instanceof HTMLElement && (target.isContentEditable ||
          /INPUT|TEXTAREA|SELECT/.test(target.tagName))) return
        event.preventDefault()
        input.current?.focus()
      }
    }
    window.addEventListener('keydown', focusFinder)
    return () => window.removeEventListener('keydown', focusFinder)
  }, [])

  return (
    <aside className={`deck-navigation ${collapsed ? 'deck-navigation-compact' : ''}`} data-search-active={!!query.trim()} aria-label="Command Deck navigation">
      <Link to="/" className="deck-mark" aria-label="DST Server Overview">
        <span className="deck-mark-symbol" aria-hidden="true">D</span>
        {!collapsed && <span>Dune Server Tool<small>Command Deck</small></span>}
      </Link>
      <label className="deck-find">
        <Icon name="Search" size={18} />
        <input
          ref={input}
          aria-label="Find a task"
          placeholder="Find a task"
          value={query}
          onChange={event => setQuery(event.target.value)}
          onKeyDown={event => {
            if (event.key === 'Escape') { setQuery(''); input.current?.blur() }
          }}
        />
      </label>
      {!collapsed && <p className="deck-find-help">Find any DST tool. <kbd>Ctrl K</kbd></p>}
      <nav className="deck-destinations" aria-label="Tools">
        {results.map(item => {
          // Specific workspace links take precedence over the broad Gameplay Admin gateway.
          const active = item.to === '/gameplay'
            ? pathname === '/gameplay'
            : isNavItemActive(item, pathname, search)
          return (
            <Link
              key={item.to}
              to={item.sidebarTo ?? item.to}
              aria-current={active ? 'page' : undefined}
              className="deck-destination"
              title={collapsed ? `${item.label}: ${item.description}` : item.description}
            >
              <Icon name={item.icon} size={19} />
              <span className={collapsed ? 'deck-compact-label' : ''}>{item.label}</span>
              {!collapsed && <Icon name="ChevronRight" size={12} className="deck-link-chevron" />}
            </Link>
          )
        })}
        {results.length === 0 && <p className="deck-empty-search">No tools match. Try a page name.</p>}
      </nav>
      {!collapsed && <p className="deck-nav-foot">Same tools. Your workspace.<br />Classic navigation is always available.</p>}
    </aside>
  )
}
