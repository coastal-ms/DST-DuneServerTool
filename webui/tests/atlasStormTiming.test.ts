import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function stormTimingGuide('), html.indexOf('function renderStormTiming('))
const guide = new Function(body + '; return stormTimingGuide;')()
const now = Date.parse('2026-10-18T10:00:00Z')
function fixture() {
  return { native: { pid: 11, startTime: '22', capturedAt: new Date(now).toISOString(), stormSchedule: { enabled: true, minimumSeconds: 3300, maximumSeconds: 3900 } },
    stormHistory: [{ map: 'DeepDesert', pid: 11, startTime: '22', capturedAt: '2026-10-18T09:15:00Z', storms: [{ total: 900, remaining: 300 }] }] }
}
describe('storm timing guide', () => {
  it('uses the observed start and current spawn range for a time window', () => {
    const result = guide(fixture(), 'DeepDesert', now)
    expect(result.lastStartedAt).toBe(Date.parse('2026-10-18T09:05:00Z'))
    expect(result.earliestAt).toBe(now)
    expect(result.latestAt).toBe(now + 600_000)
  })
  it('does not invent another cycle after an unobserved window expires', () => {
    const current = fixture(); current.native.capturedAt = new Date(now + 700_000).toISOString()
    expect(guide(current, 'DeepDesert', now + 700_000).latestAt).toBeUndefined()
  })
  it('discards anchors from another world process after a restart', () => {
    const current = fixture(); current.native.pid = 12
    expect(guide(current, 'DeepDesert', now).lastStartedAt).toBeUndefined()
  })
  it('does not use another map or stale native identity to forecast', () => {
    expect(guide(fixture(), 'HaggaBasin', now)).toBeNull()
    const current = fixture(); current.native.capturedAt = '2026-10-18T09:50:00Z'
    expect(guide(current, 'DeepDesert', now).latestAt).toBeUndefined()
  })
  it('uses a newer active storm observation and supports fixed configured intervals', () => {
    const current: any = fixture(); current.native.stormSchedule.maximumSeconds = 3300
    current.wormFeed = { pid: 11, startTime: '22', capturedAt: new Date(now).toISOString(), storms: [{ total: 900, remaining: 900 }] }
    const result = guide(current, 'DeepDesert', now)
    expect(result.earliestAt).toBe(now + 3300_000); expect(result.latestAt).toBe(result.earliestAt)
  })
  it('prefers the automatic log anchor over a manually observed storm', () => {
    const current: any = fixture(); current.native.stormSchedule.lastSpawnAt = '2026-10-18T09:10:00Z'
    current.wormFeed = { pid: 11, startTime: '22', capturedAt: new Date(now).toISOString(), storms: [{ total: 900, remaining: 900 }] }
    expect(guide(current, 'DeepDesert', now).lastStartedAt).toBe(Date.parse('2026-10-18T09:10:00Z'))
  })
  it('handles disabled schedules, invalid ranges, and missing elapsed times', () => {
    const current: any = fixture(); current.native.stormSchedule.enabled = false
    expect(guide(current, 'DeepDesert', now).enabled).toBe(false)
    current.native.stormSchedule.enabled = true; current.native.stormSchedule.maximumSeconds = -1
    expect(guide(current, 'DeepDesert', now)).toBeNull()
    current.native.stormSchedule.maximumSeconds = 3900; current.stormHistory[0].storms[0].remaining = null
    expect(guide(current, 'DeepDesert', now).lastStartedAt).toBeUndefined()
  })
})
