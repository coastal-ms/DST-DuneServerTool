import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { api, ApiError, registerOnlinePlayerConfirmationHandler } from '../src/api/client'
import type { Command, CommandsResponse } from '../src/api/types'
import type { PortalAccountRole } from '../src/auth/portalAccess'
import { COMMAND_DECK_KEY } from '../src/hooks/useCommandDeck'
import { Commands } from '../src/pages/Commands'
import { COMMAND_CATEGORIES, getCommandCategory } from '../src/pages/commands/categories'

const state = vi.hoisted(() => ({
  local: true,
  role: null as PortalAccountRole,
  data: null as CommandsResponse | null,
  loading: false,
  error: null as string | null,
  refresh: vi.fn(async () => {}),
  forceRefresh: vi.fn(async () => {}),
  navigate: vi.fn(),
  search: '',
}))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => ({ forceRefresh: state.forceRefresh }) }))
vi.mock('../src/hooks/useApi', () => ({ useApi: () => ({
  data: state.data, loading: state.loading, error: state.error, refresh: state.refresh,
}) }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => state.local }))
vi.mock('../src/auth/PortalAuthGate', () => ({ usePortalAuth: () => ({
  status: { account: state.role ? { role: state.role } : null },
}) }))
vi.mock('../src/router', async importOriginal => ({
  ...await importOriginal<typeof import('../src/router')>(),
  useNavigate: () => state.navigate,
  useSearch: () => state.search,
}))
vi.mock('../src/api/client', async importOriginal => ({
  ...await importOriginal<typeof import('../src/api/client')>(),
  api: vi.fn(),
}))

function command(name: string, label: string, overrides: Partial<Command> = {}): Command {
  return {
    name, label, section: 'Battlegroup', key: '1', mode: 'Console', requires: 'running',
    external: true, desc: `Run the ${label.toLowerCase()} operation.`, available: true, reason: '',
    ...overrides,
  }
}

function fixture(): CommandsResponse {
  const commands = [
    command('start-vm', 'Start VM', { section: 'VM', requires: 'exists' }),
    command('reboot', 'Reboot VM', { section: 'VM' }),
    command('startup', 'Startup'),
    command('start', 'Start battlegroup'),
    command('restart', 'Restart battlegroup', { desc: 'Restart the game servers safely.' }),
    command('apply-inis', 'Apply INIs'),
    command('update', 'Update server'),
    command('delete-vm', 'Delete VM', { section: 'VM', requires: 'exists' }),
    command('inspect/logs', 'Inspect logs', { section: 'Tools', requires: 'none', mode: 'InApp' }),
    command('stop', 'Stop battlegroup', { available: false, reason: 'VM is not running.' }),
  ]
  return {
    state: {
      vmExists: true, vmRunning: true, bgState: 'running',
      vm: { exists: true, running: true, name: 'Test VM', state: 'Running', ip: null, uptime: 0 },
    },
    sectionNames: ['My VM', 'Game services', 'Tools'],
    sections: [
      ['start-vm', 'reboot', 'delete-vm'],
      ['startup', 'start', 'restart', 'apply-inis', 'update', 'stop'],
      ['inspect/logs'],
    ],
    commands,
  }
}

let unregisterGuard: (() => void) | undefined
beforeEach(() => {
  vi.useFakeTimers()
  vi.clearAllMocks()
  vi.mocked(api).mockReset()
  vi.mocked(api).mockResolvedValue({ ok: true, name: 'restart', mode: 'Console', pid: null, started: '' })
  localStorage.setItem(COMMAND_DECK_KEY, '1')
  vi.stubGlobal('matchMedia', () => ({ matches: false }))
  state.local = true
  state.search = ''
  state.role = null
  state.data = fixture()
  state.loading = false
  state.error = null
})
afterEach(() => {
  unregisterGuard?.()
  unregisterGuard = undefined
  cleanup()
  vi.clearAllTimers()
  vi.useRealTimers()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  localStorage.clear()
})

function choices() {
  return within(screen.getByRole('navigation', { name: 'Command categories' }))
}
function selectTask(name: RegExp) {
  const command = state.data?.commands.find(command => name.test(command.label || command.name))
  const category = command ? getCommandCategory(command) : 'tools'
  fireEvent.click(choices().getByRole('button', { name: COMMAND_CATEGORIES.find(group => group.id === category)!.label, exact: true }))
}

describe('Contextual Commands workbench', () => {
  it('opens server updates directly from Classic without running an operation', () => {
    localStorage.removeItem(COMMAND_DECK_KEY)
    state.search = 'task=updates'
    render(<Commands />)
    expect(screen.getByRole('heading', { name: 'Server updates', exact: true })).toBeInTheDocument()
    expect(screen.getAllByRole('article').map(article => article.getAttribute('aria-label'))).toEqual(['Update server'])
    expect(screen.getByRole('link', { name: 'All commands' })).toHaveAttribute('href', '/commands')
    expect(api).not.toHaveBeenCalled()
  })

  it.each(['owner', 'admin'] as const)('offers only update controls on the updates shortcut for remote %s', role => {
    state.local = false
    state.role = role
    state.search = 'task=updates'
    render(<Commands />)
    expect(screen.getAllByRole('article')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Run Update server' })).toBeInTheDocument()
    expect(api).not.toHaveBeenCalled()
  })

  it('opens a requested command category from Classic without dispatch', () => {
    localStorage.removeItem(COMMAND_DECK_KEY)
    state.search = 'category=vm'
    render(<Commands />)
    expect(screen.getByRole('button', { name: 'Run Reboot VM' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Run Update server' })).not.toBeInTheDocument()
    expect(api).not.toHaveBeenCalled()
  })
  it('offers a mobile category picker and clears global search when choosing a category', () => {
    render(<Commands />)
    fireEvent.change(screen.getByRole('searchbox', { name: 'Search all commands' }), { target: { value: 'inspect/logs' } })
    expect(screen.getByRole('combobox', { name: 'Category' })).toHaveValue('search')
    fireEvent.change(screen.getByRole('combobox', { name: 'Category' }), { target: { value: 'vm' } })
    expect(screen.getByRole('searchbox', { name: 'Search all commands' })).toHaveValue('')
    expect(screen.getAllByRole('article')).toHaveLength(4)
    expect(screen.queryByRole('button', { name: 'Run Inspect logs' })).not.toBeInTheDocument()
    expect(api).not.toHaveBeenCalled()
  })
  it('opens a purpose-based category with several controls, and keeps all operations reachable', () => {
    render(<Commands />)
    expect(screen.getAllByRole('article').map(article => article.getAttribute('aria-label'))).toEqual([
      'Start battlegroup', 'Restart battlegroup', 'Update server', 'Stop battlegroup',
    ])
    expect(screen.queryByRole('button', { name: 'Run Reboot VM' })).not.toBeInTheDocument()
    fireEvent.click(choices().getByRole('button', { name: 'All controls' }))
    expect(screen.getAllByRole('article')).toHaveLength(11)
    selectTask(/^Apply INIs/)
    expect(screen.getAllByRole('article')).toHaveLength(1)
    expect(screen.getByRole('heading', { name: 'Configuration' })).toBeInTheDocument()
    selectTask(/^Start VM/)
    expect(screen.getAllByRole('article').map(article => article.getAttribute('aria-label'))).toEqual([
      'Start VM', 'Reboot VM', 'Delete VM', 'Startup',
    ])
    expect(screen.queryByRole('button', { name: /^Reorder / })).not.toBeInTheDocument()
    expect(api).not.toHaveBeenCalled()
    expect(state.navigate).not.toHaveBeenCalled()
  })

  it('searches across every category and restores the category after clearing without executing', () => {
    const confirm = vi.spyOn(window, 'confirm')
    render(<Commands />)
    const search = screen.getByRole('searchbox', { name: 'Search all commands' })
    fireEvent.change(search, { target: { value: 'game safely' } })
    expect(screen.getAllByRole('article')).toHaveLength(1)
    const run = screen.getByRole('button', { name: 'Run Restart battlegroup' })
    expect(run).toBeEnabled()
    fireEvent.change(search, { target: { value: 'inspect/logs' } })
    expect(screen.getAllByRole('article')).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Run Inspect logs' })).toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'VM is not running' } })
    expect(screen.getByRole('button', { name: 'Run Stop battlegroup' })).toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'no such operation' } })
    expect(screen.getByText('No matching commands.')).toBeInTheDocument()
    expect(screen.queryByRole('article')).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Clear search' }))
    expect(screen.getByRole('button', { name: 'Run Restart battlegroup' })).toBeInTheDocument()
    fireEvent.change(search, { target: { value: 'My VM' } })
    expect(screen.getAllByRole('article')).toHaveLength(3)
    expect(api).not.toHaveBeenCalled()
    expect(confirm).not.toHaveBeenCalled()
    expect(state.navigate).not.toHaveBeenCalled()
  })

  it('supports keyboard selection without dispatch and uses the original encoded run endpoint only on Run', async () => {
    vi.useRealTimers()
    const user = userEvent.setup()
    render(<Commands />)
    choices().getByRole('button', { name: 'Terminals & Tools' }).focus()
    await user.keyboard('{Enter}')
    expect(api).not.toHaveBeenCalled()
    vi.useFakeTimers()
    vi.mocked(api).mockResolvedValueOnce({ ok: true, name: 'inspect/logs', mode: 'InApp', pid: 42, started: '' })
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run Inspect logs' })) })
    expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/run/inspect%2Flogs', { method: 'POST' })
    expect(screen.getByText("Launched 'inspect/logs' (PID 42) in a new console window.")).toBeInTheDocument()
    await act(async () => { await vi.advanceTimersByTimeAsync(1500) })
    expect(state.refresh).toHaveBeenCalledOnce()
    expect(state.forceRefresh).toHaveBeenCalledOnce()
  })

  it.each(['players_online', 'player_status_unknown'] as const)(
    'retains the %s guard, busy state, cancellation, and explicit forced retry',
    async conflict => {
      vi.mocked(api).mockRejectedValueOnce(new ApiError(409, 'Player safety check', {
        conflict, playersOnline: conflict === 'players_online' ? 1 : null,
        playerNames: ['Test player'], message: 'Confirm before continuing.',
      }))
      let answer!: (allow: boolean) => void
      const confirmation = new Promise<boolean>(resolve => { answer = resolve })
      const guard = vi.fn(() => confirmation)
      unregisterGuard = registerOnlinePlayerConfirmationHandler(guard)
      render(<Commands />)
      selectTask(/^Restart battlegroup/)
      expect(guard).not.toHaveBeenCalled()
      await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run Restart battlegroup' })) })
      expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/run/restart', { method: 'POST' })
      expect(guard).toHaveBeenCalledOnce()
      expect(screen.getByRole('button', { name: 'Launching…' })).toBeDisabled()
      expect(screen.getAllByRole('button', { name: /^Run / }).every(button => button.hasAttribute('disabled'))).toBe(true)
      expect(choices().getAllByRole('button').every(button => button.hasAttribute('disabled'))).toBe(true)
      fireEvent.click(screen.getByRole('button', { name: 'Launching…' }))
      expect(api).toHaveBeenCalledOnce()
      await act(async () => { answer(false) })
      expect(screen.getByRole('button', { name: 'Run Restart battlegroup' })).toBeEnabled()
      expect(api).toHaveBeenCalledOnce()
      expect(screen.queryByText(/Launch failed/)).not.toBeInTheDocument()

      unregisterGuard()
      unregisterGuard = registerOnlinePlayerConfirmationHandler(async () => true)
      vi.mocked(api).mockRejectedValueOnce(new ApiError(409, 'Player safety check', { conflict }))
      await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run Restart battlegroup' })) })
      expect(vi.mocked(api).mock.calls).toEqual([
        ['/api/commands/run/restart', { method: 'POST' }],
        ['/api/commands/run/restart', { method: 'POST' }],
        ['/api/commands/run/restart?force=true', { method: 'POST' }],
      ])
    },
  )

  it('shows current VM requirements and unavailable reasons, updating the selected task from refreshed data', () => {
    const view = render(<Commands />)
    selectTask(/^Stop battlegroup/)
    expect(within(screen.getByRole('article', { name: 'Stop battlegroup' })).getByText('Requires a running VM.')).toBeInTheDocument()
    expect(screen.getByText('VM is not running.')).toBeInTheDocument()
    const run = screen.getByRole('button', { name: 'Run Stop battlegroup' })
    expect(run).toBeDisabled()
    fireEvent.click(run)
    expect(api).not.toHaveBeenCalled()
    const fresh = fixture()
    fresh.commands = fresh.commands.map(item => item.name === 'stop' ? { ...item, available: true, reason: '' } : item)
    state.data = fresh
    view.rerender(<Commands />)
    expect(screen.getByRole('button', { name: 'Run Stop battlegroup' })).toBeEnabled()
    expect(screen.queryByText('VM is not running.')).not.toBeInTheDocument()
  })

  it.each<PortalAccountRole>(['admin', 'owner', null])(
    'preserves the remote allowlist and local-only boundaries for role %s, including an unplaced owner/admin update',
    role => {
      state.local = false
      state.role = role
      const data = fixture()
      data.sections[1] = data.sections[1].filter(name => name !== 'update')
      state.data = data
      render(<Commands />)
      fireEvent.click(choices().getByRole('button', { name: 'All controls' }))
      expect(screen.getAllByRole('article')).toHaveLength(role === 'owner' || role === 'admin' ? 7 : 6)
      for (const label of ['Start VM', 'Reboot VM', 'Startup', 'Start battlegroup', 'Restart battlegroup', 'Apply INIs']) {
        expect(screen.getByRole('button', { name: `Run ${label}` })).toBeInTheDocument()
      }
      expect(screen.queryByRole('button', { name: 'Run Update server' }) !== null).toBe(role === 'owner' || role === 'admin')
      expect(screen.queryByRole('button', { name: /Delete VM|Inspect logs|Stop battlegroup|Open PowerShell/ })).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Custom layout' })).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Reset layout' })).not.toBeInTheDocument()
      selectTask(/^Restart battlegroup/)
      expect(screen.getByRole('button', { name: 'Run Restart battlegroup' })).toBeEnabled()
      expect(api).not.toHaveBeenCalled()
    },
  )

  it('opens the existing local PowerShell route only after the explicit Open action', () => {
    render(<Commands />)
    selectTask(/^Open PowerShell/)
    expect(state.navigate).not.toHaveBeenCalled()
    expect(screen.getByText("Open DST's embedded PowerShell terminal on this computer.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Open PowerShell' }))
    expect(state.navigate).toHaveBeenCalledExactlyOnceWith('/terminal')
    expect(api).not.toHaveBeenCalled()
  })

  it('retains saved custom sections without overriding the purpose-based categories', async () => {
    render(<Commands />)
    selectTask(/^Restart battlegroup/)
    fireEvent.click(screen.getByRole('button', { name: 'Custom layout' }))
    expect(screen.queryByRole('region', { name: 'Command controls' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /^Reorder / })).toHaveLength(10)
    expect(screen.getByRole('button', { name: 'Reset layout' })).toBeInTheDocument()
    expect(api).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Game services' }))
    fireEvent.change(screen.getByRole('textbox'), { target: { value: 'Server tasks' } })
    fireEvent.keyDown(screen.getByRole('textbox'), { key: 'Enter' })
    expect(api).not.toHaveBeenCalled()
    await act(async () => { await vi.advanceTimersByTimeAsync(400) })
    expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/layout', {
      method: 'PUT',
      body: JSON.stringify({ sectionNames: ['My VM', 'Server tasks', 'Tools'], sections: fixture().sections }),
    })
    fireEvent.click(screen.getByRole('button', { name: 'Back to categories' }))
    expect(screen.getByRole('button', { name: 'Run Restart battlegroup' })).toBeInTheDocument()
    expect(choices().getByRole('button', { name: 'Battlegroup', exact: true })).toHaveAttribute('aria-pressed', 'true')
  })

  it('retains the exact layout-reset confirmation and does not reset when declined', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    render(<Commands />)
    fireEvent.click(screen.getByRole('button', { name: 'Custom layout' }))
    fireEvent.click(screen.getByRole('button', { name: 'Reset layout' }))
    expect(confirm).toHaveBeenCalledExactlyOnceWith('Reset the Commands page to its default layout (section names, order, and assignments)?')
    expect(api).not.toHaveBeenCalled()
    confirm.mockReturnValue(true)
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Reset layout' })) })
    expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/layout/reset', { method: 'POST' })
  })

  it('retains keyboard ordering through the original local drag handles without running a command', async () => {
    vi.useRealTimers()
    const user = userEvent.setup()
    const data = fixture()
    const order = data.sections.flat()
    const getRect = HTMLElement.prototype.getBoundingClientRect
    vi.spyOn(HTMLElement.prototype, 'getBoundingClientRect').mockImplementation(function (this: HTMLElement) {
      const label = this.firstElementChild?.getAttribute('aria-label')
      const index = order.indexOf(label?.replace('Reorder ', '') ?? '')
      return index < 0 ? getRect.call(this) : new DOMRect(0, index * 80, 300, 64)
    })
    render(<Commands />)
    await user.click(screen.getByRole('button', { name: 'Custom layout' }))
    screen.getByRole('button', { name: 'Reorder start-vm' }).focus()
    await user.keyboard('[Space][ArrowDown][Space]')
    await waitFor(() => expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/layout', {
      method: 'PUT',
      body: JSON.stringify({
        sectionNames: data.sectionNames,
        sections: [['reboot', 'start-vm', 'delete-vm'], data.sections[1], data.sections[2]],
      }),
    }))
  })

  it('retains classic sections, card actions, layout controls, and the local PowerShell link outside opt-in', async () => {
    localStorage.setItem(COMMAND_DECK_KEY, '0')
    render(<Commands />)
    expect(screen.queryByRole('searchbox')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Custom layout' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /^Reorder / })).toHaveLength(10)
    expect(screen.getByRole('button', { name: 'Reset layout' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Open PowerShell/ })).toBeInTheDocument()
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: /^1Restart battlegroup Console/ })) })
    expect(api).toHaveBeenCalledExactlyOnceWith('/api/commands/run/restart', { method: 'POST' })
  })

  it('preserves loading, error, refresh, and launch-failure feedback', async () => {
    state.data = null
    state.loading = true
    const view = render(<Commands />)
    expect(screen.getByText('Loading commands…')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Refresh' })).toBeDisabled()
    state.loading = false
    state.error = 'Commands could not be loaded.'
    view.rerender(<Commands />)
    expect(screen.getByText('Commands could not be loaded.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(state.refresh).toHaveBeenCalledOnce()
    expect(state.forceRefresh).toHaveBeenCalledOnce()

    state.data = fixture()
    state.error = null
    view.rerender(<Commands />)
    selectTask(/^Restart battlegroup/)
    vi.mocked(api).mockRejectedValueOnce(new Error('VM unavailable'))
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run Restart battlegroup' })) })
    expect(screen.getByText('Launch failed: VM unavailable')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Run Restart battlegroup' })).toBeEnabled()
  })
})
