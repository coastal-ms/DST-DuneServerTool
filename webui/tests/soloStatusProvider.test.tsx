import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { InstallationProvider } from '../src/hooks/useInstallationMode'
import { StatusProvider, useStatus } from '../src/hooks/useStatus'

const request = vi.hoisted(() => vi.fn(async (path: string) => {
  if (path === '/api/installation') return { mode: 'solo' }
  throw new Error(`Unexpected server request: ${path}`)
}))
vi.mock('../src/api/client', () => ({ api: request }))

afterEach(() => { cleanup(); localStorage.clear(); vi.clearAllMocks() })

it('opens Solo without polling server status, restoring server indicators, or refreshing infrastructure', async () => {
  localStorage.setItem('dst.status.last.v1', JSON.stringify({ savedAt: Date.now(), status: {
    ts: new Date().toISOString(), vm: { running: true }, serverName: 'Old full installation',
  } }))
  function StatusConsumer() {
    const status = useStatus()
    return <button onClick={() => void status.forceRefresh()}>{status.status ? 'Server loaded' : 'Solo ready'}</button>
  }
  render(<InstallationProvider><StatusProvider><StatusConsumer /></StatusProvider></InstallationProvider>)
  await waitFor(() => expect(screen.queryByText('Solo ready')).not.toBeNull())
  screen.getByRole('button').click()
  await waitFor(() => expect(request).toHaveBeenCalledTimes(1))
  expect(request).toHaveBeenCalledWith('/api/installation')
})
