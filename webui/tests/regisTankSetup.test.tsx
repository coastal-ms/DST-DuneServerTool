import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { RegisTankSetup } from '../src/pages/gameconfig/RegisTankSetup'
const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks() })

it('requires a fully stopped battlegroup before enabling', async () => {
  request.mockResolvedValue({ enabled: false, supported: true })
  render(<RegisTankSetup vmRunning stopped={false} />)
  await screen.findByText('Tank compatibility is disabled.')
  expect(screen.getByText('Enable Tank compatibility')).toBeDisabled()
})

it('enables compatibility without starting the battlegroup and reports the result', async () => {
  request.mockResolvedValueOnce({ enabled: false, supported: true }).mockResolvedValueOnce({ enabled: true, message: 'Start the battlegroup.' })
  const busy = vi.fn()
  render(<RegisTankSetup vmRunning stopped onBusyChange={busy} />)
  await waitFor(() => expect(screen.getByText('Enable Tank compatibility')).toBeEnabled())
  fireEvent.click(screen.getByText('Enable Tank compatibility'))
  await screen.findByRole('status')
  expect(request).toHaveBeenLastCalledWith('/api/gameconfig/regis-tanks', { method: 'PUT', body: JSON.stringify({ enabled: true, acknowledgeStoredTanks: false }) })
  expect(busy.mock.calls).toEqual([[true], [false]])
})

it('does not disable if the saved-Tank warning is declined', async () => {
  request.mockResolvedValue({ enabled: true, supported: true })
  vi.spyOn(window, 'confirm').mockReturnValue(false)
  render(<RegisTankSetup vmRunning stopped />)
  await waitFor(() => expect(screen.getByText('Disable Tank compatibility')).toBeEnabled())
  fireEvent.click(screen.getByText('Disable Tank compatibility'))
  expect(request).toHaveBeenCalledTimes(1)
})
