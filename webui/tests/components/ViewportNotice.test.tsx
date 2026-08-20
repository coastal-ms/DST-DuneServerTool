import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { ViewportNotice } from '../../src/components/ViewportNotice'

describe('ViewportNotice', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('renders through the document body and can be dismissed', async () => {
    const dismiss = vi.fn()
    const user = userEvent.setup()

    render(<ViewportNotice kind="ok" text="Settings saved." onDismiss={dismiss} />)

    expect(screen.getByRole('status')).toHaveTextContent('Settings saved.')
    await user.click(screen.getByRole('button', { name: 'Dismiss notification' }))
    expect(dismiss).toHaveBeenCalledOnce()
  })

  it('automatically dismisses successful notices after six seconds', () => {
    vi.useFakeTimers()
    const dismiss = vi.fn()

    render(<ViewportNotice kind="ok" text="Settings saved." onDismiss={dismiss} />)
    vi.advanceTimersByTime(5_999)
    expect(dismiss).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)
    expect(dismiss).toHaveBeenCalledOnce()
  })

  it('keeps errors visible until explicitly dismissed', () => {
    vi.useFakeTimers()
    const dismiss = vi.fn()

    render(<ViewportNotice kind="err" text="Save failed." onDismiss={dismiss} />)
    vi.advanceTimersByTime(60_000)
    expect(screen.getByRole('alert')).toHaveTextContent('Save failed.')
    expect(dismiss).not.toHaveBeenCalled()
  })
})
