import { describe, expect, it, vi } from 'vitest'
vi.mock('../src/api/client', () => ({ api: vi.fn() }))
import { api } from '../src/api/client'
import { getReviewedGrantCounts } from '../src/api/gameplay'

describe('reviewed grant counts response', () => {
  it('unwraps the player route result envelope', async () => {
    vi.mocked(api).mockResolvedValueOnce({ ok: true, result: { total: 311, owned: 311, remaining: 0 } })
    expect(await getReviewedGrantCounts(1, 2, 3, 'ObservedCharacterSwatches')).toEqual({ total: 311, owned: 311, remaining: 0 })
  })
  it('rejects missing count fields instead of displaying undefined', async () => {
    vi.mocked(api).mockResolvedValueOnce({ ok: true, result: {} })
    await expect(getReviewedGrantCounts(1, 2, 3, 'ObservedCharacterSwatches')).rejects.toThrow('Character counts unavailable')
  })
})