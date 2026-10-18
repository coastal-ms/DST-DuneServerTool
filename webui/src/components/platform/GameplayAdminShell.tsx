import { useEffect, type ReactNode } from 'react'
import { Icon } from '../Icon'
import { Link, useHash, useLocation, useNavigate, useSearch } from '../../router'
import { useCommandDeck } from '../../hooks/useCommandDeck'
import { WorkspaceHeadingContext } from './WorkspaceHeadingContext'
import {
  GAMEPLAY_DESTINATIONS,
  rememberGameplayDestination,
  resolveGameplaySection,
  type GameplaySectionId,
} from '../../platform/gameplay'

export function GameplayAdminShell({
  activeSection,
  children,
}: {
  activeSection?: GameplaySectionId
  children: ReactNode
}) {
  const contextual = useCommandDeck()
  const navigate = useNavigate()
  const { pathname } = useLocation()
  const search = useSearch()
  const hash = useHash()
  const active = activeSection ?? resolveGameplaySection(pathname, search)
  const liveMap = active === 'map' && new URLSearchParams(search).get('view') === 'live'

  useEffect(() => {
    rememberGameplayDestination(`${pathname}${search ? `?${search}` : ''}${hash}`)
  }, [hash, pathname, search])

  if (contextual) {
    const title = active === 'overview' ? 'Gameplay Admin' : GAMEPLAY_DESTINATIONS.find(destination => destination.id === active)?.label || 'Gameplay Admin'
    return <WorkspaceHeadingContext.Provider value={title}>
      <div className="portal-gameplay-shell" data-gameplay-admin-shell>
        <header className="portal-domain-toolbar">
          <h1>{title}</h1>
          <nav aria-label="Gameplay Admin sections">
            <select aria-label="Gameplay workspace" value={active} onChange={event => {
              const destination = GAMEPLAY_DESTINATIONS.find(item => item.id === event.target.value)
              if (!destination) throw new Error('Unknown gameplay workspace')
              navigate(destination.to)
            }}>
              {GAMEPLAY_DESTINATIONS.map(destination => <option key={destination.id} value={destination.id}>{destination.label}</option>)}
            </select>
          </nav>
        </header>
        <div className="portal-domain-content">{children}</div>
      </div>
    </WorkspaceHeadingContext.Provider>
  }

  return (
    <div className="min-w-0 max-w-full" data-gameplay-admin-shell>
      {!liveMap && (!contextual || active === 'overview') && <div className="mb-4 flex min-w-0 items-center gap-3 border-b border-border pb-3">
        <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl border border-accent/25 bg-accent/10 text-accent-bright">
          <Icon name="Gamepad2" size={20} />
        </span>
        <div className="min-w-0">
          {active === 'overview'
            ? <h1 className="text-xl font-semibold text-text">Gameplay Admin</h1>
            : <div className="text-sm font-semibold uppercase tracking-wider text-accent-bright">Gameplay Admin</div>}
          <p className="text-sm text-text-muted">
            In-world players, bases, vehicles, and economy
          </p>
        </div>
      </div>}

      <nav
        aria-label="Gameplay Admin sections"
        className={`${liveMap ? 'mb-2' : 'mb-5'} -mx-3 max-w-full overflow-x-auto overscroll-x-contain border-b border-border px-3 touch-pan-x [scrollbar-width:none] sm:mx-0 sm:px-0 [&::-webkit-scrollbar]:hidden`}
      >
        <div className="flex min-w-max items-center gap-1">
          {GAMEPLAY_DESTINATIONS.map(destination => {
            const selected = active === destination.id
            return (
              <Link
                key={destination.id}
                to={destination.to}
                aria-current={selected ? 'page' : undefined}
                className={`min-h-11 shrink-0 border-b-2 px-3 py-2.5 text-sm font-medium transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ibad ${
                  selected
                    ? 'border-accent text-accent-bright'
                    : 'border-transparent text-text-muted hover:text-text'
                }`}
              >
                <span className="inline-flex items-center gap-2">
                  <Icon name={destination.icon} size={15} />
                  {destination.label}
                </span>
              </Link>
            )
          })}
        </div>
      </nav>

      <div className="min-w-0 max-w-full">{children}</div>
    </div>
  )
}
