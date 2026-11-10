import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { SoloMode } from '../src/pages/SoloMode'

const fixture = vi.hoisted(() => ({
  status: { connected: true, dataRoot: 'C:\\Solo', dbPath: 'C:\\Solo\\game.db', profileToken: 'fixture-profile', profiles: [] },
  settings: { entries: [{ key: 'm_DayLengthMinutes', value: '45.5', present: true, needsApply: false }] },
  runtime: { gameRunning: false, processes: [] },
}))
vi.mock('../src/hooks/useApi', () => ({ useApi: (path: string) => ({
  data: path === '/api/solo/status' ? fixture.status
    : path === '/api/solo/settings' ? fixture.settings
    : path === '/api/solo/runtime' ? fixture.runtime : null,
  loading: false, error: null, refresh: vi.fn(),
}) }))
afterEach(() => { cleanup(); localStorage.clear() })

it('shows the existing day length in minutes and allows decimal edits in World and economy', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Settings', exact: true }))
  const input = screen.getByRole('spinbutton', { name: 'Day length (minutes)', exact: true })
  expect(input).toHaveValue(45.5)
  expect(screen.getByText('World and economy')).toBeInTheDocument()
  expect(screen.getByText(/Default: 30 minutes. Leave blank to remove the override/)).toBeInTheDocument()
  fireEvent.change(input, { target: { value: '90.25' } })
  expect(input).toHaveValue(90.25)
  fireEvent.change(input, { target: { value: '' } })
  expect(input).toHaveValue(null)
})
