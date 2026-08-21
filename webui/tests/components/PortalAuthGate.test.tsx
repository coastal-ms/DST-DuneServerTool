import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { PortalAuthGate } from '../../src/auth/PortalAuthGate'

function jsonResponse(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  }))
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  sessionStorage.clear()
})

describe('PortalAuthGate', () => {
  it('shows incumbent-themed login and returns to the requested portal content', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => jsonResponse({
        accountLoginEnabled: true, authenticated: false, mustChangePassword: false, account: null,
      }))
      .mockImplementationOnce(() => jsonResponse({
        accountLoginEnabled: true,
        authenticated: true,
        mustChangePassword: false,
        account: { id: 'a', username: 'hawk', role: 'admin', enabled: true },
      }))
    const user = userEvent.setup()
    render(<PortalAuthGate><div>Existing dashboard</div></PortalAuthGate>)

    expect(await screen.findByRole('heading', { name: 'Dune Server Tool' })).toBeInTheDocument()
    await user.type(screen.getByLabelText('Username'), 'hawk')
    await user.type(screen.getByLabelText('Password'), 'one time password')
    await user.click(screen.getByRole('button', { name: 'Sign in' }))

    expect(await screen.findByText('Existing dashboard')).toBeInTheDocument()
    expect(fetchMock.mock.calls[1][0]).toBe('/api/portal-auth/login')
  })

  it('forces a password change and surfaces validation errors', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => jsonResponse({
        accountLoginEnabled: true,
        authenticated: true,
        mustChangePassword: true,
        account: { id: 'a', username: 'owner', role: 'owner', enabled: true },
      }))
    const user = userEvent.setup()
    render(<PortalAuthGate><div>Existing dashboard</div></PortalAuthGate>)

    expect(await screen.findByRole('heading', { name: 'Change your password' })).toBeInTheDocument()
    await user.type(screen.getByLabelText('One-time password'), 'temporary password')
    await user.type(screen.getByLabelText('New password'), 'long new password')
    await user.type(screen.getByLabelText('Confirm new password'), 'different password')
    await user.click(screen.getByRole('button', { name: 'Change password' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('do not match')
  })

  it('keeps legacy portal content unchanged while account mode is disabled', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementationOnce(() => jsonResponse({
      accountLoginEnabled: false, authenticated: false, mustChangePassword: false, account: null,
    }))
    render(<PortalAuthGate><div>Existing dashboard</div></PortalAuthGate>)
    await waitFor(() => expect(screen.getByText('Existing dashboard')).toBeInTheDocument())
    expect(screen.queryByLabelText('Username')).not.toBeInTheDocument()
  })
})
