import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { COMMAND_CATEGORIES, getCommandCategory } from '../src/pages/commands/categories'
import type { Command } from '../src/api/types'

describe('Command purpose categories', () => {
  it('assigns each shipped backend command to exactly one explicit category', () => {
    const source = readFileSync(resolve(process.cwd(), '..', 'app', 'server', 'lib', 'Commands.ps1'), 'utf8')
    const catalog = [...source.matchAll(/@\{\s*Section='[^']+';\s*Key='[^']+';\s*Name='([^']+)'/g)].map(match => match[1])
    const categorized = COMMAND_CATEGORIES.flatMap(category => [...category.commands])
    expect(catalog.length).toBeGreaterThan(20)
    expect([...categorized].sort()).toEqual([...catalog].sort())
    expect(new Set(categorized).size).toBe(categorized.length)
    expect(COMMAND_CATEGORIES.every(category => category.commands.length >= 2 && category.commands.length <= 7)).toBe(true)
  })
  it.each([['VM', 'vm'], ['Battlegroup', 'battlegroup'], ['Tools', 'tools']])('keeps future %s commands reachable', (section, expected) => {
    const command: Command = { name: 'future-operation', section, label: '', key: '', mode: 'Console', requires: 'none', desc: '', available: true, reason: '', external: false }
    expect(getCommandCategory(command)).toBe(expected)
  })
})
