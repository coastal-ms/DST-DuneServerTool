import { afterEach, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { StatusProvider, useStatus } from '../src/hooks/useStatus'

const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
vi.mock('../src/hooks/useInstallationMode', () => ({ useSoloInstallation: () => false }))
vi.mock('../src/hooks/useHealthRefresh', () => ({ useHealthRefreshPreset: () => ({ statusIntervalMs: 0 }) }))

afterEach(() => { cleanup(); localStorage.clear(); vi.clearAllMocks() })

it('publishes the manual forced response immediately and rejects an older poll completing afterward', async () => {
  let finishPoll!: (value: unknown) => void
  const snapshot = (status: string) => ({
    ts: new Date().toISOString(), vm: { running: true },
    bg: { state: 'running' }, ports: { results: [{ port: 31982, status }] },
  })
  localStorage.setItem('dst.status.last.v1', JSON.stringify({ savedAt: Date.now(), status: snapshot('closed') }))
  request.mockImplementation((path: string) => {
    if (path === '/api/status') return new Promise(resolve => { finishPoll = resolve })
    if (path === '/api/status/refresh') return Promise.resolve(snapshot('open'))
    throw new Error(`Unexpected ${path}`)
  })
  function Consumer() {
    const status = useStatus()
    return <button onClick={() => void status.forceRefresh()}>{status.status?.ports?.results[0].status}</button>
  }
  render(<StatusProvider><Consumer /></StatusProvider>)
  fireEvent.click(screen.getByRole('button', { name: 'closed' }))
  await waitFor(() => expect(screen.getByRole('button')).toHaveTextContent('open'))
  expect(request).toHaveBeenCalledWith('/api/status/refresh', { method: 'POST' })
  await act(async () => { finishPoll(snapshot('closed')) })
  expect(screen.getByRole('button')).toHaveTextContent('open')
  expect(request.mock.calls.filter(([path]) => path === '/api/status')).toHaveLength(1)
  expect(JSON.parse(localStorage.getItem('dst.status.last.v1')!).status.ports.results[0].status).toBe('open')
})
