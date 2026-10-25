import fs from 'node:fs'
import path from 'node:path'
import { expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const body = html.slice(html.indexOf('function isOwnedMapVehicle('), html.indexOf('function liveVehicle('))
const visible = new Function(body + ';return isOwnedMapVehicle')()

it('shows owned active vehicles and hides unclaimed, unknown old snapshots and stored recovery vehicles', () => {
  expect(visible({ playerOwned: true, state: 'Active' })).toBe(true)
  expect(visible({ playerOwned: false, state: 'Active' })).toBe(false)
  expect(visible({ state: 'Active' })).toBe(false)
  expect(visible({ playerOwned: 'true', state: 'Active' })).toBe(false)
  for (const state of ['VehicleBackup', 'VehicleRecovery', 'Travel']) expect(visible({ playerOwned: true, state })).toBe(false)
})
