import type { ReactNode } from 'react'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { Settings } from '../src/pages/Settings'

const state = vi.hoisted(() => ({
  api: vi.fn(),
  browse: { ok: true, cancelled: false, path: 'C:\\keys\\selected-private-key' },
  stripError: false,
}))
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
  window.history.replaceState(null, '', '/settings')
  state.browse = { ok: true, cancelled: false, path: 'C:\\keys\\selected-private-key' }
  state.stripError = false
  state.api.mockReset().mockImplementation(async (path: string) => {
    if (path === '/api/config') {
      return { path: 'config', exists: true, complete: true, keys: [], values: { SshKey: 'C:\\keys\\old-key', WindowsUser: 'saved-user', SteamPath: 'C:\\Steam' } }
    }
    if (path === '/api/browse-path') return state.browse
    if (path === '/api/config/strip-ssh-passphrase') {
      if (state.stripError) throw new Error('Incorrect passphrase.')
      return { ok: true, stripped: true, message: 'Passphrase removed.' }
    }
    throw new Error(`Unexpected API call: ${path}`)
  })
})

afterEach(() => { cleanup(); window.history.replaceState(null, '', '/'); vi.restoreAllMocks() })

async function openSettings() {
  render(<Settings />)
  const key = await screen.findByLabelText(/SSH private-key file/)
  fireEvent.change(screen.getByLabelText(/Windows username/), { target: { value: 'unsaved-user' } })
  return key
}

function expectNoRotation() {
  expect(state.api.mock.calls.filter(([path]) => path === '/api/config/rotate-ssh-key')).toHaveLength(0)
}

it('directs generation to Commands and retains existing-key controls', async () => {
  const key = await openSettings()
  expect(screen.queryByRole('button', { name: 'Generate new' })).not.toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Server Controls → Commands → Generate SSH key (g)' }))
    .toHaveAttribute('href', '/commands?category=network')
  expect(screen.getByTitle('Browse for file…')).toBeEnabled()
  expect(screen.getByRole('button', { name: 'Remove passphrase' })).toBeEnabled()
  expect(key).toHaveValue('C:\\keys\\old-key')
  expectNoRotation()
})

it('opens the Commands network category without rotating a key or saving drafts', async () => {
  await openSettings()
  fireEvent.click(screen.getByRole('link', { name: 'Server Controls → Commands → Generate SSH key (g)' }))
  expect(window.location.pathname + window.location.search).toBe('/commands?category=network')
  expect(state.api.mock.calls.every(([path, options]) => path === '/api/config' && !options?.method)).toBe(true)
})

it('browses for a private-key file without losing unrelated unsaved edits', async () => {
  const key = await openSettings()
  fireEvent.click(screen.getByTitle('Browse for file…'))
  await waitFor(() => expect(key).toHaveValue(state.browse.path))
  const request = state.api.mock.calls.find(([path]) => path === '/api/browse-path')
  expect(JSON.parse(request?.[1].body)).toMatchObject({ mode: 'file', current: 'C:\\keys\\old-key' })
  expect(screen.getByLabelText(/Windows username/)).toHaveValue('unsaved-user')
  expectNoRotation()
})

it.each([{ ok: true, cancelled: true }, { ok: false, cancelled: false }])(
  'preserves the selected key when browsing returns %j', async result => {
    state.browse = { ...state.browse, ...result }
    const key = await openSettings()
    fireEvent.click(screen.getByTitle('Browse for file…'))
    await waitFor(() => expect(screen.getByTitle('Browse for file…')).toBeEnabled())
    expect(key).toHaveValue('C:\\keys\\old-key')
    expect(screen.getByLabelText(/Windows username/)).toHaveValue('unsaved-user')
    expectNoRotation()
  },
)

async function removePassphrase() {
  const key = await openSettings()
  fireEvent.click(screen.getByRole('button', { name: 'Remove passphrase' }))
  const passphrase = screen.getByPlaceholderText('Current passphrase')
  fireEvent.change(passphrase, { target: { value: 'test-passphrase' } })
  fireEvent.keyDown(passphrase, { key: 'Enter' })
  return key
}

it('removes the passphrase while retaining the selected key and other drafts', async () => {
  const key = await removePassphrase()
  await screen.findByText('Passphrase removed.')
  const request = state.api.mock.calls.find(([path]) => path === '/api/config/strip-ssh-passphrase')
  expect(JSON.parse(request?.[1].body)).toEqual({ passphrase: 'test-passphrase' })
  expect(screen.queryByPlaceholderText('Current passphrase')).not.toBeInTheDocument()
  expect(key).toHaveValue('C:\\keys\\old-key')
  expect(screen.getByLabelText(/Windows username/)).toHaveValue('unsaved-user')
  expectNoRotation()
})

it('reports passphrase failure without changing the key selection', async () => {
  state.stripError = true
  const key = await removePassphrase()
  const error = await screen.findByText('Incorrect passphrase.')
  expect(error.closest('.text-danger')).not.toBeNull()
  expect(screen.getByPlaceholderText('Current passphrase')).toBeInTheDocument()
  expect(key).toHaveValue('C:\\keys\\old-key')
  expectNoRotation()
})
