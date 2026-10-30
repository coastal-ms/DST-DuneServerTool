import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { PlayerGameServerCard } from '../src/components/PlayerGameServerCard'
afterEach(cleanup)
it('mirrors player-relevant server and map readiness without server controls', () => {
 render(<PlayerGameServerCard status={{available:true,state:'running',serverName:'Fixture',ready:true,maps:[{map:'Survival_1',state:'Ready',ready:true,players:2},{map:'DeepDesert_1',state:'Starting',ready:false,players:0}]}} />)
 expect(screen.getByRole('heading',{name:'Game Server — Fixture'})).toBeInTheDocument()
 expect(screen.getByText('Hagga Basin')).toBeInTheDocument()
 expect(screen.getByText('Starting')).toBeInTheDocument()
 expect(screen.getByText('2 players')).toBeInTheDocument()
 expect(screen.queryByRole('button')).not.toBeInTheDocument()
})
it('shows unavailable instead of a healthy server when status cannot be read', () => {
 render(<PlayerGameServerCard status={{available:false,state:'unavailable'}} />)
 expect(screen.getByText('Unavailable')).toBeInTheDocument()
 expect(screen.getByText('Map status is unavailable.')).toBeInTheDocument()
})
