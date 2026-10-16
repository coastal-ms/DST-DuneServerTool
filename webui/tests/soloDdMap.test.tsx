import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { SoloMode } from '../src/pages/SoloMode'
import { getCoriolisSeeds } from '../src/api/gameplay'
import { getMapState } from '../src/api/maps'

vi.mock('../src/hooks/useApi', () => ({
  useApi: () => ({ data: null, loading: false, error: null, refresh: vi.fn() }),
}))
vi.mock('../src/api/gameplay', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/gameplay')>(),
  getCoriolisSeeds: vi.fn(),
}))
vi.mock('../src/api/maps', () => ({ getMapState: vi.fn() }))

afterEach(() => { cleanup(); vi.clearAllMocks() })

it('keeps Deck setup in its own tab immediately after the Solo map', () => {
  render(<SoloMode />)
  const map = screen.getByRole('button', { name: 'DD Map', exact: true })
  const deck = screen.getByRole('button', { name: 'Steam Deck', exact: true })
  expect(map.nextElementSibling).toBe(deck)
  expect(screen.queryByText('Solo device')).not.toBeInTheDocument()
  expect(screen.queryByRole('heading', { name: 'Steam Deck', exact: true })).not.toBeInTheDocument()
  fireEvent.click(deck)
  expect(screen.getByRole('heading', { name: 'Steam Deck', exact: true })).toBeInTheDocument()
  expect(screen.queryByText('Solo Deep Desert')).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Overview', exact: true }))
  expect(screen.queryByRole('heading', { name: 'Steam Deck', exact: true })).not.toBeInTheDocument()
})

it('opens the Solo reference map beside Progression without a connected save or self-hosted seed lookup', () => {
  render(<SoloMode />)
  const progression = screen.getByRole('button', { name: 'Progression', exact: true })
  const map = screen.getByRole('button', { name: 'DD Map', exact: true })
  expect(progression.nextElementSibling).toBe(map)
  fireEvent.click(map)
  expect(screen.getByText('Solo Deep Desert')).toBeInTheDocument()
  expect(screen.getByText('46 of 46 POIs')).toBeInTheDocument()
  expect(screen.getByText(/Single Player reference layout matches Seed 11/)).toBeInTheDocument()
  expect(getCoriolisSeeds).not.toHaveBeenCalled()
  expect(getMapState).not.toHaveBeenCalled()
  expect(screen.queryByText('Reading the current seed…')).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: '10', exact: true })).not.toBeInTheDocument()
  fireEvent.click(screen.getByTitle('Hide Large Spice Field'))
  expect(screen.getByText('40 of 46 POIs')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Show all' }))
  expect(screen.getByText('46 of 46 POIs')).toBeInTheDocument()
})
