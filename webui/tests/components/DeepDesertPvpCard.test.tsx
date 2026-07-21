import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { DeepDesertPvpCard } from '../../src/pages/gameconfig/DeepDesertPvpCard'
import { getDeepDesertPvp, saveDeepDesertPvp } from '../../src/api/gameconfig'

vi.mock('../../src/api/gameconfig', () => ({
  getDeepDesertPvp: vi.fn(),
  saveDeepDesertPvp: vi.fn(),
}))

const baseState = {
  ok: true,
  enabled: false,
  forceAll: false,
  selectedPartitionIds: [],
  inactiveSelectedPartitionIds: [],
  staleSelectedPartitionIds: [],
  instances: [
    {
      map: 'DeepDesert_1' as const,
      partitionId: 8,
      dimension: 0,
      phase: 'Running',
      ready: true,
      gamePort: 7779,
      serverDisplayName: 'Reapers Deep Desert',
      pvpEnabled: false,
    },
  ],
}

beforeEach(() => {
  vi.mocked(getDeepDesertPvp).mockResolvedValue(baseState)
  vi.mocked(saveDeepDesertPvp).mockResolvedValue({
    ...baseState,
    enabled: true,
    selectedPartitionIds: [8],
    instances: [{ ...baseState.instances[0], pvpEnabled: true }],
    message: 'Saved and restarting.',
    restart: { ok: true, podsFound: 1, podsDeleted: 1 },
  })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('DeepDesertPvpCard', () => {
  it('loads live partitions and applies the selected partition id', async () => {
    const user = userEvent.setup()
    render(<DeepDesertPvpCard vmRunning />)

    const master = await screen.findByRole('checkbox')
    await user.click(master)
    expect(await screen.findByText('Reapers Deep Desert')).toBeInTheDocument()
    expect(screen.getByText(/partition 8/)).toBeInTheDocument()

    await user.click(screen.getAllByRole('checkbox')[1])
    await user.click(screen.getByRole('button', { name: /apply & restart deep desert/i }))

    await waitFor(() => {
      expect(saveDeepDesertPvp).toHaveBeenCalledWith(true, [8])
    })
    expect(await screen.findByText('Saved and restarting.')).toBeInTheDocument()
  })
})
