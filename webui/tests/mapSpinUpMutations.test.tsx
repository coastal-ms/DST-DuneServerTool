import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MapSpinUp } from '../src/pages/MapSpinUp'
import { getMapSpinUp, setMapPartySharing, setMapSpinUp } from '../src/api/mapSpinUp'

vi.mock('../src/api/mapSpinUp', () => ({
  getMapSpinUp: vi.fn(),
  setMapSpinUp: vi.fn(),
  setMapPartySharing: vi.fn(),
}))
vi.mock('../src/api/maps', () => ({
  fixOnDemandPartitions: vi.fn(),
  getMapState: vi.fn(),
  restartMapPods: vi.fn(),
}))
vi.mock('../src/hooks/useStatus', () => ({
  useStatus: () => ({ status: { vm: { running: true } } }),
}))
vi.mock('../src/hooks/useReducedRoutineUi', () => ({
  confirmRoutineAction: vi.fn(),
}))
vi.mock('../src/pages/gameconfig/SpicefieldsCard', () => ({
  SpicefieldsCard: () => null,
}))

const map = {
  map: 'CB_Story_DestroyedZanovar',
  label: 'Zanovar',
  group: 'supported' as const,
  minServers: 0,
  enabled: false,
  supportsPartySharing: true,
  sharedParties: false,
}

beforeEach(() => {
  localStorage.clear()
  vi.mocked(getMapSpinUp).mockResolvedValue({ ok: true, maps: [map] })
})

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

describe('Map Spin-Up mutation feedback', () => {
  it('keeps a failed toggle result visible after refresh without a success-styled duplicate', async () => {
    const user = userEvent.setup()
    vi.mocked(setMapSpinUp).mockResolvedValue({
      ok: false,
      map: map.map,
      message: 'Spin-up update failed.',
    })
    render(<MapSpinUp embedded />)

    await screen.findByText('Zanovar')
    await user.click(screen.getAllByRole('checkbox')[0])

    await waitFor(() => expect(getMapSpinUp).toHaveBeenCalledTimes(2))
    expect(screen.getByText('Spin-up update failed.')).toHaveClass('text-danger')
    expect(screen.getAllByText('Spin-up update failed.')).toHaveLength(1)
  })

  it('keeps a rejected party-sharing mutation visible after refresh', async () => {
    const user = userEvent.setup()
    vi.mocked(setMapPartySharing).mockRejectedValue(new Error('Party-sharing request failed.'))
    render(<MapSpinUp embedded />)

    await user.click(await screen.findByRole('checkbox', { name: /Shared multiplayer/ }))

    await waitFor(() => expect(getMapSpinUp).toHaveBeenCalledTimes(2))
    expect(screen.getByText(/Party-sharing request failed\./)).toHaveClass('text-danger')
  })
})
