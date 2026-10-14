import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { RegisTankSetup } from '../src/pages/gameconfig/RegisTankSetup'
const request=vi.hoisted(() => vi.fn())
vi.mock('../src/api/client',()=>({api:request}))
afterEach(()=>{cleanup();vi.resetAllMocks()})
it('reports automatic startup support without mutation controls',async()=>{
 request.mockResolvedValue({enabled:false,supported:true})
 render(<RegisTankSetup vmRunning stopped />)
 expect(await screen.findByText('Tank support will be prepared at the next battlegroup start.')).toBeInTheDocument()
 expect(screen.queryByRole('button')).not.toBeInTheDocument()
 expect(request.mock.calls).toEqual([['/api/gameconfig/regis-tanks']])
})
it('reports unsupported builds without requesting activation',async()=>{
 request.mockResolvedValue({enabled:false,supported:false})
 render(<RegisTankSetup vmRunning stopped />)
 expect(await screen.findByText('Tank support is unavailable for this server build.')).toBeInTheDocument()
 expect(request).toHaveBeenCalledOnce()
})
