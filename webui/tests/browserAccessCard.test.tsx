import React from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { api } from '../src/api/client'
import { isLocalViewer } from '../src/util/viewer'
import { BrowserAccessCard } from '../src/pages/settings/BrowserAccessCard'

vi.mock('../src/api/client', () => ({ api: vi.fn() }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: vi.fn() }))
vi.mock('../src/pages/settings/PortalAccountsManager', () => ({ PortalAccountsManager: () => null }))

afterEach(() => { cleanup(); vi.resetAllMocks(); localStorage.clear() })

describe('Remote Access bridge status', () => {
  it('uses the pairing snapshot once and lets a re-check replace a failed snapshot', async () => {
    vi.mocked(isLocalViewer).mockReturnValue(true)
    const bridge = { ready: false, listening: true, issues: ['Health check timed out.'], port: 47900 }
    vi.mocked(api).mockImplementation(async path => {
      if (path === '/api/mobile/pairing') return { token: '', url: 'https://portal.example.ts.net', accountLoginEnabled: true, bridge }
      if (path === '/api/mobile/bridge-status') return { ...bridge, ready: true, issues: [] }
      throw new Error(`Unexpected request: ${path}`)
    })
    render(<BrowserAccessCard />)
    expect(await screen.findByText('Remote access bridge not responding')).toBeInTheDocument()
    expect(api).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Stable public address configured')).toBeInTheDocument()
    expect(screen.queryByText('Reachable at a stable public address')).not.toBeInTheDocument()
    expect(screen.queryByText('Remote access bridge not running')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Re-check' }))
    expect(await screen.findByText('Remote access bridge ready (local port 47900).')).toBeInTheDocument()
    expect(api).toHaveBeenCalledTimes(2)
  })

  it('keeps host bridge diagnostics and repair controls out of remote sessions', async () => {
    vi.mocked(isLocalViewer).mockReturnValue(false)
    vi.mocked(api).mockResolvedValue({
      token: '', url: 'https://portal.example.ts.net', accountLoginEnabled: true,
      bridge: { ready: false, listening: true, issues: ['Health check timed out.'], port: 47900 },
    })
    render(<BrowserAccessCard />)
    expect(await screen.findByText('Stable public address configured')).toBeInTheDocument()
    expect(screen.queryByText('Remote access bridge not responding')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Repair remote bridge' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Re-check' })).not.toBeInTheDocument()
    expect(api).toHaveBeenCalledTimes(1)
  })
})
