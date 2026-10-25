import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { PlayersTab } from '../src/pages/gameplay/PlayersTab'
import { getPlayers, getPlayerSummary, getPlayerStats, giveSolari, deleteAccount, unlockTestingStations, type Player } from '../src/api/gameplay'
import { getPlayerActionTools } from '../src/pages/gameplay/players/sections'
import { playerToolHome } from '../src/pages/gameplay/players/PlayerManagement'
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
      faction_id: player.faction_id, faction_name: player.faction_name, solaris: 100, scrip: 50, total_currency: 150,
    } }
  })
  vi.mocked(giveSolari).mockResolvedValue({ ok: true, message: 'Solari granted.' })
})
afterEach(() => { cleanup(); vi.useRealTimers(); vi.clearAllMocks(); vi.restoreAllMocks(); vi.unstubAllGlobals(); localStorage.clear() })


async function selectPlayer() {
  render(<PlayersTab />)
  fireEvent.click(await screen.findByRole('button', {name: 'Inspect Aster (41)'}))
  await screen.findByRole('region', {name: 'Character snapshot'})
}
async function findTool(query: string, label: RegExp) {
  fireEvent.change(screen.getByRole('searchbox', {name: 'Find a player tool'}), {target: {value: query}})
  fireEvent.click(within(screen.getByRole('region', {name: 'Player tool search results'})).getByRole('button', {name: label}))
  return screen.getByRole('region', {name: 'Player tools'})
}
function submit(name: string) {
  fireEvent.click(within(screen.getByRole('region', {name: 'Player tools'})).getAllByRole('button', {name, exact: true}).find(button => !button.hasAttribute('aria-expanded'))!)
}
describe('Player workspace', () => {
  it('keeps the workspace and current category when selecting another character without reloading the roster', async () => {
    await selectPlayer()
    const workspace=screen.getByRole('region',{name:'Player management'})
    fireEvent.click(screen.getByRole('button',{name:'Items',exact:true}))
    fireEvent.click(screen.getByRole('button',{name:'Appearance',exact:true}))
    const reads=vi.mocked(getPlayers).mock.calls.length
    fireEvent.click(screen.getByRole('button',{name:'Inspect Beryl (42)'}))
    expect(screen.getByRole('region',{name:'Player management'})).toBe(workspace)
    expect(screen.getByRole('button',{name:'Items',exact:true})).toHaveAttribute('aria-pressed','true')
    expect(screen.getByRole('button',{name:'Appearance',exact:true})).toHaveAttribute('aria-pressed','true')
    expect(getPlayers).toHaveBeenCalledTimes(reads)
    expect(new URLSearchParams(window.location.search).get('player_id')).toBe('42')
  })
  it('does not show an old character action result after switching characters', async () => {
    let finish!: (value:{ok:boolean;message:string})=>void
    vi.mocked(giveSolari).mockReturnValue(new Promise(resolve=>{finish=resolve}))
    await selectPlayer(); await findTool('money',/Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton',{name:'Amount'}),{target:{value:'2'}})
    submit('Give Solari')
    fireEvent.click(screen.getByRole('button',{name:'Inspect Beryl (42)'}))
    await act(async()=>finish({ok:true,message:'Old character result'}))
    expect(screen.queryByText('Old character result')).not.toBeInTheDocument()
    expect(screen.queryByRole('spinbutton',{name:'Amount'})).not.toBeInTheDocument()
  })
  it('opens Character Inventory first and places Bank last in Items', async () => {
    await selectPlayer()
    fireEvent.click(screen.getByRole('button',{name:'Items',exact:true}))
    const tabs=within(screen.getByRole('navigation',{name:'Items views'})).getAllByRole('button')
    expect(tabs[0]).toHaveTextContent('Character Inventory')
    expect(tabs[0]).toHaveAttribute('aria-pressed','true')
    expect(tabs.at(-1)).toHaveTextContent('Bank')
    expect(screen.queryByRole('button',{name:'Backpack & bank',exact:true})).not.toBeInTheDocument()
    expect(screen.queryByRole('button',{name:'Item tools & recovery',exact:true})).not.toBeInTheDocument()
  })
  it('shows Scrip separately and opens its adjustment tool', async () => {
    await selectPlayer()
    const label = screen.getByText('Scrip', {exact: true})
    expect(label.parentElement).toHaveTextContent('50')
    fireEvent.click(within(label.parentElement!).getByRole('button', {name:'Adjust'}))
    expect(await screen.findByText('Current Scrip')).toBeInTheDocument()
    expect(screen.getByRole('spinbutton', {name:'Amount'})).toBeInTheDocument()
  })
  it('retains every existing action in the searchable catalog and all-tools view', async () => {
    const tools=getPlayerActionTools(false)
    expect(tools).toHaveLength(55)
    expect(new Set(tools.map(tool=>tool.id)).size).toBe(55)
    expect(tools.every(tool=>['Overview','Items','Progression','Activity','Advanced'].includes(playerToolHome(tool.group,tool.id)))).toBe(true)
    await selectPlayer()
    fireEvent.click(screen.getByRole('button',{name:'Advanced',exact:true}))
    fireEvent.click(screen.getByRole('button',{name:'All tools',exact:true}))
    const management=screen.getByRole('region',{name:'Player management'})
    for(const tool of tools) expect(within(management).getByText(tool.label,{exact:true})).toBeInTheDocument()
    expect(management.querySelectorAll('.player-tool-choice')).toHaveLength(55)
  })

  it('keeps directory selection and filters while using five task homes in either app experience', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '0')
    await selectPlayer()
    expect(within(screen.getByRole('navigation', {name: 'Character sections'})).getAllByRole('button')).toHaveLength(5)
    fireEvent.change(screen.getByRole('searchbox', {name: 'Search players'}), {target: {value: 'DeepDesert'}})
    expect(screen.queryByRole('button', {name: 'Inspect Aster (41)'})).not.toBeInTheDocument()
    expect(screen.getByRole('heading', {name: 'Aster', exact: true})).toBeInTheDocument()
    expect(screen.getByText(/outside the current directory filter/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', {name: 'Items', exact: true}))
    expect(screen.getByRole('button', {name: 'Inspect Beryl (42)'})).toBeInTheDocument()
  })
  it('searches across task homes and preserves the open draft while searching', async () => {
    await selectPlayer()
    await findTool('money', /Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', {name: 'Amount'}), {target: {value: '123'}})
    fireEvent.change(screen.getByRole('searchbox', {name: 'Find a player tool'}), {target: {value: 'zzzz-no-such-tool'}})
    expect(screen.getByText('No matching tools.')).toBeInTheDocument()
    fireEvent.change(screen.getByRole('searchbox', {name: 'Find a player tool'}), {target: {value: ''}})
    expect(screen.getByRole('spinbutton', {name: 'Amount'})).toHaveValue(123)
    expect(giveSolari).not.toHaveBeenCalled()
    submit('Give Solari')
    await waitFor(() => expect(giveSolari).toHaveBeenCalledExactlyOnceWith(61,123))
  })
  it('shows pending and completion feedback beside the current task', async () => {
    let finish!: (value: {ok: boolean;message: string}) => void
    vi.mocked(giveSolari).mockReturnValue(new Promise(resolve => { finish=resolve }))
    await selectPlayer(); await findTool('money', /Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', {name: 'Amount'}), {target: {value: '2'}})
    submit('Give Solari')
    expect(screen.getByText('Give Solari…')).toBeInTheDocument()
    vi.useFakeTimers()
    await act(async () => finish({ok:true,message:'Solari granted.'}))
    expect(screen.getByText('Solari granted.')).toBeInTheDocument()
    expect(screen.getByRole('button',{name:'Dismiss action result'})).toBeInTheDocument()
    act(() => vi.advanceTimersByTime(5000))
    expect(screen.queryByText('Solari granted.')).not.toBeInTheDocument()
  })
  it('keeps failed action feedback until dismissed', async () => {
    let fail!: (reason: Error) => void
    vi.mocked(giveSolari).mockReturnValue(new Promise((_resolve,reject) => {fail=reject}))
    await selectPlayer(); await findTool('money', /Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', {name:'Amount'}), {target:{value:'2'}})
    submit('Give Solari')
    vi.useFakeTimers()
    await act(async () => fail(new Error('Unable to adjust currency.')))
    act(() => vi.advanceTimersByTime(10000))
    expect(screen.getByText('Unable to adjust currency.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button',{name:'Dismiss action result'}))
    expect(screen.queryByText('Unable to adjust currency.')).not.toBeInTheDocument()
  })
  it('does not carry mutation input into another player', async () => {
    await selectPlayer(); await findTool('money', /Give Solari/)
    fireEvent.change(screen.getByRole('spinbutton', {name: 'Amount'}), {target: {value: '123'}})
    fireEvent.click(screen.getByRole('button', {name: 'Inspect Beryl (42)'}))
    expect(screen.queryByRole('spinbutton', {name: 'Amount'})).not.toBeInTheDocument()
    await findTool('money', /Give Solari/)
    expect(screen.getByRole('spinbutton', {name: 'Amount'})).toHaveValue(null)
    expect(giveSolari).not.toHaveBeenCalled()
  })
  it('preserves Testing Station choices, selected player and confirmation', async () => {
    vi.spyOn(window,'confirm').mockReturnValue(true)
    vi.mocked(unlockTestingStations).mockResolvedValue({ok:true,message:'Unlocked.'})
    await selectPlayer(); await findTool('Testing Stations', /Testing Stations/)
    const station=screen.getByRole('combobox',{name:'Station'})
    expect(within(station).getAllByRole('option')).toHaveLength(7)
    fireEvent.change(station,{target:{value:'DA_Dgn_136_Fire'}})
    submit('Testing Stations')
    await waitFor(()=>expect(unlockTestingStations).toHaveBeenCalledExactlyOnceWith(41,61,51,'DA_Dgn_136_Fire'))
    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Aster'))
  })
  it('retains both destructive confirmations and makes cancelled deletion inert', async () => {
    vi.spyOn(window,'confirm').mockReturnValue(false)
    vi.spyOn(window,'prompt').mockReturnValue('')
    await selectPlayer(); await findTool('Delete Account', /Delete Account/)
    submit('Delete Account (permanent)')
    expect(window.confirm).toHaveBeenCalled()
    expect(window.prompt).not.toHaveBeenCalled()
    expect(deleteAccount).not.toHaveBeenCalled()
  })
  it('prevents mutations after a failed roster refresh', async () => {
    await selectPlayer(); await findTool('money', /Give Solari/)
    vi.mocked(getPlayers).mockRejectedValueOnce(new Error('Connection unavailable'))
    fireEvent.click(screen.getByRole('button',{name:'Refresh',exact:true}))
    expect(await screen.findByRole('alert')).toHaveTextContent('Connection unavailable')
    expect(screen.getByText(/Editing is available when the live game database is connected/)).toBeInTheDocument()
    expect(screen.queryByRole('spinbutton',{name:'Amount'})).not.toBeInTheDocument()
  })
  it('honors an existing storage deep link and lets the user leave that scope', async () => {
    window.history.replaceState(null,'','/players')
    await selectPlayer()
    act(()=>{window.history.pushState(null,'','/players?player_id=42&section=inventory&scope_type=storage&scope_id=50001&location_type=storage&location_id=50001');window.dispatchEvent(new PopStateEvent('popstate'))})
    await waitFor(()=>expect(screen.getByRole('button',{name:'Storage containers',exact:true})).toHaveAttribute('aria-pressed','true'))
    expect(screen.getByRole('heading',{name:'Beryl',exact:true})).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button',{name:'Character Inventory',exact:true}))
    expect(window.location.search).not.toContain('scope_type')
    expect(screen.getByRole('button',{name:'Character Inventory',exact:true})).toHaveAttribute('aria-pressed','true')
    window.history.replaceState(null,'','/players')
  })
})
