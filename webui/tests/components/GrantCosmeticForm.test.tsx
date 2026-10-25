import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
vi.mock('../../src/api/gameplay',async importOriginal=>({...await importOriginal<typeof import('../../src/api/gameplay')>(),getCosmeticsCatalog:vi.fn(),getPlayerOwnedCosmetics:vi.fn()}))
import { getCosmeticsCatalog, getPlayerOwnedCosmetics, type CosmeticEntry } from '../../src/api/gameplay'
import { GrantCosmeticForm } from '../../src/pages/gameplay/players/sections'
const appearance:CosmeticEntry={template:'appearance:AgentX_Stillsuit_Torso',name:'Stillsuit of the Awakened Torso',group:'Gear Appearances',grant_method:'character',customization_id:'appearance:AgentX_Stillsuit_Torso'}
const token:CosmeticEntry={template:'ScoutSetVariant',name:'Scout Set',group:'Armor & Suit Sets'}
afterEach(cleanup)
beforeEach(()=>{vi.mocked(getCosmeticsCatalog).mockResolvedValue([appearance,token]);vi.mocked(getPlayerOwnedCosmetics).mockResolvedValue({account_id:1,owned:[],unlocked:[],pending:[],total:0,source:'live'})})
it('requires offline for a character appearance while retaining online token delivery',async()=>{
 const user=userEvent.setup();render(<GrantCosmeticForm busy={false} playerName="Test" accountId={1} playerOnline={true} onGrant={vi.fn()}/>)
 const picker=await screen.findByRole('listbox');await user.selectOptions(picker,appearance.template)
 expect(screen.getByRole('button',{name:'Grant',exact:true})).toBeDisabled()
 await user.selectOptions(picker,token.template)
 expect(screen.getByRole('button',{name:'Grant',exact:true})).toBeEnabled()
})
it('forwards an offline selection with its character grant metadata',async()=>{
 const user=userEvent.setup(),grant=vi.fn().mockResolvedValue(true);render(<GrantCosmeticForm busy={false} playerName="Test" accountId={1} playerOnline={false} onGrant={grant}/>)
 await user.selectOptions(await screen.findByRole('listbox'),appearance.template)
 await user.click(screen.getByRole('button',{name:'Grant',exact:true}))
 expect(grant).toHaveBeenCalledWith(appearance.template,appearance.name,appearance)
})
