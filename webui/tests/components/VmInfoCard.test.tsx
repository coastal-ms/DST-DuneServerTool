import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { VmInfoCard } from '../../src/pages/database/VmInfoCard'
import {
  cleanupFailedDatabaseOperations,
  cleanupOldFuncomImages,
  getVmHealth,
} from '../../src/api/diagnostics'

vi.mock('../../src/api/diagnostics', () => ({
  cleanupFailedDatabaseOperations: vi.fn(),
  cleanupOldFuncomImages: vi.fn(),
  getVmHealth: vi.fn(),
}))

const vmHealth = {
  ok: true,
  complete: true,
  faults: [],
  disk: { usePct: 52, availK: 50_000_000, sizeK: 100_000_000, known: true },
  database: {
    phase: 'Ready',
    total: 10,
    open: 0,
    activeCount: 0,
    failedCount: 0,
    active: [],
    failed: [],
    stuck: [],
  },
  mapLimits: { known: false, entries: [] },
  images: { buildCount: 4, totalBytes: 20_000_000_000 },
  dnat: { udpRules: 34, missing: false },
  node: { diskPressure: false, memoryPressure: false, ready: true },
  swap: { totalK: 0, active: false },
}

beforeEach(() => {
  // The card's open/closed choice now persists in localStorage, so each test
  // must start from a clean slate or it inherits the previous test's toggle.
  localStorage.clear()
  vi.mocked(getVmHealth).mockResolvedValue(vmHealth)
  vi.mocked(cleanupFailedDatabaseOperations).mockResolvedValue({
    ok: true,
    complete: true,
    message: 'Removed 2 failed database operation records.',
    removedCount: 2,
    removedNames: ['dump-a', 'dump-b'],
    failedNames: [],
  })
  vi.mocked(cleanupOldFuncomImages).mockResolvedValue({
    ok: true,
    complete: true,
    message: 'Removed 2 unused old Funcom build images.',
    removedCount: 2,
    removedIds: ['sha256:a', 'sha256:b'],
    failedIds: [],
    estimatedBytes: 8_000_000_000,
    reclaimedK: 4_194_304,
    activeBuilds: [2051294],
    preservedBuilds: [2048594, 2051294],
  })
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.restoreAllMocks()
})

describe('VmInfoCard image cleanup', () => {
  it('runs cleanup only after explicit confirmation and refreshes facts', async () => {
    const user = userEvent.setup()
    render(<VmInfoCard />)

    await user.click(screen.getByRole('button', { name: /vm info/i }))
    expect(await screen.findByText(/4 · 18\.6 GB/)).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /clean old build images/i }))

    expect(window.confirm).toHaveBeenCalledOnce()
    await waitFor(() => expect(cleanupOldFuncomImages).toHaveBeenCalledOnce())
    expect(getVmHealth).toHaveBeenCalledTimes(2)
    expect(await screen.findByText(/4\.0 GiB reclaimed/)).toBeInTheDocument()
  })

  it('does nothing when confirmation is declined', async () => {
    vi.mocked(window.confirm).mockReturnValue(false)
    const user = userEvent.setup()
    render(<VmInfoCard />)

    await user.click(screen.getByRole('button', { name: /vm info/i }))
    await screen.findByText(/retained build images/i)
    await user.click(screen.getByRole('button', { name: /clean old build images/i }))

    expect(cleanupOldFuncomImages).not.toHaveBeenCalled()
  })
})

describe('VmInfoCard database operation cleanup', () => {
  it('separates active and failed operations and removes only after confirmation', async () => {
    vi.mocked(getVmHealth).mockResolvedValue({
      ...vmHealth,
      database: {
        phase: 'Ready',
        total: 62,
        open: 3,
        activeCount: 1,
        failedCount: 2,
        active: [{ name: 'restore-running', phase: 'Running', ageMinutes: 3 }],
        failed: [
          { name: 'dump-failed-a', phase: 'Failed', ageMinutes: 100 },
          { name: 'dump-failed-b', phase: 'Failed', ageMinutes: 200 },
        ],
        stuck: [
          { name: 'restore-running', phase: 'Running', ageMinutes: 3 },
          { name: 'dump-failed-a', phase: 'Failed', ageMinutes: 100 },
          { name: 'dump-failed-b', phase: 'Failed', ageMinutes: 200 },
        ],
      },
    })
    const user = userEvent.setup()
    render(<VmInfoCard />)

    await user.click(screen.getByRole('button', { name: /vm info/i }))
    expect(await screen.findByText('62 total · 2 failed · 1 active')).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /active database operations/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /failed database operations/i })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /clean failed operations/i }))

    expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('exactly Failed'))
    await waitFor(() => expect(cleanupFailedDatabaseOperations).toHaveBeenCalledOnce())
    expect(getVmHealth).toHaveBeenCalledTimes(2)
    expect(await screen.findByText(/Removed 2 failed database operation records/)).toBeInTheDocument()
  })

  it('does not clean failed operations when confirmation is declined', async () => {
    vi.mocked(window.confirm).mockReturnValue(false)
    vi.mocked(getVmHealth).mockResolvedValue({
      ...vmHealth,
      database: {
        ...vmHealth.database,
        open: 1,
        failedCount: 1,
        failed: [{ name: 'dump-failed', phase: 'Failed', ageMinutes: 100 }],
        stuck: [{ name: 'dump-failed', phase: 'Failed', ageMinutes: 100 }],
      },
    })
    const user = userEvent.setup()
    render(<VmInfoCard />)

    await user.click(screen.getByRole('button', { name: /vm info/i }))
    await user.click(await screen.findByRole('button', { name: /clean failed operations/i }))

    expect(cleanupFailedDatabaseOperations).not.toHaveBeenCalled()
  })
})
