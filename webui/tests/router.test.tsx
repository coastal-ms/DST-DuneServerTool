import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { LEGACY_REMOTE_MAP_DESTINATION } from '../src/platform/routes'
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
