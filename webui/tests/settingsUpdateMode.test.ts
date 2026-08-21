import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'

describe('Settings updater initiation mode contract', () => {
  it('keeps update, reinstall, and Return to Stable interactive', () => {
    const source = fs.readFileSync(path.resolve(process.cwd(), 'src/pages/Settings.tsx'), 'utf8')
    const calls = source.match(/installUpdate\(\{[^}]+\}\)/g) ?? []
    expect(calls).toHaveLength(3)
    expect(calls.every(call => call.includes("mode: 'interactive'") && call.includes("source: 'settings'"))).toBe(true)
    expect(calls.filter(call => call.includes('reinstall: true'))).toHaveLength(1)
  })
})
