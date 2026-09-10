import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getPlayerDetail, getReserveRecovery, setWeaponAmmo, type Player } from '../src/api/gameplay'
import { InventorySection } from '../src/pages/gameplay/players/sections'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'

vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getPlayerDetail: vi.fn(),
  getReserveRecovery: vi.fn(),
  setWeaponAmmo: vi.fn(),
}))

const player: Player = {
  id: 42, account_id: 99, controller_id: 100, name: 'Test player',
  class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Offline',
}

beforeEach(() => {
  localStorage.clear()
  vi.mocked(getPlayerDetail).mockResolvedValue({
    source: 'live', specs: [], currency: [],
    inventory: [{
      id: 9001, template_id: 'TestRifle', name: 'Test rifle',
      stack_size: 1, quality: 0, durability: 'N/A', max_durability: 'N/A',
      water_amount: 'N/A', water_type: '', current_ammo: '17',
    }],
  })
  vi.mocked(setWeaponAmmo).mockResolvedValue({ ok: true, message: 'Ammo saved.' })
  vi.mocked(getReserveRecovery).mockResolvedValue({
    source: 'live', available: false, blocked_reason: 'Reserve is empty.',
    pawn_id: 42, controller_id: 100, online_status: 'Offline',
    reserve_inventory_id: 216, backpack_inventory_id: 205,
    item_rows: 0, item_units: 0, required_volume: 0, used_volume: 10,
    max_slots: 50, used_slots: 2, max_volume: 1000, revision: 'a'.repeat(64),
    items: [], rollback: null,
  })
})

afterEach(() => {
  cleanup()
  localStorage.clear()
  vi.clearAllMocks()
})

async function openEditor(online = false) {
  render(<InventorySection
    player={{ ...player, online_status: online ? 'Online' : 'Offline' }}
    canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()}
  />)
  fireEvent.click(await screen.findByText('Test rifle'))
  return screen.getByRole('spinbutton', { name: 'Loaded ammo' })
}

describe('player loaded-ammo editor', () => {
  it.each([
    ['250', 250], ['0', 0], ['2000000000', 2000000000],
    ['1e3', 1000], ['2e9', 2000000000],
  ])('saves %s as the exact integer %i', async (input, expected) => {
    const field = await openEditor()
    fireEvent.change(field, { target: { value: input } })
    const save = screen.getByRole('button', { name: 'Save ammo' })
    expect(save).toBeEnabled()
    fireEvent.click(save)
    await waitFor(() => {
      expect(setWeaponAmmo).toHaveBeenCalledExactlyOnceWith(42, 9001, expected, 17)
    })
  })

  it.each(['', '2.5', '-1', '2000000001', '2e10', '1e-3', 'invalid'])(
    'does not submit invalid ammo %j', async input => {
      const field = await openEditor()
      fireEvent.change(field, { target: { value: input } })
      const save = screen.getByRole('button', { name: 'Save ammo' })
      expect(save).toBeDisabled()
      fireEvent.click(save)
      expect(setWeaponAmmo).not.toHaveBeenCalled()
    },
  )

  it('keeps editing disabled for an online player', async () => {
    expect(await openEditor(true)).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Save ammo' })).toBeDisabled()
    expect(setWeaponAmmo).not.toHaveBeenCalled()
  })
  it.each([false, true])('preserves ammo safety and read-only selection in Command Deck (online=%s)', async online => {
    localStorage.setItem(COMMAND_DECK_KEY, '1')
    const field = await openEditor(online)
    expect(screen.getByText(/only persists safely while the player is offline/)).toBeInTheDocument()
    expect(field.closest('.player-item-editors')).not.toBeNull()
    expect(screen.getByRole('button', { name: 'Save ammo' }).hasAttribute('disabled')).toBe(online)
    expect(setWeaponAmmo).not.toHaveBeenCalled()
  })

  it.each([false, true])('uses the compact inventory grid only in Command Deck (enabled=%s)', async enabled => {
    if (enabled) localStorage.setItem(COMMAND_DECK_KEY, '1')
    await openEditor()
    const item = screen.getByText('Test rifle').closest('.player-inventory-item')
    expect(item).toHaveAttribute('data-expanded', 'true')
    expect(!!item?.closest('.player-inventory-grid')).toBe(enabled)
    fireEvent.click(screen.getByText('Test rifle'))
    expect(item).toHaveAttribute('data-expanded', 'false')
    fireEvent.keyDown(screen.getByTitle('Delete item'), { key: ' ' })
    expect(item).toHaveAttribute('data-expanded', 'false')
    expect(screen.queryByRole('spinbutton', { name: 'Loaded ammo' })).not.toBeInTheDocument()
    expect(setWeaponAmmo).not.toHaveBeenCalled()
  })

  it('keeps read-only inventory compact without exposing write controls', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '1')
    render(<InventorySection player={player} canWrite={false} demo={false}
      refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
    const name = await screen.findByText('Test rifle')
    expect(name.closest('.player-inventory-grid')).not.toBeNull()
    fireEvent.click(name)
    expect(screen.queryByRole('spinbutton', { name: 'Loaded ammo' })).not.toBeInTheDocument()
    expect(screen.queryByTitle('Delete item')).not.toBeInTheDocument()
    expect(setWeaponAmmo).not.toHaveBeenCalled()
  })
})
