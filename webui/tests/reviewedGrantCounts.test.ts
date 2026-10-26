import { describe, expect, it, vi } from 'vitest'
vi.mock('../src/api/client', () => ({ api: vi.fn() }))
import { api } from '../src/api/client'
import { getReviewedGrantCounts } from '../src/api/gameplay'

describe('reviewed grant counts response', () => {
  it('unwraps the player route result envelope', async () => {
    vi.mocked(api).mockResolvedValueOnce({ ok: true, result: { total: 1, owned: 1, remaining: 0, entries: [{id: 'Saved', owned: true}] } })
    expect(await getReviewedGrantCounts(1, 2, 3, 'ObservedCharacterSwatches')).toEqual({ total: 1, owned: 1, remaining: 0, entries: [{id: 'Saved', owned: true}] })
  })
  it('rejects missing count fields instead of displaying undefined', async () => {
    vi.mocked(api).mockResolvedValueOnce({ ok: true, result: {} })
    await expect(getReviewedGrantCounts(1, 2, 3, 'ObservedCharacterSwatches')).rejects.toThrow('Character counts unavailable')
  })
  it.each([
    {total: 1, owned: 0, remaining: 1, entries: [{value: [{id: 'A', owned: false}], Count: 1}]},
    {total: 1, owned: 0, remaining: 1, entries: [{id: null, owned: false}]},
    {total: 1, owned: 0, remaining: 1, entries: {}},
    {total: 1, owned: 0, remaining: 1, entries: []},
    {total: 1, owned: 1, remaining: 0, entries: [{id: 'A', owned: false}]},
  ])('rejects an unusable preview before rendering', async result => {
    vi.mocked(api).mockResolvedValueOnce({ok: true, result})
    await expect(getReviewedGrantCounts(1, 2, 3, 'ObservedCharacterSwatches')).rejects.toThrow('Character counts unavailable')
  })
})