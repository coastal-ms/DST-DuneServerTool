import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import WidgetMode from '../src/pages/WidgetMode'

const mocks = vi.hoisted(() => ({ api: vi.fn(), shell: vi.fn(), navigate: vi.fn() }))
vi.mock('../src/api/client', () => ({ api: mocks.api }))
vi.mock('../src/util/shellBridge', () => ({ isShellHost: () => true, setShellWidget: mocks.shell }))
vi.mock('../src/pages/WickMaps', () => ({ WickMaps: () => <div>Solo seed map</div> }))
vi.mock('../src/components/solo/SoloLiveMap', () => ({ SoloLiveMap: () => <button>Open Solo Live Map</button> }))
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
it('shows the Solo seed map and Live Map launcher without querying server maps', async () => {
  mocks.api.mockResolvedValue({ gameRunning: true })
  render(<WidgetMode soloOnly />)
  await act(async () => {})
  expect(mocks.api).not.toHaveBeenCalled()
  expect(screen.getByText('Solo seed map')).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Open Solo Live Map' })).toBeTruthy()
  expect(mocks.shell).toHaveBeenCalledWith(true, 'solo-map')
  fireEvent.click(screen.getByRole('button', { name: 'Open full DST' }))
  await act(async () => {})
  expect(mocks.navigate).toHaveBeenCalledWith('/solo')
})

it('leaves Connecting when a status request stalls and retries after the timeout', async () => {
  mocks.api.mockImplementation((_path: string, init: RequestInit) => new Promise((_resolve, reject) => {
    init.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')))
  }))
  render(<WidgetMode />)
  expect(screen.getByText('Connecting...')).toBeTruthy()
  await act(async () => { await vi.advanceTimersByTimeAsync(15_000) })
  expect(screen.getByText('Connection unavailable')).toBeTruthy()
  expect(screen.queryByText('Connecting...')).toBeNull()
  await act(async () => { await vi.advanceTimersByTimeAsync(15_000) })
  expect(mocks.api).toHaveBeenCalledTimes(2)
})
