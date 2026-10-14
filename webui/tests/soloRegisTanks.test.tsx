import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloRegisTanks } from '../src/components/solo/SoloRegisTanks'
const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
it('enables bundled support before launching through the existing mod launcher', async () => {
  const state = { gamePath: 'C:/Game', platform: 'steam', gameRunning: false, mods: [] }
  request.mockResolvedValueOnce(state).mockResolvedValueOnce({ ...state, mods: [{ id: 'dst-regis-tanks', enabled: true }] }).mockResolvedValueOnce({ ok: true })
  render(<SoloRegisTanks connectionToken="test" />)
  await waitFor(() => expect(screen.getByText('Launch Solo with Tank support')).toBeEnabled())
  fireEvent.click(screen.getByText('Launch Solo with Tank support'))
  await screen.findByRole('status')
  expect(request.mock.calls.slice(1)).toEqual([['/api/solo/mods/regis-tanks/enable', { method: 'POST' }], ['/api/solo/mods/launch', { method: 'POST', body: JSON.stringify({ withMods: true }) }]])
})
it('keeps setup disabled while Dune is running', async () => {
  request.mockResolvedValue({ gamePath: 'C:/Game', platform: 'steam', gameRunning: true, mods: [] })
  render(<SoloRegisTanks connectionToken="test" />)
  await waitFor(() => expect(request).toHaveBeenCalledOnce())
  expect(screen.getByText('Enable Tank support')).toBeDisabled()
  expect(screen.getByText('Launch Solo with Tank support')).toBeDisabled()
})
