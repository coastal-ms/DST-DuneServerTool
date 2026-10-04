import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getCosmeticsCatalog, getPlayerOwnedCosmetics, grantBuildingSets, grantHouseSwatches, type Player } from '../src/api/gameplay'
import { ManagePlayerSection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: true }) }))
vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getCosmeticsCatalog: vi.fn(), getPlayerOwnedCosmetics: vi.fn(), grantBuildingSets: vi.fn(), grantHouseSwatches: vi.fn(),
}))
const player: Player = { id: 42, account_id: 99, controller_id: 100, name: 'Own character', class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Online' }
beforeEach(() => {
  vi.mocked(getCosmeticsCatalog).mockResolvedValue([
    { template: 'OwnedSet', name: 'Owned', group: 'Building Sets - Faction', bulk_building_set: true },
    { template: 'MissingSet', name: 'Missing', group: 'Building Sets - Decor', bulk_building_set: true },
    { template: 'Fabricator_Patent', name: 'Fabricator', group: 'Building Sets - Crafting', bulk_building_set: false },
    { template: 'Ecaz_Placeables_Swatch', name: 'House Ecaz Placeables Swatch', group: 'Swatches (Dyes)' },
  ])
  vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['ownedset'], total: 1, source: 'live' })
  vi.mocked(grantBuildingSets).mockResolvedValue({ ok: true, message: 'Token batch sent.' })
  vi.mocked(grantHouseSwatches).mockResolvedValue({ ok: true, message: 'Swatch tokens sent.' })
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); vi.clearAllMocks(); localStorage.clear() })
async function open(status = 'Online', label = 'All Building Sets') {
  render(<ManagePlayerSection player={{ ...player, online_status: status }} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }))
  return screen.findByRole('button', { name: /Deliver 1 missing/ })
}
describe('All Building Sets', () => {
  it('offers own-character bulk grant, excludes crafting and skips owned sets', async () => {
    const button = await open()
    expect(screen.getByText('1/2 detected')).toBeInTheDocument()
    expect(screen.getByText(/Crafting stations.*excluded/)).toBeInTheDocument()
    expect(screen.getByText(/Some sets may not unlock because of Funcom/)).toBeInTheDocument()
    fireEvent.click(button)
    await waitFor(() => expect(grantBuildingSets).toHaveBeenCalledExactlyOnceWith(42, 99))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('1 missing Building Set token'))
    expect(await screen.findByRole('button', { name: /Activation cascade running/ })).toBeDisabled()
    expect(grantHouseSwatches).not.toHaveBeenCalled()
  })
  it.each(['Offline', 'LoggingOut', 'Unknown'])('blocks delivery when %s', async status => {
    expect(await open(status)).toBeDisabled()
    expect(grantBuildingSets).not.toHaveBeenCalled()
  })
  it('sends nothing when the user cancels confirmation', async () => {
    vi.mocked(window.confirm).mockReturnValue(false)
    fireEvent.click(await open())
    expect(grantBuildingSets).not.toHaveBeenCalled()
  })
  it('stops claiming activation is running when remaining unlocks cannot be confirmed', async () => {
    const button = await open()
    vi.useFakeTimers()
    vi.spyOn(Date, 'now').mockReturnValue(0)
    await act(async () => { fireEvent.click(button) })
    vi.mocked(Date.now).mockReturnValue(120001)
    await act(async () => { await vi.advanceTimersByTimeAsync(2000) })
    expect(screen.getByText(/Some building sets remain unconfirmed/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Activation cascade running/ })).not.toBeInTheDocument()
    expect(grantBuildingSets).toHaveBeenCalledTimes(1)
  })
  it('retains the existing House Swatch endpoint and catalog filter', async () => {
    fireEvent.click(await open('Online', 'All House Swatches'))
    await waitFor(() => expect(grantHouseSwatches).toHaveBeenCalledExactlyOnceWith(42, 99, 'all'))
    expect(grantBuildingSets).not.toHaveBeenCalled()
  })
})
