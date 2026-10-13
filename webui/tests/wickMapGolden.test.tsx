import { createHash } from 'node:crypto'
import React from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, describe, expect, it, vi } from 'vitest'
import data from '../src/data/wickmaps.json'
import { WickMaps } from '../src/pages/WickMaps'

vi.mock('../src/api/gameplay', () => ({
  getCoriolisSeeds: async () => ({
    source: 'live',
    maps: [{ map: 'DeepDesert', seed: 0 }],
    farm_seed: 0,
  }),
}))

vi.mock('../src/api/maps', () => ({
  getMapState: async () => ({ running: true }),
}))

afterEach(() => cleanup())

describe('Deep Desert atlas golden fixture', () => {
  it('preserves all 12 static layouts, confidence, possible spice, labels, and marker coordinates', () => {
    expect(data.availableSeeds).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    expect(data.seeds.map(seed => ({
      seed: seed.seed,
      poiCount: seed.poiCount,
      largeSpiceSectors: seed.largeSpiceSectors,
      reliability: seed.reliability,
    }))).toEqual([
      { seed: 0, poiCount: 40, largeSpiceSectors: ['F1', 'F5', 'H5', 'I8'], reliability: 'high' },
      { seed: 1, poiCount: 45, largeSpiceSectors: ['F1', 'G5', 'I1', 'I3', 'I8'], reliability: 'high' },
      { seed: 2, poiCount: 43, largeSpiceSectors: ['F4', 'G1', 'G8', 'I2', 'I5', 'I9'], reliability: 'high' },
      { seed: 3, poiCount: 54, largeSpiceSectors: ['F3', 'F9', 'G4', 'H2', 'H8'], reliability: 'medium' },
      { seed: 4, poiCount: 52, largeSpiceSectors: ['F1', 'F9', 'H5', 'I3', 'I9'], reliability: 'high' },
      { seed: 5, poiCount: 60, largeSpiceSectors: ['F5', 'F7', 'I2', 'I5', 'I9'], reliability: 'medium' },
      { seed: 6, poiCount: 51, largeSpiceSectors: ['H2', 'H8', 'I5'], reliability: 'high' },
      { seed: 7, poiCount: 30, largeSpiceSectors: ['E5', 'H2', 'H8'], reliability: 'low' },
      { seed: 8, poiCount: 58, largeSpiceSectors: ['F1', 'F4', 'F8', 'I7'], reliability: 'high' },
      { seed: 9, poiCount: 45, largeSpiceSectors: ['F1', 'F6', 'F8', 'I1', 'I9'], reliability: 'medium' },
      { seed: 10, poiCount: 49, largeSpiceSectors: ['F8', 'G1', 'H4', 'I3', 'I9'], reliability: 'high' },
      { seed: 11, poiCount: 46, largeSpiceSectors: ['F1', 'F5', 'H9', 'I2', 'I4', 'I7'], reliability: 'high' },
    ])

    const canonical = JSON.stringify(data.seeds.map(seed => ({
      seed: seed.seed,
      confidence: seed.confidence,
      reliability: seed.reliability,
      note: seed.note,
      capturedUtc: seed.capturedUtc,
      largeSpiceSectors: seed.largeSpiceSectors,
      poiCount: seed.poiCount,
      legend: seed.legend,
      pois: seed.pois,
    })))
    expect(createHash('sha256').update(canonical).digest('hex'))
      .toBe('b21bf968ae6c2f965113a3c822331a0d797935afa9f82c01de932cfecb259fbc')
  })

  it('uses the corrected Standard layout for seed 10 without substituting the Solo map or seed 5', () => {
    const seed = data.seeds.find(s => s.seed === 10)!
    expect(seed.pois).toEqual(expect.arrayContaining([
      { sector: 'I1', subx: 4, suby: 3, type: 'wreck' },
      { sector: 'H2', subx: 2, suby: 1, type: 'stravidium' },
      { sector: 'G8', subx: 2, suby: 1, type: 'titanium' },
      { sector: 'F8', subx: 2, suby: 3, type: 'large-spice-field' },
      { sector: 'D7', subx: 4, suby: 1, type: 'wreck' },
    ]))
    expect(seed.legend.reduce((count, entry) => count + entry.count, 0)).toBe(seed.pois.length)
    expect(seed.pois.filter(p => p.type === 'large-spice-field').map(p => p.sector).sort())
      .toEqual(['F8', 'G1', 'H4', 'I3', 'I9'])
    expect(seed.pois).not.toEqual(data.seeds.find(s => s.seed === 5)!.pois)
    expect(seed.pois).not.toEqual(data.seeds.find(s => s.seed === 11)!.pois)
  })

  it('keeps every marker visible by default with attribution and keyboard/touch-accessible detail', async () => {
    const user = userEvent.setup()
    render(<WickMaps embedded />)

    expect(screen.getByText('40 of 40 POIs')).toBeInTheDocument()
    expect(screen.getByText('Wick')).toBeInTheDocument()
    expect(screen.getByText('DrkShrk')).toBeInTheDocument()

    const marker = screen.getAllByRole('button', { name: / — [A-I][1-9]$/ })[0]
    marker.focus()
    await user.keyboard('{Enter}')
    expect(marker).toHaveFocus()
  })
})
