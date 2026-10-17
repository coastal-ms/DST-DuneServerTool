import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { LabSaveReview } from '../src/pages/gameconfig/LabSaveReview'
import { DefaultsKeyRow } from '../src/pages/GameConfig'
import { getGameConfigClient, saveLabLocal } from '../src/api/gameconfig'
import type { GameConfigClientInfo } from '../src/api/types'

vi.mock('../src/api/gameconfig', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameconfig')>(),
  getGameConfigClient: vi.fn(), saveLabLocal: vi.fn(),
}))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => true }))
const updates = [{ file: 'game' as const, section: 'Building', key: 'DoorTime', value: '3' }]
beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(getGameConfigClient).mockResolvedValue({
    game: { path: 'C:\\Game.ini', effective: {} }, engine: { path: 'C:\\Engine.ini', effective: {} },
  } as unknown as GameConfigClientInfo)
  vi.mocked(saveLabLocal).mockResolvedValue({ ok: true } as Awaited<ReturnType<typeof saveLabLocal>>)
})
afterEach(cleanup)

it('requires explicit approval and saves each selected destination without deploying the server', async () => {
  const server = vi.fn().mockResolvedValue({}), done = vi.fn()
  render(<LabSaveReview updates={updates} onServerSave={server} onDone={done} onCancel={vi.fn()} />)
  await screen.findByText('C:\\Game.ini')
  expect(saveLabLocal).not.toHaveBeenCalled()
  expect(server).not.toHaveBeenCalled()
  await userEvent.click(screen.getByRole('button', { name: 'Approve local changes & Save' }))
  await waitFor(() => expect(done).toHaveBeenCalled())
  expect(saveLabLocal).toHaveBeenCalledWith(updates)
  expect(server).toHaveBeenCalledOnce()
  expect(done.mock.calls[0][0]).toContain('Use Apply server settings')
})

it('allows server-only saves without writing local files', async () => {
  const server = vi.fn().mockResolvedValue({})
  render(<LabSaveReview updates={updates} onServerSave={server} onDone={vi.fn()} onCancel={vi.fn()} />)
  await userEvent.click(screen.getByRole('checkbox', { name: /Save to this PC/ }))
  await userEvent.click(screen.getByRole('button', { name: 'Save server files' }))
  await waitFor(() => expect(server).toHaveBeenCalledOnce())
  expect(saveLabLocal).not.toHaveBeenCalled()
})

it('saves local files without contacting an unavailable server', async () => {
  const server = vi.fn(), done = vi.fn()
  render(<LabSaveReview updates={updates} serverAvailable={false} onServerSave={server} onDone={done} onCancel={vi.fn()} />)
  await screen.findByText('C:\\Game.ini')
  await userEvent.click(screen.getByRole('button', { name: 'Approve local changes & Save' }))
  await waitFor(() => expect(done).toHaveBeenCalled())
  expect(saveLabLocal).toHaveBeenCalledWith(updates)
  expect(server).not.toHaveBeenCalled()
})

it('reports partial completion and retries only the unfinished destination', async () => {
  const server = vi.fn().mockRejectedValueOnce(new Error('Server offline')).mockResolvedValue({})
  render(<LabSaveReview updates={updates} onServerSave={server} onDone={vi.fn()} onCancel={vi.fn()} />)
  await screen.findByText('C:\\Game.ini')
  await userEvent.click(screen.getByRole('button', { name: 'Approve local changes & Save' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Local files saved.')
  await userEvent.click(screen.getByRole('button', { name: 'Approve local changes & Save' }))
  await waitFor(() => expect(server).toHaveBeenCalledTimes(2))
  expect(saveLabLocal).toHaveBeenCalledOnce()
})

it.each([
  { key: 'm_DoorDataTable', value: '/Game/Dune/Systems/Building/Data/DT_Doors.DT_Doors' },
  { key: 'SaveDirectory', value: 'C:\\Users\\Player\\Saved' },
  { key: 'InstallLocation', value: '/home/player/game' },
])('preserves $key as a read-only path without Clear or Default actions', async ({ key, value }) => {
  const change = vi.fn()
  render(<DefaultsKeyRow k={{ key, default: value, current: '', hasOverride: false, overridden: false, isArray: false, type: 'string' }}
    rowIdx={0} pending={undefined} onChange={change} arrayPending={undefined} onArrayChange={change} expanded={false} onToggleExpand={vi.fn()} />)
  const input = screen.getByRole('textbox')
  expect(input).toHaveValue(value)
  expect(input).toHaveAttribute('readonly')
  await userEvent.type(input, 'bad')
  expect(change).not.toHaveBeenCalled()
  expect(screen.queryByRole('button', { name: 'Clear' })).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Default' })).not.toBeInTheDocument()
})
