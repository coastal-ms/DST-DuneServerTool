import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { SoloLiveMap } from '../../src/components/solo/SoloLiveMap'
import { api } from '../../src/api/client'

vi.mock('../../src/api/client', () => ({ api: vi.fn() }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

it('keeps opening disabled until the local mod has a current DD frame', async () => {
  vi.mocked(api).mockResolvedValue({ available: false, status: 'Waiting for Deep Desert' })
  render(<SoloLiveMap connectionToken="solo-one" />)
  await screen.findByText('Waiting for Deep Desert')
  expect(screen.getByRole('button', { name: 'Open Solo Live Map' })).toBeDisabled()
  expect(api).toHaveBeenCalledWith('/api/solo/live-map')
})

it('opens through the local API and reports launch failures', async () => {
  vi.mocked(api).mockResolvedValueOnce({ available: true, status: 'Live' })
    .mockRejectedValueOnce(new Error('Companion closed'))
  render(<SoloLiveMap connectionToken="solo-one" />)
  const open = screen.getByRole('button', { name: 'Open Solo Live Map' })
  await waitFor(() => expect(open).toBeEnabled())
  fireEvent.click(open)
  expect(await screen.findByRole('alert')).toHaveTextContent('Companion closed')
  expect(api).toHaveBeenLastCalledWith('/api/solo/live-map/open', { method: 'POST', body: '{}' })
})
