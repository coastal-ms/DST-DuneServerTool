import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function spiceLayer('), html.indexOf('function receiveSelection('))
const { spiceLayer, migrateSpiceLayers } = new Function(body + ';return {spiceLayer,migrateSpiceLayers};')()
describe('separate spice layers', () => {
 it('starts with only large spice selected', () => {
  expect(html).toContain("new Set(['storms','worms','spice-large','grid','history','bases'])")
  expect(html).toContain('data-layer="spice-large" checked')
  expect(html).toContain('data-layer="spice-medium"><')
  expect(html).toContain('data-layer="spice-small"><')
 })
 it('routes each size independently and keeps flour separate', () => {
  expect(['Small','Medium','Large'].map(s=>spiceLayer('DA_FieldType_Spice_'+s))).toEqual(['spice-small','spice-medium','spice-large'])
  expect(spiceLayer('DA_FieldType_FlourSand_Small')).toBe('flour')
 })
 it('migrates old combined spice to large only and preserves an old hidden choice', () => {
  expect(migrateSpiceLayers(['worms','resources'])).toEqual(['worms','spice-large'])
  expect(migrateSpiceLayers(['worms'])).toEqual(['worms'])
 })
 it('preserves explicit size choices including large switched off', () => {
  expect(migrateSpiceLayers(['spice-small','spice-medium'])).toEqual(['spice-small','spice-medium'])
  expect(migrateSpiceLayers(['resources','spice-medium'])).toEqual(['spice-medium'])
 })
})
