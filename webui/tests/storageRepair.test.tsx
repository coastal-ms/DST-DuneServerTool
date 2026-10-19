import {cleanup,fireEvent,render,screen,waitFor} from '@testing-library/react'
import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest'
import {StorageTab} from '../src/pages/gameplay/StorageTab'
import {getStorage,getStorageItems,repairStorageContents} from '../src/api/gameplay'
vi.mock('../src/pages/gameplay/players/sections',()=>({GivePackageForm:()=>null}))
vi.mock('../src/api/gameplay',async original=>({...await original<typeof import('../src/api/gameplay')>(),getStorage:vi.fn(),getStorageItems:vi.fn(),repairStorageContents:vi.fn()}))
const box={id:123,name:'Gear box',class:'Storage',raw_class:'Storage',owner_name:'Owner',map:'Hagga',item_count:1,item_names:['Sword']}
beforeEach(()=>{
  vi.mocked(getStorage).mockResolvedValue({containers:[box],source:'live'})
  vi.mocked(getStorageItems).mockResolvedValue({items:[{id:11,template_id:'Sword',name:'Sword',stack_size:1,quality:1,durability:'10',max_durability:'100'}],source:'live'})
  vi.mocked(repairStorageContents).mockResolvedValue({ok:true,message:'Repaired this storage box. Restart the server zone.'})
})
afterEach(()=>{cleanup();vi.clearAllMocks()})
describe('Storage detail repair',()=>{
  it('repairs the selected box and reloads its contents',async()=>{
    render(<StorageTab/>)
    fireEvent.click(await screen.findByText('Gear box'))
    const button=await screen.findByRole('button',{name:'Repair all contents'})
    await waitFor(()=>expect(button).not.toBeDisabled())
    fireEvent.click(button)
    await waitFor(()=>expect(repairStorageContents).toHaveBeenCalledWith(123))
    expect(await screen.findByText('Repaired this storage box. Restart the server zone.')).toBeInTheDocument()
    expect(vi.mocked(getStorageItems).mock.calls.length).toBeGreaterThan(1)
  })
  it('does not offer repair for demo storage',async()=>{
    vi.mocked(getStorage).mockResolvedValue({containers:[box],source:'demo'})
    render(<StorageTab/>)
    fireEvent.click(await screen.findByText('Gear box'))
    expect(screen.queryByRole('button',{name:'Repair all contents'})).not.toBeInTheDocument()
    expect(repairStorageContents).not.toHaveBeenCalled()
  })
})
