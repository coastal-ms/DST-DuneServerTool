import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import WidgetMode from '../src/pages/WidgetMode'

const mocks = vi.hoisted(() => ({ api: vi.fn(), shell: vi.fn(), navigate: vi.fn() }))
vi.mock('../src/api/client', () => ({ api: mocks.api }))
vi.mock('../src/util/shellBridge', () => ({ isShellHost: () => true, setShellWidget: mocks.shell }))
vi.mock('../src/router', () => ({ useNavigate: () => mocks.navigate }))
beforeEach(() => {
  vi.useFakeTimers()
  vi.clearAllMocks()
  mocks.shell.mockResolvedValue(undefined)
  mocks.api.mockResolvedValue({ observedAt: new Date().toISOString(), maps: [
    { map: 'DeepDesert_1', ready: true, alive: true },
    { map: 'Survival_1', ready: true, alive: false },
  ] })
})
afterEach(() => { cleanup(); vi.useRealTimers() })
it('uses only the narrow status read, respects alive, and stops reads on exit', async () => {
  const view = render(<WidgetMode />)
  await act(async () => {})
  expect(screen.getByText('Hagga Basin')).toBeTruthy()
  expect(screen.getByText('Unavailable')).toBeTruthy()
  expect(mocks.shell).toHaveBeenCalledWith(true)
  await act(async () => { await vi.advanceTimersByTimeAsync(45_000) })
  expect(mocks.api.mock.calls.map(c => c[0])).toEqual(Array(4).fill('/api/widget/status'))
  view.unmount()
  await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
  expect(mocks.api).toHaveBeenCalledTimes(4)
})
it('restores the existing desktop before returning to full DST', async () => {
  render(<WidgetMode />)
  await act(async () => {})
  fireEvent.click(screen.getByRole('button', { name: 'Open full DST' }))
  await act(async () => {})
  expect(mocks.shell).toHaveBeenLastCalledWith(false)
  expect(mocks.navigate).toHaveBeenCalledWith('/')
})
it('marks previous ready data unknown when the connection fails', async () => {
  render(<WidgetMode />)
  await act(async () => {})
  mocks.api.mockRejectedValue(new Error('offline'))
  await act(async () => { await vi.advanceTimersByTimeAsync(15_000) })
  expect(screen.getAllByText('Unknown')).toHaveLength(2)
  expect(screen.getByText('Connection unavailable')).toBeTruthy()
})
it('uses the Solo runtime adapter without querying server maps', async () => {
  mocks.api.mockResolvedValue({ gameRunning: true })
  render(<WidgetMode soloOnly />)
  await act(async () => {})
  expect(mocks.api).toHaveBeenCalledWith('/api/solo/runtime')
  expect(screen.getByText('Ready')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Open full DST' }))
  await act(async () => {})
  expect(mocks.navigate).toHaveBeenCalledWith('/solo')
})
