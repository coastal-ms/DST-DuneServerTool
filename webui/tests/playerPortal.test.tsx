import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import PlayerPortal from '../src/pages/PlayerPortal'
import { getPlayers, getPlayerStats, giveSolari, type Player } from '../src/api/gameplay'
import { getMapState, startMap } from '../src/api/maps'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: true, canAccessOwnerSurfaces: false }) }))
vi.mock('../src/auth/PortalAuthGate', () => ({ usePortalAuth: () => ({ logout: vi.fn() }) }))
vi.mock('../src/pages/WickMaps', () => ({ WickMaps: () => <div>Map atlas</div> }))
vi.mock('../src/pages/workspaces/MapLiveState', () => ({ MapLiveState: () => <div>Cached map</div> }))
vi.mock('../src/hooks/usePlatformCapabilities', () => ({ usePlatformCapabilities: () => ({ hasCapability: () => true }) }))
vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getPlayers: vi.fn(), getPlayerStats: vi.fn(), giveSolari: vi.fn(),
}))
vi.mock('../src/api/maps', async original => ({
  ...await original<typeof import('../src/api/maps')>(), getMapState: vi.fn(), startMap: vi.fn(),
}))
const player: Player = { id: 21, account_id: 11, controller_id: 31, name: 'Own character', class: 'Mentat', map: 'Survival_1', faction_id: 1, faction_name: 'Atreides', online_status: 'Offline' }
beforeEach(() => {
  localStorage.setItem(COMMAND_DECK_KEY, '1')
  vi.mocked(getPlayers).mockResolvedValue({ players: [player], source: 'live' })
  vi.mocked(getPlayerStats).mockResolvedValue({ source: 'live', stats: {
    pawn_id: 21, account_id: 11, controller_id: 31, character_name: player.name,
    class: 'Mentat', map: 'Survival_1', online_status: 'Offline', last_seen: '',
    faction_id: 1, faction_name: 'Atreides', solaris: 10, total_currency: 10,
  } })
  vi.mocked(giveSolari).mockResolvedValue({ ok: true, message: 'Granted to own character.' })
  vi.mocked(startMap).mockResolvedValue({ ok: true, key: 'deepdesert', message: 'Warming map.' })
  vi.mocked(getMapState).mockResolvedValue({ ok: true, running: false } as Awaited<ReturnType<typeof getMapState>>)
  vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ available: true, state: 'running' }), { status: 200 }))
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.clearAllMocks(); localStorage.clear() })

describe('Player portal', () => {
  it('renders own management and status without server commands, world controls or another-player selector', async () => {
    render(<PlayerPortal />)
    expect(await screen.findByText('Server: running')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: /Own character/ })).toBeInTheDocument()
    const sections = screen.getByRole('navigation', { name: 'Character sections' })
    for (const label of ['Overview', 'Items', 'Progression', 'Activity', 'Advanced']) {
      expect(within(sections).getByRole('button', { name: label, exact: true })).toBeInTheDocument()
    }
    expect(screen.queryByRole('button', { name: 'Session controls', exact: true })).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('searchbox', { name: 'Find a player tool' }), {target: {value: 'money'}})
    const results = screen.getByRole('region', {name: 'Player tool search results'})
    fireEvent.click(within(results).getByRole('button', {name: /Give Solari/}))
    const actions = await screen.findByRole('region', {name: 'Player tools'})
    expect(within(actions).queryByText('Cheat Scripts')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Stop Battlegroup|Server commands|Teleport To Player/ })).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('spinbutton', { name: 'Amount' }), { target: { value: '7' } })
    fireEvent.click(within(actions).getAllByRole('button', { name: 'Give Solari', exact: true }).find(button => !button.hasAttribute('aria-expanded'))!)
    await waitFor(() => expect(giveSolari).toHaveBeenCalledWith(31, 7))
  })
  it('allows map viewing and warming without stop or restart controls', async () => {
    render(<PlayerPortal />)
    fireEvent.click(screen.getByRole('button', { name: 'Map', exact: true }))
    expect(screen.getByText('Cached map')).toBeInTheDocument()
    expect(screen.queryByText('Map atlas')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'DD reference map', exact: true }))
    expect(screen.getByText('Map atlas')).toBeInTheDocument()
    expect(screen.queryByText('Cached map')).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByRole('button', { name: 'Warm map', exact: true })[0])
    await waitFor(() => expect(startMap).toHaveBeenCalledWith('deepdesert'))
    expect(screen.queryByRole('button', { name: /stop|restart|fix partitions/i })).not.toBeInTheDocument()
  })
  it('explains an unlinked character rather than leaving a blank character page', async () => {
    vi.mocked(getPlayers).mockResolvedValue({ players: [], source: 'live' })
    render(<PlayerPortal />)
    expect(await screen.findByText('No linked character found')).toBeInTheDocument()
    expect(screen.getByText(/Ask the server host to check the character linked/)).toBeInTheDocument()
  })
  it('offers retry when character loading fails', async () => {
    vi.mocked(getPlayers).mockRejectedValueOnce(new Error('Character link unavailable.'))
    render(<PlayerPortal />)
    expect(await screen.findByText('Could not load your character')).toBeInTheDocument()
    expect(screen.getByText('Character link unavailable.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Retry', exact: true }))
    expect(await screen.findByRole('heading', { name: /Own character/ })).toBeInTheDocument()
  })
})
