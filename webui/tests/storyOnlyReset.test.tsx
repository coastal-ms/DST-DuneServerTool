import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { JourneySection } from '../src/pages/gameplay/players/sections'
import { api } from '../src/api/client'
import type { Player } from '../src/api/gameplay'
vi.mock('../src/api/client', async original => ({
  ...await original<typeof import('../src/api/client')>(),
  api: vi.fn().mockResolvedValue({ ok: true, nodes: [], message: 'Story reset complete' }),
}))
const player = { id: 17, account_id: 605, name: 'Review character', online_status: 'Offline' } as Player
const props = { player, canWrite: true, demo: false, refreshKey: 0, flash: vi.fn(), onChanged: vi.fn() }
const writes = () => vi.mocked(api).mock.calls.filter(([, init]) => init?.method === 'POST')
beforeEach(() => {
  vi.clearAllMocks()
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  vi.spyOn(window, 'prompt').mockReturnValue('i acknowledge')
})
afterEach(() => { cleanup(); vi.restoreAllMocks() })
it('requires both confirmations and uses the dedicated skill-preserving endpoint', async () => {
  render(<JourneySection {...props} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Reset to Post-NPE' }))
  await waitFor(() => expect(writes()).toHaveLength(1))
  expect(writes()[0]).toEqual(['/api/gameplay/players/journey/reset-story', { method: 'POST', body: JSON.stringify({ account_id: 605 }) }])
  expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('keeping learned skills, skill points and tech points'))
  expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('before crossing'))
})
it('sends no reset when the first confirmation is cancelled', async () => {
  vi.mocked(window.confirm).mockReturnValue(false)
  render(<JourneySection {...props} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Reset to Post-NPE' }))
  expect(window.prompt).not.toHaveBeenCalled()
  expect(writes()).toHaveLength(0)
})
it('sends no reset without the typed acknowledgement', async () => {
  vi.mocked(window.prompt).mockReturnValue('')
  render(<JourneySection {...props} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Reset to Post-NPE' }))
  await waitFor(() => expect(props.flash).toHaveBeenCalledWith('Post-NPE reset cancelled.', 'err'))
  expect(writes()).toHaveLength(0)
})
it('disables the new reset for online characters', async () => {
  render(<JourneySection {...props} player={{ ...player, online_status: 'Online' }} />)
  expect(await screen.findByRole('button', { name: 'Reset to Post-NPE' })).toBeDisabled()
  expect(writes()).toHaveLength(0)
})
it('keeps the existing Reset All on its original endpoint', async () => {
  render(<JourneySection {...props} />)
  fireEvent.click(await screen.findByRole('button', { name: 'Reset All' }))
  await waitFor(() => expect(writes()).toHaveLength(1))
  expect(writes()[0][0]).toBe('/api/gameplay/players/journey/reset')
})
