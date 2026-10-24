import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { PlayerItemToolsSection } from '../src/pages/gameplay/players/sections'
import { deleteInventoryItem, getPlayerDetail, type Player } from '../src/api/gameplay'

vi.mock('../src/auth/portalAccess', () => ({usePortalAccess: () => ({isPlayer:true})}))
vi.mock('../src/api/gameplay', async original => ({...await original<typeof import('../src/api/gameplay')>(),getPlayerDetail:vi.fn(),deleteInventoryItem:vi.fn()}))
const player: Player={id:21,account_id:11,controller_id:31,name:'Own',online_status:'Offline',class:'',map:'',faction_id:0,faction_name:''}
beforeEach(()=>{vi.mocked(getPlayerDetail).mockResolvedValue({source:'live',specs:[],currency:[],inventory:[{id:123,template_id:'Wire',name:'Welding wire',kind:'item',stack_size:7,quality:0,durability:'N/A',max_durability:'N/A',water_amount:'N/A',water_type:''}]})})
afterEach(()=>{cleanup();vi.clearAllMocks()})
it('shows pending deletion on the exact row and reports completion without scrolling',async()=>{
 let finish!: (value:{ok:boolean;message:string})=>void
 vi.mocked(deleteInventoryItem).mockReturnValue(new Promise(resolve=>{finish=resolve}))
 const onWorking=vi.fn(),flash=vi.fn()
 render(<PlayerItemToolsSection player={player} canWrite demo refreshKey={0} onChanged={vi.fn()} onWorking={onWorking} flash={flash} />)
 const button=await screen.findByRole('button',{name:'Delete Welding wire'})
 fireEvent.click(button)
 expect(button).toBeDisabled()
 expect(button.querySelector('.animate-spin')).toBeInTheDocument()
 expect(onWorking).toHaveBeenLastCalledWith('Delete Welding wire')
 await act(async()=>finish({ok:true,message:'Item deleted.'}))
 expect(deleteInventoryItem).toHaveBeenCalledExactlyOnceWith(123,7)
 expect(flash).toHaveBeenCalledWith('Item deleted.','ok')
 expect(onWorking).toHaveBeenLastCalledWith(null)
})
it('makes the player-only offline requirement visible before deletion',async()=>{
 render(<PlayerItemToolsSection player={{...player,online_status:'Online'}} canWrite demo refreshKey={0} onChanged={vi.fn()} flash={vi.fn()} />)
 const button=await screen.findByRole('button',{name:'Delete Welding wire'})
 expect(button).toBeDisabled()
 expect(button).toHaveAttribute('title','Log out of the game before deleting saved inventory items')
 expect(deleteInventoryItem).not.toHaveBeenCalled()
})
