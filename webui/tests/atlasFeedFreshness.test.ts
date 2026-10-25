import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function feedFreshness('), html.indexOf('let liveWait='))
const freshness = new Function(body + ';return feedFreshness;')()
const progress = new Function(body + ';return liveReadProgress;')()
const now = Date.parse('2026-10-18T14:00:00Z')
const stamp = (seconds: number) => new Date(now - seconds * 1000).toISOString()
const fixture = () => ({ live: true, refreshSeconds: 3, snapshot: { observedAt: stamp(4), servers: [] as { map: string; alive: boolean; ready: boolean }[] }, wormFeed: { capturedAt: stamp(14139) }, haggaWormFeed: { capturedAt: stamp(3) } })
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
    const current = { ...fixture(), liveStartedAt: stamp(5) }
    const result = freshness(current, 'DeepDesert', now)
    expect(result.starting).toBe(true)
    expect(result.positions.text).toBe('Positions · updating…')
    current.wormFeed.capturedAt = stamp(2)
    expect(freshness(current, 'DeepDesert', now).starting).toBe(false)
  })
  it('does not keep hiding a stalled startup behind updating', () => {
    const current = { ...fixture(), liveStartedAt: stamp(31) }
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
  it('distinguishes a slow first position read from a failed read without hiding its age', () => {
    const current = { ...fixture(), liveStartedAt: stamp(95), wormError: null as string | null }
    const result = freshness(current, 'DeepDesert', now)
    expect(result.loadingPositions).toBe(true)
    expect(result.loadingSeconds).toBe(95)
    expect(result.positions.text).toBe('Positions · 3h 55m ago')
    current.wormError = 'Read failed'
    expect(freshness(current, 'DeepDesert', now).loadingPositions).toBe(false)
    current.wormError = null; current.wormFeed.capturedAt = stamp(2)
    expect(freshness(current, 'DeepDesert', now).loadingPositions).toBe(false)
  })
  it('shows actual selected-map work while old errors survive a retry', () => {
    const current = { ...fixture(), activity: ['native', 'haggaPositions'], wormError: 'private failure detail' }
    expect(progress(current, 'DeepDesert', 95, now)).toEqual({ stage: 'Finding Deep Desert live objects', detail: 'Server data ready · 1m 35s elapsed' })
    current.activity = ['positions']
    expect(progress(current, 'DeepDesert', 96, now).stage).toBe('Reading Deep Desert positions')
    current.activity = ['haggaNative']
    expect(progress(current, 'DeepDesert', 97, now).stage).toBe('Retrying Deep Desert positions')
    expect(progress(current, 'DeepDesert', 97, now).stage).not.toContain('private')
  })
  it('distinguishes queued work, server readiness and database reads', () => {
    const current = { ...fixture(), activity: [] as string[] }
    expect(progress(current, 'DeepDesert', 4, now).stage).toBe('Waiting for Deep Desert positions')
    current.snapshot = { observedAt: stamp(100), servers: [{ map: 'DeepDesert_1', alive: false, ready: false }] }
    expect(progress(current, 'DeepDesert', 8, now).stage).toBe('Waiting for Deep Desert server')
    current.snapshot.servers[0] = { map: 'DeepDesert_1', alive: true, ready: true }
    current.activity = ['db']
    expect(progress(current, 'DeepDesert', 10, now)).toEqual({ stage: 'Reading server data', detail: 'Server data pending · 10s elapsed' })
  })
  it('clears progress after recovery or Stop live', () => {
    const current = fixture()
    expect(progress(current, 'HaggaBasin', 90, now)).toBeNull()
    current.wormFeed.capturedAt = stamp(1)
    expect(progress(current, 'DeepDesert', 90, now)).toBeNull()
    current.live = false; current.wormFeed.capturedAt = stamp(500)
    expect(progress(current, 'DeepDesert', 90, now)).toBeNull()
  })
})
