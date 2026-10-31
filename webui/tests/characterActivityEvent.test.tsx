import {cleanup,fireEvent,render,screen} from '@testing-library/react'
import {afterEach,expect,it} from 'vitest'
import {CharacterActivityEvent} from '../src/components/CharacterActivityEvent'
afterEach(cleanup)
it.each([
 ['communinet_19',{m_BuildableName:'Home base',m_StateChange:'Off'},'Home base: power Off'],
 ['communinet_13',{m_BuildableName:'Home base',m_TotemShieldState:'Restored'},'Home base: shield Restored'],
 ['communinet_98',{m_NewName:'Coastal Home Base'},'Base renamed to Coastal Home Base'],
 ['communinet_95',{m_BaseName:'Home base',m_PowerTimeLeftSeconds:180000},'Home base: running low on power (2d 2h 0m remaining)'],
 ['communinet_97',{},'Base permissions changed'],
 ['communinet_999',{},'Communinet event'],
])('renders readable game event %s',(event_type,meta,title)=>{
 render(<CharacterActivityEvent ev={{id:1,ts:'2026-10-30T18:00:00Z',event_type,meta:JSON.stringify(meta)}} />)
 expect(screen.getByText(title)).toBeInTheDocument()
})
it('keeps existing account activity readable and reveals safe details on demand',()=>{
 render(<CharacterActivityEvent ev={{id:1,ts:'2026-10-30T18:00:00Z',event_type:'update_solaris',meta:'{"solaris_delta":5,"solaris_balance":10}'}} />)
 fireEvent.click(screen.getByRole('button'))
 expect(screen.getByText('5 Solari added')).toBeInTheDocument()
 expect(screen.getByText('Balance')).toBeInTheDocument()
})
