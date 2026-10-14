import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { StartupSettingsSync } from '../src/pages/gameconfig/StartupSettingsSync'

const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

it('cancels opt-out without changing the checkbox or writing configuration', async () => {
  request.mockResolvedValueOnce({enabled:true})
  render(<StartupSettingsSync />)
  const toggle = screen.getByRole('checkbox')
  await waitFor(() => expect(toggle).toBeEnabled())
  fireEvent.click(toggle)
  fireEvent.click(screen.getByRole('button', {name:'Cancel'}))
  expect(toggle).toBeChecked()
  expect(request).toHaveBeenCalledTimes(1)
})

it('defaults to DST management and shows the responsibility notice after opt-out', async () => {
  request.mockResolvedValueOnce({ enabled: true }).mockResolvedValueOnce({ enabled: false })
  const busy = vi.fn()
  render(<StartupSettingsSync onBusyChange={busy} />)
  const toggle = screen.getByRole('checkbox', { name: 'Let DST manage server configuration' })
  await waitFor(() => expect(toggle).toBeEnabled())
  expect(toggle).toBeChecked()
  fireEvent.click(toggle)
  expect(screen.getByRole('alertdialog')).toBeInTheDocument()
  expect(request).toHaveBeenCalledTimes(1)
  expect(toggle).toBeChecked()
  fireEvent.click(screen.getByRole('button', { name: 'Disable management' }))
  await waitFor(() => expect(toggle).not.toBeChecked())
  expect(screen.getByRole('note')).toHaveTextContent('You assume responsibility')
  expect(screen.getByText(/Applies to Solo and self-hosted/)).toBeInTheDocument()
  expect(request).toHaveBeenLastCalledWith('/api/gameconfig/retail-startup-sync', { method: 'PUT', body: JSON.stringify({ enabled: false }) })
  expect(busy.mock.calls).toEqual([[true], [false]])
  expect(request.mock.calls.every(([path]) => path === '/api/gameconfig/retail-startup-sync')).toBe(true)
})

it('loads the saved disabled preference and lets the user turn synchronization back on', async () => {
  request.mockResolvedValueOnce({ enabled: false }).mockResolvedValueOnce({ enabled: true })
  render(<StartupSettingsSync />)
  const toggle = screen.getByRole('checkbox')
  await waitFor(() => expect(toggle).toBeEnabled())
  expect(toggle).not.toBeChecked()
  fireEvent.click(toggle)
  await waitFor(() => expect(toggle).toBeChecked())
  expect(screen.getByRole('status')).toHaveTextContent('Use Apply INIs')
  expect(request).toHaveBeenLastCalledWith('/api/gameconfig/retail-startup-sync', { method: 'PUT', body: JSON.stringify({ enabled: true }) })
})

it('keeps the confirmed preference when saving fails', async () => {
  request.mockResolvedValueOnce({ enabled: true }).mockRejectedValueOnce(new Error('Save failed'))
  render(<StartupSettingsSync />)
  const toggle = screen.getByRole('checkbox')
  await waitFor(() => expect(toggle).toBeEnabled())
  fireEvent.click(toggle)
  fireEvent.click(screen.getByRole('button', { name: 'Disable management' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Save failed')
  expect(toggle).toBeChecked()
})
