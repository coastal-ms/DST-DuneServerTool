import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getCosmeticsCatalog, getPlayerOwnedCosmetics, grantBuildingSets, grantHouseSwatches, grantSkins, getSkinCosmetics, type Player } from '../src/api/gameplay'
import { ManagePlayerSection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: true }) }))
vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getCosmeticsCatalog: vi.fn(), getPlayerOwnedCosmetics: vi.fn(), grantBuildingSets: vi.fn(), grantHouseSwatches: vi.fn(), grantSkins: vi.fn(),
}))
const player: Player = { id: 42, account_id: 99, controller_id: 100, name: 'Own character', class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Online' }
const actionFlash = vi.fn()
beforeEach(() => {
  vi.mocked(getCosmeticsCatalog).mockResolvedValue([
    { template: 'OwnedSet', name: 'Owned', group: 'Building Sets - Faction', bulk_building_set: true },
    { template: 'MissingSet', name: 'Missing', group: 'Building Sets - Decor', bulk_building_set: true },
    { template: 'Fabricator_Patent', name: 'Fabricator', group: 'Building Sets - Crafting', bulk_building_set: false },
    { template: 'ArmorSkin', name: 'Armor Skin', group: 'Armor & Suit Sets' },
    { template: 'WeaponSkin', name: 'Weapon Skin', group: 'Weapon Skins' },
    { template: 'VehicleSkin', name: 'Vehicle Skin', group: 'Vehicle Skins' },
    { template: 'Ecaz_Placeables_Swatch', name: 'House Ecaz Placeables Swatch', group: 'Swatches (Dyes)' },
    { template: 'PlainDye', name: 'Desert Red Swatch', group: 'Swatches (Dyes)' },
  ])
  vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['ownedset'], unlocked: ['ownedset'], pending: [], total: 1, source: 'live' })
  vi.mocked(grantSkins).mockResolvedValue({ ok: true, message: 'Skin batch sent.' })
  vi.mocked(grantBuildingSets).mockResolvedValue({ ok: true, message: 'Token batch sent.' })
  vi.mocked(grantHouseSwatches).mockResolvedValue({ ok: true, message: 'Swatch tokens sent.' })
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.useRealTimers(); vi.restoreAllMocks(); vi.clearAllMocks(); localStorage.clear() })
async function open(status = 'Online', label = 'All Building Sets') {
  render(<ManagePlayerSection player={{ ...player, online_status: status }} canWrite demo={false} refreshKey={0} flash={actionFlash} onChanged={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }))
  return screen.findByRole('button', { name: /Deliver 1 missing/ })
}
describe('All Building Sets', () => {
  it('offers own-character bulk grant, excludes crafting and skips owned sets', async () => {
    const button = await open()
    expect(screen.getByText('1/2 unlocked · 0 held tokens')).toBeInTheDocument()
    expect(screen.getByText(/Crafting stations.*excluded/)).toBeInTheDocument()
    expect(screen.getByText(/Some sets may not unlock because of Funcom/)).toBeInTheDocument()
    fireEvent.click(button)
    await waitFor(() => expect(grantBuildingSets).toHaveBeenCalledExactlyOnceWith(42, 99))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('1 missing Building Set token'))
    expect(await screen.findByRole('button', { name: /No new Building Sets tokens to request/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Refresh unlock status' })).toBeEnabled()
    expect(actionFlash).toHaveBeenCalledWith('Token batch sent.', 'info')
    expect(screen.queryByRole('button', { name: /Checking unlocks|remain online/ })).not.toBeInTheDocument()
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
    expect(screen.queryByRole('button', { name: /Grant requests submitted/ })).not.toBeInTheDocument()
    expect(grantBuildingSets).toHaveBeenCalledTimes(1)
  })
  it('retains the existing House Swatch endpoint and catalog filter', async () => {
    fireEvent.click(await open('Online', 'All House Swatches'))
    await waitFor(() => expect(grantHouseSwatches).toHaveBeenCalledExactlyOnceWith(42, 99, 'all'))
    expect(grantBuildingSets).not.toHaveBeenCalled()
  })
})

describe.each(['armor', 'weapon'] as const)('All %s Skins', kind => {
  const label = kind === 'armor' ? 'All Armor Skins' : 'All Weapon Skins'
  it('submits only the chosen skin category and shows the limitation', async () => {
    const button = await open('Online', label)
    expect(screen.getByText(/Some entries may not unlock because of Funcom/)).toBeInTheDocument()
    const catalog = await getCosmeticsCatalog()
    expect(getSkinCosmetics(catalog, kind).map(entry => entry.template)).toEqual([kind === 'armor' ? 'ArmorSkin' : 'WeaponSkin'])
    fireEvent.click(button)
    await waitFor(() => expect(grantSkins).toHaveBeenCalledExactlyOnceWith(42, 99, kind))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Some skins may not unlock'))
    expect(grantBuildingSets).not.toHaveBeenCalled()
    expect(grantHouseSwatches).not.toHaveBeenCalled()
  })
  it('blocks offline grants', async () => {
    expect(await open('Offline', label)).toBeDisabled()
    expect(grantSkins).not.toHaveBeenCalled()
  })
  it('skips learned skins and pending tokens', async () => {
    vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['ARMORSKIN', 'weaponskin'], total: 2, source: 'live' })
    render(<ManagePlayerSection player={player} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }))
    expect(await screen.findByRole('button', { name: /No new .* Skins tokens to request/ })).toBeDisabled()
    expect(grantSkins).not.toHaveBeenCalled()
  })
})

describe.each([
  { kind: 'vehicle' as const, label: 'All Vehicle Skins', tokens: ['VehicleSkin'] },
  { kind: 'dyes' as const, label: 'All Dyes', tokens: ['PlainDye', 'Ecaz_Placeables_Swatch'] },
])('$label', ({ kind, label, tokens }) => {
  it('uses the same own-character action and submits a neutral request notice', async () => {
    render(<ManagePlayerSection player={player} canWrite demo={false} refreshKey={0} flash={actionFlash} onChanged={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }))
    const button = await screen.findByRole('button', { name: new RegExp(`Deliver ${tokens.length} missing`) })
    const catalog = await getCosmeticsCatalog()
    expect(getSkinCosmetics(catalog, kind).map(e => e.template).sort()).toEqual([...tokens].sort())
    fireEvent.click(button)
    await waitFor(() => expect(grantSkins).toHaveBeenCalledExactlyOnceWith(42, 99, kind))
    expect(actionFlash).toHaveBeenCalledWith('Skin batch sent.', 'info')
    expect(screen.getByRole('button', { name: 'Refresh unlock status' })).toBeEnabled()
    expect(grantBuildingSets).not.toHaveBeenCalled()
    expect(grantHouseSwatches).not.toHaveBeenCalled()
  })
  it('skips saved unlocks and held tokens', async () => {
    vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: tokens, unlocked: [], pending: tokens, total: tokens.length, source: 'live' })
    render(<ManagePlayerSection player={player} canWrite demo={false} refreshKey={0} flash={actionFlash} onChanged={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: new RegExp(label) }))
    expect(await screen.findByRole('button', { name: /No new .* tokens to request/ })).toBeDisabled()
    expect(grantSkins).not.toHaveBeenCalled()
  })
})

it('does not call held armor tokens unlocked or send duplicates', async () => {
  vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['ArmorSkin'], unlocked: [], pending: ['ArmorSkin'], total: 1, source: 'live' })
  render(<ManagePlayerSection player={player} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: /All Armor Skins/ }))
  expect(await screen.findByText('0/1 unlocked · 1 held tokens')).toBeInTheDocument()
  expect(screen.getByText('Token held — unlock unconfirmed')).toBeInTheDocument()
  expect(screen.getByRole('button', { name: /No new Armor Skins tokens to request/ })).toBeDisabled()
  expect(grantSkins).not.toHaveBeenCalled()
})

it('finds the unlocked Muad’Dib terrarium using plain apostrophe spelling', async () => {
  vi.mocked(getCosmeticsCatalog).mockResolvedValue([{ template: 'MTX_Neut_MuadDibCage_Patent', name: 'Terrarium of Muad’dib', group: 'Building Sets - Decor', bulk_building_set: true }])
  vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['MTX_Neut_MuadDibCage_Patent'], unlocked: ['MTX_Neut_MuadDibCage_Patent'], pending: [], total: 1, source: 'live' })
  render(<ManagePlayerSection player={player} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
  fireEvent.click(screen.getByRole('button', { name: /All Building Sets/ }))
  const search = await screen.findByRole('textbox', { name: 'Search unlock catalog' })
  fireEvent.change(search, { target: { value: "Muad'dib" } })
  expect(screen.getByText('Terrarium of Muad’dib')).toBeInTheDocument()
  expect(screen.getByText('Unlocked on character')).toBeInTheDocument()
})

it('shows held unusable tokens while excluding them from the request', async () => {
  vi.mocked(getCosmeticsCatalog).mockResolvedValue([
    { template: 'UsableSkin', name: 'Usable Skin', group: 'Armor & Suit Sets' },
    { template: 'UnusableSkin', name: 'Unusable Skin', group: 'Armor & Suit Sets', bulk_exclusion: 'No working research action' },
  ])
  vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({ account_id: 99, owned: ['UnusableSkin'], unlocked: [], pending: ['UnusableSkin'], total: 1, source: 'live' })
  const button = await open('Online', 'All Armor Skins')
  expect(screen.getByText('0/1 unlocked · 1 held tokens')).toBeInTheDocument()
  expect(screen.getByText(/No working research action/)).toBeInTheDocument()
  fireEvent.click(button)
  await waitFor(() => expect(grantSkins).toHaveBeenCalledExactlyOnceWith(42, 99, 'armor'))
})

it('stops verification and aborts a hung ownership request without granting again', async () => {
  const button = await open()
  vi.useFakeTimers()
  await act(async () => { fireEvent.click(button) })
  vi.mocked(getPlayerOwnedCosmetics).mockImplementation(() => new Promise(() => {}))
  await act(async () => { await vi.advanceTimersByTimeAsync(500) })
  const signal = vi.mocked(getPlayerOwnedCosmetics).mock.calls.at(-1)?.[1]
  expect(signal?.aborted).toBe(false)
  await act(async () => { await vi.advanceTimersByTimeAsync(9500) })
  expect(signal?.aborted).toBe(true)
  expect(screen.getByText(/Some unlocks remain unconfirmed/)).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: /Grant requests submitted/ })).not.toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Refresh unlock status' })).toBeEnabled()
  expect(grantBuildingSets).toHaveBeenCalledTimes(1)
})
