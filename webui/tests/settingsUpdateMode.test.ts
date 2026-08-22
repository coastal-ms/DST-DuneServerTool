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

  it('offers the reinstall action for the selected test build', () => {
    const source = fs.readFileSync(path.resolve(process.cwd(), 'src/pages/Settings.tsx'), 'utf8')
    expect(source).toContain("'Reinstall test build'")
    expect(source).toContain("'Re-download and reinstall the selected test build'")
    expect(source).not.toContain("updCheck.channel !== 'test' && !!updCheck.assetName")
  })
})
