import { describe, expect, it } from 'vitest'
import { selectWickMapSeed } from '../src/wickMapSeed'

const maps = [
  { map: 'DeepDesert', seed: 4 },
  { map: 'DeepDesert_1', seed: 5 },
]

describe('selectWickMapSeed', () => {
  it('uses the farm seed while Deep Desert is stopped', () => {
    expect(selectWickMapSeed(maps, 7, false)).toEqual({ seed: 7, source: 'farm' })
  })

  it('uses the friendly running-map output while Deep Desert is running', () => {
    expect(selectWickMapSeed(maps, 7, true)).toEqual({ seed: 4, source: 'deep-desert' })
  })

  it('keeps the current friendly-row behavior when map state is unavailable', () => {
    expect(selectWickMapSeed(maps, 7, null)).toEqual({ seed: 4, source: 'deep-desert' })
  })

  it('falls back to the partition-style row when the friendly row is missing', () => {
    expect(selectWickMapSeed([{ map: 'DeepDesert_1', seed: 3 }], 7, true))
      .toEqual({ seed: 3, source: 'deep-desert' })
  })
})
