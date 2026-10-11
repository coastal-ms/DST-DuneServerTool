import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SoloMods } from '../../src/components/solo/SoloMods'
const request = vi.hoisted(() => vi.fn())
vi.mock('../../src/api/client', () => ({ api: request }))
vi.mock('../../src/components/CollapsibleCard', () => ({ CollapsibleCard: ({ children, headerRight }: { children: React.ReactNode; headerRight: React.ReactNode }) => <div>{headerRight}{children}</div> }))
const mods = ['First', 'Second', 'Third'].map(name => ({ folder: name, id: name, name, version: '', enabled: true, errors: [] }))
afterEach(() => { cleanup(); vi.resetAllMocks() })
describe('Solo mod shortcuts and ordering', () => {
  it('persists the dropped order with enabled flags intact', async () => {
    request.mockResolvedValue({ mods, gamePath: 'C:/Dune', soloArguments: '', runtimeReady: true, session: null })
    render(<SoloMods />)
    const drag = await screen.findByRole('button', { name: 'Drag Third to reorder' })
    fireEvent.dragStart(drag, { dataTransfer: { setData: vi.fn(), effectAllowed: '' } })
    fireEvent.drop(screen.getByRole('button', { name: 'Drag First to reorder' }).parentElement!.parentElement!)
    await waitFor(() => expect(request).toHaveBeenCalledWith('/api/solo/mods/selection', expect.anything()))
    const call = request.mock.calls.find(call => call[0] === '/api/solo/mods/selection')!
    const saved = JSON.parse(call[1].body).mods
    expect(saved.map((mod: { folder: string }) => mod.folder)).toEqual(['Third', 'First', 'Second'])
    expect(saved.every((mod: { enabled: boolean }) => mod.enabled)).toBe(true)
  })
  it('creates a shortcut without launching the game', async () => {
    request.mockResolvedValue({ mods, gamePath: 'C:/Dune', soloArguments: '', runtimeReady: true, session: null })
    render(<SoloMods />)
    fireEvent.click(await screen.findByRole('button', { name: 'Create desktop shortcut' }))
    await waitFor(() => expect(request).toHaveBeenCalledWith('/api/solo/mods/shortcut', expect.objectContaining({ method: 'POST' })))
    expect(request.mock.calls.some(call => call[0] === '/api/solo/mods/launch')).toBe(false)
  })
})
