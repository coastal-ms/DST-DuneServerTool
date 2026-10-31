import {cleanup,render,screen,waitFor,within} from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import {afterEach,expect,it,vi} from 'vitest'
import {CosmeticMultiSelect} from '../../src/components/CosmeticMultiSelect'
import type {CosmeticEntry} from '../../src/api/gameplay'
const catalog:CosmeticEntry[]=[{template:'a',name:'Armor A',group:'Armor'},{template:'b',name:'Building B',group:'Buildings'},{template:'c',name:'Color C',group:'Colors',grant_method:'character',customization_id:'c'}]
const props={catalog,owned:new Set<string>(),saved:new Set<string>(),pending:new Set<string>(),disabled:false}
afterEach(cleanup)
it('grants a multi-selection once and retains it after completion and ownership refresh',async()=>{
 const user=userEvent.setup(),grant=vi.fn().mockResolvedValue(true),complete=vi.fn().mockResolvedValue(undefined)
 const view=render(<CosmeticMultiSelect {...props} onGrant={grant} onComplete={complete} />)
 await user.selectOptions(screen.getByRole('listbox'),['a','c'])
 await user.click(screen.getByRole('button',{name:'Grant selected (2)'}))
 await waitFor(()=>expect(complete).toHaveBeenCalledTimes(1))
 expect(complete).toHaveBeenCalledWith({incomplete:false,message:'2/2 selected grant requests submitted.\nArmor A: Submitted\nColor C: Submitted'})
 expect(grant.mock.calls.map(([entry])=>entry.template)).toEqual(['a','c'])
 expect(grant.mock.calls[1][0].customization_id).toBe('c')
 view.rerender(<CosmeticMultiSelect {...props} owned={new Set(['a','c'])} saved={new Set(['a','c'])} onGrant={grant} onComplete={complete} />)
 expect((screen.getByRole('option',{name:/Armor A/}) as HTMLOptionElement).selected).toBe(true)
 expect((screen.getByRole('option',{name:/Color C/}) as HTMLOptionElement).selected).toBe(true)
 expect(within(screen.getByRole('list',{name:'Selected cosmetic grants'})).getAllByText('Submitted')).toHaveLength(2)
 expect(screen.getByRole('button',{name:'Grant selected (0)'})).toBeDisabled()
})
it('includes every selected entry and its exact failure in the completion summary',async()=>{
 const user=userEvent.setup(),complete=vi.fn(),grant=vi.fn().mockResolvedValueOnce(true).mockRejectedValueOnce(new Error('Backpack is full'))
 render(<CosmeticMultiSelect {...props} onGrant={grant} onComplete={complete} />)
 await user.selectOptions(screen.getByRole('listbox'),['a','b','c'])
 await user.click(screen.getByRole('button',{name:'Grant selected (3)'}))
 await waitFor(()=>expect(complete).toHaveBeenCalledTimes(1))
 expect(complete).toHaveBeenCalledWith({incomplete:true,message:'1/3 selected grant requests submitted.\nArmor A: Submitted\nBuilding B: Backpack is full\nColor C: Not submitted'})
 expect(grant).toHaveBeenCalledTimes(2)
})
it('keeps selections across searches so different groups can be granted together',async()=>{
 const user=userEvent.setup(),grant=vi.fn().mockResolvedValue(true)
 render(<CosmeticMultiSelect {...props} onGrant={grant} />)
 await user.selectOptions(screen.getByRole('listbox'),'a')
 await user.type(screen.getByLabelText('Search cosmetics'),'Building')
 await user.selectOptions(screen.getByRole('listbox'),'b')
 await user.click(screen.getByRole('button',{name:'Grant selected (2)'}))
 await waitFor(()=>expect(grant).toHaveBeenCalledTimes(2))
 expect(grant.mock.calls.map(([entry])=>entry.template)).toEqual(['a','b'])
})
it('stops after a failed request and retries the remainder without repeating submitted entries',async()=>{
 const user=userEvent.setup(),grant=vi.fn().mockResolvedValueOnce(true).mockResolvedValueOnce(false).mockResolvedValue(true)
 render(<CosmeticMultiSelect {...props} onGrant={grant} />)
 await user.selectOptions(screen.getByRole('listbox'),['a','b','c'])
 await user.click(screen.getByRole('button',{name:'Grant selected (3)'}))
 await screen.findByText('Not submitted — see action result.')
 expect(grant).toHaveBeenCalledTimes(2)
 await user.click(screen.getByRole('button',{name:'Grant selected (2)'}))
 await waitFor(()=>expect(grant).toHaveBeenCalledTimes(4))
 expect(grant.mock.calls.map(([entry])=>entry.template)).toEqual(['a','b','b','c'])
})
it('mirrors the ownership and excluded-token filters without changing bulk grant rules',async()=>{
 const user=userEvent.setup()
 render(<CosmeticMultiSelect {...props} catalog={[...catalog,{template:'excluded',name:'Excluded token',group:'Test',bulk_exclusion:'Excluded test token'}]} owned={new Set(['a'])} saved={new Set(['a'])} onGrant={vi.fn()} />)
 expect(screen.getByLabelText('Show saved records and held tokens')).toBeChecked()
 expect(screen.queryByRole('option',{name:/Excluded token/})).not.toBeInTheDocument()
 await user.click(screen.getByLabelText('Show saved records and held tokens'))
 expect(screen.queryByRole('option',{name:/Armor A/})).not.toBeInTheDocument()
 await user.click(screen.getByLabelText('Show tokens excluded from bulk grants'))
 expect(screen.getByRole('option',{name:/Excluded token/})).toBeInTheDocument()
})
