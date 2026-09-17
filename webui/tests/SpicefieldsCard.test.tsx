import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getSpicefields, saveSpicefield, setSpicefieldSpawning } from '../src/api/gameconfig'
import { SpicefieldsCard } from '../src/pages/gameconfig/SpicefieldsCard'

vi.mock('../src/api/gameconfig', () => ({
  getSpicefields: vi.fn(),
  saveSpicefield: vi.fn(),
  setSpicefieldSpawning: vi.fn(),
}))

const row = {
  spicefieldTypeId: 42,
  mapName: 'Hagga Basin',
  mapId: 'Survival_1',
  fieldType: 'Small',
  dimensionIndex: 0,
  maxActive: 5,
  maxPrimed: 3,
  currentActive: 2,
  currentPrimed: 1,
  isSpawningActive: true,
  spawnWeight: 1,
  partitionActive: true,
}

beforeEach(() => {
  localStorage.clear()
  vi.mocked(saveSpicefield).mockResolvedValue({ ok: true, row })
  vi.mocked(setSpicefieldSpawning).mockResolvedValue({ ok: true, row })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('SpicefieldsCard primed status', () => {
  it('hides Retail primed status while retaining Max primed configuration', async () => {
    vi.mocked(getSpicefields).mockResolvedValue({
      available: true,
      adapter: 'retail-config',
      rows: [{ ...row, adapter: 'retail-config' as const, currentPrimed: null, currentPrimedExact: false }],
    })

    render(<SpicefieldsCard vmRunning />)

    expect(await screen.findByText('Active on map')).toBeInTheDocument()
    expect(screen.queryByText('Primed to spawn')).not.toBeInTheDocument()
    expect(screen.queryByText(/N\/A/)).not.toBeInTheDocument()
    expect(screen.getByText('Max primed')).toBeInTheDocument()
    expect(screen.getAllByText('Spawning').length).toBeGreaterThan(0)
  })

  it('keeps exact current primed status for legacy database rows', async () => {
    vi.mocked(getSpicefields).mockResolvedValue({
      available: true,
      adapter: 'legacy-db',
      rows: [{ ...row, adapter: 'legacy-db' as const, currentPrimedExact: true }],
    })

    render(<SpicefieldsCard vmRunning />)

    expect(await screen.findByText('Primed to spawn')).toBeInTheDocument()
    expect(screen.getByText('Max primed')).toBeInTheDocument()
  })
})
