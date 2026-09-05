import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getPlayerDetail, setWeaponAmmo, type Player } from '../src/api/gameplay'
import { InventorySection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getPlayerDetail: vi.fn(),
  setWeaponAmmo: vi.fn(),
}))

const player: Player = {
  id: 42, account_id: 99, controller_id: 100, name: 'Test player',
  class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Offline',
}

beforeEach(() => {
  vi.mocked(getPlayerDetail).mockResolvedValue({
    source: 'live', specs: [], currency: [],
    inventory: [{
      id: 9001, template_id: 'TestRifle', name: 'Test rifle',
      stack_size: 1, quality: 0, durability: 'N/A', max_durability: 'N/A',
      water_amount: 'N/A', water_type: '', current_ammo: '17',
    }],
  })
  vi.mocked(setWeaponAmmo).mockResolvedValue({ ok: true, message: 'Ammo saved.' })
})

afterEach(() => {
  cleanup()
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
})
