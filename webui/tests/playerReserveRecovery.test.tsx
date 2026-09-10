import React from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  getPlayerDetail, getReserveRecovery, recoverReserve, rollbackReserve,
  type Player, type ReserveRecoveryPreview,
} from '../src/api/gameplay'
import { InventorySection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getPlayerDetail: vi.fn(),
  getReserveRecovery: vi.fn(),
  recoverReserve: vi.fn(),
  rollbackReserve: vi.fn(),
}))

const player: Player = {
  id: 42, account_id: 99, controller_id: 100, name: 'Test player',
  class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Offline',
}

const preview: ReserveRecoveryPreview = {
  source: 'live', available: true, blocked_reason: '',
  pawn_id: 42, controller_id: 100, online_status: 'Offline',
  reserve_inventory_id: 216, backpack_inventory_id: 205,
  item_rows: 1, item_units: 6, required_volume: 12, used_volume: 10,
  max_slots: 50, used_slots: 2, max_volume: 1000, revision: 'a'.repeat(64),
  items: [{
    item_id: 301, template_id: 'CopperBar', name: 'Copper Bar', stack_size: 6, quality: 0,
    source_position: 4, destination_position: 0, unit_volume: 2, total_volume: 12,
  }],
  rollback: null,
}

beforeEach(() => {
  vi.mocked(getPlayerDetail).mockResolvedValue({
    source: 'live', specs: [], currency: [],
    inventory: [{
      id: 301, template_id: 'CopperBar', name: 'Copper Bar', stack_size: 6, quality: 0,
      durability: 'N/A', max_durability: 'N/A', water_amount: 'N/A', water_type: '',
      current_ammo: 'N/A', inventory_id: 216, inventory_type: 33, is_reserve: true,
    }],
  })
  vi.mocked(getReserveRecovery).mockResolvedValue(preview)
  vi.mocked(recoverReserve).mockResolvedValue({ ok: true, message: 'Recovered Reserve.' })
  vi.mocked(rollbackReserve).mockResolvedValue({ ok: true, message: 'Rolled back Reserve.' })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function renderInventory() {
  render(<InventorySection player={player} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
}

describe('Reserve recovery inventory controls', () => {
  it('labels every Reserve row and disables direct deletion', async () => {
    renderInventory()
    const reserveBadge = await screen.findByText('Reserve · protected')
    expect(screen.getByTitle(/Reserve items cannot be deleted directly/)).toBeDisabled()
    fireEvent.click(reserveBadge.closest('.player-inventory-item')!.querySelector('[role="button"]')!)
    expect(screen.getByText(/Reserve quantities cannot be reduced directly/)).toBeInTheDocument()
    const stack = screen.getByRole('spinbutton', { name: 'Stack quantity' })
    fireEvent.change(stack, { target: { value: '5' } })
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
  })

  it('requires typed acknowledgement before applying the exact preview revision', async () => {
    renderInventory()
    expect(await screen.findByText(/Reserve 4 → Backpack 0/)).toBeInTheDocument()
    const button = screen.getByRole('button', { name: /Recover Reserve to Backpack/ })
    expect(button).toBeDisabled()
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve recovery confirmation' }), { target: { value: 'RECOVER' } })
    expect(button).toBeEnabled()
    fireEvent.click(button)
    await waitFor(() => expect(recoverReserve).toHaveBeenCalledExactlyOnceWith(42, 100, 'a'.repeat(64)))
  })

  it('shows truthful blocked identity evidence even when protected inventory loads', async () => {
    vi.mocked(getReserveRecovery).mockResolvedValue({
      ...preview, available: false, blocked_reason: 'The exact pawn/controller pair no longer identifies one player.',
    })
    renderInventory()
    expect(await screen.findByText('Reserve · protected')).toBeInTheDocument()
    expect(await screen.findByText(/exact pawn\/controller pair/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Recover Reserve to Backpack/ })).not.toBeInTheDocument()
    expect(recoverReserve).not.toHaveBeenCalled()
  })

  it('discards a prior acknowledgement while refreshing and requires a new one even for the same revision', async () => {
    renderInventory()
    await screen.findByRole('button', { name: /Recover Reserve to Backpack/ })
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve recovery confirmation' }), { target: { value: 'RECOVER' } })
    let finish!: (value: ReserveRecoveryPreview) => void
    vi.mocked(getReserveRecovery).mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh inventory' }))
    expect(await screen.findByText('Checking Reserve safety…')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Recover Reserve to Backpack/ })).not.toBeInTheDocument()
    await act(async () => { finish(preview) })
    expect(await screen.findByRole('button', { name: /Recover Reserve to Backpack/ })).toBeDisabled()
  })

  it('does not pair an earlier player preview with the current selection', async () => {
    vi.mocked(getReserveRecovery).mockResolvedValue({ ...preview, controller_id: 101 })
    renderInventory()
    expect(await screen.findByText(/Reserve preview does not match the selected player/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Recover Reserve to Backpack/ })).not.toBeInTheDocument()
  })

  it('keeps both writes unavailable when current player status is not Offline', async () => {
    vi.mocked(getReserveRecovery).mockResolvedValue({
      ...preview,
      rollback: { recovery_id: 'b'.repeat(32), item_rows: 1, created_at: '2026-01-01T00:00:00Z' },
    })
    render(<InventorySection player={{ ...player, online_status: 'Online' }} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
    await screen.findByRole('button', { name: /Recover Reserve to Backpack/ })
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve recovery confirmation' }), { target: { value: 'RECOVER' } })
    expect(screen.getByRole('button', { name: /Recover Reserve to Backpack/ })).toBeDisabled()
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve rollback confirmation' }), { target: { value: 'ROLLBACK' } })
    expect(screen.getByRole('button', { name: /Roll back recovery/ })).toBeDisabled()
  })

  it('does not restore a stale preview after the selection changes', async () => {
    let finishOld!: (value: ReserveRecoveryPreview) => void
    vi.mocked(getReserveRecovery).mockImplementationOnce(() => new Promise(resolve => { finishOld = resolve }))
    const props = { canWrite: true, demo: false, refreshKey: 0, flash: vi.fn(), onChanged: vi.fn() }
    const { rerender } = render(<InventorySection {...props} player={player} />)
    await waitFor(() => expect(getReserveRecovery).toHaveBeenCalledWith(42, 100))
    vi.mocked(getReserveRecovery).mockResolvedValue({ ...preview, pawn_id: 44, controller_id: 102, revision: 'c'.repeat(64) })
    rerender(<InventorySection {...props} player={{ ...player, id: 44, controller_id: 102 }} />)
    await screen.findByRole('button', { name: /Recover Reserve to Backpack/ })
    await act(async () => { finishOld(preview) })
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve recovery confirmation' }), { target: { value: 'RECOVER' } })
    fireEvent.click(screen.getByRole('button', { name: /Recover Reserve to Backpack/ }))
    await waitFor(() => expect(recoverReserve).toHaveBeenCalledExactlyOnceWith(44, 102, 'c'.repeat(64)))
  })

  it('offers only exact persisted rollback and requires a second typed acknowledgement', async () => {
    vi.mocked(getReserveRecovery).mockResolvedValue({
      ...preview, available: false, blocked_reason: 'Reserve is empty.',
      item_rows: 0, item_units: 0, items: [],
      rollback: { recovery_id: 'b'.repeat(32), item_rows: 1, created_at: '2026-01-01T00:00:00Z' },
    })
    renderInventory()
    const button = await screen.findByRole('button', { name: /Roll back recovery/ })
    expect(button).toBeDisabled()
    fireEvent.change(screen.getByRole('textbox', { name: 'Reserve rollback confirmation' }), { target: { value: 'ROLLBACK' } })
    fireEvent.click(button)
    await waitFor(() => expect(rollbackReserve).toHaveBeenCalledExactlyOnceWith(42, 100, 'b'.repeat(32)))
  })
})
