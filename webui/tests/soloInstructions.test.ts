import { describe, expect, it } from 'vitest'
import {
  SOLO_ACTION_RULES,
  SOLO_FIRST_USE_STEPS,
  SOLO_HIDDEN_SETTINGS,
  SOLO_READ_ONLY_SETTINGS,
} from '../src/pages/SoloMode'

describe('Solo Mode user instructions', () => {
  it('requires one real Solo launch and a full exit before first management', () => {
    expect(SOLO_FIRST_USE_STEPS.join(' ')).toContain('enter the world')
    expect(SOLO_FIRST_USE_STEPS.join(' ')).toContain('Quit all the way to the desktop')
    expect(SOLO_FIRST_USE_STEPS.join(' ')).toContain('Connect and validate')
  })

  it('distinguishes live-safe reads from closed-game writes', () => {
    const rules = Object.fromEntries(SOLO_ACTION_RULES.map(rule => [rule.title, rule.state]))
    expect(rules['Connect and inspect']).toBe('Game may be open')
    expect(rules['Create save backup']).toBe('Game may be open')
    expect(rules['Apply Solo settings']).toBe('Game must be closed')
    expect(rules['Items, currencies, and fillables']).toBe('Game must be closed')
    expect(rules['Progression actions']).toBe('Game must be closed')
    expect(rules['Restore save']).toBe('Game must be closed')
  })

  it('keeps the in-game difficulty setting read-only', () => {
    expect(SOLO_READ_ONLY_SETTINGS.has('DifficultyLevel')).toBe(true)
  })

  it('hides the irrelevant PVP setting', () => {
    expect(SOLO_HIDDEN_SETTINGS.has('PVPMode')).toBe(true)
  })
})
