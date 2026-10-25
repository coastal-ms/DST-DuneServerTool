import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { HistorySection } from '../src/pages/gameplay/players/sections'
import { getPlayerEvents, type Player } from '../src/api/gameplay'
vi.mock('../src/api/gameplay', async original => ({...await original<typeof import('../src/api/gameplay')>(),getPlayerEvents:vi.fn()}))
afterEach(()=>{cleanup();vi.clearAllMocks()})
it('shows understandable currency activity without exposing raw metadata or internal identity',async()=>{
 vi.mocked(getPlayerEvents).mockResolvedValue({source:'live',events:[{id:1,ts:'2026-10-24T20:00:00Z',event_type:'update_solaris',meta:JSON.stringify({event:'adjust_player_virtual_currency_balance',fls_id:'private-character-id',solaris_delta:-3000,solaris_balance:997000})}]})
 const player={id:21,account_id:11,controller_id:31,name:'Own'} as Player
 render(<HistorySection player={player} canWrite demo refreshKey={0} flash={vi.fn()} onChanged={vi.fn()} />)
 fireEvent.click(await screen.findByRole('button',{name:/3,000 Solari removed/}))
 expect(screen.getByText('Balance')).toBeInTheDocument()
 expect(screen.getByText('997,000')).toBeInTheDocument()
 expect(screen.queryByText(/private-character-id|fls_id|adjust_player_virtual_currency_balance/)).not.toBeInTheDocument()
 expect(document.querySelector('pre')).not.toBeInTheDocument()
})
