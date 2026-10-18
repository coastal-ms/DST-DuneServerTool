import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function feedFreshness('), html.indexOf('function renderFeedAge('))
const freshness = new Function(body + ';return feedFreshness;')()
const now = Date.parse('2026-10-18T14:00:00Z')
const stamp = (seconds: number) => new Date(now - seconds * 1000).toISOString()
const fixture = () => ({ live: true, refreshSeconds: 3, snapshot: { observedAt: stamp(4) }, wormFeed: { capturedAt: stamp(14139) }, haggaWormFeed: { capturedAt: stamp(3) } })
describe('map update status', () => {
  it('formats old readings in hours instead of thousands of seconds', () => {
    const result = freshness(fixture(), 'DeepDesert', now)
    expect(result.database.text).toBe('Database · 4s ago')
    expect(result.positions.text).toBe('Positions · 3h 55m ago')
    expect(result.delayed).toBe(true)
  })
  it('uses the selected region and handles missing position feeds', () => {
    expect(freshness(fixture(), 'HaggaBasin', now).positions.text).toBe('Positions · 3s ago')
    expect(freshness({ live: true }, 'HaggaBasin', now).positions.text).toBe('Positions · waiting…')
  })
  it('shows updating while a new Live session replaces an old snapshot', () => {
    const current: any = fixture(); current.liveStartedAt = stamp(5)
    const result = freshness(current, 'DeepDesert', now)
    expect(result.starting).toBe(true)
    expect(result.positions.text).toBe('Positions · updating…')
    current.wormFeed.capturedAt = stamp(2)
    expect(freshness(current, 'DeepDesert', now).starting).toBe(false)
  })
  it('does not keep hiding a stalled startup behind updating', () => {
    const current: any = fixture(); current.liveStartedAt = stamp(31)
    const result = freshness(current, 'DeepDesert', now)
    expect(result.starting).toBe(false)
    expect(result.positions.text).toBe('Positions · 3h 55m ago')
    expect(result.delayed).toBe(true)
  })
  it('formats minutes and days, and clamps future timestamps', () => {
    const current = fixture()
    for (const [seconds, text] of [[123, '2m 3s'], [90000, '1d 1h'], [-5, '0s']] as const) {
      current.wormFeed.capturedAt = stamp(seconds)
      expect(freshness(current, 'DeepDesert', now).positions.text).toBe('Positions · ' + text + ' ago')
    }
  })
})
