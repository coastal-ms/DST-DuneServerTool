import React from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api } from '../src/api/client'
import { WindowsPerMapSettings } from '../src/pages/gameconfig/WindowsPerMapSettings'
import { VmStorageCard } from '../src/pages/database/VmStorageCard'
vi.mock('../src/api/client', () => ({ api: vi.fn(), withOnlinePlayerGuard: (run: (force: boolean) => unknown) => run(false) }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => true }))
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.resetAllMocks() })
const targets = [{ id: 'world:0:1', label: 'Sietch — partition 1' }, { id: 'world:0:17', label: 'Sietch — partition 17' }, { id: 'world:1:8', label: 'Deep Desert — partition 8' }, { id: 'world:1:21', label: 'Deep Desert — partition 21' }]
const snapshot = (target: string, value = '1.0') => ({ targets, target, file: 'server', revision: 'a'.repeat(64), raw: 'ini', overridden: false, canSave: true, fields: [{ id: 'CraftingCost', key: 'CraftingCost', label: 'Crafting cost', group: 'Crafting', value, type: 'float', editable: true, valid: true, supported: true, present: true, displayValue: value, inverted: false, options: [], validationError: '', readOnly: false }] })
describe('Partition settings selection', () => {
  beforeEach(() => {
    vi.mocked(api).mockImplementation(async (path, options) => {
      if (options?.method === 'PUT') { const body = JSON.parse(options.body as string); return snapshot(body.target, body.updates.CraftingCost) }
      if (path === '/api/map-settings') return { targets }
      return snapshot(new URL('http://local' + path).searchParams.get('target')!)
    })
  })
  it('defaults to Global with Game and Engine options and exposes only Custom settings for each partition', async () => {
    render(<WindowsPerMapSettings />)
    expect(screen.getByLabelText('Map settings target')).toHaveValue('global')
    expect(screen.getByLabelText('Global settings file')).toHaveValue('server')
    expect(screen.getByRole('option', { name: 'Game.ini' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Engine.ini' })).toBeInTheDocument()
    await screen.findByRole('option', { name: 'Sietch — partition 1' })
    expect(api).toHaveBeenCalledTimes(1)
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'world:0:1' } })
    expect(await screen.findByRole('slider', { name: /Crafting cost slider/ })).toBeInTheDocument()
    expect(screen.queryByLabelText('Global settings file')).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('slider', { name: /Crafting cost slider/ }), { target: { value: '2' } })
    expect(screen.getByRole('spinbutton', { name: /Crafting cost exact value/ })).toHaveValue(2)
    fireEvent.click(screen.getByRole('button', { name: 'Default Settings' }))
    expect(screen.getByRole('spinbutton', { name: /Crafting cost exact value/ })).toHaveValue(1)
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'global' } })
    expect(screen.getByLabelText('Global settings file')).toBeInTheDocument()
  })
  it('offers PvP and sandworm choices and saves running-map edits without any lifecycle request', async () => {
    const base = snapshot('world:1:21')
    const field = base.fields[0]
    const fields = [
      { ...field, id:'PVPMode',key:'PVPMode',label:'PvP Mode',type:'select',value:'Limited',options:['NoPVP','Limited','Full'] },
      { ...field, id:'SandwormConsequences',key:'SandwormConsequences',label:'Sandworm Consequences',type:'select',value:'None',options:['Default','None','Backpack','All'] },
    ]
    vi.mocked(api).mockImplementation(async (path, options) => path === '/api/map-settings' && !options ? {targets} : {...base,fields})
    render(<WindowsPerMapSettings />)
    await screen.findByRole('option', {name:'Deep Desert — partition 21'})
    fireEvent.change(screen.getByLabelText('Map settings target'), {target:{value:'world:1:21'}})
    fireEvent.change(await screen.findByRole('combobox',{name:'PvP Mode'}), {target:{value:'Full'}})
    fireEvent.change(screen.getByRole('combobox',{name:'Sandworm Consequences'}), {target:{value:'Backpack'}})
    expect(screen.getByText(/without starting or restarting/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button',{name:/Save map overrides/}))
    await waitFor(()=>expect(api).toHaveBeenCalledWith('/api/map-settings',expect.objectContaining({method:'PUT',body:expect.stringContaining('"SandwormConsequences":"Backpack"')})))
    expect(vi.mocked(api).mock.calls.some(([path])=>path.includes('/commands/'))).toBe(false)
    expect(await screen.findByText(/Pending the next battlegroup restart or scheduled maintenance through DST/)).toBeInTheDocument()
  })
  it('keeps drafts separate across multiple sietches and Deep Deserts and saves the selected ID only', async () => {
    render(<WindowsPerMapSettings />)
    await screen.findByRole('option', { name: 'Sietch — partition 1' })
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'world:0:1' } })
    const input = await screen.findByRole('spinbutton', { name: /Crafting cost/ })
    fireEvent.change(input, { target: { value: '0.5' } })
    await waitFor(() => expect(sessionStorage.getItem('dst.windows.map-settings.world:0:1.server')).toContain('0.5'))
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'world:1:21' } })
    await waitFor(() => expect(screen.getByRole('spinbutton', { name: /Crafting cost/ })).toHaveValue(1))
    fireEvent.change(screen.getByRole('spinbutton', { name: /Crafting cost/ }), { target: { value: '0.7' } })
    fireEvent.click(screen.getByRole('button', { name: /Save map overrides/ }))
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/map-settings', expect.objectContaining({ method: 'PUT', body: expect.stringContaining('world:1:21') })))
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'world:0:1' } })
    await waitFor(() => expect(screen.getByRole('spinbutton', { name: /Crafting cost/ })).toHaveValue(0.5))
  })
  it('shows stale draft conflicts and requires refresh before a server accepts changes', async () => {
    sessionStorage.setItem('dst.windows.map-settings.world:0:1.server', JSON.stringify({ snapshot: { ...snapshot('world:0:1'), revision: 'old' }, values: { CraftingCost: '0.3' } }))
    render(<WindowsPerMapSettings />)
    await screen.findByRole('option', { name: 'Sietch — partition 1' })
    fireEvent.change(screen.getByLabelText('Map settings target'), { target: { value: 'world:0:1' } })
    expect(await screen.findByRole('alert')).toHaveTextContent('Your draft is retained')
    expect(screen.getByRole('spinbutton', { name: /Crafting cost/ })).toHaveValue(0.3)
  })
})
describe('Guest storage explicit workflow', () => {
  it('does not inspect or mutate on entry, and a cancelled preview never expands storage', async () => {
    vi.mocked(api).mockImplementation(async path => path.endsWith('/status') ? { phase: 'idle' } : { supported: true, toolsReady: true, canGrow: true, revision: 'a'.repeat(64), disk: '/dev/sda', partition: '/dev/sda2', lv: '/dev/vg0/lv_root' })
    vi.spyOn(window, 'confirm').mockReturnValue(false)
    render(<VmStorageCard />)
    await waitFor(() => expect(api).toHaveBeenCalledTimes(1))
    fireEvent.click(screen.getByRole('button', { name: 'Inspect storage' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Expand root storage' }))
    expect(screen.getByText('Guest storage tools installed.')).toBeInTheDocument()
    expect(screen.queryByRole('button', {name:'Install guest storage tools'})).not.toBeInTheDocument()
    expect(api).not.toHaveBeenCalledWith('/api/vm-storage/expand', expect.anything())
  })
  it('offers missing prerequisites only after inspection and installs only on a deliberate click', async () => {
    vi.mocked(api).mockImplementation(async path => path.endsWith('/status') ? { phase: 'idle' } : { supported: false, canGrow: false, canInstallTools: true, reason: 'Install tools' })
    render(<VmStorageCard />)
    fireEvent.click(screen.getByRole('button', { name: 'Inspect storage' }))
    const install = await screen.findByRole('button', { name: 'Install guest storage tools' })
    expect(api).not.toHaveBeenCalledWith('/api/vm-storage/tools', expect.anything())
    fireEvent.click(install)
    await waitFor(() => expect(api).toHaveBeenCalledWith('/api/vm-storage/tools', { method: 'POST' }))
  })
})
