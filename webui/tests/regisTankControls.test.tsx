import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { RegisTankControls } from '../src/pages/gameplay/players/RegisTankControls'
const request = vi.hoisted(() => vi.fn())
vi.mock('../src/api/client', () => ({ api: request }))
afterEach(() => { cleanup(); vi.resetAllMocks() })

it('offers both variants only after server compatibility is verified', async () => {
  request.mockResolvedValue({ enabled: true, message: 'Enabled' })
  const grant = vi.fn()
  render(<RegisTankControls actorId={544} online busy={false} onGrant={grant} />)
  await waitFor(() => expect(screen.getByText('Grant Dart Tank')).toBeEnabled())
  fireEvent.click(screen.getByText('Grant Dart Tank'))
  fireEvent.click(screen.getByText('Grant Flamethrower Tank'))
  expect(grant.mock.calls).toEqual([['T6_CombatDart'], ['T6_CombatFire']])
})

it('keeps both grants disabled for unsupported builds and offline players', async () => {
  request.mockResolvedValue({ enabled: false, message: 'Unsupported build' })
  render(<RegisTankControls actorId={544} online={false} busy={false} onGrant={vi.fn()} />)
  await screen.findByText('Unsupported build')
  expect(screen.getByText('Grant Dart Tank')).toBeDisabled()
  expect(screen.getByText('Grant Flamethrower Tank')).toBeDisabled()
})
