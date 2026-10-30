import {cleanup,render,screen} from '@testing-library/react'
import {afterEach,expect,it,vi} from 'vitest'
import {SoloGameActivity} from '../src/components/solo/SoloGameActivity'
import {useApi} from '../src/hooks/useApi'
vi.mock('../src/hooks/useApi',()=>({useApi:vi.fn()}))
afterEach(cleanup)
const state={error:null,loading:false,refresh:vi.fn(),replaceData:vi.fn()}
it('uses the shared event display for the active Solo profile',()=>{
 vi.mocked(useApi).mockReturnValue({...state,data:{profileToken:'one',unsupported:false,events:[{id:-1,ts:'2026-10-30T18:00:00Z',event_type:'communinet_19',meta:'{"m_StateChange":"On","m_BuildableName":"Home base"}'}]}})
 render(<SoloGameActivity profileToken="one" />)
 expect(screen.getByText('Home base: power On')).toBeInTheDocument()
})
it('does not show an earlier profile’s events',()=>{
 vi.mocked(useApi).mockReturnValue({...state,data:{profileToken:'other',unsupported:false,events:[{id:-1,ts:'',event_type:'communinet_98',meta:'{"m_NewName":"Old profile"}'}]}})
 render(<SoloGameActivity profileToken="one" />)
 expect(screen.queryByText(/Old profile/)).not.toBeInTheDocument()
})
it('distinguishes unavailable records from an empty event history',()=>{
 vi.mocked(useApi).mockReturnValue({...state,data:{profileToken:'one',unsupported:true,events:[]}})
 render(<SoloGameActivity profileToken="one" />)
 expect(screen.getByText('Communinet records are unavailable in this save.')).toBeInTheDocument()
 expect(screen.queryByText('No Communinet events recorded for this character.')).not.toBeInTheDocument()
})
