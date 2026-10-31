import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { GivePackageForm } from '../src/pages/gameplay/players/sections'
import { getItemCatalog, getItemPackages, saveItemPackage } from '../src/api/gameplay'
import { serializeItemPackage } from '../src/util/itemPackageSharing'

vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ isPlayer: false }) }))
vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getItemPackages: vi.fn(), getItemCatalog: vi.fn(), saveItemPackage: vi.fn(),
}))
const items = [{ template: 'Combat_Test', qty: 2, quality: 3 }, { template: 'Schematic_Test', qty: 1, quality: 0 }]
beforeEach(() => {
  vi.mocked(getItemPackages).mockResolvedValue([{ id: 'starter', name: 'Starter kit', items }])
  vi.mocked(getItemCatalog).mockResolvedValue([
    { template_id: 'Combat_Test', name: 'Test Armor', category: 'Garments' },
    { template_id: 'Schematic_Test', name: 'Test Armor (Schematic)', category: 'Schematics' },
  ])
  vi.mocked(saveItemPackage).mockResolvedValue({ id: 'starter', name: 'Starter kit', items })
})
afterEach(() => { cleanup(); vi.clearAllMocks() })
describe('Package friendly item names', () => {
  it('previews an imported file as a new package and saves only after review, ignoring the sender ID', async () => {
    render(<GivePackageForm busy={false} onGive={vi.fn()} />)
    await screen.findByText('Test Armor')
    fireEvent.click(screen.getByRole('button',{name:'Import',exact:true}))
    const text=JSON.stringify({...JSON.parse(serializeItemPackage({name:'Starter kit',items})),id:'starter'})
    const file=new File([text],'shared.dst-package.json',{type:'application/json'})
    Object.defineProperty(file,'text',{value:async()=>text})
    fireEvent.change(screen.getByLabelText('Import a shared DST package'),{target:{files:[file]}})
    expect(await screen.findByDisplayValue('Test Armor (Schematic)')).toBeInTheDocument()
    expect(saveItemPackage).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button',{name:/Save/}))
    await waitFor(()=>expect(saveItemPackage).toHaveBeenCalledWith({id:undefined,name:'Starter kit',items}))
  })
  it('shows a damaged file error without saving or losing the existing package', async () => {
    render(<GivePackageForm busy={false} onGive={vi.fn()} />)
    await screen.findByText('Test Armor')
    fireEvent.click(screen.getByRole('button',{name:'Import',exact:true}))
    const file=new File(['broken'],'broken.json');Object.defineProperty(file,'text',{value:async()=> 'broken'})
    fireEvent.change(screen.getByLabelText('Import a shared DST package'),{target:{files:[file]}})
    expect(await screen.findByText(/does not contain valid package JSON/)).toBeInTheDocument()
    expect(saveItemPackage).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button',{name:'Cancel'}))
    expect(await screen.findByText('Test Armor')).toBeInTheDocument()
  })
  it('uses catalog names in the list and reopened editor while saving unchanged item ids and quantities', async () => {
    render(<GivePackageForm busy={false} onGive={vi.fn()} />)
    expect(await screen.findByText('Test Armor (Schematic)')).toBeInTheDocument()
    expect(screen.getByText('Test Armor')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Edit' }))
    expect(screen.getByDisplayValue('Test Armor')).toBeInTheDocument()
    expect(screen.getByDisplayValue('Test Armor (Schematic)')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Save/ }))
    await waitFor(() => expect(saveItemPackage).toHaveBeenCalledWith({ id: 'starter', name: 'Starter kit', items }))
  })
  it('retains usable template ids when catalog loading fails', async () => {
    vi.mocked(getItemCatalog).mockRejectedValue(new Error('Unavailable'))
    const onGive = vi.fn()
    render(<GivePackageForm busy={false} onGive={onGive} />)
    expect(await screen.findByText('Combat_Test')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Give to player' }))
    expect(onGive).toHaveBeenCalledWith(items, 'Starter kit', true)
  })
})
