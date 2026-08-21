import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { PortalAccountsManager } from '../../src/pages/settings/PortalAccountsManager'

function jsonResponse(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

const owner = {
  id: 'owner-id',
  username: 'Coastal',
  role: 'owner' as const,
  enabled: true,
  mustChangePassword: true,
  locallyVerified: false,
  gameCharacterId: '42',
  gameCharacterLabel: 'Coastal',
  createdAt: '',
  lastLoginAt: '',
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
  sessionStorage.clear()
})

describe('PortalAccountsManager progressive setup', () => {
  it('creates the first Owner without a distracting role choice and advances to the shown-once password', async () => {
    let state = { accountLoginEnabled: false, accounts: [] as typeof owner[], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [{ account_id: 42, name: 'Coastal' }] })
      if (path === '/api/remote-access/portal-accounts' && init?.method === 'POST') {
        state = { ...state, accounts: [owner] }
        return jsonResponse({ account: owner, oneTimePassword: 'generated-password-value' }, 201)
      }
      return jsonResponse(state)
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)

    expect(await screen.findByText('Step 1 — Create the first Owner')).toBeInTheDocument()
    expect(screen.queryByLabelText('Role')).not.toBeInTheDocument()
    await user.selectOptions(screen.getByLabelText('Linked game character (optional)'), '42')
    await user.click(screen.getByRole('button', { name: 'Create first Owner' }))
    expect(await screen.findByText('Step 2 — Store the one-time password')).toBeInTheDocument()
    expect(screen.getByText('generated-password-value')).toBeInTheDocument()
    expect(screen.getByText(/cannot recover/i)).toBeInTheDocument()
  })

  it('confirms OTP copy and advances only when the host says it is stored', async () => {
    let state = { accountLoginEnabled: false, accounts: [] as typeof owner[], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      if (path === '/api/remote-access/portal-accounts' && init?.method === 'POST') {
        state = { ...state, accounts: [owner] }
        return jsonResponse({ account: owner, oneTimePassword: 'generated-password-value' }, 201)
      }
      return jsonResponse(state)
    })
    const writeText = vi.spyOn(navigator.clipboard, 'writeText').mockResolvedValue(undefined)
    const user = userEvent.setup()
    render(<PortalAccountsManager />)
    await user.type(await screen.findByLabelText('Username'), 'Coastal')
    await user.click(screen.getByRole('button', { name: 'Create first Owner' }))
    await user.click(await screen.findByRole('button', { name: 'Copy one-time password' }))
    expect(writeText).toHaveBeenCalledWith('generated-password-value')
    expect(screen.getByText('One-time password copied to the clipboard.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'I stored it — continue' }))
    expect(await screen.findByText('Step 3 — Verify the Owner locally')).toBeInTheDocument()
  })

  it('prefills the Owner and clearly verifies the one-time password only on this host', async () => {
    let state = { accountLoginEnabled: false, accounts: [owner], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      if (path === '/api/remote-access/portal-accounts/verify-owner' && init?.method === 'POST') {
        state = { ...state, accounts: [{ ...owner, locallyVerified: true }] }
        return jsonResponse({ ok: true })
      }
      return jsonResponse(state)
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)
    expect(await screen.findByText('Step 3 — Verify the Owner locally')).toBeInTheDocument()
    expect(screen.getByLabelText('Owner username to verify')).toHaveValue('Coastal')
    expect(screen.getByText(/does not claim that remote access is working/i)).toBeInTheDocument()
    await user.type(screen.getByLabelText('Paste the one-time password'), 'generated-password-value')
    await user.click(screen.getByRole('button', { name: 'Verify Owner password locally' }))
    expect(await screen.findByText('Step 4 — Enable account login')).toBeInTheDocument()
    expect(screen.getAllByText(/verified locally on this host/i).length).toBeGreaterThan(0)
  })

  it('explains the migration and sends the explicit native-app acknowledgement', async () => {
    const requests: Array<{ path: string; init?: RequestInit }> = []
    let state = { accountLoginEnabled: false, accounts: [{ ...owner, locallyVerified: true }], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      requests.push({ path, init })
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      if (path === '/api/remote-access/portal-account-mode') {
        state = { ...state, accountLoginEnabled: true }
        return jsonResponse({ accountLoginEnabled: true })
      }
      return jsonResponse(state)
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)
    expect(await screen.findByText(/QR and link become a stable token-free login URL/i)).toBeInTheDocument()
    expect(screen.getByText(/Disable account login and restore legacy links/i)).toBeInTheDocument()
    const enable = screen.getByRole('button', { name: 'Enable account login' })
    expect(enable).toBeDisabled()
    await user.click(screen.getByRole('checkbox'))
    await user.click(enable)
    const request = requests.find(r => r.path === '/api/remote-access/portal-account-mode')
    expect(JSON.parse(String(request?.init?.body))).toEqual({
      enabled: true,
      acknowledgeNativeAppRetirement: true,
    })
  })

  it('puts emergency Disable first and keeps additional account management after enablement', async () => {
    const state = { accountLoginEnabled: true, accounts: [{ ...owner, locallyVerified: true }], roles: ['owner', 'admin'] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      if (String(input) === '/api/gameplay/players') return jsonResponse({ players: [] })
      return jsonResponse(state)
    })
    render(<PortalAccountsManager />)
    expect(await screen.findByText('Account login Enabled')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Emergency: Disable account login' })).toBeInTheDocument()
    expect(screen.getByText(/stable token-free URL/i)).toBeInTheDocument()
    expect(screen.getByText('Create another account')).toBeInTheDocument()
    expect(screen.getByLabelText('Role')).toBeInTheDocument()
    expect(screen.getAllByText(/Owner and Admin currently have the same portal capabilities/i).length).toBeGreaterThan(0)
  })

  it('uses any verified enabled Owner and does not regress setup when another Owner is reset', async () => {
    const verifiedOwner = {
      ...owner,
      id: 'verified-owner-id',
      username: 'VerifiedOwner',
      locallyVerified: true,
    }
    const state = {
      accountLoginEnabled: false,
      accounts: [owner, verifiedOwner],
      roles: ['owner', 'admin'],
    }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
      const path = String(input)
      if (path === '/api/gameplay/players') return jsonResponse({ players: [] })
      if (path.endsWith('/reset-password') && init?.method === 'POST') {
        return jsonResponse({ ok: true, oneTimePassword: 'reset-password-value' })
      }
      return jsonResponse(state)
    })
    const user = userEvent.setup()
    render(<PortalAccountsManager />)

    expect(await screen.findByText('Step 4 — Enable account login')).toBeInTheDocument()
    expect(screen.getByText(/verified locally on this host: VerifiedOwner/i)).toBeInTheDocument()
    await user.click(screen.getByText('Account management'))
    await user.click(screen.getAllByRole('button', { name: 'Reset password' })[0])
    expect(await screen.findByText('reset-password-value')).toBeInTheDocument()
    expect(screen.getByText('Step 4 — Enable account login')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Enable account login' })).toBeInTheDocument()
  })
})
