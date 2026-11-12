import { describe, expect, it } from 'vitest'
import { needsSoloCustomPresetNotice } from '../src/util/soloPresetGuidance'
import {
  getSoloSettingControl,
  getPendingSoloSettingChanges,
  isSoloSettingVisible,
  validateSoloSettingChanges,
} from '../src/pages/SoloMode'

describe('Solo Mode setting controls', () => {
  it('derives the warning from actual pending edits while excluding the game-controlled preset from the save', () => {
    const entries = [
      { key: 'DifficultyLevel', value: 'Survival', present: true },
      { key: 'GatheringAmount', value: '1', present: true },
      { key: 'm_DayLengthMinutes', value: '30', present: true },
    ]
    const unchanged = { DifficultyLevel: 'Survival', GatheringAmount: '1', m_DayLengthMinutes: '30' }
    const noOp = getPendingSoloSettingChanges(entries, unchanged)
    expect(noOp).toEqual({})
    expect(needsSoloCustomPresetNotice('Survival', noOp)).toBe(false)
    const nativeEdit = getPendingSoloSettingChanges(entries, { ...unchanged, DifficultyLevel: 'Custom', GatheringAmount: '2' })
    expect(nativeEdit).toEqual({ GatheringAmount: '2' })
    expect(needsSoloCustomPresetNotice('Survival', nativeEdit)).toBe(true)
    const independent = getPendingSoloSettingChanges(entries, { ...unchanged, m_DayLengthMinutes: '60' })
    expect(needsSoloCustomPresetNotice('Survival', independent)).toBe(false)
    expect(entries[0].value).toBe('Survival')
  })
  it('accepts positive decimal day lengths without inventing an absent default', () => {
    expect(getSoloSettingControl('m_DayLengthMinutes')).toEqual({ type: 'number', step: 'any' })
    expect(validateSoloSettingChanges({ m_DayLengthMinutes: '45.5' })).toBeNull()
    expect(validateSoloSettingChanges({ m_DayLengthMinutes: '' })).toBeNull()
    for (const value of ['0', '-1', 'NaN', 'Infinity', '1e309']) {
      expect(validateSoloSettingChanges({ m_DayLengthMinutes: value })).not.toBeNull()
    }
    const entries = [{ key: 'm_DayLengthMinutes', value: '', present: false, needsApply: false }]
    expect(getPendingSoloSettingChanges(entries, {})).toEqual({})
    expect(getPendingSoloSettingChanges(entries, { m_DayLengthMinutes: '90' })).toEqual({ m_DayLengthMinutes: '90' })
    expect(getPendingSoloSettingChanges([{ ...entries[0], present: true }], {})).toEqual({ m_DayLengthMinutes: '' })
    expect(getPendingSoloSettingChanges([{ ...entries[0], value: '5', present: true }], { m_DayLengthMinutes: '' })).toEqual({ m_DayLengthMinutes: '' })
  })
  it('allows repairing a missing required override without changing the saved value', () => {
    const entries = [{ key: 'MaxLandclaimSegments', value: '20', present: true, needsApply: true }]
    expect(getPendingSoloSettingChanges(entries, { MaxLandclaimSegments: '20' })).toEqual({ MaxLandclaimSegments: '20' })
    expect(getPendingSoloSettingChanges([{ ...entries[0], needsApply: false }], { MaxLandclaimSegments: '20' })).toEqual({})
  })
  it('uses buttons for boolean settings', () => {
    expect(getSoloSettingControl('m_bAreSecurityZonesEnabled')).toEqual({ type: 'boolean' })
    expect(validateSoloSettingChanges({ m_bAreSecurityZonesEnabled: 'False' })).toBeNull()
    expect(validateSoloSettingChanges({ m_bAreSecurityZonesEnabled: 'invalid' })).toContain('enabled or disabled')
    expect(getSoloSettingControl('bAllowSandstorms')).toEqual({ type: 'boolean' })
    expect(getSoloSettingControl('bLandsraadDisableDecreeRerollLimit')).toEqual({ type: 'boolean' })
  })

  it('uses supported Retail Solo enum values for dropdown settings', () => {
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

  it('accepts positive spice ratios and rejects zero, negative, or non-finite values', () => {
    expect(getSoloSettingControl('m_NodeValueToSpiceResourceRatio')).toEqual({ type: 'number', step: 'any' })
    expect(validateSoloSettingChanges({ m_NodeValueToSpiceResourceRatio: '5.0' })).toBeNull()
    for (const value of ['0', '-1', 'Infinity']) {
      expect(validateSoloSettingChanges({ m_NodeValueToSpiceResourceRatio: value })).not.toBeNull()
    }
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
