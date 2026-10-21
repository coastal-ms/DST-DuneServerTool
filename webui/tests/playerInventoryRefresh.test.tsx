import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { getPlayerDetail, repairInventoryItem, repairGear, type Player } from '../src/api/gameplay'
import { InventorySection, PlayerItemToolsSection } from '../src/pages/gameplay/players/sections'

vi.mock('../src/api/gameplay', async original => ({
  ...await original<typeof import('../src/api/gameplay')>(),
  getPlayerDetail: vi.fn(), repairInventoryItem: vi.fn(), repairGear: vi.fn(),
}))
vi.mock('../src/components/inventory/SharedInventoryExplorer', () => ({SharedInventoryExplorer: () => <div>Inventory fixture</div>}))
const player: Player = {id:42,controller_id:100,account_id:99,name:'Test player',class:'',map:'',faction_id:0,faction_name:'',online_status:'Offline'}
const item = {id:9001,template_id:'TestKnife',name:'Test knife',kind:'item' as const,stack_size:1,quality:0,durability:'96.669998',max_durability:'0',water_amount:'N/A',water_type:'',current_ammo:'N/A'}
const detail = {source:'live' as const,specs:[],currency:[],inventory:[item]}
function open(){render(<PlayerItemToolsSection player={player} canWrite demo refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)}
beforeEach(()=>{vi.mocked(getPlayerDetail).mockResolvedValue(detail);vi.mocked(repairInventoryItem).mockResolvedValue({ok:true,message:'Repair saved.'});vi.mocked(repairGear).mockResolvedValue({ok:true,message:'Gear repaired.'})})
afterEach(()=>{cleanup();vi.clearAllMocks()})
describe('Player inventory pages and editor refresh',()=>{
  it('refreshes the expanded durability fields after repair and explicit Refresh',async()=>{
    open();fireEvent.click(await screen.findByText('Test knife'))
    expect(screen.getByRole('spinbutton',{name:'CurrentDurability'})).toHaveValue(96.669998)
    vi.mocked(getPlayerDetail).mockResolvedValue({...detail,inventory:[{...item,durability:'100',max_durability:'100'}]})
    fireEvent.click(screen.getByRole('button',{name:'Repair (catalog max)'}))
    await waitFor(()=>expect(screen.getByRole('spinbutton',{name:'CurrentDurability'})).toHaveValue(100))
    expect(screen.getByRole('spinbutton',{name:'MaxDurability'})).toHaveValue(100)
    expect(repairInventoryItem).toHaveBeenCalledWith(9001)
    vi.mocked(getPlayerDetail).mockResolvedValue({...detail,inventory:[{...item,durability:'80',max_durability:'100'}]})
    fireEvent.click(screen.getByRole('button',{name:'Refresh inventory'}))
    await waitFor(()=>expect(screen.getByRole('spinbutton',{name:'CurrentDurability'})).toHaveValue(80))
  })
  it('counts only inventory rows and requests emotes separately from page zero',async()=>{
    vi.mocked(getPlayerDetail).mockResolvedValue({...detail,inventory:[item,{...item,id:2,kind:'emote',name:'Wave'},{...item,id:3,kind:'contract',name:'Contract'}]})
    open();await screen.findByText('Test knife')
    expect(screen.getByText('Page 1 · Showing 1 inventory item')).toBeInTheDocument()
    expect(getPlayerDetail).toHaveBeenLastCalledWith(42,100,true,0,'item')
    expect(screen.queryByText('Wave')).not.toBeInTheDocument()
    vi.mocked(getPlayerDetail).mockResolvedValue({...detail,inventory:[{...item,id:2,kind:'emote',name:'Wave'}]})
    fireEvent.click(screen.getByRole('button',{name:'Emotes'}))
    await screen.findByText('Wave')
    expect(getPlayerDetail).toHaveBeenLastCalledWith(42,100,true,0,'emote')
  })
  it('offers the existing backpack/equipped repair for only the selected player', async()=>{
    render(<InventorySection player={player} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
    fireEvent.click(screen.getByRole('button',{name:'Repair backpack & worn items'}))
    await waitFor(()=>expect(repairGear).toHaveBeenCalledWith(42))
  })
  it('keeps backpack/equipped repair disabled while the player is online',()=>{
    render(<InventorySection player={{...player,online_status:'Online'}} canWrite demo={false} refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
    expect(screen.getByRole('button',{name:'Repair backpack & worn items'})).toBeDisabled()
    expect(repairGear).not.toHaveBeenCalled()
  })

})
