import type { ReactNode } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { Settings } from '../src/pages/Settings'

const state = vi.hoisted(() => ({ api: vi.fn(), result: { ok: true, rotated: true, keyPath: 'C:\\keys\\sshKey\\newkey-generated', message: 'SSH login verified.' }, failReload: false, failRotation: false }))
vi.mock('../src/api/client', () => ({ api: state.api }))
vi.mock('../src/hooks/useInstallationMode', () => ({ useSoloInstallation: () => false }))
vi.mock('../src/api/update', () => ({ checkForUpdate: async () => ({}), installUpdate: vi.fn(), listPreReleases: vi.fn(), setUpdateChannel: vi.fn(), setPreReleaseTag: vi.fn() }))
vi.mock('../src/hooks/useUpdateCheck', () => ({ publishUpdateCheck: vi.fn() }))
vi.mock('../src/components/CollapsibleCard', () => ({ CollapsibleCard: ({ title, children }: { title: string; children: ReactNode }) => <section><h2>{title}</h2>{children}</section>, useCardCollapse: () => ({ open: false, setOpen: vi.fn() }) }))
vi.mock('../src/pages/gameconfig/StartupSettingsSync', () => ({ StartupSettingsSync: () => null }))
vi.mock('../src/pages/settings/AppearanceCard', () => ({ AppearanceCard: () => null }))
vi.mock('../src/pages/settings/DashboardAlertsCard', () => ({ DashboardAlertsCard: () => null }))
vi.mock('../src/pages/settings/PublicIpCard', () => ({ PublicIpCard: () => null }))
vi.mock('../src/pages/settings/ServerBrowserPingCard', () => ({ ServerBrowserPingCard: () => null }))
vi.mock('../src/pages/settings/HyperVLanCard', () => ({ HyperVLanCard: () => null }))
vi.mock('../src/pages/settings/HyperVLifecycleCard', () => ({ HyperVLifecycleCard: () => null }))
vi.mock('../src/pages/settings/BrowserAccessCard', () => ({ BrowserAccessCard: () => null }))
vi.mock('../src/pages/settings/VmMapHelperCard', () => ({ VmMapHelperCard: () => null }))
vi.mock('../src/pages/settings/FlsTokenCard', () => ({ FlsTokenCard: () => null }))
vi.mock('../src/pages/settings/FreshStartSnapshotsCard', () => ({ FreshStartSnapshotsCard: () => null }))
vi.mock('../src/pages/settings/IniBackupsCard', () => ({ IniBackupsCard: () => null }))
vi.mock('../src/pages/settings/InstallLocationCard', () => ({ InstallLocationCard: () => null }))
vi.mock('../src/pages/settings/ShellPreferencesCard', () => ({ ShellPreferencesCard: () => null }))

beforeEach(() => {
  state.result = { ok: true, rotated: true, keyPath: 'C:\\keys\\sshKey\\newkey-generated', message: 'SSH login verified.' }
  state.failReload = false; state.failRotation = false
  let reads = 0
  state.api.mockReset().mockImplementation(async (path: string) => {
    if (path === '/api/config/rotate-ssh-key') {
      if (state.failRotation) throw new Error('Authorization failed.')
      return state.result
    }
    if (path === '/api/config') {
      reads++
      if (reads > 1 && state.failReload) throw new Error('Reload unavailable')
      return { path: 'config', exists: true, complete: true, keys: [], values: { SshKey: reads > 1 ? state.result.keyPath : 'C:\\keys\\old-key', WindowsUser: 'saved-user', SteamPath: 'C:\\Steam' } }
    }
    throw new Error(`Unexpected API call: ${path}`)
  })
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})
afterEach(() => { cleanup(); vi.restoreAllMocks() })

async function generate() {
  render(<Settings />)
  const key = await screen.findByLabelText(/SSH private-key file/)
  fireEvent.change(screen.getByLabelText(/Windows username/), { target: { value: 'unsaved-user' } })
  fireEvent.click(screen.getByRole('button', { name: 'Generate new' }))
  return key
}

it('selects the verified private-key filename and preserves unrelated unsaved edits', async () => {
  const key = await generate()
  await screen.findByText('SSH login verified.')
  await waitFor(() => expect(state.api.mock.calls.filter(([path]) => path === '/api/config')).toHaveLength(2))
  expect(key).toHaveValue(state.result.keyPath)
  expect(screen.getByLabelText(/Windows username/)).toHaveValue('unsaved-user')
})
it('retains the verified file selection if the follow-up configuration read fails', async () => {
  state.failReload = true
  const key = await generate()
  await screen.findByText('SSH login verified.')
  expect(key).toHaveValue(state.result.keyPath)
})
it.each([{ ok: false, rotated: false }, { ok: true, rotated: false }])('never shows a success check for an incomplete rotation (%j)', async result => {
  state.result = { ...state.result, ...result, message: 'Rotation is still pending.' }
  const key = await generate()
  const pending = await screen.findByText('Rotation is still pending.')
  expect(pending.closest('.text-success')).toBeNull()
  expect(key).toHaveValue('C:\\keys\\old-key')
  expect(state.api.mock.calls.filter(([path]) => path === '/api/config')).toHaveLength(1)
})
it('shows authorization failure without changing the key selection', async () => {
  state.failRotation = true
  const key = await generate()
  expect(await screen.findByText('Authorization failed.')).toBeInTheDocument()
  expect(key).toHaveValue('C:\\keys\\old-key')
  expect(screen.queryByText('SSH login verified.')).not.toBeInTheDocument()
})
