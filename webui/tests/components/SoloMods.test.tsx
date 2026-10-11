import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { SoloMods } from '../../src/components/solo/SoloMods'
const request = vi.hoisted(() => vi.fn())
vi.mock('../../src/api/client', () => ({ api: request }))
vi.mock('../../src/components/CollapsibleCard', () => ({ CollapsibleCard: ({ children, headerRight }: { children: React.ReactNode; headerRight: React.ReactNode }) => <div>{headerRight}{children}</div> }))
const mods = ['First', 'Second', 'Third'].map(name => ({ folder: name, id: name, name, version: '', enabled: true, errors: [] }))
afterEach(() => { cleanup(); vi.resetAllMocks(); vi.restoreAllMocks() })
describe('Solo mod shortcuts and ordering', () => {
  it('persists the dropped order with enabled flags intact', async () => {
    request.mockResolvedValue({ mods, gamePath: 'C:/Dune', soloArguments: '', runtimeReady: true, session: null })
    render(<SoloMods />)
    const drag = await screen.findByRole('button', { name: 'Reorder Third' })
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
      const label = this.querySelector('button[aria-label^="Reorder"]')?.getAttribute('aria-label')
      const index = label ? ['Reorder First', 'Reorder Second', 'Reorder Third'].indexOf(label) : 0
      return { x: 0, y: index * 100, top: index * 100, bottom: index * 100 + 80, left: 0, right: 400, width: 400, height: 80, toJSON: () => ({}) }
    })
    drag.focus()
    fireEvent.keyDown(drag, { code: 'Space' })
    await new Promise(resolve => setTimeout(resolve, 20))
    const preview = document.body.querySelector('.shadow-lg')
    expect(preview).not.toBeNull()
    expect(preview!.parentElement!.parentElement).toBe(document.body)
    fireEvent.keyDown(document, { code: 'ArrowUp' })
    fireEvent.keyDown(document, { code: 'ArrowUp' })
    fireEvent.keyDown(document, { code: 'Space' })
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
