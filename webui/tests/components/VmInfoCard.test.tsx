import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { VmInfoCard } from '../../src/pages/database/VmInfoCard'
import { cleanupOldFuncomImages, getVmHealth } from '../../src/api/diagnostics'

vi.mock('../../src/api/diagnostics', () => ({
  cleanupOldFuncomImages: vi.fn(),
  getVmHealth: vi.fn(),
}))

const vmHealth = {
  ok: true,
  complete: true,
  faults: [],
  disk: { usePct: 52, availK: 50_000_000, sizeK: 100_000_000, known: true },
  database: { phase: 'Ready', total: 10, open: 0, stuck: [] },
  mapLimits: { known: false, entries: [] },
  images: { buildCount: 4, totalBytes: 20_000_000_000 },
  dnat: { udpRules: 34, missing: false },
  node: { diskPressure: false, memoryPressure: false, ready: true },
  swap: { totalK: 0, active: false },
}

beforeEach(() => {
  vi.mocked(getVmHealth).mockResolvedValue(vmHealth)
  vi.mocked(cleanupOldFuncomImages).mockResolvedValue({
    ok: true,
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
