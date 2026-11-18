import { createRequire } from 'node:module'
import { resolveConfig } from 'vite'
import { expect, it } from 'vitest'

const require = createRequire(import.meta.url)

it('preserves the glob operations used to discover build inputs', () => {
  const match = require('picomatch')
  expect(match.scan('/src/**/*.{ts,tsx}', { parts: true })).toEqual({
    base: '/src',
    isGlob: true,
    negated: false,
    parts: ['/src', '**', '*.{ts,tsx}'],
  })
  expect(match.isMatch('src/index.ts', ['**/*.tsx', '**/*.ts'])).toBe(true)
  expect(match.isMatch('src/index.ts', ['**/*.tsx'])).toBe(false)
  expect(match('src/**', { ignore: ['**/node_modules/**'] })('src/node_modules/input.ts')).toBe(false)
  expect(match('!(ignored).ts')('kept.ts')).toBe(true)
  expect(match('!(ignored).ts')('ignored.ts')).toBe(false)
  expect(match.makeRe('**/.env.*', { dot: true, nocase: true })).toBeInstanceOf(RegExp)
  expect(match.makeRe('**/.env.*', { dot: true, nocase: true }).test('/project/.ENV.local')).toBe(true)
})

it('keeps sensitive files blocked by Vite on Windows and Unix paths', async () => {
  const config = await resolveConfig({ configFile: false }, 'serve')
  expect(config.fsDenyGlob('/project/.env.local')).toBe(true)
  expect(config.fsDenyGlob('C:/Project/.ENV')).toBe(true)
  expect(config.fsDenyGlob('/project/.git/config')).toBe(true)
  expect(config.fsDenyGlob('/project/src/index.ts')).toBe(false)
})
