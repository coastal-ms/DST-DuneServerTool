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
  currentActive: null,
  isSpawningActive: true,
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

describe('SpicefieldsCard current Funcom settings', () => {
  it('does not infer active field counts from resource values', async () => {
    vi.mocked(getSpicefields).mockResolvedValue({
      available: true,
      adapter: 'retail-config',
      rows: [{
        ...row,
        maxActive: 10,
        maxPrimed: 10,
        defaultMaxActive: 5,
        defaultMaxPrimed: 5,
        guidanceMax: 5,
        configuredOverride: true,
        adapter: 'retail-config' as const,
      }],
    })

    render(<SpicefieldsCard vmRunning />)

    expect(await screen.findByText(/Current active count by size is unavailable/)).toBeInTheDocument()
    expect(screen.queryByText('Active on map')).not.toBeInTheDocument()
    expect(screen.queryByText('Primed to spawn')).not.toBeInTheDocument()
    expect(screen.queryByText(/N\/A/)).not.toBeInTheDocument()
    expect(screen.getByText('Max primed')).toBeInTheDocument()
    expect(screen.getByText(/Configured override\./)).toHaveTextContent(
      'Configured override. Funcom default: 5 active / 5 primed. DST guidance: 5 for both.',
    )
    expect(screen.getAllByText('Spawning').length).toBeGreaterThan(0)
  })

  it('labels a changed Funcom default separately from DST guidance', async () => {
    vi.mocked(getSpicefields).mockResolvedValue({
      available: true,
      adapter: 'retail-config',
      rows: [{
        ...row,
        maxActive: 10,
        maxPrimed: 10,
        defaultMaxActive: 10,
        defaultMaxPrimed: 10,
        guidanceMax: 5,
        configuredOverride: false,
        adapter: 'retail-config' as const,
      }],
    })

    render(<SpicefieldsCard vmRunning />)

    expect(await screen.findByText(/Current configuration\./)).toHaveTextContent(
      'Current configuration. Funcom default: 10 active / 10 primed. DST guidance: 5 for both.',
    )
  })
})
