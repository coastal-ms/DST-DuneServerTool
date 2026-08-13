import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { BaseWaterAdmin } from '../../src/pages/gameplay/players/base-water'
import { fillBaseWater, type Player } from '../../src/api/gameplay'

vi.mock('../../src/api/gameplay', () => ({
  fillBaseWater: vi.fn(),
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
  vi.mocked(fillBaseWater).mockResolvedValue({
    ok: true,
    message: 'Filled 3 owned base cisterns.',
    result: { controller: 5, total: 3, small: 1, medium: 1, large: 1 },
  })
  vi.stubGlobal('confirm', vi.fn(() => true))
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
    expect(screen.queryByRole('option', { name: /all players/i })).not.toBeInTheDocument()

    await user.selectOptions(screen.getByRole('combobox', { name: /base owner/i }), '5')
    await user.click(screen.getByRole('button', { name: /fill selected player/i }))

    await waitFor(() => expect(fillBaseWater).toHaveBeenCalledWith(5))
    expect(vi.mocked(confirm).mock.calls[0]?.[0]).toMatch(/disconnect every online player/i)
    expect(flash).toHaveBeenCalledWith('Filled 3 owned base cisterns.')
  })

  it('disables writes when live data is unavailable', () => {
    render(<BaseWaterAdmin players={players} canWrite={false} flash={vi.fn()} />)
    expect(screen.getByRole('combobox', { name: /base owner/i })).toBeDisabled()
    expect(screen.getByRole('button', { name: /fill selected player/i })).toBeDisabled()
  })
})
