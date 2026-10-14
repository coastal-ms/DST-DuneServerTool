import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloRegisTanks } from '../src/components/solo/SoloRegisTanks'
import { api } from '../src/api/client'
vi.mock('../src/api/client', () => ({api: vi.fn()}))
afterEach(cleanup)
it('grants the selected variant using buttons without reserving hotkeys', async () => {
 vi.mocked(api).mockResolvedValue({message:'Grant requested'})
 render(<SoloRegisTanks connectionToken="test" />)
 expect(screen.getByText('Grant Regis Tanks')).toBeInTheDocument()
 expect(screen.queryByText(/F8|F9/)).not.toBeInTheDocument()
 fireEvent.click(screen.getByRole('button', {name:'Grant Dart Tank'}))
 expect(await screen.findByRole('status')).toHaveTextContent('Grant requested')
 expect(api).toHaveBeenLastCalledWith('/api/solo/mods/regis-tanks', {method:'POST',body:JSON.stringify({preset:'T6_CombatDart'})})
 fireEvent.click(screen.getByRole('button', {name:'Grant Flamethrower Tank'}))
 expect(api).toHaveBeenLastCalledWith('/api/solo/mods/regis-tanks', {method:'POST',body:JSON.stringify({preset:'T6_CombatFire'})})
})
