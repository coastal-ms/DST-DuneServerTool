import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { TeleportLocations } from '../src/pages/gameplay/players/TeleportLocations'
import type { Player } from '../src/api/gameplay'
const { request } = vi.hoisted(() => ({ request: vi.fn() }))
vi.mock('../src/api/client', () => ({ api: request }))
const player = { id: 21, account_id: 11, name: 'Own', online_status: 'Online' } as Player
const view = { enabled: true, limit: 5, shared: [{ id: 'host', name: 'Host camp', map: 'HaggaBasin' }], private: [{ id: 'own', name: 'My camp', map: 'HaggaBasin' }], pending: null }
afterEach(cleanup)
beforeEach(() => { request.mockReset(); request.mockResolvedValue(view); vi.spyOn(window, 'confirm').mockReturnValue(true) })
describe('Teleport locations', () => {
  it('loads on demand and separates shared locations from the five private slots', async () => {
    render(<TeleportLocations player={player} canWrite />)
    expect(await screen.findByText('Shared host locations')).toBeTruthy()
    expect(screen.getByText('Private locations (1/5)')).toBeTruthy()
    expect(screen.getByText(/five total across all maps/)).toBeTruthy()
    expect(screen.getAllByRole('button', { name: 'Delete' })).toHaveLength(1)
    expect(request).toHaveBeenCalledTimes(1)
    expect(request).toHaveBeenCalledWith('/api/player-portal/teleports?account_id=11')
  })
  it('arms a capture for the selected account without accepting coordinates', async () => {
    request.mockImplementation(async (_url: string, options?: RequestInit) => options ? { command: '!tp save P-code' } : { ...view, pending: { name: 'New camp', command: '!tp save P-code', expiresAt: '2099-01-01' } })
    render(<TeleportLocations player={player} canWrite />)
    await screen.findByText('Shared host locations')
    fireEvent.change(screen.getByLabelText('Private location name'), { target: { value: 'New camp' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save current location' }))
    await waitFor(() => expect(request).toHaveBeenCalledWith('/api/player-portal/teleports', expect.objectContaining({ method: 'POST', body: JSON.stringify({ action: 'capture', name: 'New camp', account_id: 11 }) })))
    expect(await screen.findByText('!tp save P-code')).toBeTruthy()
  })
  it('dispatches a shared destination by id and scope after confirmation', async () => {
    render(<TeleportLocations player={player} canWrite />)
    await screen.findByText('Shared host locations')
    fireEvent.click(screen.getAllByRole('button', { name: 'Teleport' })[0])
    await waitFor(() => expect(request).toHaveBeenCalledWith('/api/player-portal/teleports', expect.objectContaining({ method: 'POST', body: JSON.stringify({ action: 'teleport', scope: 'shared', id: 'host', account_id: 11 }) })))
  })
  it('requires an online player for save and teleport but allows private deletion offline', async () => {
    render(<TeleportLocations player={{ ...player, online_status: 'Offline' }} canWrite />)
    await screen.findByText('Shared host locations')
    expect(screen.getAllByRole('button', { name: 'Teleport' }).every(button => (button as HTMLButtonElement).disabled)).toBe(true)
    expect((screen.getByRole('button', { name: 'Delete' }) as HTMLButtonElement).disabled).toBe(false)
  })
})
