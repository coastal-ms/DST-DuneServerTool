import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'

const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const source = html.slice(html.indexOf('function observationAvailable('), html.indexOf('\n', html.indexOf('function observationAvailable(')))
const now = Date.parse('2026-10-24T05:00:00Z')
const native = { pid: 10, startTime: '20', capturedAt: new Date(now - 1000).toISOString() }
const frame = (offset: number) => ({ ...native, capturedAt: new Date(now + offset).toISOString() })
function available(current: object, time = now) {
  return new Function('state', 'observationNow', 'regionNative', 'refreshSeconds', source + ';return observationAvailable')(
    current, () => time, () => native, 3,
  )
}

describe('live observation clock tolerance', () => {
  it('keeps incoming markers visible across small VM/browser clock differences', () => {
    const check = available({ live: true })
    for (const offset of [-1000, 319, 5000, -500, 200]) expect(check(frame(offset), 12000)).toBe(true)
  })
  it('still rejects excessive future timestamps, stale readings and a different game process', () => {
    const check = available({ live: true })
    expect(check(frame(5001), 12000)).toBe(false)
    expect(check(frame(-12001), 12000)).toBe(false)
    expect(check({ ...frame(0), pid: 11 }, 12000)).toBe(false)
    expect(check({ ...frame(0), startTime: '21' }, 12000)).toBe(false)
  })
  it('does not admit observations after a frozen snapshot timestamp', () => {
    const check = available({ live: false, frozenAt: new Date(now).toISOString() })
    expect(check(frame(319), 12000)).toBe(false)
    expect(check(frame(-1000), 12000)).toBe(true)
  })
})
