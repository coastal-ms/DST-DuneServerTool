import { describe, expect, it } from 'vitest'
import { getSoloSettingControl } from '../src/pages/SoloMode'

describe('Solo Mode setting controls', () => {
  it('uses buttons for boolean settings', () => {
    expect(getSoloSettingControl('bAllowSandstorms')).toEqual({ type: 'boolean' })
    expect(getSoloSettingControl('bLandsraadDisableDecreeRerollLimit')).toEqual({ type: 'boolean' })
  })

  it('uses verified PTC enum values for dropdown settings', () => {
    expect(getSoloSettingControl('DropEquipmentOnDeath')).toEqual({
      type: 'select',
      options: [
        { value: 'Default', label: 'Default' },
        { value: 'None', label: 'None' },
        { value: 'Backpack', label: 'Backpack only' },
        { value: 'All', label: 'All equipment' },
      ],
    })
    expect(getSoloSettingControl('PlayerDeathLootRule')).toEqual({
      type: 'select',
      options: [
        { value: 'DependsOnSecurityZone', label: 'Depends on security zone' },
        { value: 'NeverAllowOtherPlayers', label: 'Never allow other players' },
        { value: 'AlwaysAllowOtherPlayers', label: 'Always allow other players' },
      ],
    })
  })

  it('uses integer or decimal number inputs for numeric settings', () => {
    expect(getSoloSettingControl('FiefdomLimit')).toEqual({ type: 'number', step: 1 })
    expect(getSoloSettingControl('GatheringAmount')).toEqual({ type: 'number', step: 'any' })
  })

  it('keeps game-controlled fields as text', () => {
    expect(getSoloSettingControl('DifficultyLevel')).toEqual({ type: 'text' })
  })
})
