import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import data from '../src/data/wickmaps.json'

type Poi = { type: string; name?: string }
type Seed = { seed: number; pois: Poi[] }

const seeds = data.seeds as Seed[]

describe('DD Seed Map testing-station names', () => {
  it('preserves sourced station names for every captured seed except seed 7', () => {
    for (const seed of seeds) {
      const stations = seed.pois.filter(poi => poi.type === 'testing-station')
      expect(stations.length).toBeGreaterThan(0)
      if (seed.seed === 7) {
        expect(stations.every(station => !station.name)).toBe(true)
      } else {
        expect(stations.every(station => Boolean(station.name))).toBe(true)
      }
    }
  })

  it('uses the station name in the map hover label when available', () => {
    const source = readFileSync(resolve(__dirname, '../src/pages/WickMaps.tsx'), 'utf8')
    expect(source).toContain('text: p.name ||')
    expect(source).toContain('Math.min(420, Math.max(184, hover.text.length * 7.2))')
  })
})
