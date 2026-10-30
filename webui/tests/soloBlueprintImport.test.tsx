import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { SoloMode } from '../src/pages/SoloMode'

const fixture = vi.hoisted(() => ({
  running: false,
  refresh: vi.fn(),
  request: vi.fn(),
  status: { connected: true, dataRoot: 'C:/fixture', dbPath: 'C:/fixture/game.db',
    profileToken: 'fixture-profile', profiles: [], inspection: null },
}))
vi.mock('../src/hooks/useApi', () => ({ useApi: (path: string) => ({
  data: path === '/api/solo/status' ? fixture.status
    : path === '/api/solo/runtime' ? { gameRunning: fixture.running, processes: [] } : null,
  loading: false, error: null, refresh: fixture.refresh,
}) }))
vi.mock('../src/api/client', () => ({ api: (...args: unknown[]) => fixture.request(...args) }))

const layout = { schematic: true, name: 'Map layout',
  pieces: [['10','20',0,'Floor',[100,200,300,0,0,0,1]],
    ['10','20',1,'Wall',[300,200,500,0,0,Math.SQRT1_2,Math.SQRT1_2]]],
  placeables: [{type:'Storage_Placeable',location:{x:250,y:200,z:350},rotation:{x:0,y:0,z:0,w:1}}] }

beforeEach(() => {
  fixture.running = false
  fixture.request.mockImplementation(async (path: string) => {
    if (path === '/api/solo/blueprints/import') return { name: 'Map layout', safetyBackup: 'fixture-backup' }
    throw new Error('Unrelated catalog unavailable in this fixture')
  })
})
afterEach(() => { cleanup(); vi.clearAllMocks() })

function openInventory() {
  const view = render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  fireEvent.click(screen.getByRole('button', { name: 'Items', exact: true }))
  fireEvent.click(screen.getByRole('button', { name: 'Blueprints', exact: true }))
  return view
}
async function upload(value: unknown) {
  const file = new File(['fixture'], 'map-base.json', {type:'application/json'})
  Object.defineProperty(file, 'text', {value: async () => JSON.stringify(value)})
  fireEvent.change(document.querySelector('input[type="file"]')!, {target:{files:[file]}})
}

it('converts a Live Map download and submits the centered blueprint to the selected Solo profile', async () => {
  openInventory()
  await upload(layout)
  await screen.findByText('2 pieces · 1 placeables · 0 pentashields')
  expect(screen.queryByText('Not a portable DST blueprint file.')).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', {name:'Import blueprint',exact:true}))
  await screen.findByText(/imported into the Solo backpack and verified/)
  const call = fixture.request.mock.calls.find(([path]) => path === '/api/solo/blueprints/import')!
  const body = JSON.parse(call[1].body)
  expect(body.expectedProfileToken).toBe('fixture-profile')
  expect(body.confirm).toBe('IMPORT SOLO BLUEPRINT')
  expect(body.blueprint.instances[0]).toMatchObject({building_type:'Floor',x:-100,y:0,z:-100})
  expect(body.blueprint.instances[1].rotation).toBeCloseTo(90)
  expect(body.blueprint.placeables[0]).toMatchObject({building_type:'Storage_Placeable',x:50,y:0,z:-50})
})

it('keeps portable IDs, stability and pentashield references unchanged', async () => {
  const portable = {name:'Portable',instances:[{instance_id:7,building_type:'Floor',x:0,y:0,z:0,rotation:0,provides_stability:true}],placeables:[],pentashields:[{placeable_id:8,scale:[2,3,4]}]}
  openInventory(); await upload(portable)
  await screen.findByText('1 pieces · 0 placeables · 1 pentashields')
  fireEvent.click(screen.getByRole('button', {name:'Import blueprint',exact:true}))
  await waitFor(() => expect(fixture.request.mock.calls.some(([path]) => path === '/api/solo/blueprints/import')).toBe(true))
  const call=fixture.request.mock.calls.find(([path]) => path === '/api/solo/blueprints/import')!
  expect(JSON.parse(call[1].body).blueprint).toEqual(portable)
})

it('rejects an invalid map transform without sending a write', async () => {
  openInventory(); await upload(layout)
  await screen.findByText('2 pieces · 1 placeables · 0 pentashields')
  await upload({...layout,pieces:[['10','20',0,'Floor',[1,2]]]})
  await screen.findByText('The base layout contains an invalid building piece.')
  expect(screen.getByRole('button', {name:'Import blueprint',exact:true})).toBeDisabled()
  expect(fixture.request.mock.calls.some(([path]) => path === '/api/solo/blueprints/import')).toBe(false)
})

it('keeps the 20 MB file limit before attempting to read a blueprint', async () => {
  openInventory()
  const file = new File(['fixture'], 'too-large.json', {type:'application/json'})
  const read=vi.fn()
  Object.defineProperty(file,'size',{value:20*1024*1024+1})
  Object.defineProperty(file,'text',{value:read})
  fireEvent.change(document.querySelector('input[type="file"]')!,{target:{files:[file]}})
  await screen.findByText('Blueprint files must be 20 MB or smaller.')
  expect(read).not.toHaveBeenCalled()
  expect(screen.getByRole('button',{name:'Import blueprint',exact:true})).toBeDisabled()
})

it('keeps the import disabled if the game starts after selecting the map layout', async () => {
  const view=openInventory(); await upload(layout)
  await screen.findByText('2 pieces · 1 placeables · 0 pentashields')
  fixture.running=true; view.rerender(<SoloMode />)
  expect(screen.getByRole('button', {name:'Import blueprint',exact:true})).toBeDisabled()
  expect(fixture.request.mock.calls.some(([path]) => path === '/api/solo/blueprints/import')).toBe(false)
})
