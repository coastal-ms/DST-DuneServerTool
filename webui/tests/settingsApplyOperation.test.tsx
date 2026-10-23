import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { SettingsApplyProgress } from '../src/components/SettingsApplyProgress'
import { clearSettingsApplyResult, runSettingsApply } from '../src/hooks/useSettingsApplyOperation'
import type { StatusSnapshot } from '../src/api/types'

const live = vi.hoisted(() => ({ status: null as StatusSnapshot | null }))
vi.mock('../src/hooks/useStatus', () => ({ useStatusSnapshot: () => live.status }))

beforeEach(() => { clearSettingsApplyResult(); live.status = null })
afterEach(() => { cleanup() })

it('shows progress outside the settings route and warns before closing until the apply finishes', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  render(<SettingsApplyProgress />)
  let task!: Promise<void>
  act(() => { task = runSettingsApply(async update => { update({ message: 'Stopping the battlegroup…' }); await gate; update({ message: 'Start launched.' }) }) })
  expect(screen.getByRole('status')).toHaveTextContent('Stopping the battlegroup')
  expect(screen.getByRole('link', { name: 'Server Overview' })).toHaveAttribute('href', '/')
  expect(screen.getByText(/Keep DST open until this finishes/)).toBeInTheDocument()
  const close = new Event('beforeunload', { cancelable: true })
  window.dispatchEvent(close)
  expect(close.defaultPrevented).toBe(true)
  await act(async () => { finish(); await task })
  expect(screen.getByRole('status')).toHaveTextContent('Start launched.')
  const closedAfterFinish = new Event('beforeunload', { cancelable: true })
  window.dispatchEvent(closedAfterFinish)
  expect(closedAfterFinish.defaultPrevented).toBe(false)
  fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }))
  expect(screen.queryByRole('status')).not.toBeInTheDocument()
})

it('rejects a second apply while the first owns the sequence', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const duplicate = vi.fn()
  const first = runSettingsApply(async () => { await gate })
  await runSettingsApply(duplicate)
  expect(duplicate).not.toHaveBeenCalled()
  finish(); await first
})

it('keeps a failure visible after the operation finishes, including when progress already existed', async () => {
  render(<SettingsApplyProgress />)
  await act(async () => {
    await runSettingsApply(async update => { update({ message: 'Saving…' }); throw new Error('Write failed; the battlegroup remains stopped.') })
  })
  expect(screen.getByRole('alert')).toHaveTextContent('Write failed; the battlegroup remains stopped.')
})

it('replaces stopping with the observed stopped state while the apply request is still pending', async () => {
  let finish!: () => void
  const gate = new Promise<void>(resolve => { finish = resolve })
  const view = render(<SettingsApplyProgress />)
  let task!: Promise<void>
  act(() => { task = runSettingsApply(async update => {
    update({ stage: 'stopping', message: 'Stopping the battlegroup…' })
    await gate
    update({ stage: 'saving', message: 'Battlegroup stopped. Saving reviewed settings…' })
  }) })
  live.status = { bg: { state: 'stopped', observedAt: new Date().toISOString(), gameServers: [] } } as unknown as StatusSnapshot
  view.rerender(<SettingsApplyProgress />)
  expect(screen.getByRole('status')).toHaveTextContent('Battlegroup stopped. Preparing to save')
  await act(async () => { finish(); await task })
  expect(screen.getByRole('status')).toHaveTextContent('Saving reviewed settings')
})

it('tracks startup through game readiness after the start request returns and ignores old readiness', async () => {
  const view = render(<SettingsApplyProgress />)
  await act(async () => { await runSettingsApply(async update => {
    update({ stage: 'starting', message: 'Settings saved. Applying configuration and starting the battlegroup…' })
  }) })
  const observed = (ready: string, age = 0) => ({ bg: {
    state: 'running', observedAt: new Date(Date.now() - age).toISOString(),
    gameServers: [{ map: 'Survival_1', ready }, { map: 'DeepDesert_1', ready: 'true' }],
  } }) as unknown as StatusSnapshot
  live.status = observed('true', 60_000)
  view.rerender(<SettingsApplyProgress />)
  expect(screen.getByRole('status')).toHaveTextContent('Applying configuration')
  live.status = observed('false')
  view.rerender(<SettingsApplyProgress />)
  expect(screen.getByRole('status')).toHaveTextContent('Battlegroup starting; waiting for game servers')
  live.status = observed('true')
  view.rerender(<SettingsApplyProgress />)
  expect(screen.getByRole('status')).toHaveTextContent('Reviewed settings applied. Battlegroup ready.')
})

it('never replaces a failed start with a healthy status message', async () => {
  await act(async () => { await runSettingsApply(async update => {
    update({ stage: 'starting', message: 'Starting…' })
    throw new Error('Start failed.')
  }) })
  live.status = { bg: { state: 'running', observedAt: new Date().toISOString(), gameServers: [{ ready: 'true' }] } } as unknown as StatusSnapshot
  render(<SettingsApplyProgress />)
  expect(screen.getByRole('alert')).toHaveTextContent('Start failed.')
})
