import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { PortalAccountsManager } from '../../src/pages/settings/PortalAccountsManager'

function jsonResponse(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  sessionStorage.clear()
})

describe('PortalAccountsManager', () => {
  it('creates an owner and displays the generated password once', async () => {
    const empty = { accountLoginEnabled: false, accounts: [], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [{ account_id: 42, name: 'Coastal' }] })
      if (path === '/api/remote-access/portal-accounts' && init?.method === 'POST') {
        return jsonResponse({
          account: { id: 'x', username: 'Coastal', role: 'owner', enabled: true, mustChangePassword: true },
          oneTimePassword: 'generated-password-value',
        }, 201)
      }
      return jsonResponse(empty)
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)

    await user.selectOptions(await screen.findByLabelText('Role'), 'owner')
    await user.selectOptions(screen.getByLabelText('Linked game character (optional)'), '42')
    await user.click(screen.getByRole('button', { name: 'Create account' }))
    expect(await screen.findByText('generated-password-value')).toBeInTheDocument()
    expect(screen.getByText(/cannot be recovered/i)).toBeInTheDocument()
  })

  it('confirms when the one-time password is copied', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      if (path === '/api/remote-access/portal-accounts' && init?.method === 'POST') {
        return jsonResponse({
          account: { id: 'x', username: 'Owner', role: 'owner', enabled: true, mustChangePassword: true },
          oneTimePassword: 'generated-password-value',
        }, 201)
      }
      return jsonResponse({ accountLoginEnabled: false, accounts: [], roles: ['owner', 'admin'] })
    })
    const user = userEvent.setup()
    const writeText = vi.spyOn(navigator.clipboard, 'writeText').mockResolvedValue(undefined)
    render(<PortalAccountsManager />)

    await user.type(await screen.findByLabelText('Username'), 'Owner')
    await user.selectOptions(screen.getByLabelText('Role'), 'owner')
    await user.click(screen.getByRole('button', { name: 'Create account' }))
    await user.click(await screen.findByRole('button', { name: 'Copy' }))

    expect(writeText).toHaveBeenCalledWith('generated-password-value')
    expect(screen.getByRole('button', { name: 'Copied' })).toBeInTheDocument()
    expect(screen.getByText('One-time password copied to the clipboard.')).toBeInTheDocument()
  })

  it('explains the safe enablement step', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      if (String(input) === '/api/gameplay/players') return jsonResponse({ players: [] })
      return jsonResponse({ accountLoginEnabled: false, accounts: [], roles: ['owner', 'admin'] })
    })
    render(<PortalAccountsManager />)
    expect(await screen.findByText('Safe enablement check')).toBeInTheDocument()
    expect(screen.getByText(/paired native mobile apps stop working/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Enable account login' })).toBeDisabled()
  })

  it('sends explicit native retirement acknowledgement when enabling', async () => {
    const requests: Array<{ path: string; init?: RequestInit }> = []
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      requests.push({ path, init })
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      return jsonResponse({
        accountLoginEnabled: path === '/api/remote-access/portal-account-mode',
        nativeAppsBlockedInAccountMode: true,
        accounts: [],
        roles: ['owner', 'admin'],
      })
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)
    const acknowledgement = await screen.findByRole('checkbox')
    await user.click(acknowledgement)
    await user.click(screen.getByRole('button', { name: 'Enable account login' }))
    const request = requests.find(r => r.path === '/api/remote-access/portal-account-mode')
    expect(JSON.parse(String(request?.init?.body))).toEqual({
      enabled: true,
      acknowledgeNativeAppRetirement: true,
    })
  })
})
