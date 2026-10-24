import {cleanup,render,screen,waitFor} from '@testing-library/react'
import {afterEach,expect,it,vi} from 'vitest'
import {InventorySection} from '../src/pages/gameplay/players/sections'
import {getSharedInventory,type Player,type SharedInventoryResponse} from '../src/api/gameplay'
vi.mock('../src/api/gameplay',async original=>({...await original<typeof import('../src/api/gameplay')>(),getSharedInventory:vi.fn()}))
vi.mock('../src/components/inventory/SharedInventoryExplorer',()=>({SharedInventoryExplorer:({fixedLocation,title}:{fixedLocation:{id:number};title:string})=><div>{title}: location {fixedLocation.id}</div>}))
afterEach(()=>{cleanup();vi.clearAllMocks()})
const props={player:{id:7,name:'Own',controller_id:5,online_status:'Offline'} as Player,canWrite:true,demo:false,refreshKey:0,flash:vi.fn(),onChanged:vi.fn()}
it('resolves only the selected character bank, including an empty bank',async()=>{
 vi.mocked(getSharedInventory).mockResolvedValue({data:{locations:[
  {type:'player',id:40,label:'Backpack',playerId:7},
  {type:'player',id:41,label:'Bank Storage',playerId:8},
  {type:'player',id:42,label:'Bank Storage',playerId:7,occurrenceCount:0},
 ]}} as SharedInventoryResponse)
 render(<InventorySection {...props} initialView="bank" embedded />)
 expect(await screen.findByText('Bank: location 42')).toBeInTheDocument()
 expect(getSharedInventory).toHaveBeenCalledWith({types:['player'],playerId:7,limit:1,demo:false})
})
it('does not fall back to the backpack when there is no bank',async()=>{
 vi.mocked(getSharedInventory).mockResolvedValue({data:{locations:[{type:'player',id:40,label:'Backpack',playerId:7}]}} as SharedInventoryResponse)
 render(<InventorySection {...props} initialView="bank" embedded />)
 await waitFor(()=>expect(screen.getByText('No bank inventory was found for this character.')).toBeInTheDocument())
 expect(screen.queryByText(/Bank: location/)).not.toBeInTheDocument()
})
