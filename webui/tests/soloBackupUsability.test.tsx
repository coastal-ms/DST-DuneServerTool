import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, within, waitFor } from '@testing-library/react'
import { SoloMode } from '../src/pages/SoloMode'
import { api } from '../src/api/client'
import { pickLocalFile } from '../src/util/pathPicker'
const backups = { backups: [...Array.from({ length: 101 }, (_, index) => ({ name: `backup-${String(index).padStart(3, '0')}.db`, relativePath: `backup-${index}.db`, bytes: 12, modifiedAt: '2026-10-30T12:00:00Z', source:'local' })),...Array.from({length:30},(_,i)=>({name:`old-${i}.db`,relativePath:`archive/0/old-${i}.db`,bytes:12,modifiedAt:`2026-09-${String(i+1).padStart(2,'0')}T12:00:00Z`,source:'archive'}))], root: 'test' }
const status={connected:true,dataRoot:'C:/fixture',dbPath:'C:/fixture/game.db',profileToken:'fixture-profile',profiles:[],inspection:null}
vi.mock('../src/hooks/useApi', () => ({ useApi: (path: string) => ({ data: path === '/api/solo/backups' ? backups : path==='/api/solo/status'?status:null, loading: false, error: null, refresh: vi.fn() }) }))
vi.mock('../src/api/client', () => ({ api: vi.fn().mockResolvedValue({ok:true}) }))
vi.mock('../src/util/pathPicker',()=>({pickLocalFolder:vi.fn(),pickLocalFile:vi.fn()}))
afterEach(() => { cleanup(); localStorage.clear();vi.clearAllMocks() })
it('shows 25 backups per page and makes older pages accessible', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Backups', exact: true }))
  expect(screen.getAllByRole('checkbox', { name: /^Select backup-/ })).toHaveLength(25)
  expect(screen.getByText('Showing 1–25 of 101')).toBeVisible()
  fireEvent.click(screen.getByRole('button', { name: 'Next page' }))
  expect(screen.getByText('Showing 26–50 of 101')).toBeVisible()
  expect(screen.queryByText('backup-000.db')).not.toBeInTheDocument()
  expect(screen.getByText('backup-025.db')).toBeVisible()
  for(let i=0;i<3;i++)fireEvent.click(screen.getByRole('button', { name: 'Next page' }))
  expect(screen.getAllByRole('checkbox', { name: /^Select backup-/ })).toHaveLength(1)
  expect(screen.getByText('Showing 101–101 of 101')).toBeVisible()
  expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled()
})
it('shows the Solo reset directly in Progression without expanding story completion', () => {
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button', { name: 'Character tools', exact: true }))
  fireEvent.click(within(screen.getByRole('navigation', { name: 'Solo character sections' })).getByRole('button', { name: 'Progression', exact: true }))
  expect(screen.getByRole('button', { name: 'Reset to Post-NPE (keep skills & points)' })).toBeVisible()
})
it('browses archived backups without exposing delete controls and restores the selected archive reference',async()=>{
 vi.spyOn(window,'confirm').mockReturnValue(true)
 render(<SoloMode/>);fireEvent.click(screen.getByRole('button',{name:'Backups',exact:true}))
 fireEvent.click(screen.getByRole('button',{name:'Archive (30)'}))
 expect(screen.getByText('Showing 1–25 of 30')).toBeVisible()
 expect(screen.queryByRole('button',{name:'Delete',exact:true})).not.toBeInTheDocument()
 fireEvent.change(screen.getByRole('combobox',{name:'Backup order'}),{target:{value:'oldest'}})
 fireEvent.click(screen.getAllByRole('button',{name:'Restore',exact:true})[0]!)
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/api/solo/restore',{method:'POST',body:JSON.stringify({relativePath:'archive/0/old-0.db',expectedProfileToken:'fixture-profile',confirm:'RESTORE SOLO SAVE'})}))
})
it('loads an old backup selected through the file picker',async()=>{
 vi.mocked(pickLocalFile).mockResolvedValue('D:\\Archive\\old-save.db');vi.spyOn(window,'confirm').mockReturnValue(true)
 render(<SoloMode/>);fireEvent.click(screen.getByRole('button',{name:'Backups',exact:true}))
 fireEvent.click(screen.getByRole('button',{name:'Browse backup file…'}))
 await waitFor(()=>expect(api).toHaveBeenCalledWith('/api/solo/restore-file',{method:'POST',body:JSON.stringify({path:'D:\\Archive\\old-save.db',expectedProfileToken:'fixture-profile',confirm:'RESTORE SOLO SAVE'})}))
})
