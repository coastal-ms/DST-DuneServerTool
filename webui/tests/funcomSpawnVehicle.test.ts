import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const source = readFileSync(
  resolve(process.cwd(), 'src/pages/gameplay/players/sections.tsx'),
  'utf8',
)

describe('Funcom vehicle spawn field-test list', () => {
  it('keeps Tank hidden until its game behavior is reliable', () => {
    expect(source).toContain("catalog.vehicles.filter(v => v.id !== 'Tank')")
    expect(source).toContain("cat.vehicles.find(v => v.id !== 'Tank')")
  })
})
