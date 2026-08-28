import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import baseline from '../../tests/fixtures/platform-baseline.json'
import maps from '../src/data/wickmaps.json'

const readSource = (relativePath: string) =>
  readFileSync(resolve(process.cwd(), 'src', relativePath), 'utf8')

describe('next-generation platform baseline', () => {
  it('pins every shipped Deep Desert seed, legend, spice sector, and marker coordinate', () => {
    expect(maps.schemaVersion).toBe(baseline.deepDesertStaticMaps.schemaVersion)
    expect(maps.availableSeeds).toEqual(baseline.deepDesertStaticMaps.availableSeeds)
    expect(maps.seeds).toHaveLength(12)

    for (const expected of baseline.deepDesertStaticMaps.seeds) {
      const actual = maps.seeds.find(seed => seed.seed === expected.seed)
      expect(actual, `seed ${expected.seed}`).toBeDefined()
      expect(actual?.poiCount).toBe(expected.poiCount)
      expect(actual?.pois).toHaveLength(expected.poiCount)
      expect(actual?.largeSpiceSectors).toEqual(expected.largeSpiceSectors)
      expect(actual?.confidence).toBe(expected.confidence)
      expect(actual?.reliability).toBe(expected.reliability)
      expect(actual?.legend.map(entry => [entry.type, entry.label, entry.count])).toEqual(expected.legend)

      const markers = actual?.pois.map(({ sector, subx, suby, type }) => ({ sector, subx, suby, type }))
      const digest = createHash('sha256').update(JSON.stringify(markers)).digest('hex')
      expect(digest).toBe(expected.markersSha256)

      for (const marker of actual?.pois ?? []) {
        expect(marker.sector).toMatch(/^[A-I][1-9]$/)
        expect(marker.subx).toBeGreaterThanOrEqual(1)
        expect(marker.subx).toBeLessThanOrEqual(4)
        expect(marker.suby).toBeGreaterThanOrEqual(0)
        expect(marker.suby).toBeLessThanOrEqual(3)
      }
    }
  })

  it('pins default visibility, attribution, and the shipped disclaimer', () => {
    const source = readSource('pages/WickMaps.tsx')
    expect(baseline.deepDesertStaticMaps.defaultHiddenTypes).toEqual([])
    expect(source).toContain('useState<Set<string>>(new Set())')
    expect(source).toContain('entry.pois.filter(p => !hidden.has(p.type))')

    for (const value of Object.values(baseline.deepDesertStaticMaps.attribution)) {
      expect(source).toContain(value)
    }
    expect(source).toContain('PAYLOAD.disclaimer')
    expect(maps.disclaimer).toBe(
      'This layout data was compiled from publicly archived community sources, not from your server. It may be incomplete or inaccurate, and the game may have changed since it was captured. Please report anything that looks wrong so it can be corrected.',
    )
  })

  it('records the current eager entry bundle separately from its relative growth budget', () => {
    const appSource = readSource('App.tsx')
    expect(appSource).not.toMatch(/\blazy\s*\(/)
    expect(baseline.recordedMeasurements.enforced).toBe(false)
    expect(baseline.recordedMeasurements.webuiBuild.javascriptAssetCount).toBe(1)
    expect(baseline.recordedMeasurements.webuiBuild.routeChunkCount).toBe(0)
    expect(baseline.budgets.initialEntryJsMaxGrowthPercent).toBe(10)
    expect(baseline.budgets.mapAnd3dMustRemainRouteLazy).toBe(true)
  })

  it('pins the read-only browser fixture to the desktop map response contract', () => {
    const mapFixture = baseline.recordedMeasurements.browserSmoke.readFixtures.mapState
    expect(mapFixture.key).toBe('deepdesert')
    expect(Object.keys(mapFixture).sort()).toEqual(
      [...baseline.backendRoutes.mapResponseRequiredKeys.desktopState].sort(),
    )
  })

  it('pins source-level AppShell containment without treating recorded widths as a live test', () => {
    const shellSource = readSource('layout/AppShell.tsx')
    expect(shellSource).toContain('h-full w-full max-w-full flex flex-col overflow-hidden')
    expect(shellSource).toContain('flex-1 min-w-0 max-w-full overflow-x-hidden overflow-y-auto')
    expect(baseline.recordedMeasurements.enforced).toBe(false)
    expect(baseline.recordedMeasurements.browserSmoke.limitation).toContain(
      'no browser automation dependency',
    )
  })
})
