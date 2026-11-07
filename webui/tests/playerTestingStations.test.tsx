import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { unlockTestingStations, type Player } from '../src/api/gameplay'
import { ActionsSection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  unlockTestingStations: vi.fn(),
}))
const player: Player = { id: 42, account_id: 99, controller_id: 100, name: 'Fixture player', class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Offline' }
beforeEach(() => {
  vi.mocked(unlockTestingStations).mockResolvedValue({ ok: true, message: 'Unlocked.' })
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.clearAllMocks(); localStorage.clear() })
function show(status='Offline') {
  render(<ActionsSection player={{ ...player, online_status: status }} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} actionIds={['unlock-testing-stations']} initialAction="unlock-testing-stations" />)
}
describe('Self-hosted Testing Station backup recommendation', () => {
  it('offers a backup recommendation and lets the user continue directly', async () => {
    show()
    fireEvent.click(screen.getByRole('button', { name: 'Testing Stations' }))
    await waitFor(() => expect(unlockTestingStations).toHaveBeenCalledWith(42, 100, 99, 'all'))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('A database backup is recommended'))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('or continue now'))
  })
  it('does not unlock when the user cancels the recommendation popup', () => {
    vi.mocked(window.confirm).mockReturnValue(false)
    show()
    fireEvent.click(screen.getByRole('button', { name: 'Testing Stations' }))
    expect(unlockTestingStations).not.toHaveBeenCalled()
  })
})
