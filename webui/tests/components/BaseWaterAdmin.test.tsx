import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { BaseWaterAdmin } from '../../src/pages/gameplay/players/base-water'
import { fillBaseWater, getBaseWaterSummary, type Player } from '../../src/api/gameplay'

vi.mock('../../src/api/gameplay', () => ({
  fillBaseWater: vi.fn(),
  getBaseWaterSummary: vi.fn(),
}))

const players: Player[] = [
  {
    id: 7,
    account_id: 3,
    controller_id: 5,
    name: 'Test Player',
    class: '',
    map: 'HaggaBasin',
    faction_id: 0,
    faction_name: '',
    online_status: 'Online',
  },
]

beforeEach(() => {
  vi.mocked(getBaseWaterSummary).mockResolvedValue({
    ok: true,
    controllerId: 5,
    allPlayers: false,
    owners: 1,
    total: 3,
    small: 1,
    medium: 1,
    large: 1,
    full: 0,
    missingWater: 130000,
  })
  vi.mocked(fillBaseWater).mockResolvedValue({
    ok: true,
    message: 'Filled 3 owned base cisterns.',
    result: { controller: 5, total: 3, small: 1, medium: 1, large: 1 },
  })
  vi.stubGlobal('confirm', vi.fn(() => true))
  vi.stubGlobal('prompt', vi.fn(() => 'FILL ALL'))
})

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

describe('BaseWaterAdmin', () => {
  it('targets one explicit player and warns about the server-wide restart', async () => {
    const user = userEvent.setup()
    const flash = vi.fn()
    render(<BaseWaterAdmin players={players} canWrite flash={flash} />)

    expect(screen.getByText(/all connected players will be disconnected/i)).toBeInTheDocument()
    expect(screen.getByRole('option', { name: /all players/i })).toBeInTheDocument()

    await user.selectOptions(screen.getByRole('combobox', { name: /base owner/i }), '5')
    await user.click(screen.getByRole('button', { name: /fill selected player/i }))

    await waitFor(() => expect(getBaseWaterSummary).toHaveBeenCalledWith(5, false))
    expect(fillBaseWater).toHaveBeenCalledWith(5, false)
    expect(vi.mocked(confirm).mock.calls[0]?.[0]).toMatch(/disconnect every online player/i)
    expect(vi.mocked(confirm).mock.calls[0]?.[0]).toMatch(/3 cisterns across 1 owner/i)
    expect(flash).toHaveBeenCalledWith('Filled 3 owned base cisterns.')
  })

  it('requires typed confirmation before filling all player-owned bases', async () => {
    const user = userEvent.setup()
    const flash = vi.fn()
    vi.mocked(getBaseWaterSummary).mockResolvedValue({
      ok: true,
      controllerId: 0,
      allPlayers: true,
      owners: 4,
      total: 12,
      small: 3,
      medium: 4,
      large: 5,
      full: 2,
      missingWater: 400000,
    })
    vi.mocked(fillBaseWater).mockResolvedValue({
      ok: true,
      message: 'Filled 12 base cisterns across 4 owners.',
      result: { allPlayers: true, owners: 4, total: 12, small: 3, medium: 4, large: 5 },
    })

    render(<BaseWaterAdmin players={players} canWrite flash={flash} />)
    await user.selectOptions(screen.getByRole('combobox', { name: /base owner/i }), 'all')
    await user.click(screen.getByRole('button', { name: /fill all player-owned/i }))

    await waitFor(() => expect(getBaseWaterSummary).toHaveBeenCalledWith(undefined, true))
    expect(vi.mocked(prompt).mock.calls[0]?.[0]).toMatch(/12 cisterns across 4 owners/i)
    expect(vi.mocked(prompt).mock.calls[0]?.[0]).toMatch(/orphaned\/unowned structures/i)
    expect(fillBaseWater).toHaveBeenCalledWith(undefined, true)
    expect(flash).toHaveBeenCalledWith('Filled 12 base cisterns across 4 owners.')
  })

  it('does not run all-player fill when typed confirmation does not match', async () => {
    const user = userEvent.setup()
    vi.mocked(prompt).mockReturnValue('fill all')
    render(<BaseWaterAdmin players={players} canWrite flash={vi.fn()} />)
    await user.selectOptions(screen.getByRole('combobox', { name: /base owner/i }), 'all')
    await user.click(screen.getByRole('button', { name: /fill all player-owned/i }))
    await waitFor(() => expect(getBaseWaterSummary).toHaveBeenCalled())
    expect(fillBaseWater).not.toHaveBeenCalled()
  })

  it('disables writes when live data is unavailable', () => {
    render(<BaseWaterAdmin players={players} canWrite={false} flash={vi.fn()} />)
    expect(screen.getByRole('combobox', { name: /base owner/i })).toBeDisabled()
    expect(screen.getByRole('button', { name: /fill selected player/i })).toBeDisabled()
  })
})
