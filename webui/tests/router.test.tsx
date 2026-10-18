import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { LEGACY_REMOTE_MAP_DESTINATION } from '../src/platform/routes'
import { GameplayAdminShell } from '../src/components/platform/GameplayAdminShell'
import { GameplayEnvironment } from '../src/pages/GameplayEnvironment'
import {
  BrowserRouter,
  Link,
  NavLink,
  Navigate,
  Route,
  Routes,
  useNavigate,
  useLocation,
  useSearch,
  mergeNavigationLocation,
} from '../src/router'
import {
  isGameplayDestination,
  normalizeGameplayDestination,
  readLastGameplayDestination,
  rememberGameplayDestination,
} from '../src/platform/gameplay'

vi.mock('../src/pages/gameplay/BlueprintsTab', () => ({
  BlueprintsTab: () => <div>Blueprints fixture</div>,
}))

function LocationProbe() {
  const { pathname } = useLocation()
  const search = useSearch()
  return <output>{pathname}{search ? `?${search}` : ''}</output>
}

function NavigateButton() {
  const navigate = useNavigate()
  return <button onClick={() => navigate('/settings')}>Open settings</button>
}

beforeEach(() => {
  window.history.replaceState(null, '', '/')
  localStorage.removeItem('dst.gameplay.lastDestination')
})

afterEach(() => {
  cleanup()
})

describe('router compatibility layer', () => {
  it('renders routes and navigates through links and the imperative hook', async () => {
    const user = userEvent.setup()
    render(
      <BrowserRouter>
        <Link to="/pods">Pods</Link>
        <NavigateButton />
        <LocationProbe />
        <Routes>
          <Route path="/" element={<div>Dashboard</div>} />
          <Route path="/pods" element={<div>Pod list</div>} />
          <Route path="/settings" element={<div>Settings page</div>} />
        </Routes>
      </BrowserRouter>,
    )

    expect(screen.getByText('Dashboard')).toBeInTheDocument()
    await user.click(screen.getByRole('link', { name: 'Pods' }))
    expect(screen.getByText('Pod list')).toBeInTheDocument()
    expect(screen.getByText('/pods')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Open settings' }))
    expect(screen.getByText('Settings page')).toBeInTheDocument()
  })

  it('notifies route consumers when only query-string workspace state changes', async () => {
    const user = userEvent.setup()
    render(
      <BrowserRouter>
        <Link to="/map?view=lifecycle">Lifecycle</Link>
        <LocationProbe />
      </BrowserRouter>,
    )

    await user.click(screen.getByRole('link', { name: 'Lifecycle' }))
    expect(screen.getByText('/map?view=lifecycle')).toBeInTheDocument()
  })

  it('preserves unrelated query and hash state while destination parameters win', async () => {
    window.history.replaceState(null, '', '/dd-map?source=bookmark&view=old#seed-detail')
    render(
      <BrowserRouter>
        <LocationProbe />
        <Routes>
          <Route
            path="/dd-map"
            element={<Navigate to="/map?view=atlas" replace preserveLocation />}
          />
          <Route path="/map" element={<div>Map workspace</div>} />
        </Routes>
      </BrowserRouter>,
    )

    expect(await screen.findByText('Map workspace')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/map')
    expect(window.location.search).toBe('?source=bookmark&view=atlas')
    expect(window.location.hash).toBe('#seed-detail')
  })

  it('merges repeated destination parameters without retaining stale values', () => {
    expect(mergeNavigationLocation(
      '/map?layer=spice&layer=players',
      '?source=bookmark&layer=old',
      '#details',
    )).toBe('/map?source=bookmark&layer=spice&layer=players#details')
  })

  it('preserves remote bookmark state while selecting the lifecycle view', () => {
    expect(mergeNavigationLocation(
      LEGACY_REMOTE_MAP_DESTINATION,
      '?source=legacy-bookmark&view=maps',
      '#partition-status',
    )).toBe('/map?source=legacy-bookmark&view=lifecycle#partition-status')
  })

  it('normalizes valid persisted Gameplay Admin query and hash state', () => {
    const storage = {
      getItem: () => '/gameplay?view=blueprints&source=bookmark#details',
      setItem: vi.fn(),
      removeItem: vi.fn(),
    }
    expect(readLastGameplayDestination(storage)).toBe('/gameplay?view=blueprints&source=bookmark#details')
    expect(storage.removeItem).not.toHaveBeenCalled()
    expect(normalizeGameplayDestination('/economy?view=market-bot#list')).toBe('/economy?view=market-bot#list')
    expect(isGameplayDestination('/settings')).toBe(false)
  })

  it('canonicalizes bare and same-origin Gameplay Admin targets before reuse', () => {
    const bareStorage = {
      getItem: () => '/gameplay',
      setItem: vi.fn(),
      removeItem: vi.fn(),
    }
    expect(readLastGameplayDestination(bareStorage)).toBe('/gameplay?view=overview')
    expect(bareStorage.setItem).toHaveBeenCalledWith(
      'dst.gameplay.lastDestination',
      '/gameplay?view=overview',
    )

    expect(normalizeGameplayDestination(
      `${window.location.origin}/players?sort=name#selected`,
    )).toBe('/players?sort=name#selected')
  })

  it('clears cross-origin, protocol-relative, malformed, and unknown persisted targets', () => {
    for (const invalid of [
      'https://evil.example/gameplay?view=overview',
      '//evil.example/gameplay?view=overview',
      'http://[',
      '/settings',
    ]) {
      const storage = {
        getItem: () => invalid,
        setItem: vi.fn(),
        removeItem: vi.fn(),
      }
      expect(readLastGameplayDestination(storage)).toBe('/gameplay?view=overview')
      expect(storage.removeItem).toHaveBeenCalledWith('dst.gameplay.lastDestination')
      expect(storage.setItem).not.toHaveBeenCalled()
    }
  })

  it('does not restore the standalone map as a Gameplay Admin destination', () => {
    expect(normalizeGameplayDestination('/map?view=live')).toBeNull()
    expect(normalizeGameplayDestination('/gameplay?view=map')).toBeNull()
  })

  it('redirects old Gameplay Admin map bookmarks to the standalone map', async () => {
    window.history.replaceState(null, '', '/gameplay?view=map')
    render(<BrowserRouter><Routes>
      <Route path="/gameplay" element={<GameplayEnvironment />} />
      <Route path="/map" element={<div>Standalone map</div>} />
    </Routes></BrowserRouter>)
    expect(await screen.findByText('Standalone map')).toBeInTheDocument()
    expect(screen.queryByRole('navigation', { name: 'Gameplay Admin sections' })).not.toBeInTheDocument()
  })

  it('stores only normalized same-origin Gameplay Admin targets', () => {
    const storage = { setItem: vi.fn() }
    rememberGameplayDestination(
      `${window.location.origin}/players?view=profiles#seed-detail`,
      storage,
    )
    expect(storage.setItem).toHaveBeenCalledWith(
      'dst.gameplay.lastDestination',
      '/players?view=profiles#seed-detail',
    )

    storage.setItem.mockClear()
    rememberGameplayDestination('https://evil.example/map', storage)
    expect(storage.setItem).not.toHaveBeenCalled()
  })

  it('persists a direct gameplay hash and restores it through the Gameplay Admin gateway', async () => {
    window.history.replaceState(null, '', '/players?view=profiles#seed-detail')
    const direct = render(
      <BrowserRouter>
        <GameplayAdminShell activeSection="players">
          <div>Map content</div>
        </GameplayAdminShell>
      </BrowserRouter>,
    )

    await waitFor(() => {
      expect(localStorage.getItem('dst.gameplay.lastDestination')).toBe(
        '/players?view=profiles#seed-detail',
      )
    })
    direct.unmount()
    window.history.replaceState(null, '', '/gameplay')

    render(
      <BrowserRouter>
        <Routes>
          <Route path="/gameplay" element={<GameplayEnvironment />} />
          <Route path="/players" element={<div>Restored players</div>} />
        </Routes>
      </BrowserRouter>,
    )

    expect(await screen.findByText('Restored players')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/players')
    expect(window.location.search).toBe('?view=profiles')
    expect(window.location.hash).toBe('#seed-detail')
  })

  it('keeps the legacy Gameplay Blueprints route working', async () => {
    window.history.replaceState(null, '', '/gameplay?view=blueprints')
    render(
      <BrowserRouter>
        <Routes>
          <Route path="/gameplay" element={<GameplayEnvironment />} />
        </Routes>
      </BrowserRouter>,
    )

    expect(await screen.findByText('Blueprints fixture')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/gameplay')
    expect(window.location.search).toBe('?view=blueprints')
  })

  it('updates the persisted gameplay destination when only the hash changes', async () => {
    window.history.replaceState(null, '', '/players?view=profiles#seed-one')
    render(
      <BrowserRouter>
        <GameplayAdminShell activeSection="players">
          <div>Map content</div>
        </GameplayAdminShell>
      </BrowserRouter>,
    )

    window.location.hash = '#seed-two'
    await waitFor(() => {
      expect(localStorage.getItem('dst.gameplay.lastDestination')).toBe(
        '/players?view=profiles#seed-two',
      )
    })
  })

  it('supports active links and fallback redirects', async () => {
    render(
      <BrowserRouter>
        <NavLink
          to="/settings"
          className={({ isActive }) => isActive ? 'active' : 'inactive'}
        >
          Settings
        </NavLink>
        <Routes>
          <Route path="/settings" element={<div>Settings page</div>} />
          <Route path="*" element={<Navigate to="/settings" replace />} />
        </Routes>
      </BrowserRouter>,
    )

    expect(await screen.findByText('Settings page')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Settings' })).toHaveClass('active')
  })
})
