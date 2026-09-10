import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { api } from '../../src/api/client'
import { HyperVLifecycleCard } from '../../src/pages/settings/HyperVLifecycleCard'

vi.mock('../../src/api/client', () => ({
  ApiError: class ApiError extends Error {
    body?: unknown
  },
  api: vi.fn(),
}))

const readyStatus = {
  ok: true,
  configured: false,
  ip: '192.168.23.219',
  rollbackStatePresent: false,
  rollbackStateMatches: false,
  rollbackStateError: '',
  host: {
    identity: 'local:test-host',
    vmId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    vmName: 'dune-awakening',
    vmState: 'Running',
    shutdownServiceId: '9f8233ac-be49-4c79-8ee3-e7e1985b2077',
    shutdownEnabled: false,
    automaticStopAction: 'Save',
    compliant: false,
  },
  guest: {
    reachable: true,
    supported: true,
    reason: '',
    hvUtils: true,
    shutdownChannel: true,
    installed: false,
    runlevel: false,
    serviceStarted: false,
  },
}

beforeEach(() => {
  localStorage.clear()
  vi.mocked(api).mockImplementation(async (path, init) => {
    if (path === '/api/setup/hyperv-lifecycle' && !init?.method) return readyStatus
    if (path === '/api/setup/hyperv-lifecycle/reconcile' && init?.method === 'POST') {
      return {
        ...readyStatus,
        configured: true,
        rollbackStatePresent: true,
        rollbackStateMatches: true,
        host: { ...readyStatus.host, shutdownEnabled: true, automaticStopAction: 'ShutDown', compliant: true },
        guest: { ...readyStatus.guest, installed: true, runlevel: true, serviceStarted: true },
      }
    }
    if (path === '/api/setup/hyperv-lifecycle' && init?.method === 'DELETE') return readyStatus
    throw new Error(`Unexpected API call: ${path}`)
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('HyperVLifecycleCard', () => {
  it('loads passively and reconciles only after an explicit operator action', async () => {
    const user = userEvent.setup()
    render(<HyperVLifecycleCard />)

    expect(api).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: /hyper-v vm lifecycle/i }))
    await screen.findByText(/operating system shutdown: disabled/i)
    expect(api).toHaveBeenCalledTimes(1)
    expect(api).toHaveBeenLastCalledWith('/api/setup/hyperv-lifecycle')

    await user.click(screen.getByRole('button', { name: /^reconcile$/i }))
    await screen.findByText(/lifecycle reconciled/i)
    await waitFor(() => {
      expect(api).toHaveBeenCalledWith('/api/setup/hyperv-lifecycle/reconcile', { method: 'POST' })
    })
  })

  it('requires an inline confirmation before uninstalling', async () => {
    vi.mocked(api).mockResolvedValueOnce({
      ...readyStatus,
      configured: true,
      rollbackStatePresent: true,
      rollbackStateMatches: true,
      host: { ...readyStatus.host, shutdownEnabled: true, automaticStopAction: 'ShutDown', compliant: true },
      guest: { ...readyStatus.guest, installed: true, runlevel: true, serviceStarted: true },
    })
    const user = userEvent.setup()
    render(<HyperVLifecycleCard />)

    await user.click(screen.getByRole('button', { name: /hyper-v vm lifecycle/i }))
    const remove = await screen.findByRole('button', { name: /remove lifecycle integration/i })
    await user.click(remove)
    expect(api).toHaveBeenCalledTimes(1)
    await user.click(screen.getByRole('button', { name: /confirm remove/i }))

    await waitFor(() => {
      expect(api).toHaveBeenCalledWith('/api/setup/hyperv-lifecycle', { method: 'DELETE' })
    })
  })
})
