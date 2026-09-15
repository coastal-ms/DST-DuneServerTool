import React from 'react'
import { cleanup, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  getSpicefields,
  getSpicefieldState,
  setSpicefieldSpawning,
} from '../src/api/gameconfig'
import { BgSpiceSummary } from '../src/pages/dashboard/BgSpiceSummary'

vi.mock('../src/api/gameconfig', () => ({
  getSpicefields: vi.fn(),
  getSpicefieldState: vi.fn(),
  setSpicefieldSpawning: vi.fn(),
}))

const summaryRow = {
  spicefieldTypeId: 42,
  mapName: 'HaggaBasin',
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
  vi.mocked(getSpicefields).mockResolvedValue({
    available: true,
    rows: [summaryRow],
    partitionGate: true,
  })
  vi.mocked(getSpicefieldState).mockResolvedValue({
    available: true,
    spicefieldTypeId: 42,
    mapName: 'HaggaBasin',
    dimensionIndex: 0,
    requestedFieldType: 'Small',
    fieldTypeResolved: false,
    fields: [
      { fieldId: '9007199254740992', valueRemaining: '150000' },
      { fieldId: '9007199254740993', valueRemaining: '5000' },
    ],
    totalRawValueRemaining: '155000',
    totalAvailable: 12,
    returned: 2,
    truncated: true,
    source: {
      schema: 'dune.resourcefield_state',
      schemaFingerprint: 'a'.repeat(64),
      queryDurationMs: 8,
    },
  })
  vi.mocked(setSpicefieldSpawning).mockResolvedValue({ ok: true, row: summaryRow })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('BgSpiceSummary raw field details', () => {
  it('opens from an explicit row control and labels untyped raw values accurately', async () => {
    const user = userEvent.setup()
    render(<BgSpiceSummary enabled />)

    const detailsButton = await screen.findByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    })
    expect(detailsButton).toHaveAttribute('aria-expanded', 'false')

    await user.click(detailsButton)

    expect(getSpicefieldState).toHaveBeenCalledWith(42)
    expect(await screen.findByText('155,000')).toBeInTheDocument()
    expect(screen.getByText(/does not identify their Small, Medium, or Large type/i)).toBeInTheDocument()
    expect(screen.getByText(/not a proven conversion to harvestable spice/i)).toBeInTheDocument()
    expect(screen.getByText('Showing 2 of 12 active fields.')).toBeInTheDocument()

    const details = screen.getByRole('region')
    expect(within(details).getByText('9007199254740992')).toBeInTheDocument()
    expect(within(details).getByText('150,000')).toBeInTheDocument()
    expect(detailsButton).toHaveAttribute('aria-expanded', 'true')
  })

  it('closes without activating the spawning toggle', async () => {
    const user = userEvent.setup()
    render(<BgSpiceSummary enabled />)
    await user.click(await screen.findByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    }))
    await screen.findByText('155,000')

    await user.click(screen.getByRole('button', { name: 'Close' }))

    await waitFor(() => {
      expect(screen.queryByRole('region')).not.toBeInTheDocument()
    })
    expect(setSpicefieldSpawning).not.toHaveBeenCalled()
  })
})
