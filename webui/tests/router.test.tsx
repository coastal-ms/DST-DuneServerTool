import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import {
  BrowserRouter,
  Link,
  NavLink,
  Navigate,
  Route,
  Routes,
  useNavigate,
  useLocation,
} from '../src/router'

function LocationProbe() {
  const { pathname } = useLocation()
  return <output>{pathname}</output>
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
