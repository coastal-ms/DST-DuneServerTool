import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { PublicIpCard } from '../../src/pages/settings/PublicIpCard'
import { api } from '../../src/api/client'

vi.mock('../../src/api/client', () => ({
  ApiError: class ApiError extends Error {
    body?: unknown
  },
  api: vi.fn(),
  withOnlinePlayerGuard: <T,>(fn: (force: boolean) => Promise<T>) => fn(false),
}))

beforeEach(() => {
  localStorage.clear()
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  vi.mocked(api).mockImplementation(async (path, init) => {
    if (path === '/api/public-ip/status') {
      return {
        mode: 'manual',
        manualPublicIp: '',
        hostRouteEnabled: false,
      }
    }
    if (path === '/api/public-ip/apply/status') {
      return { phase: 'idle', running: false }
    }
    if (path === '/api/public-ip/validate') {
      return { ok: true, publicIp: '203.0.113.10' }
    }
    if (path === '/api/public-ip/apply' && init?.method === 'POST') {
      return { ok: true, publicIp: '203.0.113.10' }
    }
    throw new Error(`Unexpected API call: ${path}`)
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.restoreAllMocks()
})

describe('PublicIpCard host route option', () => {
  it('loads the persisted opt-out and includes it in Apply', async () => {
    const user = userEvent.setup()
    render(<PublicIpCard />)

    const routeToggle = await screen.findByRole('checkbox', { name: /enable same-pc public-ip loopback route/i })
    expect(routeToggle).not.toBeChecked()
    expect(screen.getByText(/wireguard, or vps relay endpoint/i)).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /enter public ip manually/i }))
    await user.type(screen.getByPlaceholderText('8.8.8.8'), '203.0.113.10')
    await user.click(screen.getByRole('button', { name: /validate ip/i }))
    await screen.findByText(/usable public ipv4 address/i)
    await user.click(screen.getByRole('button', { name: /apply public ip/i }))

    await waitFor(() => {
      expect(api).toHaveBeenCalledWith('/api/public-ip/apply', expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          mode: 'manual',
          publicIp: '203.0.113.10',
          hostRouteEnabled: false,
          confirmed: true,
        }),
      }))
    })
  })
})
