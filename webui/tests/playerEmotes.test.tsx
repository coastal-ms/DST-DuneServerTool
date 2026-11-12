import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, expect, it, vi } from 'vitest'
import { giveItem, type Player } from '../src/api/gameplay'
import { ActionsSection, getPlayerActionTools } from '../src/pages/gameplay/players/sections'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: false }) }))
vi.mock('../src/api/gameplay', async original => ({ ...await original<typeof import('../src/api/gameplay')>(), giveItem: vi.fn() }))
const player: Player = { id: 42, account_id: 99, controller_id: 100, name: 'Test character', class: '', map: '', faction_id: 0, faction_name: '', online_status: 'Online' }
afterEach(() => { cleanup(); vi.clearAllMocks() })

it.each(['Online', 'Offline'])('uses ordinary item delivery for %s characters with quantity one and no overflow', async status => {
  const user = userEvent.setup(), flash = vi.fn()
  vi.mocked(giveItem).mockResolvedValue({ ok: true, message: 'Accepted' })
  render(<ActionsSection player={{ ...player, online_status: status }} canWrite demo={false} refreshKey={0} flash={flash} onChanged={vi.fn()} actionIds={['grant-emotes']} initialAction="grant-emotes" />)
  await user.selectOptions(screen.getByRole('listbox'), ['Emote_Bow_01', 'Emote_Wave_01'])
  await user.click(screen.getByRole('button', { name: 'Grant selected (2)' }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Grant selected (0)' })).toBeDisabled())
  expect(giveItem).toHaveBeenCalledTimes(2)
  expect(giveItem).toHaveBeenCalledWith(42, 'Emote_Bow_01', 1, 0, false)
  expect(giveItem).toHaveBeenCalledWith(42, 'Emote_Wave_01', 1, 0, false)
  expect(flash).toHaveBeenLastCalledWith(expect.stringContaining('request submitted'), 'info')
})

it('keeps the actual backend failure visible and stops the selected grant sequence', async () => {
  const user = userEvent.setup(), flash = vi.fn()
  vi.mocked(giveItem).mockRejectedValue(new Error('Backpack capacity exceeded'))
  render(<ActionsSection player={player} canWrite demo={false} refreshKey={0} flash={flash} onChanged={vi.fn()} actionIds={['grant-emotes']} initialAction="grant-emotes" />)
  await user.selectOptions(screen.getByRole('listbox'), ['Emote_Bow_01', 'Emote_Wave_01'])
  fireEvent.click(screen.getByRole('button', { name: 'Grant selected (2)' }))
  await screen.findByText('Request failed — see action result.')
  expect(flash).toHaveBeenLastCalledWith('Backpack capacity exceeded', 'err')
  expect(giveItem).toHaveBeenCalledTimes(1)
})

it('exposes the card to self-hosted admins only', () => {
  expect(getPlayerActionTools(false).some(tool => tool.id === 'grant-emotes')).toBe(true)
  expect(getPlayerActionTools(true).some(tool => tool.id === 'grant-emotes')).toBe(false)
})
