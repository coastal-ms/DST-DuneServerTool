import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { LandclaimTimerCard } from '../../src/pages/gameconfig/LandclaimTimerCard'
import { getLandclaimTimer, saveLandclaimTimer } from '../../src/api/gameconfig'
import type { LandclaimTimerState } from '../../src/api/types'
vi.mock('../../src/api/gameconfig', () => ({ getLandclaimTimer: vi.fn(), saveLandclaimTimer: vi.fn() }))
const state: LandclaimTimerState = {
  server: { available: true, enabled: true, seconds: '1', formattedOk: true },
  client: { exists: true, dirExists: true, path: 'fixture/Game.ini', dir: 'fixture', enabled: false, seconds: '', formattedOk: false },
  clientBlock: '',
}
afterEach(() => { cleanup(); vi.clearAllMocks(); localStorage.clear() })
describe('Land claim timer client retry', () => {
  it('retries a skipped client write while the server already matches, and reports the skip', async () => {
    vi.mocked(getLandclaimTimer).mockResolvedValue(state)
    vi.mocked(saveLandclaimTimer).mockResolvedValue({ ...state, ok: true, enabled: true, seconds: '1',
      result: { ok: true, server: { ok: true, applied: true }, client: { ok: false, applied: false, reason: 'Game is running.' } } })
    render(<LandclaimTimerCard vmRunning />)
    const apply = await screen.findByRole('button', { name: 'Apply', exact: true })
    await waitFor(() => expect(apply).toBeEnabled())
    fireEvent.click(apply)
    expect(await screen.findByText(/Client Game.ini was not updated: Game is running/)).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveClass('text-warning')
    expect(apply).toBeEnabled()
    expect(saveLandclaimTimer).toHaveBeenCalledWith(true, '1')
    vi.mocked(saveLandclaimTimer).mockResolvedValue({ ...state, ok: true, enabled: true, seconds: '1',
      client: { ...state.client, enabled: true, seconds: '1', formattedOk: true },
      result: { ok: true, server: { ok: true, applied: true }, client: { ok: true, applied: true } } })
    fireEvent.click(apply)
    await waitFor(() => expect(apply).toBeDisabled())
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.getByText(/client Game.ini updated/)).toBeInTheDocument()
    expect(saveLandclaimTimer).toHaveBeenCalledTimes(2)
  })
  it('can retry clearing a client override after the server is already back to defaults', async () => {
    vi.mocked(getLandclaimTimer).mockResolvedValue({ ...state,
      server: { ...state.server, enabled: false, seconds: '', formattedOk: false },
      client: { ...state.client, enabled: true, seconds: '1', formattedOk: true } })
    vi.mocked(saveLandclaimTimer).mockResolvedValue({ ...state, ok: true, enabled: false, seconds: '',
      server: { ...state.server, enabled: false, seconds: '', formattedOk: false },
      client: { ...state.client, enabled: false, seconds: '', formattedOk: false },
      result: { ok: true, server: { ok: true, applied: true }, client: { ok: true, applied: true } } })
    render(<LandclaimTimerCard vmRunning />)
    const clear = await screen.findByRole('button', { name: 'Clear & restore default' })
    await waitFor(() => expect(clear).toBeEnabled())
    fireEvent.click(clear)
    await waitFor(() => expect(clear).toBeDisabled())
    expect(saveLandclaimTimer).toHaveBeenCalledWith(false, '')
  })
  it('does not offer a client-only retry when the client folder is unavailable', async () => {
    vi.mocked(getLandclaimTimer).mockResolvedValue({ ...state, client: { ...state.client, exists: false, dirExists: false } })
    render(<LandclaimTimerCard vmRunning />)
    const apply = await screen.findByRole('button', { name: 'Apply', exact: true })
    await screen.findByRole('spinbutton')
    expect(apply).toBeDisabled()
    expect(saveLandclaimTimer).not.toHaveBeenCalled()
  })
  it('offers re-apply when matching timer values have incomplete client formatting', async () => {
    vi.mocked(getLandclaimTimer).mockResolvedValue({ ...state, client: { ...state.client, enabled: true, seconds: '1', formattedOk: false } })
    render(<LandclaimTimerCard vmRunning />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Apply', exact: true })).toBeEnabled())
  })
  it('starts with an empty input when enabling and requires a typed value', async () => {
    vi.mocked(getLandclaimTimer).mockResolvedValue({ ...state, server: { ...state.server, enabled: false, seconds: '' } })
    render(<LandclaimTimerCard vmRunning />)
    await screen.findAllByText('game default')
    fireEvent.click(screen.getByRole('checkbox'))
    expect(screen.getByRole('spinbutton')).toHaveValue(null)
    expect(screen.getByRole('spinbutton')).not.toHaveAttribute('placeholder')
    expect(screen.getByRole('button', { name: 'Apply', exact: true })).toBeDisabled()
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '1' } })
    expect(screen.getByRole('button', { name: 'Apply', exact: true })).toBeEnabled()
  })
})
