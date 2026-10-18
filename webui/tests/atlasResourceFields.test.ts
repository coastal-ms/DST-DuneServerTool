import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function activeResourceFields('), html.indexOf('function resourceRemainingText('))
const fields = new Function(body + ';return activeResourceFields;')()
const now = Date.parse('2026-10-18T15:00:00Z')
function fixture() {
 const medium = { savedFieldId: '31453815724766360', parent: 0, location: [-330600, -483000, 7150.75], remainingValue: 150000, isActive: false }
 const large = { savedFieldId: '9205148799454225888', parent: 0, location: [-711200, -1016000, -4143.9], remainingValue: 2500000, isActive: false }
 const native = { systems: [{ groups: [ { configName: 'DA_FieldType_Spice_Medium', active: [], referenceFields: [medium] }, { configName: 'DA_FieldType_Spice_Large', active: [], referenceFields: [large] } ] }] }
 const snapshot = { observedAt: new Date(now).toISOString(), spice: [medium, large].map(p => ({ map: 'DeepDesert', dimension_index: 0, field_id: p.savedFieldId, spawn_time: 4441966, value_remaining: p.remainingValue })) }
 return { native, snapshot }
}
describe('persisted and native spice fields', () => {
 it('includes the saved medium and large fields while their actor flags are inactive', () => {
  const f = fixture(), result = fields(f.native, f.snapshot, 'DeepDesert', now)
  expect(result.map((p: any) => p.type)).toEqual(['DA_FieldType_Spice_Medium', 'DA_FieldType_Spice_Large'])
  expect(result.every((p: any) => p.resourceSource === 'saved' && p.remainingValue === null)).toBe(true)
 })
 it('keeps inactive locations hidden without a matching current saved field', () => {
  const f = fixture(); f.snapshot.spice = []
  expect(fields(f.native, f.snapshot, 'DeepDesert', now)).toEqual([])
 })
 it('does not duplicate native active fields or replace their live remaining value', () => {
  const f = fixture(); f.native.systems[0].groups[0].active = [{ ...f.native.systems[0].groups[0].referenceFields[0], remainingValue: 139290, isActive: true }] as any
  const result = fields(f.native, f.snapshot, 'DeepDesert', now)
  expect(result).toHaveLength(2); expect(result[0].remainingValue).toBe(139290)
 })
 it('rejects depleted, stale, other-world and other-dimension saved records', () => {
  for (const change of [ (f: any) => f.snapshot.spice.forEach((p: any) => p.value_remaining = 0), (f: any) => f.snapshot.observedAt = new Date(now - 180001).toISOString(), (f: any) => f.snapshot.spice.forEach((p: any) => p.map = 'HaggaBasin'), (f: any) => f.snapshot.spice.forEach((p: any) => p.dimension_index = 1) ]) {
   const f = fixture(); change(f); expect(fields(f.native, f.snapshot, 'DeepDesert', now)).toEqual([])
  }
 })
 it('rejects ambiguous IDs and unspawned saved records', () => {
  const f = fixture(); f.snapshot.spice.push(f.snapshot.spice[0]); f.snapshot.spice[1].spawn_time = 0
  expect(fields(f.native, f.snapshot, 'DeepDesert', now)).toEqual([])
 })
})
