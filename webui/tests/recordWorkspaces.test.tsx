import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { BasesTab } from '../src/pages/gameplay/BasesTab'
import { MarketTab } from '../src/pages/gameplay/MarketTab'
import VehiclesWorkspace from '../src/pages/workspaces/VehiclesWorkspace'
import {
  getBases, getMarketItems, getMarketStats, getMarketCategories, getMarketListings, getMarketSales,
  getInventoryPlayers, getVehicleFleet, getVehicleIntegrity, repairVehicle, saveVehicleNames, deleteVehicles, destroyClaim,
} from '../src/api/gameplay'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'
import { isLocalViewer } from '../src/util/viewer'
vi.mock('../src/util/viewer', () => ({ isLocalViewer: vi.fn(() => true) }))

vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({ status: { bg: { state: 'running' } } }) }))
vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getBases: vi.fn(), getMarketItems: vi.fn(), getMarketStats: vi.fn(), getMarketCategories: vi.fn(), getMarketListings: vi.fn(), getMarketSales: vi.fn(),
  getInventoryPlayers: vi.fn(), getVehicleFleet: vi.fn(), getVehicleIntegrity: vi.fn(), repairVehicle: vi.fn(), saveVehicleNames: vi.fn(), deleteVehicles: vi.fn(), destroyClaim: vi.fn(),
}))
async function renderFleet() {
  const view = render(<VehiclesWorkspace />)
  await screen.findByRole('option', { name: 'Aster' })
  await userEvent.setup().selectOptions(screen.getByRole('combobox', { name: 'Fleet player' }), '20001')
  return view
}
beforeEach(() => {
  vi.mocked(getInventoryPlayers).mockResolvedValue({ players: [{ id: 20001, name: 'Aster' }] })
  vi.mocked(isLocalViewer).mockReturnValue(true)
  localStorage.setItem(COMMAND_DECK_KEY, '1')
  vi.mocked(getBases).mockResolvedValue({ source: 'live', bases: [{ id: 1, name: 'North base', owner: 'Aster', pieces: 40, placeables: 12, totemId: 11 }] })
  vi.mocked(getMarketItems).mockResolvedValue({ source: 'live', total: 1, page: 0, limit: 50, items: [{
    template_id: 'TestItem', quality: 0, display_name: 'Test item', category: 'items/resources', tier: 1, rarity: 'common', lowest_price: 25, total_stock: 10, bot_stock: 0, listing_count: 1, icon: '',
  }] })
  vi.mocked(getMarketStats).mockResolvedValue({ source: 'live', stats: { total_listings: 1, bot_listings: 0, player_listings: 1, total_stock: 10, bot_stock: 0, player_stock: 10, unique_items: 1 } })
  vi.mocked(getMarketCategories).mockResolvedValue({ categories: ['items/resources'] })
  vi.mocked(getMarketListings).mockResolvedValue({ source: 'live', listings: [] })
  vi.mocked(getMarketSales).mockResolvedValue({ source: 'live', sales: [] })
  vi.mocked(getVehicleFleet).mockResolvedValue({ source: 'live', total: 1, observed_at: new Date().toISOString(), stale_after_seconds: 20, database_scope: 'a'.repeat(64), vehicles: [{ id: 7, class: 'Buggy', subtype: 'Buggy', vehicle_name: 'Scout', owners: 'Aster', map: 'Survival_1', actor_state: 'Active', target_revision: 'b'.repeat(32), cargo_hold_count: 1, cargo_stack_count: 2, module_count: 4, permissions: [{ player_id: '11', rank: 1, character_name: 'Aster', online_status: 'Offline', player_state_count: 1 }, { player_id: '12', rank: 2, character_name: 'Chani', online_status: 'Offline', player_state_count: 1 }] }] })
  vi.mocked(getVehicleIntegrity).mockResolvedValue({ source: 'live', observed_at: new Date().toISOString(), modules: [{ id: '8', template_id: 'Chassis', current_durability: null, max_durability: 100, decayed_max_durability: 80, repair_max_durability: 100 }] })
  vi.mocked(repairVehicle).mockResolvedValue({ ok: true, message: 'Repaired 4 vehicle modules.' })
  vi.mocked(saveVehicleNames).mockResolvedValue({ ok: true, renamed: 1, restart_started: true, message: 'Saved 1 vehicle name change and launched the battlegroup restart.' })
  vi.mocked(deleteVehicles).mockResolvedValue({ ok: true, message: 'Vehicle deleted.', processed: 1, failed: 0 })
})
afterEach(() => { cleanup(); localStorage.clear(); vi.clearAllMocks(); vi.restoreAllMocks(); window.history.replaceState({}, '', '/') })

describe('Record-focused gameplay workspaces', () => {
  it('opens a keyboard-operable base dossier without weakening the stopped-battlegroup release guard', async () => {
    const user = userEvent.setup()
    render(<BasesTab />)
    const inspect = await screen.findByRole('button', { name: 'Inspect base North base' })
    expect(screen.getByRole('button', { name: 'Release claim' })).toBeDisabled()
    inspect.focus()
    await user.keyboard('{Enter}')
    const dialog = screen.getByRole('dialog', { name: 'North base' })
    expect(within(dialog).getByText('Aster')).toBeInTheDocument()
    expect(destroyClaim).not.toHaveBeenCalled()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(inspect).toHaveFocus()
  })
  it('opens market details accessibly and reports failed reads rather than empty successful data', async () => {
    vi.mocked(getMarketListings).mockRejectedValue(new Error('Listings unavailable'))
    const user = userEvent.setup()
    render(<MarketTab />)
    const inspect = await screen.findByRole('button', { name: 'Inspect Test item' })
    inspect.focus()
    await user.keyboard('{Enter}')
    expect(screen.getByRole('dialog', { name: 'Test item' })).toBeInTheDocument()
    expect(await screen.findByRole('alert')).toHaveTextContent('Listings unavailable')
    expect(screen.queryByText('No active listings.')).not.toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(inspect).toHaveFocus()
  })
  it('filters and inspects vehicles with direct repair and delete actions', async () => {
    await renderFleet()
    expect(await screen.findByText(/Give each vehicle a distinct in-game name/)).toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Scout' }))
    const dialog = screen.getByRole('dialog', { name: 'Scout' })
    expect(within(dialog).getByText('Buggy')).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Repair vehicle' })).toBeInTheDocument()
    expect(within(dialog).queryByRole('button', { name: 'Delete vehicle' })).not.toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Select Scout for deletion' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Close detail panel' }))
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search vehicle fleet' }), { target: { value: 'absent' } })
    expect(screen.queryByRole('button', { name: 'Inspect Scout' })).not.toBeInTheDocument()
    expect(screen.queryByText('Demo Data')).not.toBeInTheDocument()
  })
  it('does not read the fleet before selecting a player', async () => {
    render(<VehiclesWorkspace />)
    await screen.findByRole('option', { name: 'Aster' })
    expect(getVehicleFleet).not.toHaveBeenCalled()
    await userEvent.setup().selectOptions(screen.getByRole('combobox', { name: 'Fleet player' }), '20001')
    await screen.findByRole('button', { name: 'Inspect Scout' })
    expect(getVehicleFleet).toHaveBeenCalledWith(20001)
  })
  it('edits and saves active vehicle names as one restart-backed batch without a confirmation modal', async () => {
    const user = userEvent.setup()
    await renderFleet()
    await screen.findByRole('button', { name: 'Inspect Scout' })
    await user.click(screen.getByRole('button', { name: 'Edit Vehicle Names' }))
    await waitFor(() => expect(getVehicleFleet).toHaveBeenCalledTimes(2))
    expect(screen.getByText('Battlegroup restart required:')).toBeInTheDocument()
    const name = screen.getByRole('textbox', { name: 'New vehicle name' })
    expect(name).toHaveClass('border-2', 'border-accent/70', 'bg-surface')
    await user.clear(name)
    await user.type(name, '##Desert Runner')
    expect(screen.getByText('Remove the leading ## and enter a custom name.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save Vehicle Names' })).toBeDisabled()
    await user.clear(name)
    await user.type(name, 'none')
    expect(screen.getByText('This name is reserved by the game.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save Vehicle Names' })).toBeDisabled()
    await user.clear(name)
    await user.type(name, 'Desert Runner')
    await user.click(screen.getByRole('button', { name: 'Save Vehicle Names' }))
    await waitFor(() => expect(saveVehicleNames).toHaveBeenCalledWith([
      { vehicle_id: 7, expected_current_name: 'Scout', name: 'Desert Runner' },
    ], 'a'.repeat(64)))
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
    expect(await screen.findByText('Saved 1 vehicle name change and launched the battlegroup restart.')).toBeInTheDocument()
    expect(screen.getByText('Battlegroup restart required:')).toBeInTheDocument()
  })
  it('cancels stale name drafts when the fleet is refreshed', async () => {
    const user = userEvent.setup()
    await renderFleet()
    await screen.findByRole('button', { name: 'Inspect Scout' })
    await user.click(screen.getByRole('button', { name: 'Edit Vehicle Names' }))
    await waitFor(() => expect(getVehicleFleet).toHaveBeenCalledTimes(2))
    const name = screen.getByRole('textbox', { name: 'New vehicle name' })
    await user.clear(name)
    await user.type(name, 'Desert Runner')

    vi.mocked(getVehicleFleet).mockResolvedValue({
      source: 'live',
      total: 1,
      observed_at: new Date().toISOString(),
      stale_after_seconds: 20,
      database_scope: 'a'.repeat(64),
      vehicles: [{ id: 7, class: 'Buggy', subtype: 'Buggy', vehicle_name: 'Ranger', owners: 'Aster', map: 'Survival_1', actor_state: 'Active', target_revision: 'b'.repeat(32), cargo_hold_count: 1, cargo_stack_count: 2, module_count: 4 }],
    })
    await user.click(screen.getByRole('button', { name: 'Refresh' }))

    await waitFor(() => expect(getVehicleFleet).toHaveBeenCalledTimes(3))
    expect(screen.queryByRole('textbox', { name: 'New vehicle name' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Inspect Ranger' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save Vehicle Names' })).toBeDisabled()
  })
  it('refuses editing for online or unresolved vehicle owners and shows the reason', async () => {
    vi.mocked(getVehicleFleet).mockResolvedValue({
      source: 'live',
      total: 1,
      database_scope: 'a'.repeat(64),
      vehicles: [{
        id: 7,
        class: 'Buggy',
        vehicle_name: 'Scout',
        actor_state: 'Active',
        rename_blocked_reason: 'Every owning player must be Offline before renaming this vehicle.',
      }],
    })
    await renderFleet()
    await screen.findByRole('button', { name: 'Inspect Scout' })
    fireEvent.click(screen.getByRole('button', { name: 'Edit Vehicle Names' }))
    await waitFor(() => expect(getVehicleFleet).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('textbox', { name: 'New vehicle name' })).not.toBeInTheDocument()
    expect(screen.getByText('Every owning player must be Offline before renaming this vehicle.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save Vehicle Names' })).toBeDisabled()
  })
  it('separates recovery records from the active fleet', async () => {
    vi.mocked(getVehicleFleet).mockResolvedValue({
      source: 'live',
      total: 2,
      observed_at: new Date().toISOString(),
      stale_after_seconds: 20,
      vehicles: [
        { id: 7, class: 'Buggy', subtype: 'Buggy', vehicle_name: 'Scout', owners: 'Aster', map: 'Survival_1', actor_state: 'Active', target_revision: 'b'.repeat(32), cargo_hold_count: 1, cargo_stack_count: 2, module_count: 4 },
        { id: 8, class: 'Buggy', subtype: 'Buggy', vehicle_name: 'Recovery buggy', owners: 'Aster', map: 'Survival_1', actor_state: 'VehicleRecovery', target_revision: 'c'.repeat(32), cargo_hold_count: 0, cargo_stack_count: 0, module_count: 0, deletion_blocked_reason: 'Vehicle is in VehicleRecovery.' },
      ],
    })
    await renderFleet()
    expect(await screen.findByText('1 fleet vehicle · 1 recovery record')).toBeInTheDocument()
    const recovery = screen.getByText('Recovery records (1)').closest('details')
    expect(recovery).not.toBeNull()
    expect(within(recovery as HTMLElement).getByText('Recovery buggy')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Inspect Scout' })).toBeInTheDocument()
  })
  it('labels demo vehicles honestly and prevents their deletion', async () => {
    vi.mocked(getVehicleFleet).mockResolvedValue({ source: 'demo', total: 1, vehicles: [{ id: 7, class: 'Buggy', vehicle_name: 'Scout' }] })
    await renderFleet()
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Scout' }))
    expect(screen.getByRole('button', { name: 'Delete selected (0)' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Repair vehicle' })).toBeDisabled()
    await waitFor(() => expect(screen.queryByText('1 live vehicle')).not.toBeInTheDocument())
  })
  it('refreshes fleet and module data before showing repair success', async () => {
    await renderFleet()
    fireEvent.click(await screen.findByRole('button', { name: 'Inspect Scout' }))
    const dialog = screen.getByRole('dialog', { name: 'Scout' })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Repair vehicle' }))
    expect(within(dialog).getByRole('button', { name: 'Repairing...' })).toBeDisabled()
    expect(await screen.findByText('Repaired 4 vehicle modules.', {}, { timeout: 3000 })).toBeInTheDocument()
    expect(repairVehicle).toHaveBeenCalledWith(7)
    await waitFor(() => expect(getVehicleIntegrity).toHaveBeenCalledTimes(2), { timeout: 3000 })
    expect(within(dialog).getByRole('button', { name: 'Repair vehicle' })).toBeEnabled()
  }, 8000)
  it('deletes one vehicle through one confirmation and one API action', async () => {
    await renderFleet()
    fireEvent.click(await screen.findByRole('checkbox', { name: 'Select Scout for deletion' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected (1)' }))
    const confirmation = screen.getByRole('alertdialog', { name: 'Restart the entire battlegroup and delete 1 vehicle?' })
    expect(within(confirmation).getByText(/backs up the database/)).toBeInTheDocument()
    expect(within(confirmation).getByText(/Every connected player will be disconnected/)).toBeInTheDocument()
    expect(within(confirmation).getByText(/1–5 minutes/)).toBeInTheDocument()
    fireEvent.click(within(confirmation).getByRole('button', { name: 'Restart BG & delete 1' }))
    await waitFor(() => expect(deleteVehicles).toHaveBeenCalledWith([7]))
  })
  it('deletes multiple selected vehicles with one battlegroup restart action', async () => {
    vi.mocked(getVehicleFleet).mockResolvedValue({
      source: 'live',
      total: 2,
      observed_at: new Date().toISOString(),
      stale_after_seconds: 20,
      vehicles: [
        { id: 7, class: 'Buggy', subtype: 'Buggy', vehicle_name: 'Scout', owners: 'Aster', map: 'Survival_1', actor_state: 'Active', target_revision: 'b'.repeat(32), cargo_hold_count: 1, cargo_stack_count: 2, module_count: 4 },
        { id: 9, class: 'Sandbike', subtype: 'Sandbike', vehicle_name: 'Runner', owners: 'Aster', map: 'Survival_1', actor_state: 'Active', target_revision: 'c'.repeat(32), cargo_hold_count: 0, cargo_stack_count: 0, module_count: 3 },
      ],
    })
    await renderFleet()
    fireEvent.click(await screen.findByRole('checkbox', { name: 'Select Scout for deletion' }))
    fireEvent.click(screen.getByRole('checkbox', { name: 'Select Runner for deletion' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected (2)' }))
    const confirmation = screen.getByRole('alertdialog', { name: 'Restart the entire battlegroup and delete 2 vehicles?' })
    expect(within(confirmation).getByText(/stops the entire battlegroup once/)).toBeInTheDocument()
    fireEvent.click(within(confirmation).getByRole('button', { name: 'Restart BG & delete 2' }))
    await waitFor(() => expect(deleteVehicles).toHaveBeenCalledWith([7, 9]))
  })
  it('shows a direct deletion failure on the fleet screen', async () => {
    vi.mocked(deleteVehicles).mockRejectedValueOnce(new Error('Vehicle changed; refresh and try again'))
    await renderFleet()
    fireEvent.click(await screen.findByRole('checkbox', { name: 'Select Scout for deletion' }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete selected (1)' }))
    fireEvent.click(within(screen.getByRole('alertdialog', { name: 'Restart the entire battlegroup and delete 1 vehicle?' })).getByRole('button', { name: 'Restart BG & delete 1' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Vehicle changed; refresh and try again')
  })
    it('keeps fleet and cargo readable for remote viewers', async () => {
      vi.mocked(isLocalViewer).mockReturnValue(false)
      await renderFleet()
      fireEvent.click(await screen.findByRole('button', { name: 'Inspect Scout' }))
      expect(screen.getByRole('link', { name: 'Inspect cargo (2 stacks)' })).toHaveAttribute('href', '/vehicles?view=cargo&scope_type=vehicle&scope_id=7')
      expect(await screen.findByText(/Current not reported/)).toBeInTheDocument()
      expect(screen.getByText(/Chani - Co-Owner/)).toBeInTheDocument()
    })
    it('disables stale retained snapshots after a failed refresh', async () => {
      await renderFleet()
      await screen.findByRole('button', { name: 'Inspect Scout' })
      vi.mocked(getVehicleFleet).mockRejectedValueOnce(new Error('Database unavailable'))
      fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
      await screen.findByText('Database unavailable')
      expect(screen.getByRole('checkbox', { name: 'Select Scout for deletion' })).toBeEnabled()
    })
})
