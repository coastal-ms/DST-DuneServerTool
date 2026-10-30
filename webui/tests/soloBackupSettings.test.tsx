import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { SoloBackupSettings } from '../src/components/solo/SoloBackupSettings'
import { api } from '../src/api/client'
import { pickLocalFolder } from '../src/util/pathPicker'
const state={data:{ok:true,root:'local',policy:{managed:false,directory:'',maximumBackups:50}},loading:false,error:null,refresh:vi.fn().mockResolvedValue(undefined)}
vi.mock('../src/hooks/useApi',()=>({useApi:()=>state}))
vi.mock('../src/api/client',()=>({api:vi.fn()}))
vi.mock('../src/util/pathPicker',()=>({pickLocalFolder:vi.fn()}))
beforeEach(()=>{state.data.policy.managed=false;state.data.policy.directory='';vi.mocked(pickLocalFolder).mockResolvedValue('D:\\Archive');vi.mocked(api).mockResolvedValue({ok:true,policy:{managed:true,directory:'D:\\Archive'}})})
afterEach(()=>{cleanup();vi.clearAllMocks()})
it('defaults off and checking opens the folder picker before enabling management',async()=>{
 const saved=vi.fn().mockResolvedValue(undefined)
 render(<SoloBackupSettings profileToken="intended-profile" disabled={false} onSaved={saved}/> )
 const checkbox=screen.getByRole('checkbox',{name:'Let DST manage backups'})
 expect(checkbox).not.toBeChecked();expect(api).not.toHaveBeenCalled()
 fireEvent.click(checkbox)
 await waitFor(()=>expect(pickLocalFolder).toHaveBeenCalledOnce())
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/api/solo/backup-policy',{method:'PUT',body:JSON.stringify({managed:true,directory:'D:\\Archive',expectedProfileToken:'intended-profile'})}))
 await waitFor(()=>expect(saved).toHaveBeenCalledOnce())
 expect(checkbox).toBeChecked()
})
it('cancelling the picker leaves management off without a policy write',async()=>{
 vi.mocked(pickLocalFolder).mockResolvedValue(null)
 render(<SoloBackupSettings profileToken="profile" disabled={false} onSaved={vi.fn()}/> )
 const checkbox=screen.getByRole('checkbox',{name:'Let DST manage backups'});fireEvent.click(checkbox)
 await waitFor(()=>expect(checkbox).toBeEnabled())
 expect(checkbox).not.toBeChecked();expect(api).not.toHaveBeenCalled()
})
it('turning management off does not open a picker or request archive deletion',async()=>{
 state.data.policy.managed=true;state.data.policy.directory='D:\\Archive'
 vi.mocked(api).mockResolvedValue({ok:true,policy:{managed:false,directory:'D:\\Archive'}})
 render(<SoloBackupSettings profileToken="profile" disabled={false} onSaved={vi.fn().mockResolvedValue(undefined)}/> )
 fireEvent.click(screen.getByRole('checkbox',{name:'Let DST manage backups'}))
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/api/solo/backup-policy',{method:'PUT',body:JSON.stringify({managed:false,directory:'D:\\Archive',expectedProfileToken:'profile'})}))
 expect(pickLocalFolder).not.toHaveBeenCalled()
})
it('does not change policy when the connected profile is not validated',()=>{
 render(<SoloBackupSettings profileToken="" disabled={true} onSaved={vi.fn()}/> )
 expect(screen.getByRole('checkbox',{name:'Let DST manage backups'})).toBeDisabled()
})
