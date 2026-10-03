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
    for (const label of ['Manage Player', 'Inventory', 'Specs', 'Tags', 'History', 'Journey', 'Actions']) {
      expect(within(sections).getByRole('button', { name: label, exact: true })).toBeInTheDocument()
    }
    fireEvent.click(within(sections).getByRole('button', { name: 'Actions', exact: true }))
    const actions = await screen.findByRole('region', { name: 'Player actions' })
    expect(within(actions).queryByText('Cheat Scripts')).not.toBeInTheDocument()
    expect(within(actions).queryByText('Spawn Vehicle')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Stop Battlegroup|Server commands|Teleport To Player/ })).not.toBeInTheDocument()
    fireEvent.click(within(screen.getByRole('navigation', { name: 'Player actions categories' })).getByRole('button', { name: /Currency/ }))
    fireEvent.click(within(actions).getByRole('button', { name: /^Give Solari/ }))
    fireEvent.change(screen.getByRole('spinbutton', { name: 'Amount' }), { target: { value: '7' } })
    fireEvent.click(within(actions).getAllByRole('button', { name: 'Give Solari', exact: true }).find(button => !button.hasAttribute('aria-expanded'))!)
    await waitFor(() => expect(giveSolari).toHaveBeenCalledWith(31, 7))
  })
  it('allows map viewing and warming without stop or restart controls', async () => {
    render(<PlayerPortal />)
    fireEvent.click(screen.getByRole('button', { name: 'Map', exact: true }))
    expect(screen.getByText('Map atlas')).toBeInTheDocument()
    expect(screen.getByText('Cached map')).toBeInTheDocument()
    fireEvent.click(screen.getAllByRole('button', { name: 'Warm map', exact: true })[0])
    await waitFor(() => expect(startMap).toHaveBeenCalledWith('deepdesert'))
    expect(screen.queryByRole('button', { name: /stop|restart|fix partitions/i })).not.toBeInTheDocument()
  })
})
