import { describe, expect, it } from 'vitest'
import { getAtlasStationName } from '../src/atlasPoiNames'

describe('community buried-station names', () => {
  it.each([
    ['C2', 'The Forgotten Cells'], ['D4', 'The Furnace'],
    ['F6', 'The Museum'], ['H7', 'The Control Room'],
  ])('resolves the verified Layout 10 station in %s', (sector, name) => {
    expect(getAtlasStationName(10, sector, 'testing-station')).toBe(name)
  })

  it('does not carry names into another layout or an unrelated POI', () => {
    for (const layout of [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11]) {
      expect(getAtlasStationName(layout, 'F6', 'testing-station')).toBeNull()
    }
    expect(getAtlasStationName(10, 'F6', 'wreck')).toBeNull()
    expect(getAtlasStationName(10, 'A2', 'testing-station')).toBeNull()
  })
})
