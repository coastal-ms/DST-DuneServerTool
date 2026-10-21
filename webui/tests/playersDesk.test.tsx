import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlayersTab } from '../src/pages/gameplay/PlayersTab'
import { getPlayers, getPlayerSummary, getPlayerStats, giveSolari, deleteAccount, unlockTestingStations, type Player } from '../src/api/gameplay'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'

vi.mock('../src/pages/gameplay/players/coriolis', () => ({ CoriolisAdmin: () => <div>Existing lifecycle controls</div> }))
vi.mock('../src/pages/gameplay/players/base-water', () => ({ BaseWaterAdmin: () => <div>Existing water controls</div> }))
vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getPlayers: vi.fn(), getPlayerSummary: vi.fn(), getPlayerStats: vi.fn(), giveSolari: vi.fn(), deleteAccount: vi.fn(), unlockTestingStations: vi.fn(),
}))
const players: Player[] = [
  { id: 41, account_id: 51, controller_id: 61, name: 'Aster', class: 'Mentat', map: 'Survival_1', faction_id: 1, faction_name: 'Atreides', online_status: 'Offline' },
  { id: 42, account_id: 52, controller_id: 62, name: 'Beryl', class: 'Trooper', map: 'DeepDesert_1', faction_id: 2, faction_name: 'Harkonnen', online_status: 'Online' },
]
beforeEach(() => {
  localStorage.clear()
  localStorage.setItem(COMMAND_DECK_KEY, '1')
  vi.stubGlobal('matchMedia', () => ({ matches: false, addEventListener() {}, removeEventListener() {} }))
  vi.mocked(getPlayers).mockResolvedValue({ source: 'live', players })
  vi.mocked(getPlayerSummary).mockResolvedValue({ source: 'live', totals: { players: 2, online: 1, factions: 2 }, by_faction: [], by_map: [] })
  vi.mocked(getPlayerStats).mockImplementation(async id => {
    const player = players.find(item => item.id === id)!
    return { source: 'live', stats: {
      pawn_id: player.id, account_id: player.account_id, controller_id: player.controller_id, character_name: player.name,
      class: player.class, map: player.map, online_status: player.online_status, last_seen: '2026-09-01T12:00:00Z',
      faction_id: player.faction_id, faction_name: player.faction_name, solaris: 100, total_currency: 150,
    } }
  })
  vi.mocked(giveSolari).mockResolvedValue({ ok: true, message: 'Solari granted.' })
})
afterEach(() => { cleanup(); vi.clearAllMocks(); vi.restoreAllMocks(); vi.unstubAllGlobals(); localStorage.clear() })

async function openActions() {
  render(<PlayersTab />)
  fireEvent.click(await screen.findByRole('button', { name: 'Inspect Aster (41)' }))
  await screen.findByRole('region', { name: 'Character snapshot' })
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Player sections' })).getByRole('button', { name: 'Actions', exact: true }))
  return screen.getByRole('region', { name: 'Player actions' })
}
function chooseCategory(label: string) {
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Player actions categories' })).getByRole('button', { name: label }))
}
function chooseAction(name: RegExp) {
  fireEvent.click(screen.getByRole('button', { name }))
}
function submitAction(name: string) {
  const buttons = screen.getAllByRole('button', { name, exact: true })
  fireEvent.click(buttons[buttons.length - 1])
}

describe('Contextual Players desk', () => {
  it('offers all six or one Testing Station and targets the selected self-hosted character after confirmation', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    vi.mocked(unlockTestingStations).mockResolvedValue({ok: true, message: 'Unlocked.'})
    await openActions()
    chooseCategory('Progression')
    chooseAction(/^Testing Stations/)
    const choice = screen.getByRole('combobox', {name: 'Station'})
    expect(within(choice).getAllByRole('option')).toHaveLength(7)
    expect(choice).toHaveValue('all')
    fireEvent.change(choice, {target: {value: 'DA_Dgn_136_Fire'}})
    submitAction('Testing Stations')
    await waitFor(() => expect(unlockTestingStations).toHaveBeenCalledExactlyOnceWith(41, 61, 51, 'DA_Dgn_136_Fire'))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Aster'))
  })
  it('keeps directory and dossier distinct, with full section access and explicit filter state', async () => {
    render(<PlayersTab />)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Aster (41)' }))
    expect(await screen.findByRole('region', { name: 'Character snapshot' })).toBeInTheDocument()
    expect(within(screen.getByRole('navigation', { name: 'Player sections' })).getAllByRole('button')).toHaveLength(9)
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search players' }), { target: { value: 'DeepDesert' } })
    expect(screen.queryByRole('button', { name: 'Inspect Aster (41)' })).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Aster', exact: true })).toBeInTheDocument()
    expect(screen.getByText(/outside the current directory filter/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Inspect Beryl (42)' })).toBeInTheDocument()
  })
  it('keeps selecting and searching tasks read-only and preserves open form input while filtering', async () => {
    await openActions()
    expect(screen.getByText(/of \d+ actions/)).toBeInTheDocument()
    chooseCategory('Currency')
    chooseAction(/^Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', { name: 'Amount' }), { target: { value: '123' } })
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search player actions' }), { target: { value: 'does not exist' } })
    expect(screen.getByText('No matching actions.')).toBeInTheDocument()
    expect(giveSolari).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Clear search' }))
    fireEvent.change(screen.getByRole('spinbutton', { name: 'Amount' }), { target: { value: '123' } })
    submitAction('Give Solari')
    await waitFor(() => expect(giveSolari).toHaveBeenCalledExactlyOnceWith(61, 123))
  })
  it('does not carry an open mutation form into a different player', async () => {
    await openActions()
    chooseCategory('Currency')
    chooseAction(/^Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', { name: 'Amount' }), { target: { value: '123' } })
    fireEvent.click(screen.getByRole('button', { name: 'Inspect Beryl (42)' }))
    expect(screen.queryByRole('spinbutton', { name: 'Amount' })).not.toBeInTheDocument()
    chooseCategory('Currency')
    chooseAction(/^Give Solari/)
    expect(screen.getByRole('spinbutton', { name: 'Amount' })).toHaveValue(null)
    expect(giveSolari).not.toHaveBeenCalled()
  })
  it('keeps the selected mobile task and draft while changing directory filters and returning', async () => {
    await openActions()
    chooseCategory('Currency')
    chooseAction(/^Give Solari/)
    const amount = screen.getByRole('spinbutton', { name: 'Amount' })
    fireEvent.change(amount, { target: { value: '123' } })
    fireEvent.click(screen.getByRole('button', { name: 'Change player' }))
    const desk = document.querySelector('.players-desk')!
    expect(desk).toHaveAttribute('data-directory-open', 'true')
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search players' }), { target: { value: 'no such player' } })
    expect(screen.getByText('No players match.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Return to selected player' }))
    expect(desk).toHaveAttribute('data-directory-open', 'false')
    expect(screen.getByRole('spinbutton', { name: 'Amount' })).toBe(amount)
    expect(amount).toHaveValue(123)
    expect(giveSolari).not.toHaveBeenCalled()
  })
  it('retains destructive confirmation and does not dispatch when declined', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    await openActions()
    chooseCategory('Danger')
    chooseAction(/^Delete Account/)
    submitAction('Delete Account (permanent)')
    expect(confirm).toHaveBeenCalledOnce()
    expect(deleteAccount).not.toHaveBeenCalled()
  })
  it('does not expose live actions for demo data or a failed roster refresh', async () => {
    const view = await openActions()
    expect(within(view).getByRole('navigation')).toBeInTheDocument()
    vi.mocked(getPlayers).mockRejectedValueOnce(new Error('Connection unavailable'))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Connection unavailable')
    expect(screen.queryByRole('navigation', { name: 'Player actions categories' })).not.toBeInTheDocument()
    expect(screen.getByText(/Editing is available when the live game database is connected/)).toBeInTheDocument()
    vi.mocked(getPlayers).mockResolvedValue({ source: 'demo', players })
    fireEvent.click(screen.getByRole('button', { name: 'Refresh', exact: true }))
    await waitFor(() => expect(screen.getByText(/Showing sample player data/)).toBeInTheDocument())
    expect(screen.queryByRole('navigation', { name: 'Player actions categories' })).not.toBeInTheDocument()
  })
  it('retains classic action lists outside the new experience', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '0')
    render(<PlayersTab />)
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Aster (41)' }))
    fireEvent.click(within(screen.getByRole('navigation', { name: 'Player sections' })).getByRole('button', { name: 'Actions', exact: true }))
    expect(screen.queryByRole('region', { name: 'Player actions' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Give Solari', exact: true })).toBeInTheDocument()
    await act(async () => {})
  })
})

it('honors a container link when the Players page is already mounted', async () => {
  window.history.replaceState(null, '', '/players')
  render(<PlayersTab />)
  fireEvent.click(await screen.findByRole('button', {name: 'Inspect Aster (41)'}))
  await screen.findByRole('region', {name: 'Character snapshot'})
  act(() => {
    window.history.pushState(null, '', '/players?player_id=42&section=inventory&scope_type=storage&scope_id=50001&location_type=storage&location_id=50001')
    window.dispatchEvent(new PopStateEvent('popstate'))
  })
  await waitFor(() => expect(within(screen.getByRole('navigation', {name: 'Player sections'})).getByRole('button', {name: 'Inventory', exact: true})).toHaveAttribute('aria-pressed', 'true'))
  expect(within(screen.getByRole('region', {name: 'Player dossier'})).getByRole('heading', {name: 'Beryl'})).toBeInTheDocument()
  expect(screen.getByRole('tab', {name: 'Storage containers'})).toHaveClass('btn-primary')
  window.history.replaceState(null, '', '/players')
})
