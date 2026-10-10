import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api } from '../src/api/client'
import { SoloMods } from '../src/components/solo/SoloMods'
vi.mock('../src/api/client', () => ({api: vi.fn()}))
vi.mock('../src/util/pathPicker', () => ({pickLocalFolder: vi.fn()}))
const state = {mods: [{folder: 'Example', id: 'Example', name: 'Example', version: '1.0', enabled: false, warnings: ['Declares WPS Launcher'], errors: ['Missing or disabled dependency: Framework']}], folder: 'C:/DST/Mods', gamePath: 'C:/Dune', skipIntro: false, runtimeReady: true, session: null}
beforeEach(() => { vi.mocked(api).mockImplementation(async () => state) })
afterEach(() => { cleanup(); vi.clearAllMocks(); localStorage.clear() })
describe('Solo mod controls', () => {
  it('saves the moved order and disables moves at the list boundaries', async () => {
    const other = {...state.mods[0], folder:'Other', id:'Other', name:'Other', enabled:true, errors:[]}
    vi.mocked(api).mockImplementation(async () => ({...state, mods:[state.mods[0], other]}))
    render(<SoloMods />)
    fireEvent.click(screen.getByRole('button', {name:/Solo mods/}))
    await screen.findByText('Example')
    expect(screen.getByRole('link', {name:/Browse Dune/})).toHaveAttribute('href', 'https://www.nexusmods.com/duneawakening')
    expect(screen.getByRole('button', {name:'Move Example up'})).toBeDisabled()
    expect(screen.getByRole('button', {name:'Move Other down'})).toBeDisabled()
    fireEvent.click(screen.getByRole('button', {name:'Move Other up'}))
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/solo/mods/selection', {method:'POST',body:JSON.stringify({mods:[other,state.mods[0]],gamePath:state.gamePath})}))
  })
  it('shows dependency errors and keeps normal and modded launches separate', async () => {
    render(<SoloMods />)
    expect(screen.getByRole('button', {name: /Solo mods/})).toHaveAttribute('aria-expanded', 'false')
    fireEvent.click(screen.getByRole('button', {name: /Solo mods/}))
    await screen.findByText('Example')
    expect(screen.getByText(/We make no guarantees.*does not provide individual mod troubleshooting/)).toBeInTheDocument()
    expect(screen.queryByText('Declares WPS Launcher')).not.toBeInTheDocument()
    expect(screen.getByText(/Missing or disabled dependency/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', {name: /Solo mods/}))
    expect(screen.queryByText('Example')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', {name: 'Launch Normally'}))
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/solo/mods/launch', {method:'POST',body:JSON.stringify({withMods:false})}))
    await waitFor(() => expect(screen.getByRole('button', {name:'Launch with Mods'})).toBeEnabled())
    fireEvent.click(screen.getByRole('button', {name: 'Launch with Mods'}))
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/solo/mods/launch', {method:'POST',body:JSON.stringify({withMods:true})}))
    expect(screen.getByRole('button', {name: /Solo mods/})).toHaveAttribute('aria-expanded', 'false')
  })
  it('imports the selected ZIP and preserves visible loader errors', async () => {
    vi.mocked(api).mockImplementation(async path => {
      if(path === '/api/browse-path') return {cancelled:false,path:'C:/Downloads/mod.zip'}
      if(path === '/api/solo/mods/import') throw new Error('Missing mod entry point')
      return state
    })
    render(<SoloMods />)
    fireEvent.click(screen.getByRole('button', {name: /Solo mods/}))
    await screen.findByText('Example')
    fireEvent.click(screen.getByRole('button', {name:'Install mod ZIP'}))
    await screen.findByRole('alert')
    expect(screen.getByRole('alert')).toHaveTextContent('Missing mod entry point')
    expect(api).toHaveBeenCalledWith('/api/solo/mods/import', {method:'POST',body:JSON.stringify({path:'C:/Downloads/mod.zip'})})
  })
})
