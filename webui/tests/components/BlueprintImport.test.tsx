import {cleanup,render,screen,fireEvent,waitFor} from '@testing-library/react'
import {afterEach,expect,it,vi} from 'vitest'
vi.mock('../../src/api/gameplay',async original=>({...await original<typeof import('../../src/api/gameplay')>(),importBlueprint:vi.fn().mockResolvedValue({message:'Imported.'})}))
import {importBlueprint,type Player} from '../../src/api/gameplay'
import {BlueprintImport} from '../../src/pages/gameplay/players/BlueprintImport'
afterEach(()=>{cleanup();vi.clearAllMocks()})
const player={id:21,name:'Linked',online_status:'Offline'} as Player
const blueprint={name:'Base',instances:[{building_type:'Floor',x:0,y:0,z:0,rotation:0}],placeables:[],pentashields:[]}
async function upload(){const file=new File(['data'],'base.json',{type:'application/json'});Object.defineProperty(file,'text',{value:async()=>JSON.stringify(blueprint)});fireEvent.change(screen.getByLabelText('Blueprint file (.json)'),{target:{files:[file]}});await screen.findByText(/Base: 1 pieces/)}
it('imports only into the displayed linked character with visible completion',async()=>{
 const changed=vi.fn();render(<BlueprintImport player={player} canWrite onChanged={changed}/>);await upload()
 expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
 fireEvent.click(screen.getByRole('button',{name:'Import Blueprint'}))
 await screen.findByRole('status');expect(importBlueprint).toHaveBeenCalledWith(21,blueprint);expect(changed).toHaveBeenCalledOnce()
})
it('blocks import online and enables it when the character becomes offline',async()=>{
 const {rerender}=render(<BlueprintImport player={{...player,online_status:'Online'}} canWrite onChanged={vi.fn()}/>);await upload()
 expect(screen.getByRole('button',{name:'Import Blueprint'})).toBeDisabled()
 rerender(<BlueprintImport player={player} canWrite onChanged={vi.fn()}/>);await waitFor(()=>expect(screen.getByRole('button',{name:'Import Blueprint'})).toBeEnabled())
 expect(importBlueprint).not.toHaveBeenCalled()
})
