import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
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
