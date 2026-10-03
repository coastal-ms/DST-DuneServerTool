import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ManagePlayerSection } from '../src/pages/gameplay/players/sections'
import { getItemPackages, giveItems, type Player } from '../src/api/gameplay'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: true }) }))
vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getItemPackages: vi.fn(), giveItems: vi.fn(),
}))
afterEach(() => { cleanup(); vi.clearAllMocks() })

describe('Package Grade and delivery feedback', () => {
  it('shows Grade 5 separately from the Mk6 template and reports partial failure', async () => {
    const player = { id: 21, name: 'Own character', online_status: 'Online' } as Player
    const flash = vi.fn()
    vi.mocked(getItemPackages).mockResolvedValue([{
      id: 'suit', name: 'Stillsuit', items: [{ template: 'Stillsuit_Unique_Armored_06_Top', qty: 1, quality: 5 }],
    }])
    vi.mocked(giveItems).mockResolvedValue({ ok: true, message: '1/2 item templates gave OK; 1 failed.', result: { failures: 1 } })
    render(<ManagePlayerSection player={player} canWrite={true} demo={false} flash={flash} onChanged={vi.fn()} />)
    fireEvent.click(screen.getByRole('button', { name: /^Give Package/ }))
    expect(await screen.findByText('x1 · Grade 5')).toBeInTheDocument()
    expect(screen.queryByText('x1 · Mk6')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Give to Own character' }))
    await waitFor(() => expect(flash).toHaveBeenCalledWith('1/2 item templates gave OK; 1 failed.', 'err'))
  })
})
