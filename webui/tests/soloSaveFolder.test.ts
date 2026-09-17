import { describe, expect, it } from 'vitest'
import { soloSaveFolder } from '../src/util/soloSaveFolder'

describe('Solo save folder selection', () => {
  const root = String.raw`C:\Example\DuneSandbox\Saved`
  it('displays the selected account directory instead of the shared Saved root', () => {
    const folder = `${root}\\Cloud\\PlayerClientStorage\\FLS_retail\\account-one`
    expect(soloSaveFolder(root, `${folder}\\game.db`)).toBe(folder)
  })
  it('follows a different selected account without hardcoding any account identifier', () => {
    const folder = `${root}\\Cloud\\PlayerClientStorage\\FLS_retail\\account-two`
    expect(soloSaveFolder(root, `${folder}\\game.db`)).toBe(folder)
  })
  it('preserves a typed folder before discovery or connection', () => {
    const folder = `${root}\\Cloud\\PlayerClientStorage\\FLS_retail\\account-two`
    expect(soloSaveFolder(folder, '')).toBe(folder)
  })
  it('handles normalized separators and case without stripping other filenames', () => {
    expect(soloSaveFolder(root, 'C:/Example/account/GAME.DB')).toBe('C:/Example/account')
    expect(soloSaveFolder(root, 'C:/Example/not-game.db')).toBe(root)
  })
})
