import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, withOnlinePlayerGuard } from '../../src/api/client'

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

describe('online player guard', () => {
  it('shows player details and retries only after confirmation', async () => {
    const confirm = vi.fn(() => true)
    vi.stubGlobal('confirm', confirm)
    const operation = vi.fn(async (force: boolean) => {
      if (!force) {
        throw new ApiError(409, 'conflict', {
          ok: false,
          conflict: 'players_online',
          playersOnline: 2,
          playerNames: ['Vospers', 'Fargan'],
          players: [],
          message: 'Restarting will disconnect them.',
        })
      }
      return 'done'
    })

    await expect(withOnlinePlayerGuard(operation)).resolves.toBe('done')
    expect(operation.mock.calls).toEqual([[false], [true]])
    expect(confirm.mock.calls[0][0]).toContain('Vospers, Fargan')
    expect(confirm.mock.calls[0][0]).toContain('Restarting will disconnect them.')
  })

  it('does not retry when the operator cancels', async () => {
    vi.stubGlobal('confirm', vi.fn(() => false))
    const operation = vi.fn(async () => {
      throw new ApiError(409, 'conflict', {
        conflict: 'players_online',
        playersOnline: 1,
        playerNames: ['Vospers'],
      })
    })

    await expect(withOnlinePlayerGuard(operation)).rejects.toThrow(
      'Action cancelled because players are online.',
    )
    expect(operation).toHaveBeenCalledTimes(1)
  })

  it('requires confirmation before forcing when player status is unknown', async () => {
    const confirm = vi.fn(() => true)
    vi.stubGlobal('confirm', confirm)
    const operation = vi.fn(async (force: boolean) => {
      if (!force) {
        throw new ApiError(409, 'conflict', {
          conflict: 'player_status_unknown',
          playersOnline: null,
          playerNames: [],
          message: 'DST could not verify whether players are online.',
        })
      }
      return 'forced'
    })

    await expect(withOnlinePlayerGuard(operation)).resolves.toBe('forced')
    expect(operation.mock.calls).toEqual([[false], [true]])
    expect(confirm.mock.calls[0][0]).toContain('Continue without verification?')
  })
})
