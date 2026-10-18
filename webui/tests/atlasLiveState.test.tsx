import React from 'react'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AtlasLiveState } from '../src/pages/workspaces/AtlasLiveState'
const { openAtlasSession } = vi.hoisted(() => ({ openAtlasSession: vi.fn() }))
vi.mock('../src/api/atlas', () => ({ openAtlasSession }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
describe('Atlas Live State hosting', () => {
  it('shows only loading while the service request is pending', () => {
    openAtlasSession.mockReturnValue(new Promise(() => {}))
    render(<AtlasLiveState />)
    expect(screen.getByText('Opening live map…')).toBeInTheDocument()
    expect(screen.queryByTitle('Own-server live atlas')).not.toBeInTheDocument()
  })
  it('uses the authenticated same-origin map for remote DST logins', async () => {
    openAtlasSession.mockResolvedValue({ available: true, url: '/api/v1/maps/atlas/view?t=remote-test' })
    render(<AtlasLiveState />)
    expect(await screen.findByTitle('Own-server live atlas')).toHaveAttribute('src', '/api/v1/maps/atlas/view?t=remote-test&embedded=1')
    expect(screen.queryByText('Opening live map…')).not.toBeInTheDocument()
  })
  it.each([
    { available: false, reasonCode: 'startup-pending' },
    { available: true, url: 'https://example.com/?key=test-session' },
  ])('shows unavailable and retry for an unavailable or unsuitable host', async result => {
    openAtlasSession.mockResolvedValue(result)
    render(<AtlasLiveState />)
    expect(await screen.findByText('Live map unavailable')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
    expect(screen.queryByTitle('Own-server live atlas')).not.toBeInTheDocument()
  })
  it('can retry a failed service request without displaying old data', async () => {
    openAtlasSession.mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce({ available: true, url: '/api/v1/maps/atlas/view' })
    render(<AtlasLiveState />)
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }))
    expect(await screen.findByTitle('Own-server live atlas')).toBeInTheDocument()
    expect(openAtlasSession).toHaveBeenCalledTimes(2)
  })
  it('ignores a session response after leaving the page', async () => {
    let finish!: (value: unknown) => void
    openAtlasSession.mockReturnValue(new Promise(resolve => { finish = resolve }))
    const view = render(<AtlasLiveState />)
    view.unmount()
    await act(async () => { finish({ available: true, url: '/api/v1/maps/atlas/view' }) })
    expect(screen.queryByTitle('Own-server live atlas')).not.toBeInTheDocument()
  })
})
