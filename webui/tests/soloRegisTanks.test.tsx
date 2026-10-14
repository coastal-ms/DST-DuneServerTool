import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloRegisTanks } from '../src/components/solo/SoloRegisTanks'
import { api } from '../src/api/client'
vi.mock('../src/api/client', () => ({api: vi.fn()}))
afterEach(() => { cleanup(); vi.resetAllMocks() })
it('grants the selected variant using buttons without reserving hotkeys', async () => {
 vi.mocked(api).mockImplementation(async path => path.endsWith('/status') ? {worldReady:true} : {message:'Grant requested'})
 render(<SoloRegisTanks connectionToken="test" />)
 expect(screen.getByText('Grant Regis Tanks')).toBeInTheDocument()
 expect(screen.queryByText(/F8|F9/)).not.toBeInTheDocument()
 await waitFor(() => expect(screen.getByRole('button', {name:'Grant Dart Tank'})).toBeEnabled())
 fireEvent.click(screen.getByRole('button', {name:'Grant Dart Tank'}))
 expect(await screen.findByRole('status')).toHaveTextContent('Grant requested')
 expect(api).toHaveBeenLastCalledWith('/api/solo/mods/regis-tanks', {method:'POST',body:JSON.stringify({preset:'T6_CombatDart'})})
 fireEvent.click(screen.getByRole('button', {name:'Grant Flamethrower Tank'}))
 expect(api).toHaveBeenLastCalledWith('/api/solo/mods/regis-tanks', {method:'POST',body:JSON.stringify({preset:'T6_CombatFire'})})
})
it('keeps both grant buttons disabled while the world is not loaded', async () => {
 vi.mocked(api).mockResolvedValue({worldReady:false})
 render(<SoloRegisTanks connectionToken="test" />)
 await waitFor(() => expect(api).toHaveBeenCalledWith('/api/solo/mods/regis-tanks/status'))
 expect(screen.getByRole('button', {name:'Grant Dart Tank'})).toBeDisabled()
 expect(screen.getByRole('button', {name:'Grant Flamethrower Tank'})).toBeDisabled()
 fireEvent.click(screen.getByRole('button', {name:'Grant Dart Tank'}))
 expect(api).not.toHaveBeenCalledWith('/api/solo/mods/regis-tanks',expect.anything())
})
