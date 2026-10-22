import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { SettingsApplyProgress } from '../src/components/SettingsApplyProgress'
import { clearSettingsApplyResult, runSettingsApply } from '../src/hooks/useSettingsApplyOperation'

beforeEach(() => { clearSettingsApplyResult() })
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
