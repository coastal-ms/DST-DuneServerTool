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
    const loginForm = document.querySelector<HTMLFormElement>('#portal-login-form')
    expect(loginForm).toHaveAttribute('name', 'portal-login')
    expect(loginForm).toHaveAttribute('autocomplete', 'on')
    const usernameInput = screen.getByLabelText('Username')
    expect(usernameInput).toHaveAttribute('name', 'username')
    expect(usernameInput).toHaveAttribute('autocomplete', 'username')
    expect(usernameInput).toHaveAttribute('inputmode', 'text')
    expect(usernameInput).toHaveAttribute('autocapitalize', 'none')
    expect(usernameInput).toHaveAttribute('spellcheck', 'false')
    const passwordInput = screen.getByLabelText('Password')
    expect(passwordInput).toHaveAttribute('name', 'password')
    expect(passwordInput).toHaveAttribute('autocomplete', 'current-password')
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
    const changeForm = document.querySelector<HTMLFormElement>('#portal-password-change-form')
    expect(changeForm).toHaveAttribute('name', 'portal-password-change')
    const usernameContext = document.querySelector<HTMLInputElement>('#portal-password-change-username')
    expect(usernameContext).toHaveAttribute('name', 'username')
    expect(usernameContext).toHaveAttribute('autocomplete', 'username')
    expect(usernameContext).toHaveValue('owner')
    expect(screen.getByLabelText('One-time password')).toHaveAttribute('name', 'current-password')
    expect(screen.getByLabelText('One-time password')).toHaveAttribute('autocomplete', 'current-password')
    expect(screen.getByLabelText('New password')).toHaveAttribute('name', 'new-password')
    expect(screen.getByLabelText('New password')).toHaveAttribute('autocomplete', 'new-password')
    expect(screen.getByLabelText('Confirm new password')).toHaveAttribute('autocomplete', 'new-password')
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
