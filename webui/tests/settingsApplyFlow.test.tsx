import { useState } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ServerSettings } from '../src/pages/ServerSettings'
import { clearSettingsApplyResult, useSettingsApplyOperation } from '../src/hooks/useSettingsApplyOperation'
import { useSettingsDraft } from '../src/pages/gameconfig/settingsApplyContext'

const state = vi.hoisted(() => ({
  managed: true, stopped: false, outsideEdit: false, fail: '', events: [] as string[],
  api: vi.fn(),
}))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({
  status: { vm: { running: true }, bg: { state: state.stopped ? 'stopped' : 'running', gameServers: state.stopped ? [] : [{}] } },
  forceRefresh: async () => {},
}) }))
vi.mock('../src/api/client', async original => ({ ...await original<typeof import('../src/api/client')>(), api: state.api }))
vi.mock('../src/pages/gameconfig/StartupSettingsSync', () => ({ StartupSettingsSync: () => null }))
vi.mock('../src/pages/gameconfig/RegisTankSetup', () => ({ RegisTankSetup: () => null }))
vi.mock('../src/pages/gameconfig/ServerIniBackups', () => ({ ServerIniBackups: () => null }))
vi.mock('../src/pages/gameconfig/OfficialRetailServerSettingsCard', () => ({ OfficialRetailServerSettingsCard: () => <Draft id="official" /> }))
vi.mock('../src/pages/GameConfig', () => ({ GameConfig: () => <Draft id="advanced" /> }))

function Draft({ id }: { id: string }) {
  const [value, setValue] = useState('old')
  useSettingsDraft(id, {
    ready: true,
    changes: value === 'old' ? [] : [{ label: id, before: 'old', after: value, target: 'Server only' }],
    validate: async () => { if (state.outsideEdit) throw new Error('Outside edit detected') },
    apply: async () => {
      state.events.push(`save:${id}:${value}`)
      if (state.fail === id) throw new Error(`${id} write failed`)
      setValue('old')
    },
  })
  return <input aria-label={`${id} value`} value={value} onChange={e => setValue(e.target.value)} />
}

beforeEach(() => {
  clearSettingsApplyResult()
  state.managed = true; state.stopped = false; state.outsideEdit = false; state.fail = ''; state.events = []
  state.api.mockReset().mockImplementation(async (path: string, options?: RequestInit) => {
    if (path === '/api/gameconfig/retail-startup-sync') return { enabled: state.managed }
    if (path === '/api/status/refresh') return { vm: { running: true }, bg: { state: state.stopped ? 'stopped' : 'running', gameServers: state.stopped ? [] : [{}] } }
    if (path.startsWith('/api/commands/run/stop')) { state.events.push('stop'); state.stopped = true; return { ok: true } }
    if (path.startsWith('/api/gameconfig/reload-pods')) { state.events.push('deploy:start'); expect(JSON.parse(options?.body as string)).toEqual({ startStopped: true }); return { message: 'Start launched' } }
    throw new Error(`Unexpected ${path}`)
  })
})
afterEach(() => { cleanup(); vi.useRealTimers() })

async function editBothAndReview() {
  fireEvent.change(screen.getByLabelText('official value'), { target: { value: 'official draft' } })
  fireEvent.click(screen.getByRole('button', { name: 'Advanced server controls' }))
  fireEvent.change(screen.getByLabelText('advanced value'), { target: { value: 'advanced draft' } })
  fireEvent.click(screen.getByRole('button', { name: /Review & Apply/ }))
  return await screen.findByRole('alertdialog')
}

it('reviews both drafts, preserves them across tabs, and stops before writing and deploying once', async () => {
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  expect(dialog).toHaveTextContent('old → official draft')
  expect(dialog).toHaveTextContent('old → advanced draft')
  expect(state.events).toEqual([])
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  fireEvent.click(screen.getByRole('button', { name: 'Applying settings… (2)' }))
  await waitFor(() => expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft', 'deploy:start']), { timeout: 4000 })
  expect(await screen.findByRole('status')).toHaveTextContent('Start launched')
  expect(within(screen.getByRole('region', { name: 'Settings actions' })).getByRole('status')).toHaveTextContent('Start launched')
})

it('keeps manual mode off, saves files only and leaves the battlegroup stopped', async () => {
  state.managed = false
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  expect(dialog).toHaveTextContent('files only')
  expect(within(dialog).queryByRole('checkbox')).not.toBeInTheDocument()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save files; leave stopped' }))
  expect(await screen.findByText(/Settings saved to files only/, {}, { timeout: 4000 })).toBeInTheDocument()
  expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft'])
})

it('rejects an outside edit before sending stop or any writes', async () => {
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  state.outsideEdit = true
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('Outside edit detected')
  expect(state.events).toEqual([])
  expect(screen.getByLabelText('advanced value')).toHaveValue('advanced draft')
})

it('reports a partial save, preserves the failed draft, and never starts after a write failure', async () => {
  state.fail = 'advanced'
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  expect(await screen.findByRole('alert', {}, { timeout: 4000 })).toHaveTextContent('Already saved: official')
  expect(within(screen.getByRole('region', { name: 'Settings actions' })).getByRole('alert')).toHaveTextContent('Already saved: official')
  expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft'])
  expect(screen.getByLabelText('advanced value')).toHaveValue('advanced draft')
})

it('cancels the review without changing files or server state', async () => {
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Cancel' }))
  expect(state.events).toEqual([])
  expect(screen.getByLabelText('advanced value')).toHaveValue('advanced draft')
})

it('defaults to deploying and starting an already stopped managed battlegroup', async () => {
  state.stopped = true
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  expect(within(dialog).getByRole('checkbox')).toBeChecked()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  await waitFor(() => expect(state.events).toEqual(['save:official:official draft', 'save:advanced:advanced draft', 'deploy:start']))
})

it('leaves a managed battlegroup stopped when the user deliberately unchecks starting', async () => {
  state.stopped = true
  render(<ServerSettings />)
  const dialog = await editBothAndReview()
  expect(within(dialog).getByRole('checkbox')).toBeChecked()
  fireEvent.click(within(dialog).getByRole('checkbox'))
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save files; leave stopped' }))
  await waitFor(() => expect(state.events).toEqual(['save:official:official draft', 'save:advanced:advanced draft']))
  expect(await screen.findByRole('status')).toHaveTextContent('remains stopped')
})

it('defaults to starting saved settings even when there are no drafts', async () => {
  state.stopped = true
  render(<ServerSettings />)
  fireEvent.click(screen.getByRole('button', { name: /Review & Apply/ }))
  const dialog = await screen.findByRole('alertdialog')
  expect(within(dialog).getByRole('checkbox')).toBeChecked()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  await waitFor(() => expect(state.events).toEqual(['deploy:start']))
})

function ApplyObserver() {
  const state = useSettingsApplyOperation()
  return <output data-testid="apply-observer">{JSON.stringify(state)}</output>
}

it('finishes the approved saves and restart after navigating away while stop is pending', async () => {
  let releaseStop!: () => void
  const stopped = new Promise<void>(resolve => { releaseStop = resolve })
  const original = state.api.getMockImplementation()!
  state.api.mockImplementation(async (path: string, options?: RequestInit) => {
    if (path.startsWith('/api/commands/run/stop')) await stopped
    return original(path, options)
  })
  const settings = render(<ServerSettings />)
  const dialog = await editBothAndReview()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  await waitFor(() => expect(state.api).toHaveBeenCalledWith('/api/commands/run/stop', expect.anything()))
  // A later form render must not replace the values the user already approved.
  fireEvent.change(screen.getByLabelText('advanced value'), { target: { value: 'not approved' } })
  settings.unmount()
  render(<ApplyObserver />)
  expect(screen.getByTestId('apply-observer')).toHaveTextContent('"running":true')
  await act(async () => { releaseStop() })
  await waitFor(() => expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft', 'deploy:start']), { timeout: 4000 })
  await waitFor(() => expect(screen.getByTestId('apply-observer')).toHaveTextContent('"running":false'))
  expect(screen.getByTestId('apply-observer')).toHaveTextContent('Start launched')
})

it('keeps the second mounted settings page locked while the original apply continues', async () => {
  let releaseStop!: () => void
  const stopped = new Promise<void>(resolve => { releaseStop = resolve })
  const original = state.api.getMockImplementation()!
  state.api.mockImplementation(async (path: string, options?: RequestInit) => {
    if (path.startsWith('/api/commands/run/stop')) await stopped
    return original(path, options)
  })
  const settings = render(<ServerSettings />)
  const dialog = await editBothAndReview()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  await waitFor(() => expect(state.api).toHaveBeenCalledWith('/api/commands/run/stop', expect.anything()))
  settings.unmount()
  render(<ServerSettings />)
  expect(screen.getByRole('button', { name: /Applying settings/ })).toBeDisabled()
  await act(async () => { releaseStop() })
  await waitFor(() => expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft', 'deploy:start']), { timeout: 4000 })
})

it('reports a save failure after navigation and does not restart', async () => {
  state.fail = 'advanced'
  let releaseStop!: () => void
  const stopped = new Promise<void>(resolve => { releaseStop = resolve })
  const original = state.api.getMockImplementation()!
  state.api.mockImplementation(async (path: string, options?: RequestInit) => {
    if (path.startsWith('/api/commands/run/stop')) await stopped
    return original(path, options)
  })
  const settings = render(<ServerSettings />)
  const dialog = await editBothAndReview()
  fireEvent.click(within(dialog).getByRole('button', { name: 'Save & start battlegroup' }))
  await waitFor(() => expect(state.api).toHaveBeenCalledWith('/api/commands/run/stop', expect.anything()))
  settings.unmount()
  render(<ApplyObserver />)
  await act(async () => { releaseStop() })
  await waitFor(() => expect(screen.getByTestId('apply-observer')).toHaveTextContent('Already saved: official'), { timeout: 4000 })
  expect(state.events).toEqual(['stop', 'save:official:official draft', 'save:advanced:advanced draft'])
})
