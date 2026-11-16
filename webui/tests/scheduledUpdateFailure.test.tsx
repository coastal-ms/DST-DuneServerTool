import { afterEach, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { ScheduledRestarts } from '../src/pages/dashboard/ScheduledRestarts'

const api = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('../src/api/restartSchedule', () => ({
  getRestartSchedule: api.get, saveRestartSchedule: vi.fn(), checkFuncomUpdate: vi.fn(), testDiscordWebhook: vi.fn(),
}))
const schedule = (source = 'steamcmd', action = 'update-failed-restart-ok') => ({
  enabled: true, time: '04:00', broadcastLeadMinutes: 10, applyFuncomUpdates: true,
  discordEnabled: false, discordNotifyOnline: false, discordNotifyOffline: false,
  discordNotifyRestarting: false, discordNotifyUpdate: true, discordWebhookSet: true, discordMentionId: '',
  lastRestartDate: '', lastResult: '', updateAvailable: true, installedBuild: '100', latestBuild: '200', updateCheckedAt: '',
  updateFailure: { source, code: source === 'steamcmd' ? '0x6' : '', action, occurredAt: '2026-11-12T10:00:00Z', installedBuild: '100', latestBuild: '200', exitCode: 7 },
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); api.get.mockReset(); localStorage.clear() })

it('shows a failure while collapsed, distinguishes the old-build restart and links the Discord FAQ', async () => {
  api.get.mockResolvedValue(schedule())
  render(<ScheduledRestarts />)
  expect(await screen.findByRole('alert')).toHaveTextContent('SteamCMD reported error 0x6')
  expect(screen.getByRole('alert')).toHaveTextContent('Server restarted on the previous build')
  expect(screen.getByRole('link', { name: 'SteamCMD update FAQ (Discord)' })).toBeVisible()
  fireEvent.click(screen.getByText('Review update error'))
  expect(screen.getByRole('link', { name: 'SteamCMD update FAQ (Discord)' })).toHaveAttribute('href', 'https://discord.com/channels/1517599283757453333/1563393833197117510/1563393833197117510')
  expect(screen.getByRole('link', { name: 'Server updates' })).toHaveAttribute('href', '/commands?task=updates')
  expect(screen.getByRole('alert')).toHaveTextContent('Installed build 100; available build 200')
})

it('keeps an unknown updater cause generic and does not claim the fallback succeeded', async () => {
  api.get.mockResolvedValue(schedule('server-update', 'update-failed-restart-failed'))
  render(<ScheduledRestarts />)
  const warning = await screen.findByRole('alert')
  expect(warning).toHaveTextContent('updater cause not identified')
  expect(warning).toHaveTextContent('fallback server restart also failed')
  expect(warning).not.toHaveTextContent('SteamCMD reported error')
})

it('removes the warning when polling reports a resolved failure', async () => {
  let poll: (() => void) | undefined
  vi.spyOn(window, 'setInterval').mockImplementation((callback, delay) => { if (delay === 30_000) poll = callback as () => void; return 42 })
  api.get.mockResolvedValueOnce(schedule()).mockResolvedValue({ ...schedule(), updateFailure: null })
  render(<ScheduledRestarts />)
  await screen.findByRole('alert')
  await act(async () => { poll!() })
  await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
})

it('refreshes a failure without replacing an unsaved schedule edit', async () => {
  let poll: (() => void) | undefined
  vi.spyOn(window, 'setInterval').mockImplementation((callback, delay) => { if (delay === 30_000) poll = callback as () => void; return 42 })
  api.get.mockResolvedValue(schedule())
  render(<ScheduledRestarts />)
  await screen.findByRole('alert')
  fireEvent.click(screen.getByRole('button', { name: /Scheduled restarts/i }))
  fireEvent.change(screen.getByLabelText('Daily restart time'), { target: { value: '06:30' } })
  await act(async () => { poll!() })
  await waitFor(() => expect(api.get).toHaveBeenCalled())
  expect(screen.getByLabelText('Daily restart time')).toHaveValue('06:30')
})
