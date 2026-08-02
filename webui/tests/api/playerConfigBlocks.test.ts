import { describe, expect, it } from 'vitest'
import { buildAllClientBlocks } from '../../src/pages/GameConfig'
import type { GameConfigCategory, GameConfigResponse } from '../../src/api/types'

// The "Player config" button promises one thing: exactly the lines a player must
// add locally, and nothing else. These lock that promise down — a default value
// leaking in wastes a player's time, and a missing one silently breaks the
// setting for everyone but the admin.

function cfg(game: Record<string, string>, engine: Record<string, string>): GameConfigResponse {
  const bundle = (effective: Record<string, string>) => ({
    path: '', raw: '', sections: [], effective, effectiveByKey: {}, managedSections: [],
  })
  return {
    available: true,
    source: 'live',
    game: bundle(game),
    engine: bundle(engine),
  } as unknown as GameConfigResponse
}

const cats: GameConfigCategory[] = [
  {
    category: 'Vehicles',
    fields: [
      { section: 'ConsoleVariables', key: 'Vehicle.MaxVehiclesPerPlayer', file: 'engine', type: 'int', label: 'Max vehicles', default: '10', clientApply: true },
      { section: 'ConsoleVariables', key: 'Vehicle.MaxVehicles', file: 'engine', type: 'int', label: 'Max total', default: '-1', clientApply: true },
    ],
  },
  {
    category: 'Sandworm',
    fields: [
      { section: '/Script/DuneSandbox.SandwormSettings', key: 'm_bEnableHibernation', file: 'game', type: 'bool', label: 'Hibernation', default: 'True', clientApply: true },
      // Server-only: must never be handed to players.
      { section: 'ConsoleVariables', key: 'Bgd.ServerPlayerHardCap', file: 'engine', type: 'int', label: 'Hard cap', default: '-1' },
    ],
  },
] as unknown as GameConfigCategory[]

describe('buildAllClientBlocks', () => {
  it('includes only settings changed from their default', () => {
    const out = buildAllClientBlocks(cats, cfg(
      { '/Script/DuneSandbox.SandwormSettings||m_bEnableHibernation': 'True' },   // still default
      { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '20' },                 // changed
    ))
    expect(out.count).toBe(1)
    expect(out.entries).toHaveLength(1)
    expect(out.entries[0].file).toBe('engine')
    expect(out.entries[0].block).toContain('Vehicle.MaxVehiclesPerPlayer=20')
    expect(out.entries[0].block).not.toContain('m_bEnableHibernation')
  })

  it('splits Game.ini and Engine.ini into separate blocks, Game.ini first', () => {
    const out = buildAllClientBlocks(cats, cfg(
      { '/Script/DuneSandbox.SandwormSettings||m_bEnableHibernation': 'False' },
      { 'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '20' },
    ))
    expect(out.entries.map(e => e.file)).toEqual(['game', 'engine'])
    expect(out.count).toBe(2)
    expect(out.entries[0].block).toContain('[/Script/DuneSandbox.SandwormSettings]')
    expect(out.entries[1].block).toContain('[ConsoleVariables]')
  })

  it('never hands out a server-only setting', () => {
    const out = buildAllClientBlocks(cats, cfg({}, {
      'ConsoleVariables||Bgd.ServerPlayerHardCap': '80',
    }))
    expect(out.count).toBe(0)
    expect(out.entries).toHaveLength(0)
  })

  it('merges keys from different cards into one section and never repeats a key', () => {
    const duplicated: GameConfigCategory[] = [
      ...cats,
      {
        category: 'Another card',
        fields: [
          { section: 'ConsoleVariables', key: 'Vehicle.MaxVehiclesPerPlayer', file: 'engine', type: 'int', label: 'Max vehicles', default: '10', clientApply: true },
        ],
      },
    ] as unknown as GameConfigCategory[]
    const out = buildAllClientBlocks(duplicated, cfg({}, {
      'ConsoleVariables||Vehicle.MaxVehiclesPerPlayer': '20',
      'ConsoleVariables||Vehicle.MaxVehicles': '40',
    }))
    expect(out.count).toBe(2)
    expect(out.entries).toHaveLength(1)
    const headers = out.entries[0].block.match(/\[ConsoleVariables\]/g) ?? []
    expect(headers).toHaveLength(1)
    const perPlayer = out.entries[0].block.match(/Vehicle\.MaxVehiclesPerPlayer=/g) ?? []
    expect(perPlayer).toHaveLength(1)
  })

  it('returns nothing when no settings have been customised', () => {
    const out = buildAllClientBlocks(cats, cfg({}, {}))
    expect(out.count).toBe(0)
    expect(out.entries).toHaveLength(0)
  })
})
