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
      { seed: 6, poiCount: 47, largeSpiceSectors: ['H2', 'H8', 'I5'], reliability: 'high' },
      { seed: 7, poiCount: 30, largeSpiceSectors: ['E5', 'H2', 'H8'], reliability: 'low' },
      { seed: 8, poiCount: 58, largeSpiceSectors: ['F1', 'F4', 'F8', 'I7'], reliability: 'high' },
      { seed: 9, poiCount: 45, largeSpiceSectors: ['F1', 'F6', 'F8', 'I1', 'I9'], reliability: 'medium' },
      { seed: 10, poiCount: 59, largeSpiceSectors: ['F7', 'I2', 'I5', 'I9'], reliability: 'low' },
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
      .toBe('148a2524adeb117e14edb2ee26c65df7537acc354993813548f2170c41c8d1d8')
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
