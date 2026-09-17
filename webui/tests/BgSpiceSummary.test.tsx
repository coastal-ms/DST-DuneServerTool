import React from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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

const detailsResponse = {
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
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(resolvePromise => {
    resolve = resolvePromise
  })
  return { promise, resolve }
}

beforeEach(() => {
  vi.mocked(getSpicefields).mockResolvedValue({
    available: true,
    rows: [summaryRow],
    partitionGate: true,
  })
  vi.mocked(getSpicefieldState).mockResolvedValue(detailsResponse)
  vi.mocked(setSpicefieldSpawning).mockResolvedValue({ ok: true, row: summaryRow })
})

afterEach(() => {
  cleanup()
  vi.useRealTimers()
  vi.clearAllMocks()
})

describe('BgSpiceSummary raw field details', () => {
  it('labels an unavailable Retail primed count without presenting it as zero', async () => {
    vi.mocked(getSpicefields).mockResolvedValue({
      available: true,
      rows: [{ ...summaryRow, currentPrimed: null, currentPrimedExact: false }],
      partitionGate: true,
    })

    render(<BgSpiceSummary enabled />)

    const primed = await screen.findByLabelText(
      'Current primed count is unavailable on this server build; 3 is the configured ceiling, not a target.',
    )
    expect(primed).toHaveTextContent('N/A (cap 3)')
    expect(primed).not.toHaveTextContent('0/3')
  })

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

  it('invalidates a pending detail request when the summary is disabled', async () => {
    const pendingDetails = deferred<typeof detailsResponse>()
    vi.mocked(getSpicefieldState).mockReturnValue(pendingDetails.promise)
    const user = userEvent.setup()
    const { rerender } = render(<BgSpiceSummary enabled />)

    await user.click(await screen.findByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    }))
    expect(screen.getByRole('status')).toHaveTextContent('Loading raw field values')

    rerender(<BgSpiceSummary enabled={false} />)
    expect(screen.queryByRole('region')).not.toBeInTheDocument()

    await act(async () => {
      pendingDetails.resolve(detailsResponse)
      await pendingDetails.promise
    })
    rerender(<BgSpiceSummary enabled />)

    expect(screen.queryByRole('region')).not.toBeInTheDocument()
    expect(screen.queryByText('155,000')).not.toBeInTheDocument()
  })

  it('clears already-loaded details when the summary is disabled', async () => {
    const user = userEvent.setup()
    const { rerender } = render(<BgSpiceSummary enabled />)
    await user.click(await screen.findByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    }))
    expect(await screen.findByText('155,000')).toBeInTheDocument()

    rerender(<BgSpiceSummary enabled={false} />)
    rerender(<BgSpiceSummary enabled />)

    expect(screen.queryByRole('region')).not.toBeInTheDocument()
    expect(screen.queryByText('155,000')).not.toBeInTheDocument()
  })

  it('invalidates a pending detail request when its row leaves the visible set', async () => {
    vi.useFakeTimers()
    const pendingDetails = deferred<typeof detailsResponse>()
    vi.mocked(getSpicefieldState).mockReturnValue(pendingDetails.promise)
    vi.mocked(getSpicefields)
      .mockResolvedValueOnce({
        available: true,
        rows: [summaryRow],
        partitionGate: true,
      })
      .mockResolvedValue({
        available: true,
        rows: [{ ...summaryRow, partitionActive: false }],
        partitionGate: true,
      })
    render(<BgSpiceSummary enabled />)
    await act(async () => {})

    fireEvent.click(screen.getByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    }))
    expect(screen.getByRole('status')).toHaveTextContent('Loading raw field values')

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10000)
    })
    expect(screen.queryByRole('region')).not.toBeInTheDocument()

    await act(async () => {
      pendingDetails.resolve(detailsResponse)
      await pendingDetails.promise
    })
    expect(screen.queryByRole('region')).not.toBeInTheDocument()
    expect(screen.queryByText('155,000')).not.toBeInTheDocument()
  })

  it('clears already-loaded details when its row leaves the visible set', async () => {
    vi.useFakeTimers()
    vi.mocked(getSpicefields)
      .mockResolvedValueOnce({
        available: true,
        rows: [summaryRow],
        partitionGate: true,
      })
      .mockResolvedValue({
        available: true,
        rows: [{ ...summaryRow, partitionActive: false }],
        partitionGate: true,
      })
    render(<BgSpiceSummary enabled />)
    await act(async () => {})

    fireEvent.click(screen.getByRole('button', {
      name: 'Show raw field details for Hagga Basin Small',
    }))
    await act(async () => {})
    expect(screen.getByText('155,000')).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10000)
    })

    expect(screen.queryByRole('region')).not.toBeInTheDocument()
    expect(screen.queryByText('155,000')).not.toBeInTheDocument()
  })
})
