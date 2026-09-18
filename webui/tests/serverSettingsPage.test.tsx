import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useEffect } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import {
  api,
  ApiError,
  registerOnlinePlayerConfirmationHandler,
} from '../src/api/client'
import { ServerSettings } from '../src/pages/ServerSettings'

const state = vi.hoisted(() => ({
  status: {
    vm: { running: true },
    bg: { state: 'running', gameServers: [{ map: 'Arrakeen' }] },
  },
  forceRefresh: vi.fn(async () => {}),
}))

vi.mock('../src/hooks/useStatus', () => ({
  useStatus: () => ({ status: state.status, forceRefresh: state.forceRefresh }),
}))

vi.mock('../src/api/client', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/client')>(),
  api: vi.fn(),
}))

vi.mock('../src/pages/gameconfig/OfficialRetailServerSettingsCard', () => ({
  OfficialRetailServerSettingsCard: ({
    vmRunning,
    statusRefreshKey,
    onActionStateChange,
  }: {
    vmRunning: boolean
    statusRefreshKey?: string
    onActionStateChange?: (busy: boolean) => void
  }) => {
    useEffect(() => {
      onActionStateChange?.(false)
    }, [onActionStateChange])
    return (
      <div data-testid="retail-settings-card">
        {vmRunning ? 'VM running' : 'VM stopped'} · {statusRefreshKey}
        <button type="button" onClick={() => onActionStateChange?.(true)}>Mark settings busy</button>
      </div>
    )
  },
}))

let unregisterGuard: (() => void) | undefined

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api).mockResolvedValue({ ok: true, name: 'stop', mode: 'Console', pid: null, started: '' })
  state.status = {
    vm: { running: true },
    bg: { state: 'running', gameServers: [{ map: 'Arrakeen' }] },
  }
})

afterEach(() => {
  unregisterGuard?.()
  unregisterGuard = undefined
  cleanup()
  vi.useRealTimers()
})

describe('Server Settings page', () => {
  it('keeps both Console command controls visible with the current battlegroup state', () => {
    render(<ServerSettings />)

    expect(screen.getByRole('heading', { name: 'Server Settings' })).toBeInTheDocument()
    expect(screen.getByText(/ServerCustomSettings\.ini/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Stop Battlegroup' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeEnabled()
    expect(screen.getAllByText('Console')).toHaveLength(2)
    expect(screen.getByTestId('retail-settings-card')).toHaveTextContent('VM running · running:1')
  })

  it('retains the online-player confirmation contract and suppresses duplicate submissions', async () => {
    let answer!: (allow: boolean) => void
    unregisterGuard = registerOnlinePlayerConfirmationHandler(() => new Promise(resolve => { answer = resolve }))
    vi.mocked(api).mockRejectedValueOnce(new ApiError(409, 'Players online', {
      conflict: 'players_online',
      playersOnline: 1,
      playerNames: ['Test player'],
    }))
    render(<ServerSettings />)

    fireEvent.click(screen.getByRole('button', { name: 'Stop Battlegroup' }))
    expect(await screen.findByRole('button', { name: 'Launching stop…' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Launching stop…' }))
    expect(api).toHaveBeenCalledOnce()

    await act(async () => { answer(true) })

    expect(api).toHaveBeenNthCalledWith(1, '/api/commands/run/stop', { method: 'POST' })
    expect(api).toHaveBeenNthCalledWith(2, '/api/commands/run/stop?force=true', { method: 'POST' })
    expect(await screen.findByRole('button', { name: 'Stopping battlegroup…' })).toBeDisabled()
    expect(state.forceRefresh).toHaveBeenCalledOnce()
  })

  it('reports launch errors and allows a retry', async () => {
    vi.mocked(api).mockRejectedValueOnce(new Error('console unavailable'))
    render(<ServerSettings />)

    fireEvent.click(screen.getByRole('button', { name: 'Stop Battlegroup' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Stop failed: console unavailable')
    expect(screen.getByRole('button', { name: 'Stop Battlegroup' })).toBeEnabled()
    expect(state.forceRefresh).not.toHaveBeenCalled()
  })

  it('polls without overlap until stopped with zero pods, then reloads settings and cleans up its timer', async () => {
    vi.useFakeTimers()
    let rejectStoppedWithPod!: (reason: Error) => void
    let resolveFullyStopped!: () => void
    const stoppedWithPod = new Promise<void>((_resolve, reject) => { rejectStoppedWithPod = reject })
    const fullyStoppedRefresh = new Promise<void>(resolve => { resolveFullyStopped = resolve })
    state.forceRefresh
      .mockResolvedValueOnce(undefined)
      .mockReturnValueOnce(stoppedWithPod)
      .mockReturnValueOnce(fullyStoppedRefresh)

    const view = render(<ServerSettings />)
    fireEvent.click(screen.getByRole('button', { name: 'Stop Battlegroup' }))
    await act(async () => {})
    expect(state.forceRefresh).toHaveBeenCalledOnce()

    await act(async () => { vi.advanceTimersByTime(1000) })
    expect(state.forceRefresh).toHaveBeenCalledTimes(2)
    await act(async () => { vi.advanceTimersByTime(5000) })
    expect(state.forceRefresh).toHaveBeenCalledTimes(2)

    state.status = {
      vm: { running: true },
      bg: { state: 'stopped', gameServers: [{ map: 'Arrakeen' }] },
    }
    view.rerender(<ServerSettings />)
    await act(async () => { rejectStoppedWithPod(new Error('status temporarily unavailable')) })
    expect(screen.getByRole('button', { name: 'Stopping battlegroup…' })).toBeDisabled()
    expect(screen.getByTestId('retail-settings-card')).toHaveTextContent('stopped:1')
    expect(screen.getByRole('alert')).toHaveTextContent('status temporarily unavailable')
    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeEnabled()

    vi.mocked(api).mockRejectedValueOnce(new Error('Battlegroup still has one server pod'))
    fireEvent.click(screen.getByRole('button', { name: 'Start Battlegroup' }))
    await act(async () => {})
    expect(api).toHaveBeenLastCalledWith('/api/commands/run/start', { method: 'POST' })
    expect(screen.getByRole('alert')).toHaveTextContent('Start failed: Battlegroup still has one server pod')

    await act(async () => { vi.advanceTimersByTime(1000) })
    expect(state.forceRefresh).toHaveBeenCalledTimes(3)
    state.status = {
      vm: { running: true },
      bg: { state: 'stopped', gameServers: [] },
    }
    view.rerender(<ServerSettings />)
    await act(async () => { resolveFullyStopped() })

    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeEnabled()
    expect(screen.getByTestId('retail-settings-card')).toHaveTextContent('stopped:0')
    expect(screen.getByRole('status')).toHaveTextContent('settings are now unlocked')
    expect(vi.getTimerCount()).toBe(0)
    await act(async () => { vi.advanceTimersByTime(5000) })
    expect(state.forceRefresh).toHaveBeenCalledTimes(3)
  })

  it('launches the existing start command once and reflects the running transition', async () => {
    state.status = {
      vm: { running: true },
      bg: { state: 'stopped', gameServers: [] },
    }
    const view = render(<ServerSettings />)

    const start = await screen.findByRole('button', { name: 'Start Battlegroup' })
    await waitFor(() => expect(start).toBeEnabled())
    expect(start).toBeEnabled()
    fireEvent.click(start)
    expect(await screen.findByRole('button', { name: 'Starting battlegroup…' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Starting battlegroup…' }))

    expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/run/start', { method: 'POST' })
    expect(state.forceRefresh).toHaveBeenCalledOnce()
    expect(screen.getByRole('status')).toHaveTextContent('Start launched')

    state.status = {
      vm: { running: true },
      bg: { state: 'running', gameServers: [{ map: 'Arrakeen' }] },
    }
    view.rerender(<ServerSettings />)
    expect(await screen.findByRole('status')).toHaveTextContent('settings are now active')
    expect(screen.getByRole('button', { name: 'Stop Battlegroup' })).toBeEnabled()
  })

  it('reports start errors and allows retry without leaving the page', async () => {
    state.status = {
      vm: { running: true },
      bg: { state: 'stopped', gameServers: [] },
    }
    vi.mocked(api).mockRejectedValueOnce(new Error('start unavailable'))
    render(<ServerSettings />)

    const start = await screen.findByRole('button', { name: 'Start Battlegroup' })
    await waitFor(() => expect(start).toBeEnabled())
    fireEvent.click(start)

    expect(await screen.findByRole('alert')).toHaveTextContent('Start failed: start unavailable')
    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeEnabled()
    expect(state.forceRefresh).not.toHaveBeenCalled()
  })

  it('keeps Start disabled during settings work and reflects the running transition', async () => {
    state.status = {
      vm: { running: true },
      bg: { state: 'stopped', gameServers: [] },
    }
    const view = render(<ServerSettings />)
    fireEvent.click(screen.getByRole('button', { name: 'Mark settings busy' }))
    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeDisabled()

    fireEvent.click(screen.getByRole('button', { name: 'Start Battlegroup' }))
    expect(api).not.toHaveBeenCalled()

    state.status = {
      vm: { running: true },
      bg: { state: 'running', gameServers: [{ map: 'Arrakeen' }] },
    }
    view.rerender(<ServerSettings />)
    expect(screen.getByRole('button', { name: 'Start Battlegroup' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Stop Battlegroup' })).toBeEnabled()
  })
})
