// fmtToolVersion is the single UI helper for the tool's own version. It must
// always emit PLAIN semver with a "v" prefix (never the retired Roman-numeral
// stylization) — a standing product rule. These tests guard that contract.

import { describe, expect, it } from 'vitest'
import { fmtToolVersion } from '../src/format'

describe('fmtToolVersion', () => {
  it('prefixes a bare numeric version with v', () => {
    expect(fmtToolVersion('12.19.4')).toBe('v12.19.4')
    expect(fmtToolVersion('10.1.2')).toBe('v10.1.2')
  })

  it('does not double-prefix an already-v-prefixed version (case-insensitive)', () => {
    expect(fmtToolVersion('v12.19.4')).toBe('v12.19.4')
    expect(fmtToolVersion('V12.19.4')).toBe('v12.19.4')
  })

  it('trims surrounding whitespace', () => {
    expect(fmtToolVersion('  12.19.4  ')).toBe('v12.19.4')
  })

  it('returns an empty string for null / undefined / empty input', () => {
    expect(fmtToolVersion(null)).toBe('')
    expect(fmtToolVersion(undefined)).toBe('')
    expect(fmtToolVersion('')).toBe('')
    expect(fmtToolVersion('   ')).toBe('')
    expect(fmtToolVersion('v')).toBe('')
  })

  it('emits plain semver, never Roman numerals', () => {
    const out = fmtToolVersion('12.19.4')
    expect(out).toBe('v12.19.4')
    expect(out).toMatch(/^v\d+\.\d+\.\d+$/)
  })
})
