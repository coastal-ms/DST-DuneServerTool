import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const html = readFileSync(resolve(process.cwd(), '../app/tools/DuneAtlas/index.html'), 'utf8')
const source = html.split('// Map interaction geometry:')[1].split('// End map interaction geometry.')[0]
const geometry = new Function(`// Map interaction geometry:${source}; return {mapCompactBounds,mapZoomPan,mapClampedPan}`)()

describe('Live Map viewport and navigation', () => {
  it('uses the measured toolbar instead of reserving a fixed 150 pixels on a tablet', () => {
    const bounds = geometry.mapCompactBounds(820, 440, 80, 24)
    expect(bounds.top).toBe(88)
    expect(bounds.height).toBe(312)
    expect(Math.min(bounds.width, bounds.height) - 16).toBeGreaterThan(1.4 * (440 - 194 - 48))
  })
  it('keeps the pointed map position stationary through zoom in and back out', () => {
    const viewport = { left: 8, top: 88, width: 804, height: 312 }
    const layout = { viewport, x: 262, y: 96, size: 296 }
    const point = { x: 290, y: 120 }
    const pan = geometry.mapZoomPan(layout, 1, 2, point)
    const size = layout.size * 2
    const x = viewport.left + (viewport.width - size) / 2 + pan.x
    const y = viewport.top + (viewport.height - size) / 2 + pan.y
    expect((point.x - x) / size).toBeCloseTo((point.x - layout.x) / layout.size)
    expect((point.y - y) / size).toBeCloseTo((point.y - layout.y) / layout.size)
    const restored = geometry.mapZoomPan({ viewport, x, y, size }, 2, 1, point)
    expect(restored.x).toBeCloseTo(0)
    expect(restored.y).toBeCloseTo(0)
  })
  it.each([{ x: 100000, y: 100000 }, { x: -100000, y: -100000 }])('keeps part of the map visible after a large drag: %j', offset => {
    const viewport = { left: 8, top: 88, width: 804, height: 312 }, size = 592
    const pan = geometry.mapClampedPan(viewport, size, offset)
    const x = viewport.left + (viewport.width - size) / 2 + pan.x
    const y = viewport.top + (viewport.height - size) / 2 + pan.y
    expect(Math.min(x + size, viewport.left + viewport.width) - Math.max(x, viewport.left)).toBeGreaterThanOrEqual(96)
    expect(Math.min(y + size, viewport.top + viewport.height) - Math.max(y, viewport.top)).toBeGreaterThanOrEqual(96)
  })
})
