import { describe, expect, it } from 'vitest'
import {
  getSoloSettingControl,
  isSoloSettingVisible,
  validateSoloSettingChanges,
} from '../src/pages/SoloMode'

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

  it('hides native PvP-only settings that Funcom omits from Solo controls', () => {
    expect(isSoloSettingVisible('PVPMode')).toBe(false)
    expect(isSoloSettingVisible('PlayerDamageToPlayer')).toBe(false)
    expect(isSoloSettingVisible('PlayerDamageToVehicle')).toBe(false)
    expect(isSoloSettingVisible('PVPDamageStructures')).toBe(false)
    expect(isSoloSettingVisible('PlayerDamageToNPC')).toBe(true)
  })

  it('rejects decimal values for integer settings', () => {
    expect(validateSoloSettingChanges({ FiefdomLimit: '1.5' }))
      .toBe('FiefdomLimit must be a whole number.')
    expect(validateSoloSettingChanges({ MaxLandclaimSegments: '6' })).toBeNull()
  })

  it('rejects invalid booleans and enum values', () => {
    expect(validateSoloSettingChanges({ bAllowSandstorms: 'yes' }))
      .toBe('bAllowSandstorms must be enabled or disabled.')
    expect(validateSoloSettingChanges({ PlayerDeathLootRule: 'EveryoneMaybe' }))
      .toBe('PlayerDeathLootRule has an unsupported option.')
  })
})
